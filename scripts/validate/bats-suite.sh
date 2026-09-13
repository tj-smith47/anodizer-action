#!/usr/bin/env bash
# Run the bats suite and gate on its TAP summary.
#
# `bats tests/` on its own exits 0 when a test SKIPS. A suite that quietly
# converts a lost capability into a skip therefore reads green while covering
# less and less — the same invisibility that let 29 Windows failures and ~40
# never-executing tests sit behind a green ubuntu-only job. This wrapper pins
# the skip budget and fails when the real count moves off it in EITHER
# direction, naming every skipped test so the drift is diagnosable from the log
# alone. It also fails when bats plans more tests than it reports, which is how
# an unaddressable test name (`unknown test name`) manifests.
#
# Usage: bats-suite.sh [tests-dir]
# Env:   ANODIZER_EXPECTED_SKIPS   pinned skip budget (default 0)
set -euo pipefail

tests_dir="${1:-tests}"
expected="${ANODIZER_EXPECTED_SKIPS:-0}"

tap="$(mktemp)"
# shellcheck disable=SC2064  # expand $tap now: the path must survive the trap.
trap "rm -f '${tap}'" EXIT

# A test that creates a symlink must force a native one: MSYS `ln -s` copies
# by default, and the copy keeps the target's mtime, so a test written for a
# link passes or fails on Windows for reasons unrelated to the code under test.
if grep -rn --include='*.bats' --include='*.bash' -E '(^|[^A-Za-z_])ln -s[a-zA-Z]* ' "$tests_dir" \
    | grep -v 'winsymlinks:nativestrict' | grep -vE "^[^:]+:[0-9]+:\s*#|grep -q|SUDO_LOG"; then
    printf 'FAIL: a symlink created in a test must use MSYS=winsymlinks:nativestrict ln -s\n' >&2
    exit 1
fi

bats_rc=0
bats --tap "$tests_dir" | tee "$tap" || bats_rc=$?

planned="$(sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' "$tap" | tail -n 1)"
passed="$(grep -c '^ok [0-9]' "$tap" || true)"
failed="$(grep -c '^not ok [0-9]' "$tap" || true)"
skipped="$(grep -c '^ok [0-9][0-9]* .* # skip' "$tap" || true)"
reported=$((passed + failed))

printf '\nbats suite: %s ok, %s failed, %s skipped (skip budget %s), %s planned\n' \
    "$passed" "$failed" "$skipped" "$expected" "${planned:-unknown}"

rc=0

if [ "$failed" -gt 0 ]; then
    printf 'FAIL: %s test(s) failed\n' "$failed" >&2
    rc=1
fi

if [ -z "$planned" ]; then
    printf 'FAIL: bats emitted no TAP plan — the suite did not run\n' >&2
    rc=1
elif [ "$planned" -ne "$reported" ]; then
    printf 'FAIL: bats planned %s test(s) but reported %s — %s never ran\n' \
        "$planned" "$reported" "$((planned - reported))" >&2
    rc=1
fi

if [ "$skipped" -ne "$expected" ]; then
    printf 'FAIL: skip count is %s, expected %s\n' "$skipped" "$expected" >&2
    printf 'A skip is a test that stopped running. Restore the capability it\n' >&2
    printf 'needs, or move the budget deliberately in the caller.\n' >&2
    if [ "$skipped" -gt 0 ]; then
        printf 'skipped:\n' >&2
        grep '^ok [0-9][0-9]* .* # skip' "$tap" >&2
    fi
    rc=1
fi

# A bats failure with no `not ok` line (a crash, a bad argument) must not be
# swallowed by an otherwise clean summary.
if [ "$bats_rc" -ne 0 ] && [ "$rc" -eq 0 ]; then
    printf 'FAIL: bats exited %s with no failing test — the run itself broke\n' \
        "$bats_rc" >&2
    rc=1
fi

exit "$rc"
