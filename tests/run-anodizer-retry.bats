#!/usr/bin/env bats
# run-anodizer-retry.bats — tests for scripts/run/anodizer.sh's retry loop
# and its between-attempt dist hygiene.
#
# Contract under test:
#  1. After a failed attempt, cleanup leaves the dist tree GENUINELY empty
#     (files, symlinks, hidden subdirs, and the then-empty dirs themselves),
#     so a retry passes anodizer's dist-not-empty guard. The guard counts
#     ANY directory entry — a leftover empty `run-<id>/` dir poisons every
#     retry (Nightly run 27396951395).
#  2. Symlink deletion removes the link only; the target outside dist
#     survives.
#  3. Preserved-dist context manifests (root context.json) skip cleanup
#     entirely, keeping --merge / --publish-only inputs intact.
#  4. Stateful modes (--publish-only) run exactly once, no retry.
#  5. A deterministic failure (anodizer exit 2 or the stderr class marker)
#     stops after one attempt and leaves the wrapper exiting 2; every other
#     failure retries as before and exits 1.
#
# These run the REAL script with a stub `anodizer` binary that litters dist
# on attempt 1 and emulates the binary's dist-not-empty guard on attempt 2+.

load test_helper

setup() {
    common_setup
    WORKDIR="$(mktemp -d)"
    STUB_BIN="$WORKDIR/bin"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"
    export GITHUB_ACTION_PATH="$REPO_ROOT"
    export ANODIZER_STDOUT_LOG="$WORKDIR/stdout.log"
    export ANODIZER_RETRY_DELAY=0
    cd "$WORKDIR"
    printf 'dist: ./dist\n' > .anodizer.yaml
}

teardown() {
    cd /
    rm -rf "$WORKDIR"
    common_teardown
}

# Stub anodizer: attempt 1 litters dist the way a mid-build failure does
# (run-dir manifest, top-level file, hidden cache dir, symlink out of the
# tree) and fails; attempt 2+ replays the binary's dist-not-empty guard.
_write_stub() {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
set -u
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
if [ "\$n" -eq 1 ]; then
    mkdir -p ./dist/run-12345 ./dist/.cache
    echo '{}' > ./dist/run-12345/summary.json
    echo man > ./dist/anodizer.1
    echo cached > ./dist/.cache/probe
    # MSYS ln -s silently COPIES unless native symlinks are forced, and the
    # copy keeps the target's mtime, so it predates the cleanup's input marker
    # and survives as a preserved input. Only a real link exercises contract 2.
    MSYS=winsymlinks:nativestrict ln -s "$WORKDIR/outside-target" ./dist/link-out
    if [ ! -L ./dist/link-out ]; then
        echo "stub: the dist symlink was not created" >&2
        exit 3
    fi
    exit 1
fi
if [ -d ./dist ] && [ -n "\$(ls -A ./dist)" ]; then
    echo "Error: dist directory './dist' is not empty; use --clean to remove it first"
    exit 1
fi
exit 0
STUB
    chmod +x "$STUB_BIN/anodizer"
}

@test "retry cleanup empties dist (dirs, hidden dirs, symlinks) so attempt 2 passes the guard" {
    _write_stub
    echo keepme > "$WORKDIR/outside-target"
    export ANODIZER_ARGS="release --nightly"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$WORKDIR/attempts")" = "2" ]
    # Symlink deletion must remove the link, never the target.
    [ -f "$WORKDIR/outside-target" ]
    [ "$(cat "$WORKDIR/outside-target")" = "keepme" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
    [[ "$output" != *"is not empty"* ]]
}

# A --merge retry must clear the archive a failed attempt already wrote (else
# the next attempt's archive stage aborts "already exists") WHILE preserving the
# preserved-dist inputs it consumes (context manifest + shard binary). The inputs
# are aged so they unambiguously predate the script's input marker.
@test "merge retry clears generated archives but preserves preserved-dist inputs" {
    mkdir -p ./dist/linux/x86_64-unknown-linux-gnu
    echo '{"shard":"x"}' > ./dist/context.json
    echo bin > ./dist/linux/x86_64-unknown-linux-gnu/app
    touch -t 200001010000 ./dist/context.json ./dist/linux/x86_64-unknown-linux-gnu/app

    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
set -u
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
# A leftover archive from a prior attempt aborts the stage — the exact
# "already exists" cascade the retry cleanup must prevent.
if [ -e ./dist/app-linux.tar.gz ]; then
    echo "Error: archive named 'app-linux.tar.gz' already exists. Check your archive name template."
    exit 1
fi
echo archived > ./dist/app-linux.tar.gz
[ "\$n" -eq 1 ] && exit 1
exit 0
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --merge"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$WORKDIR/attempts")" = "2" ]
    # Inputs survive; the stale archive never triggers a collision on retry.
    [ -f "$WORKDIR/dist/context.json" ]
    [ -f "$WORKDIR/dist/linux/x86_64-unknown-linux-gnu/app" ]
    [[ "$output" != *"already exists"* ]]
}

@test "stateful --publish-only runs exactly once" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --publish-only"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for stateful mode"* ]]
}

# A plain full `release` is stateful: it cuts the tag, publishes, and rolls
# back on failure (deleting the tag). A blind retry would find no tag and
# exit 0 — a false-green. It must run exactly once, surfacing the real failure.
@test "stateful plain release runs exactly once (no false-green retry)" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --clean"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful release"* ]]
}

# Build-only / preview legs stay retryable. --snapshot self-tags nothing
# upstream, so a retry genuinely rebuilds rather than no-opping.
@test "release --snapshot stays retryable (3 attempts)" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --snapshot --single-target --clean --dry-run"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
}

# `--rollback-only` was removed from anodizer, which now rejects it. The
# wrapper must still classify the invocation as a plain release and run it
# once, so the removed-flag error reaches the operator unretried.
@test "a removed --rollback-only flag still classifies as a plain release (runs once)" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --rollback-only --from-run=123"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful release"* ]]
}

# `tag rollback` deletes the tag + reverts the writeback commit; a blind retry
# would error on the already-deleted tag or fight a concurrent re-tag.
@test "stateful tag rollback runs exactly once" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="tag rollback --tag v1.2.3"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for stateful mode"* ]]
}

# A one-failure-then-pass stub: attempt 1 exits 1, attempt 2+ exits 0. Lets a
# test assert a mode IS retryable (reaches attempt 2 and greens) rather than
# only that it fails N times.
_write_flaky_stub() {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
[ "\$n" -ge 2 ] && exit 0
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
}

# A one-shot always-fail stub for asserting a mode runs exactly once.
_write_failing_stub() {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
}

# F2: `publish` runs the same stateful release/publish/blob chain against the
# same PR-based publishers as `release --publish-only`, but carries no
# `--publish-only` literal. A blind retry would open DUPLICATE PRs. It must run
# exactly once, surfacing the real failure.
@test "stateful publish runs exactly once (no duplicate PRs)" {
    _write_failing_stub
    export ANODIZER_ARGS="publish --skip npm"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful publish/continue"* ]]
}

# F2: `continue` (single-host stage-resume) runs the identical publish chain;
# same duplicate-PR hazard as bare `publish`. Exactly once.
@test "stateful continue runs exactly once (no duplicate PRs)" {
    _write_failing_stub
    export ANODIZER_ARGS="continue --token xxx"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful publish/continue"* ]]
}

# F2 guard: `publish --dry-run` runs the pipeline with no side effects, so a
# retry opens no PRs — it stays retryable (3 attempts).
@test "publish --dry-run stays retryable (3 attempts)" {
    _write_failing_stub
    export ANODIZER_ARGS="publish --dry-run"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
}

# F2 guard: `continue --merge` resumes behind anodizer's own publish-rerun
# guard (identical to `release --merge`), so a retry is safe. Retryable.
@test "continue --merge stays retryable (3 attempts)" {
    _write_failing_stub
    export ANODIZER_ARGS="continue --merge"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
}

# F4: `tag --push` pushes the bump commit + a new tag to the remote. A partial
# push retried fails on the now-existing tag or double-applies the bump. Must
# run exactly once.
@test "stateful tag --push runs exactly once (no double-push)" {
    _write_failing_stub
    export ANODIZER_ARGS="tag --push --changelog"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful tag"* ]]
}

# F4: `tag --changelog` (without --push) still refreshes CHANGELOG.md into a
# bump commit that the same tag flow pushes; treat it as remote-mutating.
@test "stateful tag --changelog runs exactly once" {
    _write_failing_stub
    export ANODIZER_ARGS="tag --changelog"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful tag"* ]]
}

# F4 guard: a local-only `tag --dry-run` (and `--push-dry-run`) mutates nothing
# on the remote, so it stays retryable. Use the flaky stub to prove it actually
# reaches attempt 2 and greens.
@test "tag --dry-run stays retryable and recovers on attempt 2" {
    _write_flaky_stub
    export ANODIZER_ARGS="tag --dry-run"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$WORKDIR/attempts")" = "2" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
    [[ "$output" != *"retry disabled"* ]]
}

# Regression guard: a stateful `release --publish-only` is STILL caught by the
# stateful-mode case (the `publish` word-match must not steal it — `--publish-only`
# is not the standalone token ` publish `). Exactly once, classic warn.
@test "release --publish-only still runs exactly once (publish-only literal, not the publish subcommand)" {
    _write_failing_stub
    export ANODIZER_ARGS="release --publish-only --skip npm"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for stateful mode"* ]]
}

# Regression guard: a standalone `preflight` is a side-effect-free pre-release
# gate; the publish/continue/tag cases must not steal it. Still retryable.
@test "preflight subcommand retryable (3 attempts)" {
    _write_failing_stub
    export ANODIZER_ARGS="preflight --skip blob"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
}

# Misroute guard: `preflight` is also a stage NAME, so `release --skip preflight`
# carries a bare ` preflight ` token. The leading-anchored case must NOT steal
# it into the check-only class — it is a plain stateful `release` (runs once).
@test "release --skip preflight classifies as stateful release, not preflight (runs once)" {
    _write_failing_stub
    export ANODIZER_ARGS="release --skip preflight"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful release"* ]]
}

# Regression guard: `release --dry-run` stays retryable — the new publish/tag
# word-matches must not match a plain release invocation.
@test "release --dry-run still retryable (3 attempts)" {
    _write_failing_stub
    export ANODIZER_ARGS="release --dry-run --single-target"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
}

# Misroute guard (B1): `publish` is a real stage NAME, so `release --skip publish`
# carries a bare ` publish ` token. The leading-anchored case must NOT steal it
# into the publish/continue class — it is a plain stateful `release` (runs once,
# release warn). A non-anchored match would have left it falsely classified.
@test "release --skip publish classifies as stateful release, not publish (runs once)" {
    _write_failing_stub
    export ANODIZER_ARGS="release --skip publish"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful release"* ]]
    [[ "$output" != *"stateful publish/continue"* ]]
}

# Misroute guard (B1): `tag` is also a stage name. `release --workspace tag`
# carries a bare ` tag ` token; an unanchored match would route it into the tag
# case and — with no --push/--changelog — DANGEROUSLY mark a stateful release
# 3×-retryable. It must classify as a stateful release (runs once).
@test "release --workspace tag classifies as stateful release, not tag (runs once)" {
    _write_failing_stub
    export ANODIZER_ARGS="release --workspace tag"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for a stateful release"* ]]
    [[ "$output" != *"stateful tag"* ]]
}

# A stub that fails the way anodizer's deterministic classifier does: an error
# on stderr, a marker line only when asked for, and a caller-chosen exit code.
# `$1` = exit code, `$2` = "marker" to emit the classification line. Each signal
# is exercised alone so neither test can pass on the strength of the other.
_write_classified_stub() {
    local exit_code="$1" marker="${2:-}"
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
echo "anodizer-output version=9.9.9"
echo "error: dist directory './dist' is not empty; use --clean to remove it first" >&2
STUB
    if [ "$marker" = "marker" ]; then
        echo 'echo "anodizer-error-class: deterministic" >&2' >> "$STUB_BIN/anodizer"
    fi
    echo "exit $exit_code" >> "$STUB_BIN/anodizer"
    chmod +x "$STUB_BIN/anodizer"
}

# Exit code 2 is anodizer's EXIT_DETERMINISTIC: the failure is argv/config
# determined and will fail identically forever. A retryable mode must still
# stop after ONE attempt, and the wrapper re-states the classification in its
# own exit code.
@test "exit code 2 fails fast after exactly one attempt" {
    _write_classified_stub 2
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 2 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"deterministic error"* ]]
    [[ "$output" == *"retrying cannot help"* ]]
    [[ "$output" != *"attempt 1/3 failed"* ]]
}

# The stderr marker classifies on its own, covering an anodizer old enough to
# still exit 1 on its deterministic paths. The wrapper normalizes that to 2:
# the classification is what the caller acts on, not which signal carried it.
@test "stderr class marker fails fast even when the exit code is not 2" {
    _write_classified_stub 1 marker
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 2 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"deterministic error"* ]]
    [[ "$output" == *"retrying cannot help"* ]]
    [[ "$output" != *"attempt 1/3 failed"* ]]
}

# The narrowness guard: an unclassified exit 1 is the transient case (network,
# 5xx, rate limit) and must still burn the full retry budget.
@test "unclassified exit 1 still retries the full count" {
    _write_classified_stub 1
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
    [[ "$output" == *"failed after 3 attempts"* ]]
    [[ "$output" != *"deterministic error"* ]]
}

# Status plumbing: `tee` exits 0 on every attempt, so a pipeline that reports
# tee's status would see 0/1 and never classify. The wrapper must read
# anodizer's own 2 — while the stdout tee keeps working and the stderr marker
# channel stays out of the stdout marker log.
@test "anodizer's exit 2 survives the tee pipeline and the marker never reaches the stdout log" {
    _write_classified_stub 2 marker
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 2 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"exit 2"* ]]
    # tee still populated the stdout marker log...
    grep -qF "anodizer-output version=9.9.9" "$ANODIZER_STDOUT_LOG"
    # ...and stderr never contaminated that stdout-only channel.
    ! grep -qF "anodizer-error-class" "$ANODIZER_STDOUT_LOG"
    # stderr still reached the log for a human to read.
    [[ "$output" == *"is not empty"* ]]
}

# Classification is per-attempt: a transient attempt 1 must not mask a
# deterministic attempt 2, and attempt 1's clean stderr must not be inherited.
@test "a deterministic failure on attempt 2 stops the loop before attempt 3" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
if [ "\$n" -eq 1 ]; then
    echo "error: 503 Service Unavailable" >&2
    exit 1
fi
echo "error: unknown publisher 'nmp'" >&2
echo "anodizer-error-class: deterministic" >&2
exit 2
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 2 ]
    [ "$(cat "$WORKDIR/attempts")" = "2" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
    [[ "$output" != *"attempt 2/3 failed"* ]]
    [[ "$output" == *"deterministic error (exit 2)"* ]]
}

# A no-retry stateful mode already runs once; classification must still report
# WHY, so the operator stops looking for a flake.
@test "a deterministic failure in a no-retry stateful mode reports the classification" {
    _write_classified_stub 2 marker
    export ANODIZER_ARGS="release --publish-only"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 2 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"deterministic error (exit 2)"* ]]
    [[ "$output" != *"no retry for stateful modes"* ]]
}

# The per-attempt stderr capture is an mktemp file removed by an EXIT trap.
# A leak would accumulate one file per step on a long-lived self-hosted runner,
# and the failing path is the one that leaks most easily — it exits mid-loop.
# Point TMPDIR at an empty dir and assert nothing is left behind afterwards.
@test "the stderr capture temp file is cleaned up on the deterministic exit path" {
    _write_classified_stub 2 marker
    export ANODIZER_ARGS="release --snapshot"
    local saved_tmpdir="${TMPDIR:-}"
    mkdir -p "$WORKDIR/tmpprobe"
    export TMPDIR="$WORKDIR/tmpprobe"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
    [ "$status" -eq 2 ]
    [ -z "$(ls -A "$WORKDIR/tmpprobe")" ]
}

# Exit-code contract, non-deterministic direction: a failure anodizer did NOT
# classify stays 1 no matter what code it exited with. Propagating an arbitrary
# code would make 2 ambiguous — a future anodizer exit 2 for some unrelated
# reason is the only thing allowed to mean "deterministic" to a caller.
@test "an unclassified failure exits 1 even when anodizer exited with another code" {
    _write_classified_stub 3
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" != *"deterministic error"* ]]
}

# The classifier reads the STDERR capture only. A marker printed on stdout is a
# release-note line or a doc echo, not a classification — treating it as one
# would let ordinary output disable retries. This also pins the fd-3 swap: if
# stdout ever leaked into the stderr capture, this test retries zero times.
@test "a class marker on stdout does not classify (stderr capture only)" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
echo "anodizer-error-class: deterministic"
echo "error: 503 Service Unavailable" >&2
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --snapshot"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" != *"deterministic error"* ]]
}

# Misroute guard (B1): `continue` stage name in a snapshot release. The bare
# ` continue ` token must not pull it into the publish/continue class; a
# --snapshot release self-tags nothing and stays retryable (3 attempts).
@test "release --snapshot --workspace continue stays retryable (not publish/continue)" {
    _write_failing_stub
    export ANODIZER_ARGS="release --snapshot --workspace continue"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
    [[ "$output" != *"stateful publish/continue"* ]]
}
