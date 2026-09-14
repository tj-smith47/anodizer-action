#!/usr/bin/env bats
# auto-detect-deps.bats — unit tests for scripts/install/auto-detect-deps.sh.
#
# The script no longer parses the config: it asks `anodizer tools --json` for
# the authoritative tool set (that logic, and the per-stage/per-publisher
# detection it replaced, is owned and tested by anodizer itself) and translates
# the reported BINARY names into deps.sh install KEYWORDS. These tests pin that
# translation layer — the binary→keyword map, any_of resolution, ambient
# skipping, scope-flag forwarding, the loud warning for an unmapped required
# tool, and the graceful fallbacks — by driving the script against a FAKE
# `anodizer` whose `tools --json` output (and recorded argv) the test controls.
#
# A minimal PATH (the script's own externals + the fake anodizer, no pipeline
# tools) is used so the "already on PATH ⇒ no install" branch doesn't mask the
# map on a developer box that happens to have cosign/snapcraft/etc. installed.

load test_helper

setup() {
    common_setup
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_OUTPUT"

    CLEAN_BIN="${_TEST_HOME}/bin"
    mkdir -p "$CLEAN_BIN"
    local c
    # sort + tail back the npm-floor version_ge comparison; every other name
    # here backs the script's other, non-floor resolution logic.
    for c in bash cat dirname env grep head jq mktemp rm sed sort tail tr; do
        path_shim "$CLEAN_BIN" "$c"
    done

    FAKE_ARGS_LOG="${_TEST_HOME}/anodizer-args.log"
    : > "$FAKE_ARGS_LOG"
    WORKDIR="${_TEST_HOME}/workdir"
    mkdir -p "$WORKDIR"
    # Presence-only: the script's config probe must find SOMETHING; the fake
    # anodizer never reads it.
    printf 'version: 2\n' > "${WORKDIR}/.anodizer.yaml"
}

teardown() {
    common_teardown
}

# Install a fake `anodizer` that records its argv and prints $1 as the
# `tools --json` payload (exit $2, default 0).
_fake_anodizer() {
    local json="$1" rc="${2:-0}"
    cat > "${CLEAN_BIN}/anodizer" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '${FAKE_ARGS_LOG}'
case " \$* " in
    *" tools "*) printf '%s\n' '${json}'; exit ${rc} ;;
esac
exit 0
EOF
    chmod +x "${CLEAN_BIN}/anodizer"
}

# Install a fake `npm` on PATH whose `--version` prints $1, mirroring real
# npm's bare `X.Y.Z` output (no leading "v" or extra text).
_fake_npm() {
    local version="$1"
    cat > "${CLEAN_BIN}/npm" << EOF
#!/usr/bin/env bash
echo "${version}"
EOF
    chmod +x "${CLEAN_BIN}/npm"
}

# Install a fake `anodizer` whose `tools` subcommand fails (emulates an
# anodizer predating the command, or an invalid config).
_fake_anodizer_no_tools() {
    cat > "${CLEAN_BIN}/anodizer" << EOF
#!/usr/bin/env bash
echo "error: unrecognized subcommand 'tools'" >&2
exit 2
EOF
    chmod +x "${CLEAN_BIN}/anodizer"
}

_run() {
    local args="${1:-release}"
    run env -i \
        HOME="$HOME" \
        PATH="$CLEAN_BIN" \
        NO_COLOR=1 \
        RUNNER_OS="${RUNNER_OS:-Linux}" \
        GITHUB_OUTPUT="$GITHUB_OUTPUT" \
        ANODIZER_ARGS="$args" \
        bash -c "cd '${WORKDIR}' && bash '${REPO_ROOT}/scripts/install/auto-detect-deps.sh'"
}

# The emitted deps CSV (empty string when unset).
_deps() { sed -n 's/^deps=//p' "$GITHUB_OUTPUT"; }

# Assert keyword $1 IS present in the deps CSV.
_has_dep() { [[ ",$(_deps)," == *",$1,"* ]]; }
# Assert keyword $1 is NOT present in the deps CSV.
_no_dep() { [[ ",$(_deps)," != *",$1,"* ]]; }

# ── binary → keyword map ─────────────────────────────────────────────────────

@test "map: single-tool requirements translate to their install keywords" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["cosign"],"advisory":false},{"any_of":["syft"],"advisory":false},{"any_of":["nfpm"],"advisory":false},{"any_of":["makensis"],"advisory":false},{"any_of":["upx"],"advisory":false},{"any_of":["rpmbuild"],"advisory":false},{"any_of":["linuxdeploy"],"advisory":false},{"any_of":["rcodesign"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep cosign
    _has_dep syft
    _has_dep nfpm
    _has_dep nsis        # makensis → nsis
    _has_dep upx
    _has_dep rpmbuild
    _has_dep linuxdeploy
    _has_dep rcodesign
}

@test "map: npm binary maps to the node keyword" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["npm"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep node
    _no_dep npm
}

@test "map: cross toolchain (zig + cargo-zigbuild) is emitted" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["zig"],"advisory":true},{"any_of":["cargo-zigbuild"],"advisory":true}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep zig
    _has_dep cargo-zigbuild
}

@test "map: kms CLIs (aws/gcloud/az) pass through verbatim" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["aws"],"advisory":false},{"any_of":["gcloud"],"advisory":false},{"any_of":["az"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep aws
    _has_dep gcloud
    _has_dep az
}

# ── WiX dialect (anodizer resolves the dialect; the action installs it) ───────

@test "map: WiX v4 binary maps to wix; v3 (candle/light/wixl) maps to wix3" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["wix"],"advisory":false}]}'
    _run
    _has_dep wix
    _no_dep wix3

    : > "$GITHUB_OUTPUT"
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["candle"],"advisory":false},{"any_of":["light"],"advisory":false}]}'
    _run
    _has_dep wix3
    _no_dep wix

    : > "$GITHUB_OUTPUT"
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["wixl"],"advisory":false}]}'
    _run
    _has_dep wix3
}

@test "map: xmllint (chocolatey nuspec validation) maps to the xmllint keyword" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["xmllint"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep xmllint
    [[ "$output" != *"::warning::"* ]]
}

@test "map: ruby (homebrew formula syntax check, advisory) maps to the ruby keyword" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["ruby"],"advisory":true}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep ruby
    [[ "$output" != *"::warning::"* ]]
}

# ── any_of groups ────────────────────────────────────────────────────────────

@test "any_of: the dmg group resolves to create-dmg (single keyword)" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["hdiutil","genisoimage","mkisofs"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep create-dmg
}

@test "any_of: the pkg group (pkgbuild|xar) resolves to pkgbuild" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["pkgbuild","xar"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep pkgbuild
}

@test "any_of: a binary already on PATH satisfies the group with no install" {
    # jq is present in the minimal PATH; a requirement on it must install nothing.
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["jq"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [ -z "$(_deps)" ]
    [[ "$output" != *"::warning::"* ]]
}

# ── npm Trusted-Publishing floor (version-aware satisfaction) ────────────────

@test "floor: npm on PATH below the OIDC floor still installs node" {
    _fake_npm "10.9.3"
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["npm"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep node
}

@test "floor: npm on PATH exactly at the OIDC floor is satisfied; node is not installed" {
    _fake_npm "11.5.1"
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["npm"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [ -z "$(_deps)" ]
    _no_dep node
}

@test "floor: npm on PATH above the OIDC floor is satisfied; node is not installed" {
    _fake_npm "12.0.0"
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["npm"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [ -z "$(_deps)" ]
    _no_dep node
}

@test "floor: npm absent from PATH still installs node (regression guard)" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["npm"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep node
}

# ── ambient tools + dedup ────────────────────────────────────────────────────

@test "ambient: runner-provided tools (cargo/git/gpg/ssh/docker) install nothing and never warn" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["cargo"],"advisory":false},{"any_of":["git"],"advisory":false},{"any_of":["gpg"],"advisory":false},{"any_of":["ssh"],"advisory":false},{"any_of":["docker"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [ -z "$(_deps)" ]
    [[ "$output" != *"::warning::"* ]]
}

@test "map: flatpak + flatpak-builder collapse to a single flatpak keyword" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["flatpak"],"advisory":false},{"any_of":["flatpak-builder"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [ "$(_deps)" = "flatpak" ]
}

@test "dedup: snapcraft + unsquashfs collapse to a single snapcraft keyword" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["snapcraft"],"advisory":false},{"any_of":["unsquashfs"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [ "$(_deps)" = "snapcraft" ]
}

@test "map: a cosign* command variant still maps to the cosign keyword" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["cosign-fips"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    _has_dep cosign
}

# ── scope + config forwarding ────────────────────────────────────────────────

@test "scope: --publish-only / --skip / --publishers are forwarded to anodizer tools" {
    _fake_anodizer '{"schema_version":1,"tools":[]}'
    _run "release --publish-only --skip=npm --publishers cargo,homebrew"
    [ "$status" -eq 0 ]
    # The script normalises space-form flags to =-form before forwarding.
    grep -q -- '--publish-only' "$FAKE_ARGS_LOG"
    grep -q -- '--skip=npm' "$FAKE_ARGS_LOG"
    grep -q -- '--publishers=cargo,homebrew' "$FAKE_ARGS_LOG"
}

@test "scope: space-form --skip <csv> is forwarded as --skip=<csv>" {
    _fake_anodizer '{"schema_version":1,"tools":[]}'
    _run "release --publish-only --skip npm"
    [ "$status" -eq 0 ]
    grep -q -- '--skip=npm' "$FAKE_ARGS_LOG"
}

@test "config: -f/--config from args is forwarded (before the subcommand)" {
    _fake_anodizer '{"schema_version":1,"tools":[]}'
    _run "release -f custom.yaml"
    [ "$status" -eq 0 ]
    # -f/--config is normalised to --config=<path> and precedes the subcommand.
    grep -qE -- '--config=custom.yaml +tools' "$FAKE_ARGS_LOG"
}

# ── failure visibility ───────────────────────────────────────────────────────

@test "warn: a required tool with no install recipe warns loudly and is not dropped silently" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["cyclonedx"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"*"cyclonedx"* ]]
    _no_dep cyclonedx
}

@test "advisory: an unmapped advisory tool is skipped quietly (no warning)" {
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["some-advisory-tool"],"advisory":true}]}'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"::warning::"* ]]
    [ -z "$(_deps)" ]
}

@test "fallback: when 'anodizer tools' fails, warn and emit an empty set (no crash)" {
    _fake_anodizer_no_tools
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    [ -z "$(_deps)" ]
}

@test "fallback: no config in the workdir warns and emits an empty set" {
    rm -f "${WORKDIR}/.anodizer.yaml"
    _fake_anodizer '{"schema_version":1,"tools":[{"any_of":["cosign"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"*"no anodizer config"* ]]
    [ -z "$(_deps)" ]
}

@test "schema: an unexpected schema_version warns but still parses the tools" {
    _fake_anodizer '{"schema_version":99,"tools":[{"any_of":["cosign"],"advisory":false}]}'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"*"schema_version"* ]]
    _has_dep cosign
}
