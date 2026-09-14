#!/usr/bin/env bats
# install-ruby.bats — unit tests for the ruby installer in
# scripts/install/deps.sh.
#
# ruby backs anodizer's homebrew prepublish guard, which runs `ruby -c` over
# the generated formula and cask when the interpreter is present. Linux gets
# the distro ruby apt package; macOS ships /usr/bin/ruby with the OS (no
# install); Windows is skipped (the tap push is plain git — the validating
# runner in practice is Linux).
#
# Stubs apt-get so no network is needed. Covers:
#
#   1. Linux → queues the ruby apt package, exits 0
#   2. macOS → no-op (ships with the OS), no package manager touched, exits 0
#   3. Windows → skipped, exits 0
#
# The binary→keyword translation (anodizer reporting `ruby`) is covered by
# auto-detect-deps.bats.

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    # ── Stub: sudo / apt-get — apt_flush's batched update+install runs
    #    hermetically (no real package manager, no network). apt-get records
    #    its argv so the test can assert the PACKAGE the batch installs. ──
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"
    export APT_LOG="${_TEST_HOME}/apt.log"
    cat > "${FAKE_BIN}/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$APT_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/apt-get"

    # Keep run_quiet's capture file inside the sandbox.
    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe) and call install_ruby directly, then
# apt_flush so queued apt packages surface in the output. skip_unsupported_os
# is stubbed so the Windows arm can be exercised without its real side-effects.
_run_install_ruby() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        APT_LOG="${APT_LOG}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_ruby
            apt_flush
        "
}

# ── Test 1: Linux → queues the ruby apt package ──

@test "ruby: Linux queues the ruby apt package, exits 0" {
    # The per-package ✓ on flush is a verbose-only line; run under verbose so it
    # surfaces for the assertion.
    _run_install_ruby RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    # ruby rides the single batched apt install — one batch header plus a
    # per-package ✓ on flush, NOT a per-tool "queued"/"installing" line.
    [[ "$output" == *"installing apt batch: ruby"* ]]
    [[ "$output" == *"ruby installed"* ]]
    # The installed PACKAGE is ruby.
    grep -q "install .*ruby" "$APT_LOG"
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 2: macOS ships /usr/bin/ruby with the OS — nothing to install ──

@test "ruby: macOS is a no-op (ships with the OS), touches no package manager, exits 0" {
    _run_install_ruby RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [ ! -f "$APT_LOG" ]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 3: Windows is skipped (tap push is plain git; no ruby needed) ──

@test "ruby: Windows is skipped, exits 0" {
    _run_install_ruby RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [ ! -f "$APT_LOG" ]
}
