#!/usr/bin/env bats
# install-cosign-verify.bats — unit tests for cosign keyless-signature
# verification behaviour in scripts/install/deps.sh.
#
# These tests stub out curl, sudo, install, cosign, and every checksum/decoder
# tool the install path can reach — sha256sum + base64 (Linux) and shasum +
# openssl (macOS) — plus uname (macOS arch detection) and brew, so no network
# or elevated privileges are required.
#
# Linux outcomes (tests 1–5):
#   1. cosign verify-blob succeeds          → install proceeds, exits 0
#   2. cosign verify-blob fails             → loud error + exit non-zero
#   3. ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1 → SHA-256-only warning, exits 0
#   4. correct keyless identity/issuer flags are passed to cosign
#   5. COSIGN_KEY/COSIGN_PUB_KEY stripped from the verify-blob env
#
# macOS outcomes (tests 6–10): the macOS arm must download the pinned cosign
# directly (never via Homebrew) and use the BSD-correct tools rather than the
# Linux ones:
#   6. arm64 fetches cosign-darwin-arm64, no brew, AND proves the BSD tools
#      (shasum + openssl) ran while the Linux tools (sha256sum + base64) did not
#   7. x86_64 fetches cosign-darwin-amd64
#   8. keyless verify-blob uses the correct GCP identity / Google OIDC issuer
#   9. ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1 → SHA-256-only, verify-blob not run
#  10. unsupported arch fails loudly with no download and no brew
#
# The macOS/Linux tool stubs each append the tool name to a per-platform marker
# file (macos_tools_called / linux_tools_called), cleared per test in setup, so
# test 6 can assert the macOS arm exercises the BSD contract and never falls
# through to the GNU tools.

load test_helper

setup() {
    common_setup

    # Fake bin dir — all stubs live here and are first on PATH.
    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # Per-platform tool markers: each checksum/decoder stub appends its name
    # here so a test can assert which tool family actually ran. Cleared per
    # test (a fresh _TEST_HOME each run already guarantees this, but be
    # explicit so an in-test re-source can't see stale bleed).
    MACOS_TOOLS_FILE="${_TEST_HOME}/macos_tools_called"
    LINUX_TOOLS_FILE="${_TEST_HOME}/linux_tools_called"
    rm -f "${MACOS_TOOLS_FILE}" "${LINUX_TOOLS_FILE}"

    # ── Stub: curl ───────────────────────────────────────────────────────
    CURL_URLS_FILE="${_TEST_HOME}/curl_urls"
    cat > "${FAKE_BIN}/curl" <<STUB
#!/usr/bin/env bash
# Capture -o <file> and write deterministic placeholder content; record every
# requested URL so tests can assert which release asset was fetched.
out=""
for arg; do
    case "\$prev" in -o) out="\$arg" ;; esac
    case "\$arg" in http*) echo "\$arg" >> "${CURL_URLS_FILE}" ;; esac
    prev="\$arg"
done
if [ -n "\$out" ]; then
    case "\$out" in
        *cosign_checksums.txt)
            # A fixed placeholder hash — the -c/shasum stubs echo OK without
            # comparing, so the value is cosmetic. Hardcoded (not piped through
            # sha256sum) so this stub never touches the per-platform tool
            # markers. Emit a line per platform asset so sha_from_checksums
            # resolves on Linux + macOS.
            h="0000000000000000000000000000000000000000000000000000000000000000"
            {
                printf '%s  cosign-linux-amd64\n'  "\$h"
                printf '%s  cosign-darwin-arm64\n' "\$h"
                printf '%s  cosign-darwin-amd64\n' "\$h"
            } > "\$out"
            ;;
        *) printf 'fakebinary' > "\$out" ;;
    esac
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum (Linux checksum tool) ────────────────────────────
    # When called with -c it reads "HASH  FILE" from stdin and returns 0.
    # Records itself in the Linux-tools marker so a macOS test can prove it
    # did NOT fall through to the GNU checker.
    cat > "${FAKE_BIN}/sha256sum" <<STUB
#!/usr/bin/env bash
echo sha256sum >> "${LINUX_TOOLS_FILE}"
if [[ "\$*" == *"-c"* ]]; then
    read -r line
    echo "\${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/sha256sum"

    # ── Stub: base64 (Linux pem/sig decoder) ─────────────────────────────
    # The Linux arm decodes the keyless pem/sig with `base64 -d`. Pass stdin
    # through so the pipeline + pipefail contract is exercised, and record the
    # call so a macOS test can prove the BSD decoder ran instead.
    cat > "${FAKE_BIN}/base64" <<STUB
#!/usr/bin/env bash
echo base64 >> "${LINUX_TOOLS_FILE}"
if [[ "\$*" == *"-d"* ]]; then
    cat
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/base64"

    # ── Stub: sudo ───────────────────────────────────────────────────────
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: install (coreutils) ────────────────────────────────────────
    # `sudo install /tmp/cosign /usr/local/bin/cosign` — redirect to fake dir.
    FAKE_USR="${_TEST_HOME}/usr-local-bin"
    mkdir -p "$FAKE_USR"
    cat > "${FAKE_BIN}/install" <<STUB
#!/usr/bin/env bash
# Last two non-flag args are src and dst.
args=()
for a; do [[ "\$a" != -* ]] && args+=("\$a"); done
src="\${args[-2]}"
dst="${FAKE_USR}/\$(basename "\${args[-1]}")"
cp "\$src" "\$dst" 2>/dev/null || true
exit 0
STUB
    chmod +x "${FAKE_BIN}/install"

    # ── Stub: shasum (macOS checksum tool) ───────────────────────────────
    # `shasum -a 256 -c -` reads "HASH  FILE" from stdin and returns 0.
    # Records itself in the macOS-tools marker so test 6 can prove the BSD
    # checker ran (and the GNU sha256sum did not).
    cat > "${FAKE_BIN}/shasum" <<STUB
#!/usr/bin/env bash
echo shasum >> "${MACOS_TOOLS_FILE}"
if [[ "\$*" == *"-c"* ]]; then
    read -r line
    echo "\${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/shasum"

    # ── Stub: openssl (macOS base64 decoder) ─────────────────────────────
    # The macOS arm decodes the keyless pem/sig with `openssl base64 -d -A`.
    # Pass stdin through so the pipeline + pipefail contract is exercised.
    # Records itself in the macOS-tools marker so test 6 can prove the BSD
    # decoder ran (and the GNU base64 did not).
    cat > "${FAKE_BIN}/openssl" <<STUB
#!/usr/bin/env bash
echo openssl >> "${MACOS_TOOLS_FILE}"
if [[ "\$*" == *"base64"* ]]; then
    cat
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/openssl"

    # ── Stub: uname (macOS arch detection) ───────────────────────────────
    # Reports the arch named by ${STUB_UNAME_M:-arm64} for `uname -m`.
    cat > "${FAKE_BIN}/uname" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"-m"* ]]; then
    echo "\${STUB_UNAME_M:-arm64}"
    exit 0
fi
exec /usr/bin/uname "\$@"
STUB
    chmod +x "${FAKE_BIN}/uname"

    # ── Stub: brew — records every invocation so tests assert it is NOT
    # called for cosign on macOS (direct download must bypass Homebrew). ──
    BREW_CALLED_FILE="${_TEST_HOME}/brew_called"
    cat > "${FAKE_BIN}/brew" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "${BREW_CALLED_FILE}"
exit 0
STUB
    chmod +x "${FAKE_BIN}/brew"
}

teardown() {
    common_teardown
}

# Shared invocation wrapper. Sources scripts/install/deps.sh (which is
# source-safe — its `main "$@"` is gated on direct execution) so every
# installer helper is in scope, then calls `install_cosign` directly.
# brew_install / choco_install are stubbed since this file only exercises
# the Linux branch.
_run_install_cosign() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install()  { :; }
            choco_install() { :; }
            install_cosign
        "
}

# macOS invocation wrapper. Unlike the Linux wrapper, brew_install is NOT
# stubbed away — the macOS arm must reach cosign via direct download and never
# touch Homebrew, so the brew stub on PATH stays the real arbiter of that
# assertion. STUB_UNAME_M selects the arch the uname stub reports.
_run_install_cosign_macos() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="macOS" \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install()  { :; }
            choco_install() { :; }
            install_cosign
        "
}

# ── Test 1: verify-blob succeeds → exits 0 ──────────────────────────────

@test "cosign: verify-blob success -> install exits 0" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign
    [ "$status" -eq 0 ]

    # GNU-tool contract: the Linux arm verifies with `sha256sum -c -` and
    # decodes with `base64 -d` — BOTH must have run — and never reaches for
    # the BSD tools (shasum / openssl).
    [ -f "${LINUX_TOOLS_FILE}" ]
    grep -q '^sha256sum$' "${LINUX_TOOLS_FILE}"
    grep -q '^base64$'    "${LINUX_TOOLS_FILE}"
    [ ! -f "${MACOS_TOOLS_FILE}" ]
}

# ── Test 2: verify-blob fails → loud error + non-zero exit ──────────────

@test "cosign: verify-blob failure -> exits non-zero with error message" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"verify-blob"* ]]; then
    echo "Error: exactly one of --key/--cert/--sk required" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign
    [ "$status" -ne 0 ]
    # Must emit the loud-fail message verbatim. The bytes are stable in
    # both NO_COLOR=1 (current test) and ANSI-on modes because gha_fail
    # inserts color escapes around the leading glyph only.
    [[ "$output" == *"cosign keyless signature verification FAILED"* ]]
    # Must NOT treat the SHA256 hash-check as a substitute for sig verify.
    [[ "$output" != *"SHA256 already verified"* ]]
}

# ── Test 3: ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1 → SHA-256-only, exits 0

@test "cosign: SKIP_COSIGN_VERIFY=1 -> warns + exits 0, verify-blob not called" {
    verify_called_file="${_TEST_HOME}/verify_called"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"verify-blob"* ]]; then
    touch "${verify_called_file}"
    echo "Error: should not be called" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1
    [ "$status" -eq 0 ]
    [ ! -f "${verify_called_file}" ]
    [[ "$output" == *"skipped"* ]] || [[ "$output" == *"skip"* ]] || [[ "$output" == *"SHA256-only"* ]]
}

# ── Test 4: correct keyless flags passed to cosign ──────────────────────

@test "cosign: verify-blob uses correct GCP service-account identity and Google OIDC issuer" {
    invocation_file="${_TEST_HOME}/cosign_args"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
echo "\$@" > "${invocation_file}"
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign
    [ "$status" -eq 0 ]

    invocation="$(cat "${invocation_file}")"
    [[ "$invocation" == *"keyless@projectsigstore.iam.gserviceaccount.com"* ]]
    [[ "$invocation" == *"https://accounts.google.com"* ]]
    [[ "$invocation" != *"token.actions.githubusercontent.com"* ]]
}

# ── Test 5: COSIGN_KEY in caller env must be stripped from verify-blob ──
#
# Regression guard: when the caller (anodizer's release workflow) sets
# COSIGN_KEY at step level for the downstream sign stage, cosign's PEM
# verify-blob would otherwise see both KeyRef (from env) and CertRef
# (from --certificate flag) and bail with PubKeyParseError. The
# `env -u COSIGN_KEY` prefix in cosign_install_linux must strip the key
# before cosign sees it.

@test "cosign: COSIGN_KEY in caller env is stripped before verify-blob runs" {
    env_capture_file="${_TEST_HOME}/cosign_env"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"verify-blob"* ]]; then
    env > "${env_capture_file}"
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign COSIGN_KEY="fake-key-reference" COSIGN_PUB_KEY="fake-pub-key"
    [ "$status" -eq 0 ]

    [ -f "${env_capture_file}" ]
    ! grep -q '^COSIGN_KEY=' "${env_capture_file}"
    ! grep -q '^COSIGN_PUB_KEY=' "${env_capture_file}"
}

# ── Test 6: macOS arm64 fetches the darwin-arm64 asset via direct download
#            and never invokes Homebrew (the version-pin-bypass bug guard) ──
#
# Regression guard: routing macOS through `brew_install cosign` installed the
# LATEST cosign (2.6+), which errors on `--tlog-upload=false` and broke the
# determinism harness's offline sign-blob. The macOS arm must download the
# pinned cosign directly, like the Linux/Windows arms.

@test "cosign: macOS arm64 fetches cosign-darwin-arm64 and does not call brew" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign_macos STUB_UNAME_M=arm64
    [ "$status" -eq 0 ]

    # The darwin-arm64 release binary was requested...
    grep -q 'cosign/releases/download/.*/cosign-darwin-arm64$' "${CURL_URLS_FILE}"
    # ...and never the linux/amd64 asset. An explicit if/fail (not a bare
    # `! grep`, which bats does not let fail a test mid-body) so a wrong-asset
    # fetch is caught.
    if grep -q 'cosign-linux-amd64' "${CURL_URLS_FILE}"; then false; fi
    # Homebrew was never touched for cosign.
    [ ! -f "${BREW_CALLED_FILE}" ]

    # BSD-tool contract: the macOS arm must verify with the BSD checker
    # (`shasum -a 256 -c -`) and the cross-platform decoder (`openssl base64
    # -d -A`) — BOTH must have run.
    [ -f "${MACOS_TOOLS_FILE}" ]
    grep -q '^shasum$'  "${MACOS_TOOLS_FILE}"
    grep -q '^openssl$' "${MACOS_TOOLS_FILE}"
    # ...and it must NOT have fallen through to the GNU tools (`sha256sum -c -`
    # / `base64 -d`). If a regression swaps the macOS decoder/checker back to
    # the Linux ones, those stubs would record here and this catches it.
    if [ -f "${LINUX_TOOLS_FILE}" ]; then
        if grep -q '^sha256sum$' "${LINUX_TOOLS_FILE}"; then false; fi
        if grep -q '^base64$'    "${LINUX_TOOLS_FILE}"; then false; fi
    fi
}

# ── Test 7: macOS x86_64 fetches the darwin-amd64 asset ─────────────────────

@test "cosign: macOS x86_64 fetches cosign-darwin-amd64" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign_macos STUB_UNAME_M=x86_64
    [ "$status" -eq 0 ]

    grep -q 'cosign/releases/download/.*/cosign-darwin-amd64$' "${CURL_URLS_FILE}"
    [ ! -f "${BREW_CALLED_FILE}" ]
}

# ── Test 8: macOS exercises keyless verify-blob with the correct identity ──

@test "cosign: macOS verify-blob uses GCP identity + Google OIDC issuer" {
    invocation_file="${_TEST_HOME}/cosign_args"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"verify-blob"* ]]; then
    echo "\$@" > "${invocation_file}"
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign_macos STUB_UNAME_M=arm64
    [ "$status" -eq 0 ]

    [ -f "${invocation_file}" ]
    invocation="$(cat "${invocation_file}")"
    [[ "$invocation" == *"keyless@projectsigstore.iam.gserviceaccount.com"* ]]
    [[ "$invocation" == *"https://accounts.google.com"* ]]
    [ ! -f "${BREW_CALLED_FILE}" ]
}

# ── Test 9: macOS SKIP_COSIGN_VERIFY=1 → SHA-256-only, verify-blob not run ──

@test "cosign: macOS SKIP_COSIGN_VERIFY=1 -> warns, verify-blob not called, no brew" {
    verify_called_file="${_TEST_HOME}/verify_called"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"verify-blob"* ]]; then
    touch "${verify_called_file}"
    echo "Error: should not be called" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign_macos STUB_UNAME_M=arm64 ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1
    [ "$status" -eq 0 ]
    [ ! -f "${verify_called_file}" ]
    [[ "$output" == *"skipped"* ]] || [[ "$output" == *"skip"* ]] || [[ "$output" == *"SHA256-only"* ]]
    [ ! -f "${BREW_CALLED_FILE}" ]
}

# ── Test 10: macOS unsupported arch fails loudly ────────────────────────────

@test "cosign: macOS unsupported arch -> loud fail, no download, no brew" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    _run_install_cosign_macos STUB_UNAME_M=ppc64
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsupported macOS arch for cosign"* ]]
    [ ! -f "${BREW_CALLED_FILE}" ]
}

# ── Test 11: RUNNER_TEMP is the staging dir, whatever its spelling ──────
# GitHub runners always set RUNNER_TEMP, and on Windows it is a backslash
# path; the install must stage under it even when the spelling needs
# quoting inside a `bash -c` string. A directory name with a space pins the
# quoting on every platform; the Windows leg additionally exercises the
# cygpath conversion through the runner's real RUNNER_TEMP.
@test "cosign: staged files land under RUNNER_TEMP even when its path needs quoting" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"
    local stage="${_TEST_HOME}/stage dir"
    mkdir -p "$stage"

    _run_install_cosign RUNNER_TEMP="$stage"

    [ "$status" -eq 0 ]
    [ -f "${stage}/cosign" ]
    [ -f "${stage}/cosign.pem" ]
    [ -f "${stage}/cosign.sig" ]
    [ -f "${stage}/cosign_checksums.txt" ]
}
