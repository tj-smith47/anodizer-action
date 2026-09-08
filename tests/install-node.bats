#!/usr/bin/env bats
# install-node.bats — unit tests for the node installer in
# scripts/install/deps.sh.
#
# node/npm back anodizer's `npms:` publisher, which publishes the npm
# metapackage via npm Trusted Publishing (OIDC) — a handshake needing
# Node >= 22.14.0 / npm >= 11.5.1. On Linux it installs via a direct,
# SHASUMS256.txt-verified nodejs.org download (mirroring install_zig's
# index.json fetch) so no sha is hardcoded; macOS uses brew and Windows
# uses choco (chocolatey package id `nodejs`).
#
# Stubs curl, sha256sum, sudo, tar, ln, brew, and choco so no network or
# root is needed. The sudo stub records argv (it does NOT exec) so the
# /opt/node extract + /usr/local/bin symlinks are asserted from the log
# rather than written to the real filesystem. Covers:
#
#   1. Linux x64   → tarball + SHASUMS256.txt fetched, sha verified, extracted
#      to /opt/node, node+npm+npx symlinked into /usr/local/bin, exits 0
#   2. Linux arm64 → Node's arm64 asset name is used (not aarch64)
#   3. NODE_VERSION override → forwarded into the download URL + tarball name
#   4. macOS  → node via brew
#   5. Windows → choco install nodejs
#   6. npm floor: every install_node path upgrades npm to >= 11.5.1 via
#      `npm install -g npm@$NPM_VERSION` (the npm node bundles is below the
#      Trusted-Publishing OIDC floor), with NPM_VERSION honoured as an override

load test_helper

setup() {
    common_setup

    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_ENV="${_TEST_HOME}/github_env"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_ENV"
    : > "$GITHUB_OUTPUT"

    CURL_LOG="${_TEST_HOME}/curl.log"
    export CURL_LOG
    SUDO_LOG="${_TEST_HOME}/sudo.log"
    export SUDO_LOG

    # ── Stub: curl — log the request, write a deterministic SHASUMS256.txt
    #    (matching whatever tarball is expected) or placeholder bytes. ──
    cat > "${FAKE_BIN}/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${CURL_LOG}"
out="" url=""
for arg; do
    case "\$prev" in -o) out="\$arg" ;; esac
    case "\$arg" in https://*) url="\$arg" ;; esac
    prev="\$arg"
done
case "\$url" in
    *SHASUMS256.txt)
        # The installer greps for "<sha>  <tarball>"; emit a line whose
        # filename matches the expected asset for this version/arch (plus a
        # decoy line to prove the grep is filename-anchored).
        printf 'deadbeef  some-other-file.tar.xz\nfeedface  %s\n' "\${NODE_EXPECT_TARBALL}"
        ;;
    *)
        [ -n "\$out" ] && printf 'node-bin' > "\$out"
        ;;
esac
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    SHA_LOG="${_TEST_HOME}/sha256sum.log"
    export SHA_LOG

    # ── Stub: sha256sum -c reads "HASH  FILE" from stdin, logs its argv, and
    #    returns 0 — unless SHA_FAIL is set, simulating a checksum mismatch
    #    (exit 1) so the install_node sha gate can be proven to abort. ──────
    cat > "${FAKE_BIN}/sha256sum" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-c"* ]]; then
    read -r line
    echo "$* | ${line}" >> "$SHA_LOG"
    if [ -n "${SHA_FAIL:-}" ]; then
        echo "${line##* }": FAILED
        exit 1
    fi
    echo "${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/sha256sum"

    # ── Stub: sudo — record argv, succeed. The Linux installer runs
    #    `sudo mkdir/tar/ln`; logging (not exec) keeps /opt + /usr/local/bin
    #    untouched while still proving the extract + symlinks happened. ──
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SUDO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: brew / choco — record the invocation to a log AND echo it.
    #    The installer wraps these in anodizer::run_quiet, which swallows
    #    stdout on success, so assert on the log file (a side-effect
    #    run_quiet cannot suppress), not on captured output. ──
    export BREW_LOG="${_TEST_HOME}/brew.log"
    export CHOCO_LOG="${_TEST_HOME}/choco.log"
    cat > "${FAKE_BIN}/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$BREW_LOG"
echo "brew $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/brew"
    cat > "${FAKE_BIN}/choco" <<'STUB'
#!/usr/bin/env bash
echo "choco $*" >> "$CHOCO_LOG"
echo "choco $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/choco"

    # ── Stub: npm — record argv (the post-node `npm install -g npm@<ver>`
    #    floor upgrade) and succeed. On Linux the upgrade runs under sudo, so
    #    the sudo stub captures that argv; the npm stub itself fires on the
    #    macOS/Windows paths (and is harmless on Linux). ──
    export NPM_LOG="${_TEST_HOME}/npm.log"
    cat > "${FAKE_BIN}/npm" <<'STUB'
#!/usr/bin/env bash
echo "npm $*" >> "$NPM_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/npm"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe) and call install_node directly.
_run_install_node() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_ENV="${GITHUB_ENV}" \
        CURL_LOG="${CURL_LOG}" \
        SUDO_LOG="${SUDO_LOG}" \
        SHA_LOG="${SHA_LOG}" \
        BREW_LOG="${BREW_LOG}" \
        CHOCO_LOG="${CHOCO_LOG}" \
        NPM_LOG="${NPM_LOG}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            install_node
        "
}

# ── Test 1: Linux x64 → download + checksum verify + /opt extract + symlinks ─

@test "node: Linux x64 downloads + SHASUMS-verifies + extracts to /opt/node + symlinks" {
    _run_install_node RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        NODE_EXPECT_TARBALL="node-v22.22.3-linux-x64.tar.xz"
    [ "$status" -eq 0 ]
    # The pinned-version x64 tarball + the release SHASUMS256.txt were fetched.
    grep -q 'node-v22.22.3-linux-x64.tar.xz' "$CURL_LOG"
    grep -q 'SHASUMS256.txt' "$CURL_LOG"
    # The sha gate actually ran: `sha256sum -c -` against the downloaded tarball
    # (the path arrives on the stub's stdin, logged after the ` | ` separator).
    # Staged under RUNNER_TEMP, not a fixed world-writable /tmp.
    grep -q -- "-c - | .* ${RUNNER_TEMP}/node.tar.xz" "$SHA_LOG"
    # Extracted to /opt/node with --strip-components=1.
    grep -q 'mkdir -p /opt/node' "$SUDO_LOG"
    grep -q -- '-C /opt/node --strip-components=1' "$SUDO_LOG"
    # node, npm, and npx symlinked from /opt/node/bin into /usr/local/bin.
    grep -q 'ln -sf /opt/node/bin/node /usr/local/bin/node' "$SUDO_LOG"
    grep -q 'ln -sf /opt/node/bin/npm /usr/local/bin/npm' "$SUDO_LOG"
    grep -q 'ln -sf /opt/node/bin/npx /usr/local/bin/npx' "$SUDO_LOG"
    # The bundled npm (10.9.x on the 22.x line) is below the 11.5.1 OIDC floor,
    # so the active npm is upgraded in place. On Linux the upgrade runs under
    # sudo (the /opt/node global prefix is root-owned), so it lands in SUDO_LOG.
    grep -q 'npm install -g npm@11.5.1' "$SUDO_LOG"
    # No apt repo / apt-get is involved.
    [[ "$output" != *"apt-get"* ]]
}

# ── Test 1b: sha mismatch → abort before extraction ───────────────────────

@test "node: a checksum mismatch aborts non-zero and never extracts" {
    _run_install_node RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        NODE_EXPECT_TARBALL="node-v22.22.3-linux-x64.tar.xz" \
        SHA_FAIL=1
    # The sha gate failed, so the installer must bail non-zero.
    [ "$status" -ne 0 ]
    # The gate ran (proving the failure is the gate's, not an unrelated abort).
    grep -q -- '-c -' "$SHA_LOG"
    # Extraction + symlinks must NOT have happened: no `sudo tar`/`sudo ln`/
    # `sudo mkdir /opt/node` reached the sudo log after the failed gate. (The
    # sudo log may not exist at all if nothing was sudo'd — treat absent as
    # clean.)
    if [ -f "$SUDO_LOG" ]; then
        ! grep -q 'tar' "$SUDO_LOG"
        ! grep -q '/opt/node' "$SUDO_LOG"
        ! grep -q 'ln -sf' "$SUDO_LOG"
        # The npm floor upgrade is part of install_node and must not run after
        # the gate aborts (set -e bails before it).
        ! grep -q 'npm install' "$SUDO_LOG"
    fi
}

# ── Test 2: Linux arm64 → Node's arm64 asset name (not aarch64) ─────────────

@test "node: Linux arm64 uses the arm64 asset name (not aarch64)" {
    _run_install_node RUNNER_OS="Linux" RUNNER_ARCH="ARM64" \
        NODE_EXPECT_TARBALL="node-v22.22.3-linux-arm64.tar.xz"
    [ "$status" -eq 0 ]
    grep -q 'node-v22.22.3-linux-arm64.tar.xz' "$CURL_LOG"
    ! grep -q 'aarch64' "$CURL_LOG"
}

# ── Test 3: NODE_VERSION override flows into the URL + tarball name ─────────

@test "node: NODE_VERSION override is used for the download" {
    _run_install_node RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        NODE_VERSION="22.14.0" \
        NODE_EXPECT_TARBALL="node-v22.14.0-linux-x64.tar.xz"
    [ "$status" -eq 0 ]
    grep -q 'nodejs.org/dist/v22.14.0/' "$CURL_LOG"
    grep -q 'node-v22.14.0-linux-x64.tar.xz' "$CURL_LOG"
}

# ── Test 4: macOS → node via brew ──────────────────────────────────────────

@test "node: macOS installs via brew" {
    _run_install_node RUNNER_OS="macOS" RUNNER_ARCH="ARM64"
    [ "$status" -eq 0 ]
    grep -q "brew install node" "$BREW_LOG"
    # macOS upgrades npm to the floor without sudo (brew installs are
    # user-writable), so the npm stub fires directly.
    grep -q 'npm install -g npm@11.5.1' "$NPM_LOG"
}

# ── Test 5: Windows → choco (chocolatey package id is nodejs) ──────────────

@test "node: Windows installs via choco (nodejs)" {
    _run_install_node RUNNER_OS="Windows" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    grep -q "choco install nodejs" "$CHOCO_LOG"
    # Windows (choco) likewise upgrades npm without sudo.
    grep -q 'npm install -g npm@11.5.1' "$NPM_LOG"
}

# ── npm floor: default meets the 11.5.1 OIDC floor, override is honoured ────

@test "node: default npm floor is at least 11.5.1 (Trusted Publishing)" {
    # The default NPM_DEFAULT_VERSION pin must not regress below the documented
    # floor — a node-bundled npm (10.9.x) would silently break OIDC publishing.
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        RUNNER_OS="Linux" \
        NO_COLOR=1 \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            echo \"\$NPM_DEFAULT_VERSION\"
        "
    [ "$status" -eq 0 ]
    # Floor is 11.5.1; assert major>=11 and (major>11 OR minor>=5 reaching .1).
    local v="${output}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$v"
    [ "$major" -ge 11 ]
    # When exactly major 11, minor must be >= 5 (and at 11.5, patch >= 1).
    if [ "$major" -eq 11 ]; then
        [ "$minor" -ge 5 ]
        if [ "$minor" -eq 5 ]; then [ "$patch" -ge 1 ]; fi
    fi
}

@test "node: NPM_VERSION override flows into the npm upgrade (Linux, under sudo)" {
    _run_install_node RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        NODE_EXPECT_TARBALL="node-v22.22.3-linux-x64.tar.xz" \
        NPM_VERSION="11.9.0"
    [ "$status" -eq 0 ]
    grep -q 'npm install -g npm@11.9.0' "$SUDO_LOG"
    # The default pin must not also have fired.
    ! grep -q 'npm install -g npm@11.5.1' "$SUDO_LOG"
}

@test "node: NPM_VERSION override flows into the npm upgrade (macOS, no sudo)" {
    _run_install_node RUNNER_OS="macOS" RUNNER_ARCH="ARM64" \
        NPM_VERSION="11.9.0"
    [ "$status" -eq 0 ]
    grep -q 'npm install -g npm@11.9.0' "$NPM_LOG"
}
