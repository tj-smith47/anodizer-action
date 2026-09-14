#!/usr/bin/env bash
# Emit `deps=<csv>` of deps.sh install keywords for the external tools the
# configured anodizer pipeline needs.
#
# The tool set is NOT re-derived from the config here — that is anodizer's job.
# `anodizer tools --json` reports the requirements straight from the same
# per-stage / per-publisher SSOT the preflight engine consumes, so adding a
# tool-bearing stage or publisher updates this set automatically with no shell
# logic to drift. This script's only domain is the action's own concern: HOW
# to install each reported binary — the binary -> install-keyword map below.
#
# The run's scope flags (`--publish-only`, `--skip`, `--publishers`,
# `-f/--config`) are read from $ANODIZER_ARGS and forwarded to `anodizer tools`
# so the detected set matches exactly the stages this job runs.
set -euo pipefail
# shellcheck source=../lib/gha.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"
# shellcheck source=../lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
# deps.sh is source-safe (its main() only fires when executed directly — see
# the guard at its own end), so sourcing it here reuses NPM_DEFAULT_VERSION
# as the single place the npm Trusted-Publishing floor is written, instead of
# a second hardcoded copy drifting from it. GITHUB_ACTION_PATH/RUNNER_OS
# default defensively: deps.sh hard-requires both (for its own lib source and
# its per-OS installer dispatch, neither exercised by this read-only sourcing)
# but this script — unlike deps.sh — has never needed them, and every other
# script in this repo already assumes GITHUB_ACTION_PATH is ambient rather
# than deriving it, so this is the one place that still must.
: "${GITHUB_ACTION_PATH:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
: "${RUNNER_OS:=Linux}"
# shellcheck source=deps.sh
source "$(dirname "${BASH_SOURCE[0]}")/deps.sh"

anodizer::verb Detecting "pipeline dependencies"

emit_empty() {
    anodizer::kv detected none
    gha_set_output deps ""
    exit 0
}

# anodizer auto-discovers the config in the workdir; mirror that probe only to
# give a friendly skip when there is genuinely nothing to detect.
if ! find_anodizer_config > /dev/null; then
    gha_warning "auto-install: no anodizer config found, skipping"
    anodizer::warn "no anodizer config found; nothing to auto-install"
    emit_empty
fi

if ! command -v anodizer > /dev/null 2>&1; then
    gha_warning "auto-install: anodizer is not on PATH; cannot query 'anodizer tools' — skipping (install it first, or use the 'install:' input)"
    anodizer::warn "anodizer not on PATH; cannot auto-detect dependencies"
    emit_empty
fi

# Forward the run's scope to `anodizer tools`. `-f/--config` is a global flag
# (it precedes the subcommand); the scope filters follow it. Anything else in
# the args (the subcommand, version overrides, ...) is irrelevant to the tool
# enumeration and is dropped.
config_flags=()
scope_flags=()
_args=()
read -ra _args <<< "${ANODIZER_ARGS:-}"
_n=${#_args[@]}
_i=0
while [ "$_i" -lt "$_n" ]; do
    tok="${_args[$_i]}"
    case "$tok" in
        --publish-only)    scope_flags+=(--publish-only) ;;
        --skip=*)          scope_flags+=(--skip="${tok#--skip=}") ;;
        --skip)            _i=$((_i + 1)); [ "$_i" -lt "$_n" ] && scope_flags+=(--skip="${_args[$_i]}") ;;
        --publishers=*)    scope_flags+=(--publishers="${tok#--publishers=}") ;;
        --publishers)      _i=$((_i + 1)); [ "$_i" -lt "$_n" ] && scope_flags+=(--publishers="${_args[$_i]}") ;;
        --config=*)        config_flags+=(--config="${tok#--config=}") ;;
        -f=*)              config_flags+=(--config="${tok#-f=}") ;;
        -f | --config)     _i=$((_i + 1)); [ "$_i" -lt "$_n" ] && config_flags+=(--config="${_args[$_i]}") ;;
    esac
    _i=$((_i + 1))
done

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT
if ! tools_json="$(anodizer "${config_flags[@]}" tools --json "${scope_flags[@]}" 2> "$err_file")"; then
    # A non-zero exit means either an anodizer too old to have the `tools`
    # command or a config that won't load. Either way, surface it loudly and
    # emit no set rather than guessing — the user can pin a newer anodizer or
    # pass an explicit `install:` list.
    gha_warning "auto-install: 'anodizer tools' failed — needs an anodizer with the 'tools' command, or the config is invalid. Pass an explicit 'install:' list, or upgrade anodizer. Detail: $(tr '\n' ' ' < "$err_file")"
    anodizer::warn "'anodizer tools' failed; emitting no auto-install set"
    emit_empty
fi

schema="$(jq -r '.schema_version // empty' <<< "$tools_json" 2> /dev/null || true)"
if [ "$schema" != "1" ]; then
    gha_warning "auto-install: unexpected 'anodizer tools' schema_version='${schema:-<none>}' (expected 1); parsing anyway"
fi

# ── binary -> deps.sh install keyword ────────────────────────────────────────
# anodizer reports the BINARY name a stage will spawn; deps.sh dispatches on its
# own install KEYWORD. This map bridges the two vocabularies. It is the action's
# legitimate domain: anodizer owns WHAT is needed, the action owns HOW to fetch
# it. deps.sh handles per-OS routing (and skips OS-unsupported keywords), so no
# OS guard is duplicated here.
#
# AMBIENT marks a binary the runner already provides (cargo via the Rust
# toolchain step; git/gpg/ssh/docker preinstalled on every runner image;
# codesign/xcrun ship with the macOS Xcode CLT) — there is no installer and its
# absence is not an auto-install failure.
map_binary() {
    case "$1" in
        cargo | cc | git | gpg | ssh | docker | codesign | xcrun) echo AMBIENT ;;
        cosign*)                       echo cosign ;;  # is_cosign_cmd: any cosign* basename
        syft)                          echo syft ;;
        nfpm)                          echo nfpm ;;
        makeself)                      echo makeself ;;
        snapcraft | unsquashfs)        echo snapcraft ;;  # snapcraft installer pulls squashfs-tools
        rpmbuild)                      echo rpmbuild ;;
        upx)                           echo upx ;;
        zig)                           echo zig ;;
        cargo-zigbuild)                echo cargo-zigbuild ;;
        node | npm)                    echo node ;;
        makensis)                      echo nsis ;;
        linuxdeploy)                   echo linuxdeploy ;;
        flatpak | flatpak-builder)     echo flatpak ;;
        rcodesign)                     echo rcodesign ;;
        alejandra)                     echo alejandra ;;  # nix publisher formatter
        pkgbuild | xar)                echo pkgbuild ;;
        hdiutil | genisoimage | mkisofs) echo create-dmg ;;
        wix)                           echo wix ;;   # WiX v4 (wix build)
        candle | light | wixl)         echo wix3 ;;  # WiX v3 dialect (candle+light / Linux wixl)
        xmllint)                       echo xmllint ;;  # chocolateys: prepublish .nuspec schema validation
        ruby)                          echo ruby ;;     # homebrew: prepublish formula syntax check
        aws)                           echo aws ;;
        gcloud)                        echo gcloud ;;
        az)                            echo az ;;
        *)                             echo "" ;;
    esac
}

# Binaries whose mere presence on PATH is INSUFFICIENT to satisfy an any_of
# group: they must also meet a minimum version, or resolution falls through
# to the install path so the upgrade actually runs. npm below
# NPM_DEFAULT_VERSION (deps.sh's single source of truth for the Trusted-
# Publishing/OIDC floor) cannot perform the OIDC handshake — GitHub runners
# ship npm 10.9.x bundled with every Node 22.x line, so an ambient stale npm
# must never suppress the node/install_npm_floor install that upgrades it.
declare -A _min_version=( [npm]="${NPM_DEFAULT_VERSION}" )

# True iff version $1 >= version $2 (both plain X.Y.Z, compared numerically
# via sort -V rather than string/lexical order so e.g. 9.0.0 < 11.5.1).
version_ge() {
    [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1)" = "$1" ]
}

declare -A _seen=()
deps=()

# Resolve one tool requirement (an `any_of` group + its advisory flag) to at
# most one install keyword. An `any_of` is satisfied with no install when any
# listed binary is already on PATH and, for a floor-bearing binary (see
# _min_version above), meets its minimum version; otherwise the first binary
# with a mapping selects the keyword. A required group that maps to nothing
# and is absent is a LOUD warning (the drift the config-grep era hid
# silently); an advisory group is a quiet verbose note (the pipeline degrades
# gracefully without it).
resolve_requirement() {
    local advisory="$1"
    shift
    local bins=("$@")
    local b kw floor have

    for b in "${bins[@]}"; do
        if command -v "$b" > /dev/null 2>&1; then
            floor="${_min_version[$b]:-}"
            if [ -z "$floor" ]; then
                anodizer::vdetail "satisfied ${bins[*]}: '$b' already on PATH"
                return 0
            fi
            have="$("$b" --version 2> /dev/null | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
            if [ -n "$have" ] && version_ge "$have" "$floor"; then
                anodizer::vdetail "satisfied ${bins[*]}: '$b' $have on PATH (>= $floor floor)"
                return 0
            fi
            anodizer::vdetail "under-floor ${bins[*]}: '$b' ${have:-<unknown>} on PATH < $floor floor; installing the upgrade"
            # Fall through (no return): the map_binary loop below must still
            # run so the mapped install keyword lands in deps.
        fi
    done

    for b in "${bins[@]}"; do
        kw="$(map_binary "$b")"
        case "$kw" in
            AMBIENT)
                anodizer::vdetail "satisfied ${bins[*]}: '$b' provided by the runner environment"
                return 0
                ;;
            "") continue ;;
            *)
                if [ -z "${_seen[$kw]:-}" ]; then
                    _seen[$kw]=1
                    deps+=("$kw")
                fi
                return 0
                ;;
        esac
    done

    if [ "$advisory" = "true" ]; then
        anodizer::vdetail "skipped ${bins[*]}: advisory tool with no install recipe (pipeline degrades gracefully)"
    else
        gha_warning "auto-install: no install recipe for required tool '${bins[*]}' — preinstall it on the runner or add it to the 'install:' input"
        anodizer::warn "no install recipe for required '${bins[*]}'"
    fi
}

while IFS=$'\t' read -r advisory any_of; do
    [ -z "$any_of" ] && continue
    # shellcheck disable=SC2086  # any_of is a space-joined binary list, split intentionally
    resolve_requirement "$advisory" $any_of
done < <(jq -r '.tools[] | [(.advisory | tostring), (.any_of | join(" "))] | @tsv' <<< "$tools_json")

joined="$(
    IFS=','
    echo "${deps[*]}"
)"
anodizer::kv detected "${joined:-none}"
gha_set_output deps "$joined"
