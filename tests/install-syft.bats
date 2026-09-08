#!/usr/bin/env bats
# install-syft.bats — unit tests for the syft installer in
# scripts/install/deps.sh.
#
# syft produces the SBOMs anodizer's sbom stage attaches to a release. On
# Linux it delegates to upstream's install.sh, whose OWN tarball download has
# no retry: a GitHub CDN 302 fails the whole shard (cfgd Nightly run
# 30735875560). Both the fetch of install.sh and its invocation therefore run
# under fetch_retry.
#
# Stubs curl, sudo, sleep, brew, and choco so no network, no root, and no
# retry backoff are needed. Covers:
#
#   1. Linux, upstream installer flaky   -> retried until it succeeds, exit 0
#   2. Linux, upstream installer wedged  -> exits non-zero after the budget
#   3. Linux, first try succeeds         -> invoked exactly once
#   4. macOS                             -> brew
#   5. Windows                           -> choco

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    : > "$GITHUB_PATH"
    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"

    # The installer script upstream's fetch lands at, and the counter the
    # stubbed installer bumps on every invocation.
    export SYFT_INSTALLER="${_TEST_HOME}/syft-install.sh"
    export SYFT_ATTEMPTS="${_TEST_HOME}/syft-attempts"
    : > "$SYFT_ATTEMPTS"

    # Stub curl: anodizer::fetch's -o target becomes the installer script.
    # It fails for its first $SYFT_FAIL_TIMES invocations, then succeeds.
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" prev=""
for arg; do
    case "$prev" in -o) out="$arg" ;; esac
    prev="$arg"
done
[ -n "$out" ] || exit 0
cat > "$out" <<'INNER'
#!/usr/bin/env bash
n=$(( $(cat "$SYFT_ATTEMPTS" 2>/dev/null | wc -l) + 1 ))
echo "attempt $*" >> "$SYFT_ATTEMPTS"
if [ "$n" -le "${SYFT_FAIL_TIMES:-0}" ]; then
    echo "[error] received HTTP status=302 for url=..." >&2
    exit 1
fi
exit 0
INNER
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # sudo runs the command directly; the suite never has (or needs) root.
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # fetch_retry sleeps between attempts; a real backoff would add 6s per test.
    cat > "${FAKE_BIN}/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/sleep"

    export BREW_LOG="${_TEST_HOME}/brew.log"
    export CHOCO_LOG="${_TEST_HOME}/choco.log"
    cat > "${FAKE_BIN}/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$BREW_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/brew"
    cat > "${FAKE_BIN}/choco" <<'STUB'
#!/usr/bin/env bash
echo "choco $*" >> "$CHOCO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/choco"
}

teardown() {
    common_teardown
}

_run_install_syft() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        SYFT_ATTEMPTS="${SYFT_ATTEMPTS}" \
        BREW_LOG="${BREW_LOG}" \
        CHOCO_LOG="${CHOCO_LOG}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            install_syft
        "
}

# -- Test 1: the upstream installer fails twice, then succeeds ---------------

@test "syft: Linux retries the upstream installer through a transient failure" {
    _run_install_syft RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        SYFT_FAIL_TIMES=2 ANODIZER_FETCH_ATTEMPTS=3
    [ "$status" -eq 0 ]
    # Three invocations: two failures plus the one that stuck.
    [ "$(wc -l < "$SYFT_ATTEMPTS")" -eq 3 ]
}

# -- Test 2: a wedged installer still fails the step ------------------------

@test "syft: Linux surfaces a persistent upstream installer failure" {
    _run_install_syft RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        SYFT_FAIL_TIMES=99 ANODIZER_FETCH_ATTEMPTS=3
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$SYFT_ATTEMPTS")" -eq 3 ]
}

# -- Test 3: the happy path costs exactly one invocation --------------------

@test "syft: Linux invokes the upstream installer once when it succeeds" {
    _run_install_syft RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        SYFT_FAIL_TIMES=0 ANODIZER_FETCH_ATTEMPTS=3
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SYFT_ATTEMPTS")" -eq 1 ]
    # The pinned version reaches upstream's installer verbatim.
    grep -q -- '-b /usr/local/bin v1.18.0' "$SYFT_ATTEMPTS"
}

# -- Test 4/5: the non-Linux legs are package-manager installs --------------

@test "syft: macOS installs via brew" {
    _run_install_syft RUNNER_OS="macOS" RUNNER_ARCH="ARM64"
    [ "$status" -eq 0 ]
    grep -q 'syft' "$BREW_LOG"
}

@test "syft: Windows installs via choco" {
    _run_install_syft RUNNER_OS="Windows" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    grep -q 'syft' "$CHOCO_LOG"
}
