#!/usr/bin/env bats
# install-zig.bats — unit tests for the zig installer in
# scripts/install/deps.sh.
#
# zig backs cargo-zigbuild cross-compilation (Linux-only in the harness's
# dependency sets). On Linux the installer resolves BOTH the tarball URL and
# its sha256 from ziglang.org/download/index.json — never hand-assembling the
# asset name, because ziglang.org's naming scheme is not stable across
# releases (`zig-linux-x86_64-0.13.0` flipped to `zig-x86_64-linux-0.14.1`
# and later). macOS uses brew and Windows uses choco.
#
# Stubs curl, sha256sum, sudo, brew, and choco so no network or root is
# needed; jq runs for real against a stub-served fake index.json. The fake
# index deliberately serves a NONSTANDARD tarball filename so the tests prove
# the URL is derived from the index, not reconstructed locally. Covers:
#
#   1. Linux x64  → index.json fetched, index-provided URL downloaded, sha
#      verified, extracted to /opt/zig, symlinked into /usr/local/bin
#   2. Linux arm64 → the aarch64-linux index key is used
#   3. ZIG_VERSION override → that version's index entry is used
#   4. version absent from index.json → loud abort, no tarball fetch/extract
#   5. sha mismatch → abort before extraction
#   6. macOS → brew; Windows → choco
#   7. ZIG_DEFAULT_VERSION floor: >= 0.15.0 (zig <= 0.13.0 shipped a libc
#      tree missing generic-freebsd/assert.h, breaking every C-crypto crate
#      cross-built to x86_64-unknown-freebsd; 0.15+ verified to ship it)

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
    SHA_LOG="${_TEST_HOME}/sha256sum.log"
    export SHA_LOG

    # ── Stub: curl — log the request; serve a fake index.json (built by
    #    _fake_index below) for the index URL, placeholder bytes otherwise. ──
    export ZIG_FAKE_INDEX="${_TEST_HOME}/fake-index.json"
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
    *ziglang.org/download/index.json)
        [ -n "\$out" ] && cat "\${ZIG_FAKE_INDEX}" > "\$out"
        ;;
    *)
        [ -n "\$out" ] && printf 'zig-bin' > "\$out"
        ;;
esac
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum -c reads "HASH  FILE" from stdin, logs its argv, and
    #    returns 0 — unless SHA_FAIL is set, simulating a checksum mismatch
    #    (exit 1) so the install_zig sha gate can be proven to abort. ──────
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
    #    untouched while still proving the extract + symlink happened. ──
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SUDO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: brew / choco — record the invocation to a log AND echo it.
    #    The installer wraps these in anodizer::run_quiet, which swallows
    #    stdout on success, so assert on the log file. ──
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
}

teardown() {
    common_teardown
}

# Build the fake index.json serving version $1: both Linux arches, shasum
# "feedface", and a deliberately NONSTANDARD tarball filename
# (`zig-INDEXNAME-<arch>-<ver>.tar.xz`) no local reconstruction would produce
# — fetching it proves the URL came from the index.
_fake_index() {
    local v="$1"
    cat > "$ZIG_FAKE_INDEX" <<EOF
{
  "$v": {
    "x86_64-linux": {
      "tarball": "https://ziglang.org/download/$v/zig-INDEXNAME-x86_64-$v.tar.xz",
      "shasum": "feedface"
    },
    "aarch64-linux": {
      "tarball": "https://ziglang.org/download/$v/zig-INDEXNAME-aarch64-$v.tar.xz",
      "shasum": "feedface"
    }
  }
}
EOF
}

# Echo the ZIG_DEFAULT_VERSION pin from deps.sh (source-safe).
_default_version() {
    env GITHUB_ACTION_PATH="${REPO_ROOT}" RUNNER_OS="Linux" NO_COLOR=1 \
        bash -c "source '${REPO_ROOT}/scripts/install/deps.sh'; echo \"\$ZIG_DEFAULT_VERSION\""
}

# Source deps.sh (source-safe) and call install_zig directly.
_run_install_zig() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_ENV="${GITHUB_ENV}" \
        CURL_LOG="${CURL_LOG}" \
        SUDO_LOG="${SUDO_LOG}" \
        SHA_LOG="${SHA_LOG}" \
        BREW_LOG="${BREW_LOG}" \
        CHOCO_LOG="${CHOCO_LOG}" \
        ZIG_FAKE_INDEX="${ZIG_FAKE_INDEX}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            install_zig
        "
}

# ── Test 1: Linux x64 → index-derived URL + sha gate + /opt extract ─────────

@test "zig: Linux x64 fetches index.json, downloads the index-provided URL, verifies, extracts" {
    local v; v="$(_default_version)"
    _fake_index "$v"
    _run_install_zig RUNNER_OS="Linux" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    # index.json was fetched first.
    grep -q 'ziglang.org/download/index.json' "$CURL_LOG"
    # The tarball URL is the index's (nonstandard marker name), NOT a locally
    # reconstructed zig-<os>-<arch> or zig-<arch>-<os> name.
    grep -q "zig-INDEXNAME-x86_64-$v.tar.xz" "$CURL_LOG"
    # The sha gate ran against the downloaded tarball with the index's shasum.
    # Staged under RUNNER_TEMP, not a fixed world-writable /tmp: the tarball
    # is read back by `sudo tar` after this gate.
    grep -q -- "-c - | feedface  ${RUNNER_TEMP}/zig.tar.xz" "$SHA_LOG"
    # Extracted to /opt/zig with --strip-components=1, symlinked into PATH.
    grep -q 'mkdir -p /opt/zig' "$SUDO_LOG"
    grep -q -- '-C /opt/zig --strip-components=1' "$SUDO_LOG"
    grep -q 'ln -sf /opt/zig/zig /usr/local/bin/zig' "$SUDO_LOG"
}

# ── Test 2: Linux arm64 → aarch64-linux index key ───────────────────────────

@test "zig: Linux arm64 uses the aarch64-linux index entry" {
    local v; v="$(_default_version)"
    _fake_index "$v"
    _run_install_zig RUNNER_OS="Linux" RUNNER_ARCH="ARM64"
    [ "$status" -eq 0 ]
    grep -q "zig-INDEXNAME-aarch64-$v.tar.xz" "$CURL_LOG"
    ! grep -q "zig-INDEXNAME-x86_64" "$CURL_LOG"
}

# ── Test 3: ZIG_VERSION override flows into the index lookup ────────────────

@test "zig: ZIG_VERSION override selects that version's index entry" {
    _fake_index "0.14.1"
    _run_install_zig RUNNER_OS="Linux" RUNNER_ARCH="X64" ZIG_VERSION="0.14.1"
    [ "$status" -eq 0 ]
    grep -q 'zig-INDEXNAME-x86_64-0.14.1.tar.xz' "$CURL_LOG"
}

# ── Test 4: version absent from index.json → loud abort, nothing fetched ────

@test "zig: a version missing from index.json aborts loudly before any download" {
    # Index only knows some other version; the requested one is absent.
    _fake_index "0.14.1"
    _run_install_zig RUNNER_OS="Linux" RUNNER_ARCH="X64" ZIG_VERSION="9.9.9"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zig 9.9.9 has no x86_64-linux entry"* ]]
    # No tarball download was attempted (only the index fetch).
    ! grep -q 'tar.xz' "$CURL_LOG"
    # No extraction reached sudo.
    if [ -f "$SUDO_LOG" ]; then
        ! grep -q '/opt/zig' "$SUDO_LOG"
    fi
}

# ── Test 5: sha mismatch → abort before extraction ──────────────────────────

@test "zig: a checksum mismatch aborts non-zero and never extracts" {
    local v; v="$(_default_version)"
    _fake_index "$v"
    _run_install_zig RUNNER_OS="Linux" RUNNER_ARCH="X64" SHA_FAIL=1
    [ "$status" -ne 0 ]
    # The gate ran (proving the failure is the gate's, not an unrelated abort).
    grep -q -- '-c -' "$SHA_LOG"
    if [ -f "$SUDO_LOG" ]; then
        ! grep -q 'tar' "$SUDO_LOG"
        ! grep -q '/opt/zig' "$SUDO_LOG"
        ! grep -q 'ln -sf' "$SUDO_LOG"
    fi
}

# ── Test 6: macOS → brew; Windows → choco ───────────────────────────────────

@test "zig: macOS installs via brew" {
    _run_install_zig RUNNER_OS="macOS" RUNNER_ARCH="ARM64"
    [ "$status" -eq 0 ]
    grep -q "brew install zig" "$BREW_LOG"
}

@test "zig: Windows installs via choco" {
    _run_install_zig RUNNER_OS="Windows" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    grep -q "choco install zig" "$CHOCO_LOG"
}

# ── Test 7: default pin floor — freebsd libc headers require zig >= 0.15 ────

@test "zig: ZIG_DEFAULT_VERSION is at least 0.15.0 (freebsd assert.h floor)" {
    local v; v="$(_default_version)"
    # sort -V: the floor must not sort AFTER the pin.
    [ "$(printf '0.15.0\n%s\n' "$v" | sort -V | head -1)" = "0.15.0" ]
}
