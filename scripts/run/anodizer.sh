#!/usr/bin/env bash
# Invoke `anodizer $ANODIZER_ARGS` with a retry loop for transient
# failures (registry rate limits, network timeouts, Docker push auth
# expiry).
#
# Deterministic failures (config errors, compile failures) fail
# identically on every attempt; the cost of two extra 10s waits is low
# vs. a flaky release.
#
# `--publish-only` is exempt from retries. It is intrinsically stateful:
# a partial success writes `dist/run-<run_id>/report.json`, and a blind
# retry would either (a) trip the publish-stage rerun guard and bail, or
# (b) — if forced past the guard — open duplicate PRs against PR-based
# publishers (homebrew, scoop, nix, krew, MCP). Recovery from a partial
# publish-only failure is operator-driven via
# `anodizer release --rollback-only --from-run=<id>`, not a wrapper
# retry.
#
# Deterministic failures are exempt too, by a different mechanism: anodizer
# classifies them (exit code 2 / a stderr marker line) and the loop stops on
# the first attempt rather than burning the budget on an identical failure.
#
# This wrapper's OWN exit code re-states that classification: 2 for a
# deterministic failure, 1 for anything else. GitHub Actions only distinguishes
# zero from nonzero, but the script is also a directly-callable entry point, and
# an exit-code contract that stopped at the action boundary would leave a direct
# caller with only a human-readable sentence to parse. The normalization is
# deliberate: an anodizer old enough to exit 1 on a deterministic path is still
# reported as 2 here, because the stderr marker classified it.
#
# Stdout (only) is teed to $ANODIZER_STDOUT_LOG so the outputs step can
# parse `anodizer-output` markers without losing log visibility in the
# GHA UI. Stderr flows to the CI log live on every attempt so transient and
# final failures are both debuggable in real time; it is additionally teed
# into a private per-attempt file that only the deterministic classifier
# reads. That file is deliberately NOT $ANODIZER_STDOUT_LOG: the
# `anodizer-output` marker channel is stdout-only, so an error line that
# resembles a marker must never reach the parsed output.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/config.sh"

# anodizer's deterministic-error contract (crates/core/src/error_class.rs):
# EXIT_DETERMINISTIC plus a CLASS_MARKER line on stderr. Either signal alone
# is authoritative — the marker also classifies an anodizer old enough to
# still exit 1 on its deterministic paths, and the exit code still classifies
# a run whose stderr never made it back.
anodizer_exit_deterministic=2
anodizer_class_marker='anodizer-error-class: deterministic'

# Per-attempt stderr capture, truncated at the start of every attempt so the
# classifier can never inherit a previous attempt's marker.
attempt_stderr="$(mktemp)"
# Retry-cleanup reference point: its mtime marks "before anodizer ran". Every
# dist entry already present when this script starts (preserved-dist context
# manifests, downloaded shard binaries, staged signing keys — all written by
# EARLIER action steps) predates it; only anodizer's generated output is newer.
# Created here at script start so the marker is fixed before the first attempt.
dist_input_marker="$(mktemp)"
trap 'rm -f "$attempt_stderr" "$dist_input_marker"' EXIT

# The configured output tree (default `dist`); custom `dist:` values must
# steer the retry cleanup too, or a retry would wipe the wrong directory.
dist_dir=$(resolve_dist_dir)

# Remove anodizer's generated output between retries while preserving every
# already-staged dist INPUT. A `release --merge` retry must clear the archives /
# checksums / signatures the failed attempt already wrote (else the next
# attempt's archive stage aborts with "archive ... already exists"), yet keep
# the preserved-dist tree it consumes — context manifests AND the downloaded
# shard binaries. Skipping cleanup wholesale (the old preserved-context guard)
# left the stale archives; wiping cleanup wholesale destroyed the merge inputs.
# `-newer "$dist_input_marker"` splits the two by mtime: inputs were staged by
# earlier action steps before the marker; anodizer's output is written after
# it. A build with no preserved dist (empty tree at marker time) still cleans
# to GENUINELY empty — anodizer's dist-not-empty guard counts ANY entry, so a
# leftover empty `run-<id>/` subdir or an undeleted symlink would fail the
# retry. Files and symlinks are removed at every depth (`find` without -L
# deletes a symlink as a link, never descending — deletion cannot escape the
# tree), then empty dirs are pruned depth-first.
cleanup_dist() {
    [ -d "$dist_dir" ] || return 0
    find "$dist_dir" -mindepth 1 \( -type f -o -type l \) -newer "$dist_input_marker" -delete 2>/dev/null || true
    find "$dist_dir" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
}

resolve_max_retries() {
    # Stateful modes must run exactly once. A blind whole-pipeline retry of a
    # stateful failure either no-ops into a FALSE-GREEN or double-acts.
    # case-glob matches the flag anywhere in the arg list.
    case " $ANODIZER_ARGS " in
        *" --publish-only "*|*" --rollback-only "*|*" tag rollback "*)
            anodizer::warn "retry disabled for stateful mode (--publish-only / --rollback-only / tag rollback)"
            echo 1
            return
            ;;
    esac
    # A `tag` invocation that mutates the remote (--push pushes the bump commit
    # + the new tag; --changelog refreshes CHANGELOG.md into that pushed bump
    # commit) is single-shot stateful: a partial push retried fails on the
    # now-existing tag, or — if it got past the bump commit — double-applies the
    # version writeback. Local-only `tag` forms (bare auto-tag, --dry-run,
    # --push-dry-run, --no-push) mutate nothing on the remote, so they stay
    # retryable. (`tag rollback` is already handled by the stateful-mode case
    # above.)
    #
    # LEADING-ANCHORED on the subcommand: the subcommand is always the FIRST
    # token of ANODIZER_ARGS. Matching a bare ` tag ` anywhere would misroute
    # `release --workspace tag` (`tag` is also a stage name) — dangerously
    # flipping a stateful release to 3×-retryable — so we only match `tag` when
    # it leads the arg string.
    case "$ANODIZER_ARGS " in
        "tag "*)
            case " $ANODIZER_ARGS " in
                *" --push "*|*" --changelog "*)
                    anodizer::warn "retry disabled for a stateful tag (--push / --changelog push a bump commit + a new tag; a blind retry fails on the existing tag or double-applies the writeback)."
                    echo 1
                    ;;
                *)
                    echo 3
                    ;;
            esac
            return
            ;;
    esac
    # `publish` and `continue` run the SAME stateful release / publish / blob
    # chain as `release --publish-only` against the SAME PR-based publishers
    # (homebrew, scoop, nix, krew, MCP) — they just lack the `--publish-only`
    # literal the stateful-mode case above keys off. A blind whole-pipeline
    # retry of a transient per-publisher failure re-runs the publish and opens
    # DUPLICATE PRs. Treat them like a stateful release: run once, surface the
    # real failure, let transient per-publisher failures retry INSIDE anodizer.
    # The build-only / preview leg (--dry-run, side-effect-free) and the
    # merge-resume leg (--merge, which sits behind anodizer's own publish-rerun
    # guard, identical to `release --merge`) stay retryable.
    #
    # LEADING-ANCHORED like the tag case: `publish` / `continue` are also stage
    # names, so `release --skip publish` and `release --snapshot --workspace
    # continue` must NOT match here — only a leading `publish `/`continue `
    # subcommand does.
    case "$ANODIZER_ARGS " in
        "publish "*|"continue "*)
            case " $ANODIZER_ARGS " in
                *" --dry-run "*|*" --merge "*)
                    echo 3
                    ;;
                *)
                    anodizer::warn "retry disabled for a stateful publish/continue (runs the publish + blob chain against PR-based publishers; a blind retry would open duplicate PRs). Transient failures retry inside anodizer."
                    echo 1
                    ;;
            esac
            return
            ;;
    esac
    # A standalone `preflight` runs the pre-release check (environment,
    # publisher credential probes, reconcile) and publishes nothing, so it stays
    # retryable. LEADING-ANCHORED like `tag`: `preflight` is also a stage name
    # (`release --skip preflight`), so a bare token match would flip a stateful
    # release to 3x-retryable.
    case "$ANODIZER_ARGS " in
        "preflight "*)
            echo 3
            return
            ;;
    esac
    # A plain `release` cuts the tag, creates the GitHub release, runs the
    # publishers, and on failure rolls back — DELETING the tag. A retry then
    # finds no release tag at HEAD, short-circuits "nothing to do", and exits 0,
    # turning a FAILED release GREEN (the brontes/cfgd pre-tagged pattern:
    # workflow triggered by a tag push, release job's rollback removes it).
    # Transient per-publisher failures (rate limits, network, auth expiry) are
    # retried INSIDE anodizer — the only layer that can retry without
    # re-running rollback. Build-only / preview / orchestrated legs stay
    # retryable: --snapshot / --nightly / --dry-run build no upstream state (or
    # self-tag, so a retry genuinely re-cuts rather than no-opping), --merge
    # consumes a preserved dist behind anodizer's own publish-rerun guard, and
    # --prepare / --split mutate nothing upstream.
    case " $ANODIZER_ARGS " in
        *" release "*)
            case " $ANODIZER_ARGS " in
                *" --snapshot "*|*" --nightly "*|*" --dry-run "*|*" --merge "*|*" --prepare "*|*" --split "*|*" --announce-only "*)
                    echo 3
                    ;;
                *)
                    anodizer::warn "retry disabled for a stateful release (cuts a tag + publishes, rolls back on failure; a blind retry would false-green). Transient failures retry inside anodizer."
                    echo 1
                    ;;
            esac
            return
            ;;
    esac
    echo 3
}

# Returns anodizer's OWN exit status, not a tee's. `set -o pipefail` (the
# repo-wide idiom; no script here reaches for PIPESTATUS) makes both the inner
# and the outer pipeline report the failing member, and both tees are pipeline
# members — so the shell has reaped and flushed them before the status is read.
# A `2> >(tee …)` process substitution would stream the same bytes but race the
# marker grep, since the shell does not wait for it.
run_attempt() {
    : > "$attempt_stderr"
    # fd 3 carries stdout past the stderr tee; stderr then takes stdout's place
    # in the inner pipeline, landing in the capture file and on the CI log.
    # shellcheck disable=SC2086
    # ANODIZER_ARGS is intentionally unquoted: users pass multiple flags
    # separated by whitespace via `inputs.args` and rely on word splitting
    # to forward them as distinct argv entries.
    { anodizer $ANODIZER_ARGS 2>&1 1>&3 3>&- | tee -a "$attempt_stderr" >&2; } 3>&1 \
        | tee -a "$ANODIZER_STDOUT_LOG"
}

is_deterministic_failure() {
    if [ "$1" -eq "$anodizer_exit_deterministic" ]; then
        return 0
    fi
    grep -qF -- "$anodizer_class_marker" "$attempt_stderr"
}

main() {
    anodizer::verb Running "anodizer"

    local max_retries attempt=1 status
    max_retries=$(resolve_max_retries)
    : > "$ANODIZER_STDOUT_LOG"

    while [ $attempt -le $max_retries ]; do
        status=0
        run_attempt || status=$?
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        if is_deterministic_failure "$status"; then
            anodizer::err "anodizer failed with a deterministic error (exit ${status}); retrying cannot help — fix the reported config/usage error and re-run"
            exit "$anodizer_exit_deterministic"
        fi
        if [ $attempt -eq $max_retries ]; then
            if [ $max_retries -eq 1 ]; then
                anodizer::err "anodizer failed (no retry for stateful modes)"
            else
                anodizer::err "anodizer failed after ${max_retries} attempts"
            fi
            exit 1
        fi
        anodizer::warn "attempt ${attempt}/${max_retries} failed; retrying in 10s..."

        # Clear only what this attempt generated; preserved-dist inputs
        # (context manifests + shard binaries a --merge consumes) predate the
        # marker and survive.
        cleanup_dist
        # Overridable so the bats suite can exercise the retry loop without
        # real 10s waits.
        sleep "${ANODIZER_RETRY_DELAY:-10}"
        attempt=$((attempt + 1))
    done
}

main "$@"
