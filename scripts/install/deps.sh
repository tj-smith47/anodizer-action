#!/usr/bin/env bash
# Install anodizer pipeline dependencies via the platform-native package manager.
#
# Merges $EXPLICIT_INSTALL, $AUTO_INSTALL, and $DETERMINISM_INSTALL (comma-
# separated lists), dedupes, and installs each requested dep.
#
# Recognised deps: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig,
# node, cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra, linuxdeploy,
# rcodesign, wix, wix3, pkgbuild, clang-cl, nasm, xmllint. (`wix` is the v4
# dialect — `wix build` / dotnet global tool; `wix3` is the v3 dialect —
# candle+light via choco wixtoolset. Both fall back to wixl on Linux.
# `clang-cl` is Windows-only — the determinism harness's pinned MSVC C/C++
# compiler. `nasm` is also Windows-only — aws-lc-sys hard-requires it on PATH
# to assemble its perlasm .asm on windows-msvc. `xmllint` backs the chocolatey
# prepublish guard's .nuspec schema validation.)
set -euo pipefail

# shellcheck source=../lib/gha.sh
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

: "${RUNNER_OS:?RUNNER_OS is required}"
EXPLICIT_INSTALL="${EXPLICIT_INSTALL:-}"
AUTO_INSTALL="${AUTO_INSTALL:-}"
DETERMINISM_INSTALL="${DETERMINISM_INSTALL:-}"

# Pinned defaults must be updated together — sha256 is keyed to version.
# Override with ALEJANDRA_VERSION + ALEJANDRA_SHA256 (both required) when
# pulling a different release.
ALEJANDRA_DEFAULT_VERSION="4.0.0"
ALEJANDRA_DEFAULT_SHA_AMD64="a23b9d47cba945805c6169541046de890e94e07a5aa416c86dee15bca2da6216"
ALEJANDRA_DEFAULT_SHA_ARM64="a30b0d54ee3f0d6633d0398b50258408d2cc31646a9c8c4ba3ee4ebf2cebd8c8"

# linuxdeploy + its appimage output plugin drive anodizer's `appimages:` stage.
# Both also publish a rolling `continuous` release that re-rolls its asset bytes
# in place, so a sha pinned to `continuous` silently drifts the moment upstream
# republishes — `sha256sum -c` then fails and the whole release errors. The
# defaults below therefore pin the newest *immutable* dated tag each project
# ships (they version independently — linuxdeploy and the plugin carry DIFFERENT
# tags), with shas computed by download-and-sha256 of each pinned asset (no
# upstream checksums file exists). Override the linuxdeploy binary with
# LINUXDEPLOY_VERSION + LINUXDEPLOY_SHA256/LINUXDEPLOY_PLUGIN_SHA256 (the two
# shas required together; an override without its own shas is rejected, mirroring
# the alejandra pin); override the plugin tag independently with
# LINUXDEPLOY_PLUGIN_VERSION.
LINUXDEPLOY_DEFAULT_VERSION="1-alpha-20251107-1"
LINUXDEPLOY_PLUGIN_DEFAULT_VERSION="1-alpha-20250213-1"
LINUXDEPLOY_DEFAULT_SHA_AMD64="c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d"
LINUXDEPLOY_DEFAULT_SHA_ARM64="620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff"
LINUXDEPLOY_PLUGIN_DEFAULT_SHA_AMD64="992d502a248e14ab185448ddf6f6e7d25558cb84d4623c354c3af350c25fccb3"
LINUXDEPLOY_PLUGIN_DEFAULT_SHA_ARM64="83c292149274965a865dcd44c135cfca8ba28c6b7de3eb628d4b8b5f248af17c"

# rcodesign (the apple-codesign project, indygreg/apple-platform-rs) drives
# anodizer's cross-platform `notarize.macos:` path. Release tarballs are named
# `apple-codesign-<ver>-<triple>.tar.gz` and carry the `rcodesign` binary one
# directory deep (verified by `tar -tzf`). Upstream ships NO checksums file, so
# the shas below were computed by download-and-sha256sum of each pinned asset.
# Override with RCODESIGN_VERSION + the matching *_SHA_* env vars (all required
# together — an override without its own shas is rejected, mirroring the
# alejandra/linuxdeploy pins).
RCODESIGN_DEFAULT_VERSION="0.29.0"
RCODESIGN_DEFAULT_SHA_LINUX_AMD64="dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002"
RCODESIGN_DEFAULT_SHA_LINUX_ARM64="4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f"
RCODESIGN_DEFAULT_SHA_MACOS_AMD64="14ef11bedd51a8d95eafd767939ae96d5900e5a61511bef75bb21db6e7c74140"
RCODESIGN_DEFAULT_SHA_MACOS_ARM64="d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a"

# WiX v4 is anodizer's default MSI toolchain (`wix build`); the CLI is the
# `wix` dotnet global tool. Pinned for reproducibility — override with
# WIX_VERSION. dotnet (the host for the global tool) is preinstalled on the
# GitHub windows runner images.
WIX_DEFAULT_VERSION="4.0.6"

# WiX v3 (candle+light) is the toolchain for v3-dialect .wxs files on Windows,
# installed via the `wixtoolset` choco package. Override the choco package
# version with WIX3_VERSION; unset lets choco resolve its latest. The v3
# toolset ships candle.exe/light.exe — the v4 `wix` dotnet tool does not.

# snapcraft's PyPI releases stopped at 4.8.1 (June 2021 — pre-dates
# SNAPCRAFT_STORE_CREDENTIALS), so the no-snapd fallback installs from the
# upstream git tag instead, constrained to that tag's own uv.lock. The pin
# tracks the snap store's latest/stable channel so a pip-installed snapcraft
# matches the version a snapd-equipped runner gets from
# `snap install snapcraft`. Override with SNAPCRAFT_VERSION (also honoured
# by the macOS brew path).
SNAPCRAFT_DEFAULT_VERSION="8.14.5"

# node/npm back the `npms:` publisher, which publishes anodizer's npm
# metapackage via npm Trusted Publishing (OIDC) — that handshake needs
# Node >= 22.14.0 / npm >= 11.5.1. The node pin tracks the v22 LTS line, which
# satisfies the Node floor; the npm it BUNDLES does NOT — the entire 22.x line
# ships npm 10.9.x (and even Node 24.0.0 bundles only 11.3.0), all below the
# 11.5.1 OIDC floor. So npm is pinned and upgraded independently of node's
# bundled copy (`npm install -g npm@$NPM_VERSION`) rather than relying on the
# bundle. The Linux node installer verifies the tarball against nodejs.org's
# published SHASUMS256.txt (no hardcoded sha to drift; the dated dist dir is
# immutable). Override either independently with NODE_VERSION / NPM_VERSION
# (both honoured across the Linux + macOS brew + Windows choco paths).
NODE_DEFAULT_VERSION="22.22.3"
# Floor is npm >= 11.5.1 (Trusted Publishing OIDC). Keep the default at or above
# that floor; bumping it tracks the current 11.x line.
NPM_DEFAULT_VERSION="11.5.1"

# nfpm drives anodizer's deb/rpm/apk publishers. On Linux it installs via a
# direct, checksum-verified GitHub-release download (mirroring cosign/syft)
# rather than the goreleaser apt repo — keeping a third-party apt source out of
# the runner and the single batched `apt-get update` honest. The release ships
# a `checksums.txt`, so the tarball is verified against it (no hardcoded sha to
# drift). Override with NFPM_VERSION (also honoured by the macOS brew path).
NFPM_DEFAULT_VERSION="2.46.3"

# zig backs cargo-zigbuild cross-compilation (Linux-only in the harness's
# dependency sets). The pin must ship libc headers for EVERY cross target the
# harness supports: zig <= 0.13.0's bundled libc omitted
# generic-freebsd/assert.h, which broke every C-crypto crate (ring,
# aws-lc-sys) cross-built to x86_64-unknown-freebsd — a supported-target
# failure no local check caught until a consumer's release run hit it. Keep
# this at the current stable zig: cargo-zigbuild (installed unpinned = latest
# from crates.io) tests current stable zig in its own CI, so the two move
# together. Bumping across zig releases can raise the default glibc floor of
# *-gnu cross builds (0.13 → 2.28; 0.15/0.16 → 2.31 for x86_64/aarch64) —
# projects needing an older floor pin it per-target in anodizer config
# (`<triple>.<glibc>`), not here. Override with ZIG_VERSION alone; no
# companion sha var exists because the tarball URL AND sha256 are both read
# from ziglang.org/download/index.json at install time.
ZIG_DEFAULT_VERSION="0.16.0"

DEPS=()

# Deps whose Linux installer only `apt_queue`s a stock package (no inline
# flush, no direct download): their lifecycle is carried entirely by the single
# "installing apt batch: …" header + the per-package `✓` apt_flush emits, so the
# dispatch loop suppresses the generic per-tool "installing X" line for them to
# avoid a duplicate. flatpak/pkgbuild also queue but flush inline and self-log,
# so they are NOT listed here. Membership is only consulted on Linux.
_APT_BATCHED_DEPS=" makeself rpmbuild upx nsis create-dmg wix wix3 xmllint "

# True when $1's installer on this runner just queues a stock apt package
# (so the batch header/✓ carry its log, not the generic per-tool lines).
_is_apt_batched() {
    [ "$RUNNER_OS" = "Linux" ] || return 1
    case "$_APT_BATCHED_DEPS" in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ── input merge + dedupe ─────────────────────────────────────────────

merge_dep_inputs() {
    local combined="${EXPLICIT_INSTALL}" extra
    # Merge order: explicit (user) → auto-detect (.anodizer.yaml) →
    # determinism (action-derived). Dedupe collapses overlaps.
    for extra in "$AUTO_INSTALL" "$DETERMINISM_INSTALL"; do
        [ -z "$extra" ] && continue
        if [ -n "$combined" ]; then
            combined="${combined},${extra}"
        else
            combined="$extra"
        fi
    done
    echo "$combined"
}

dedupe_deps() {
    # POSIX-safe linear scan (macOS ships bash 3.2 — no associative arrays).
    local combined="$1" dep seen_list=""
    local -a raw
    IFS=',' read -ra raw <<< "$combined"
    DEPS=()
    for dep in "${raw[@]}"; do
        dep=$(echo "$dep" | xargs)
        [ -z "$dep" ] && continue
        case ",${seen_list}," in
            *",${dep},"*) ;;
            *)
                DEPS+=("$dep")
                seen_list="${seen_list:+${seen_list},}${dep}"
                ;;
        esac
    done
}

# ── apt batching ─────────────────────────────────────────────────────

APT_PKGS=()
APT_NAMES=()
apt_queue() {
    APT_PKGS+=("$1")
    APT_NAMES+=("$2")
}
# Runs `apt-get update` at most once per process — the flag below latches on
# the first flush (or any caller that needs a fresh index) so a batch and a
# later snapcraft apt-needs install don't re-index every repo.
_APT_UPDATED=""
apt_update_once() {
    [ -n "$_APT_UPDATED" ] && return 0
    anodizer::run_quiet sudo apt-get update -q \
        || gha_fail "apt-get update failed"
    _APT_UPDATED=1
}
apt_flush() {
    [ "${#APT_PKGS[@]}" -eq 0 ] && return
    anodizer::vstep "installing apt batch: ${APT_NAMES[*]}"
    apt_update_once
    DEBIAN_FRONTEND=noninteractive \
        anodizer::run_quiet sudo apt-get install -yq "${APT_PKGS[@]}" < /dev/null \
        || gha_fail "apt batch install failed for: ${APT_NAMES[*]}"
    local name
    for name in "${APT_NAMES[@]}"; do
        anodizer::vok "${name} installed"
    done
    APT_PKGS=()
    APT_NAMES=()
}

# ── shared installer helpers ─────────────────────────────────────────

# Returns 0 when unsquashfs is on PATH; overridable in tests to simulate
# a runner image that lacks squashfs-tools.
_squashfs_tools_available() {
    command -v unsquashfs > /dev/null 2>&1
}

skip_unsupported_os() {
    local tool="$1"
    local reason="${2:-not natively supported on ${RUNNER_OS}}"
    # An OS-incompatible tool omitted on this runner is a correct routing
    # decision, not a warning — keep it out of the annotation summary and quiet
    # on a green run (visible under anodizer::verbose for debugging).
    anodizer::vdetail "skipped ${tool}: ${reason}"
}

# Probe for `$1` on PATH (overridable in tests to simulate a runner image
# that lacks the tool). A thin wrapper so ensure_on_path's lookup has a single
# seam tests can stub without redefining `command`.
_tool_on_path() {
    command -v "$1" > /dev/null 2>&1
}

# Verify an ENVIRONMENT-PROVIDED external tool is already on PATH, rather than
# installing it. Two dep classes route here (see dispatch_install): the cloud
# KMS CLIs (aws/gcloud/az) and an arbitrary `sboms.cmd:` generator. anodizer
# never bundles installers for these — they are expected on the runner image
# (GitHub-hosted runners preinstall the cloud CLIs; self-hosted images and the
# user's own SBOM generator are provisioned by the operator).
#
# Present  → success no-op (the tool is ready; the stage will spawn it).
# Absent   → `gha_fail` with an ACTIONABLE message naming the config field that
#            demanded it, so the operator knows exactly what to install and why
#            — never a silent skip (a missing KMS CLI would otherwise surface as
#            a cryptic stage-blob failure mid-publish).
#
# `$1` = tool name, `$2` = the config trigger phrase for the diagnostic.
ensure_on_path() {
    local tool="$1" trigger="$2"
    if _tool_on_path "$tool"; then
        anodizer::vok "${tool} already on PATH (${trigger})"
        _INSTALLER_EMITTED_OK=1
        return 0
    fi
    gha_fail "${tool} required by ${trigger} but not on PATH — install it on the runner"
}

# If `$<var>` is set, pin the brew formula to `<formula>@<version>`.
brew_install() {
    # `var` documents that $2 is the env-var name; the indirection in
    # `${!2:-}` reads its value. shellcheck cannot see the indirect use.
    # shellcheck disable=SC2034
    local formula="$1" var="$2" version="${!2:-}"
    if [ -n "$version" ]; then
        anodizer::run_quiet brew install "${formula}@${version}"
    else
        anodizer::run_quiet brew install "$formula"
    fi
}

# If `$<var>` is set, pass `--version=<version>` to choco.
choco_install() {
    # shellcheck disable=SC2034
    local pkg="$1" var="$2" version="${!2:-}"
    if [ -n "$version" ]; then
        anodizer::run_quiet choco install "$pkg" -y --no-progress --version="$version"
    else
        anodizer::run_quiet choco install "$pkg" -y --no-progress
    fi
}

# Look up `$2`'s SHA256 in a `<sha>  <filename>` checksums file (`$1`).
# Echoes the SHA; bails (with location detail) when the filename is absent.
sha_from_checksums() {
    local file="$1" name="$2" sha
    sha=$(grep " ${name}\$" "$file" | awk '{print $1}')
    [ -n "$sha" ] || gha_fail "checksum entry for ${name} not found in $(basename "$file")"
    echo "$sha"
}

# Number of fetch attempts on the tool-DOWNLOAD path (override for tests/tuning).
ANODIZER_FETCH_ATTEMPTS="${ANODIZER_FETCH_ATTEMPTS:-3}"

# Retry a download command with exponential backoff. Dependency installs pull
# tool tarballs/binaries/checksums over the network; a single transient blip
# (e.g. curl exit 18 — partial transfer) otherwise aborts the whole install,
# and on a determinism shard surfaces as a SPURIOUS determinism failure even
# though the bytes that half-arrived are irrelevant once re-fetched. Re-attempt
# a few times before giving up; on the final attempt the wrapped command's own
# non-zero exit propagates unchanged, so `set -e` and a trailing
# `|| gha_fail …` still fire exactly as before.
#
# This wraps only the DOWNLOAD/INSTALL path. The determinism VERIFICATION loop
# in scripts/determinism/run-harness.sh deliberately documents "No retry loop
# here" — a retry there would mask real drift — and is left untouched.
#
#   fetch_retry anodizer::fetch "$url" "$dest"
fetch_retry() {
    local attempt=1 delay=2 rc=0
    while true; do
        rc=0
        "$@" || rc=$?
        [ "$rc" -eq 0 ] && return 0
        if [ "$attempt" -ge "$ANODIZER_FETCH_ATTEMPTS" ]; then
            return "$rc"
        fi
        anodizer::vdetail "fetch failed (exit ${rc}); retry ${attempt}/$((ANODIZER_FETCH_ATTEMPTS - 1)) in ${delay}s"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# ── per-dep installers ───────────────────────────────────────────────

nfpm_install_linux() {
    local version="${NFPM_VERSION:-$NFPM_DEFAULT_VERSION}"
    local arch
    case "$RUNNER_ARCH" in
        # nfpm's release assets name x86_64 long-form but arm64 short-form
        # (nfpm_<ver>_Linux_x86_64.tar.gz vs ..._Linux_arm64.tar.gz).
        X64)   arch=x86_64 ;;
        ARM64) arch=arm64 ;;
        *)     gha_fail "Unsupported Linux arch for nfpm: $RUNNER_ARCH" ;;
    esac
    local base="https://github.com/goreleaser/nfpm/releases/download/v${version}"
    local tarball="nfpm_${version}_Linux_${arch}.tar.gz"
    local install_dir="${RUNNER_TEMP:-/tmp}/nfpm"
    mkdir -p "$install_dir"

    fetch_retry anodizer::fetch "${base}/${tarball}" "${install_dir}/${tarball}"
    fetch_retry anodizer::fetch "${base}/checksums.txt" "${install_dir}/checksums.txt"
    # Verify against the release's signed checksums.txt — no hardcoded sha to
    # drift, the tag is immutable so the bytes are stable.
    local expected
    expected=$(sha_from_checksums "${install_dir}/checksums.txt" "$tarball")
    anodizer::run_quiet bash -c "echo '${expected}  ${install_dir}/${tarball}' | sha256sum -c -"

    # The tarball carries the bare `nfpm` binary at its root (verified via
    # `tar -tzf`); extract just that onto PATH.
    tar -xzf "${install_dir}/${tarball}" -C "$install_dir" nfpm
    chmod +x "${install_dir}/nfpm"
    gha_add_path "$install_dir"
    anodizer::vok "nfpm ${version} (${arch}) installed at ${install_dir}/nfpm"
    _INSTALLER_EMITTED_OK=1
}

install_nfpm() {
    case "$RUNNER_OS" in
        Linux)   nfpm_install_linux ;;
        macOS)   brew_install goreleaser/tap/nfpm NFPM_VERSION ;;
        # nfpm has no chocolatey package, and nfpm's stage (deb/rpm/apk
        # packaging) is never host-native on Windows — the determinism
        # partition builds msi/nsis there, not nfpm. Skip like the other
        # Linux/macOS-only packagers (makeself/rpmbuild/snapcraft) rather than
        # hard-failing on a missing choco source.
        Windows) skip_unsupported_os nfpm "Linux/macOS only (no chocolatey package; deb/rpm packaging runs on Unix runners)" ;;
    esac
}

install_makeself() {
    case "$RUNNER_OS" in
        Linux)   apt_queue makeself makeself ;;
        macOS)   brew_install makeself MAKESELF_VERSION ;;
        Windows) skip_unsupported_os makeself ;;
    esac
}

# Convert a uv.lock (`$1`) into `name==version` pip constraint lines on
# stdout. Skips non-registry packages (the project itself) and names whose
# lock holds conflicting versions across dependency-group forks (dev/docs
# only in snapcraft's lock) — pip rejects conflicting duplicate constraints,
# and every runtime dependency resolves to a single locked version.
snapcraft_lock_to_constraints() {
    python3 - "$1" <<'PYEOF'
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("python >= 3.11 (tomllib) required to derive pip constraints from uv.lock\n")
    sys.exit(1)

with open(sys.argv[1], "rb") as f:
    lock = tomllib.load(f)
versions = {}
for pkg in lock["package"]:
    if "registry" not in pkg.get("source", {}):
        continue
    versions.setdefault(pkg["name"], set()).add(pkg["version"])
for name in sorted(versions):
    if len(versions[name]) == 1:
        print(f"{name}=={versions[name].pop()}")
PYEOF
}

# Containerised runners (e.g. ARC pods) have no snapd — snapd cannot run
# inside a container — so `snap install snapcraft` is impossible there. A
# pip install covers the publish-only case: `snapcraft upload` needs just
# the CLI + SNAPCRAFT_STORE_CREDENTIALS, no snapd/lxd/multipass (the .snap
# itself is packed on a snapd-equipped runner). PyPI's snapcraft is
# abandoned at 4.8.1, so the install pulls the upstream git tag, with the
# tag's uv.lock as a pip constraints file — an unconstrained resolve picks
# a newer craft-application whose lifecycle-command API breaks snapcraft at
# import time.
snapcraft_install_linux_pip() {
    local version="${SNAPCRAFT_VERSION:-$SNAPCRAFT_DEFAULT_VERSION}"
    command -v python3 > /dev/null 2>&1 \
        || gha_fail "snapcraft: no snapd and no python3 on this runner — preinstall snapcraft in the runner image, or provide python3 + pip for the pip fallback"
    command -v git > /dev/null 2>&1 \
        || gha_fail "snapcraft: the pip fallback installs from a git tag and requires git on PATH"
    local -a apt_needs=()
    command -v pipx > /dev/null 2>&1 || python3 -m pip --version > /dev/null 2>&1 \
        || apt_needs+=(python3-pip)
    # snapcraft imports the distro's apt bindings at startup on Linux
    # (snapcraft_legacy's repo module does `import apt` unconditionally).
    # python-apt is not pip-installable from PyPI, so it must come from the
    # system package manager and stay visible to the snapcraft install —
    # hence --user / --system-site-packages below rather than an isolated
    # venv.
    python3 -c 'import apt' > /dev/null 2>&1 \
        || apt_needs+=(python3-apt)
    # snapcraft_legacy/_store.py calls get_snap_tool_path("unsquashfs") during
    # upload to inspect the .snap — missing squashfs-tools raises
    # ToolMissingError() at runtime, not at install time.
    _squashfs_tools_available \
        || apt_needs+=(squashfs-tools)
    if [ "${#apt_needs[@]}" -gt 0 ]; then
        if ! command -v apt-get > /dev/null 2>&1; then
            # No apt-get: fail with actionable guidance naming the missing tool.
            _squashfs_tools_available \
                || gha_fail "snapcraft: unsquashfs not found and no apt-get to install squashfs-tools — add squashfs-tools to your runner image"
            gha_fail "snapcraft: no snapd, and the pip fallback needs ${apt_needs[*]} (no apt-get available to install them) — preinstall snapcraft in the runner image"
        fi
        anodizer::vdetail "installing ${apt_needs[*]} via apt for the pip fallback"
        apt_update_once
        DEBIAN_FRONTEND=noninteractive \
            anodizer::run_quiet sudo apt-get install -yq "${apt_needs[@]}" < /dev/null \
            || gha_fail "snapcraft: apt install of ${apt_needs[*]} failed — preinstall snapcraft (or these packages) in the runner image"
    fi

    local workdir="${RUNNER_TEMP:-/tmp}/snapcraft-pip"
    mkdir -p "$workdir"
    fetch_retry anodizer::fetch "https://raw.githubusercontent.com/canonical/snapcraft/${version}/uv.lock" "${workdir}/uv.lock" \
        || gha_fail "snapcraft: failed to fetch uv.lock for tag ${version} — does the tag exist upstream?"
    snapcraft_lock_to_constraints "${workdir}/uv.lock" > "${workdir}/constraints.txt" \
        || gha_fail "snapcraft: could not derive pip constraints from uv.lock for ${version}"
    # An empty constraints file silently degrades to an unconstrained
    # resolve — the exact failure mode the lock exists to prevent.
    [ -s "${workdir}/constraints.txt" ] \
        || gha_fail "snapcraft: uv.lock for ${version} yielded no constraints — lock schema changed?"

    local spec="git+https://github.com/canonical/snapcraft@${version}"
    if command -v pipx > /dev/null 2>&1; then
        # PIP_CONSTRAINT reaches the pip inside pipx's venv, constraining
        # the whole dependency resolve (--pip-args would not).
        # --system-site-packages keeps the distro's python-apt visible —
        # an isolated venv breaks snapcraft at import.
        anodizer::run_quiet env PIP_CONSTRAINT="${workdir}/constraints.txt" \
            pipx install --system-site-packages "$spec" \
            || gha_fail "snapcraft: pipx install failed for ${spec}"
    else
        local -a pip_args=(--user)
        # PEP 668: Ubuntu >= 24.04 marks the system interpreter
        # externally-managed; --user installs need the explicit opt-out.
        local stdlib
        stdlib=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
        [ -f "${stdlib}/EXTERNALLY-MANAGED" ] && pip_args+=(--break-system-packages)
        python3 -m pip install "${pip_args[@]}" --quiet \
            --constraint "${workdir}/constraints.txt" "$spec" \
            || gha_fail "snapcraft: pip install failed for ${spec}"
    fi
    # Both pipx and pip --user land console scripts in ~/.local/bin; expose
    # it to later workflow steps AND to this shell for the probe below.
    gha_add_path "${HOME}/.local/bin"
    export PATH="${HOME}/.local/bin:${PATH}"
    # Run the CLI, don't just stat it — a missing runtime module (e.g.
    # python-apt outside the venv) only surfaces at import time.
    local probe
    probe=$(snapcraft version 2>&1) \
        || gha_fail "snapcraft: installed but 'snapcraft version' failed — ${probe}"
    # Assert early: upload calls get_snap_tool_path("unsquashfs") and raises
    # ToolMissingError() if the binary is absent — catch it at install time.
    _squashfs_tools_available \
        || gha_fail "snapcraft: unsquashfs not found — install squashfs-tools in the runner image (snapcraft upload requires it)"
    anodizer::vok "snapcraft ${version} installed via pip (upload-capable; packing snaps still needs a snapd-equipped runner)"
    _INSTALLER_EMITTED_OK=1
}

install_snapcraft() {
    case "$RUNNER_OS" in
        Linux)
            # Run the CLI rather than stat it: a broken preinstall (e.g. a
            # venv missing python-apt) must fall through to a fresh install,
            # not pass here and die later at upload.
            # No unsquashfs assertion here: a preinstalled snapcraft means the
            # runner image's build-time `command -v unsquashfs` gate already ran.
            if snapcraft version > /dev/null 2>&1; then
                anodizer::vdetail "snapcraft already present ($(command -v snapcraft))"
                return
            fi
            # `snap version` succeeds only when the client can reach a live
            # snapd socket; a bare `command -v snap` would wrongly take the
            # snap path in containers that ship the client without snapd.
            if command -v snap > /dev/null 2>&1 && snap version > /dev/null 2>&1; then
                anodizer::run_quiet sudo snap install snapcraft --classic
            else
                snapcraft_install_linux_pip
            fi
            ;;
        macOS)   brew_install snapcraft SNAPCRAFT_VERSION ;;
        Windows) skip_unsupported_os snapcraft ;;
    esac
}

install_rpmbuild() {
    case "$RUNNER_OS" in
        Linux)   apt_queue rpm rpmbuild ;;
        macOS)   brew_install rpm RPM_VERSION ;;
        Windows) skip_unsupported_os rpmbuild ;;
    esac
}

# Download, SHA256-check, install to /usr/local/bin, and keyless-verify a
# cosign release binary. Shared by the Linux and macOS arms, which differ only
# in the release asset name, the checksum tool, and the base64 decoder:
#   $1 bin        release asset basename (e.g. cosign-linux-amd64)
#   $2 sha_cmd    checksum verifier reading "HASH  PATH" on stdin
#                 (Linux: `sha256sum -c -`; macOS has no sha256sum, so
#                 `shasum -a 256 -c -`)
#   $3 b64_decode base64 decoder reading stdin, writing stdout (Linux:
#                 `base64 -d`; macOS BSD `base64 -d` is unreliable, so
#                 `openssl base64 -d -A`, present on both platforms)
# Installs to /usr/local/bin/cosign (on PATH on GH Linux + macOS runners) so a
# bare `cosign` works for the verify step here and for downstream sign stages.
cosign_install_download_verify() {
    local bin="$1" sha_cmd="$2" b64_decode="$3"
    local version="${COSIGN_VERSION:-v2.4.1}"
    local base="https://github.com/sigstore/cosign/releases/download/${version}"
    fetch_retry anodizer::fetch "${base}/${bin}" /tmp/cosign
    # Sigstore publishes the keyless .pem and .sig as base64-encoded files
    # (single-line, starts with `LS0tLS1CRUdJTiB...`). Decode before
    # handing to cosign — its PEM parser does not strip base64, so a raw
    # download fails verify-blob with a misleading "exactly one of: key
    # reference (--key), certificate (--cert)..." error (the cert IS
    # passed, but the file content can't be parsed).
    # The pem/sig downloads pipe curl's stdout into the decoder, so run_quiet
    # wraps the whole pipeline (capturing curl/decoder stderr) rather than the
    # bare curl — wrapping curl alone would swallow the piped bytes. `set -o
    # pipefail` inside the wrapped shell preserves the outer pipefail contract
    # so a curl failure mid-pipe still aborts.
    fetch_retry anodizer::run_quiet bash -c "set -o pipefail; curl -sSfL '${base}/${bin}-keyless.pem' | ${b64_decode} > /tmp/cosign.pem"
    fetch_retry anodizer::run_quiet bash -c "set -o pipefail; curl -sSfL '${base}/${bin}-keyless.sig' | ${b64_decode} > /tmp/cosign.sig"
    fetch_retry anodizer::fetch "${base}/cosign_checksums.txt" /tmp/cosign_checksums.txt

    # SHA256 first — bootstraps trust without requiring cosign-to-verify-cosign.
    local expected
    expected=$(sha_from_checksums /tmp/cosign_checksums.txt "$bin")
    anodizer::run_quiet bash -c "echo '${expected}  /tmp/cosign' | ${sha_cmd}"
    sudo install /tmp/cosign /usr/local/bin/cosign

    # Then keyless signature. Cosign releases are signed by the GCP service
    # account keyless@projectsigstore.iam.gserviceaccount.com via Google
    # OIDC (not GitHub Actions OIDC). See
    # https://docs.sigstore.dev/cosign/system_config/installation/
    if [ "${ANODIZER_ACTION_SKIP_COSIGN_VERIFY:-}" = "1" ]; then
        gha_warning "cosign keyless signature verification skipped at user request (ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1); SHA256-only validation was performed"
        anodizer::warn "cosign keyless signature verification skipped by user (SHA256-only, not signature-verified)"
        return
    fi
    # Strip COSIGN_KEY / COSIGN_PUB_KEY from the verify-blob env: the
    # caller (e.g. anodizer's release workflow) sets COSIGN_KEY at step
    # level for the downstream signing pipeline, but cosign auto-binds
    # COSIGN_KEY → --key. With --certificate also set, cosign's NOf(KeyRef,
    # Sk, CertRef) check rejects the call with a misleading "exactly one
    # of --key/--cert/--sk must be provided" error before the cert file
    # is even parsed.
    anodizer::run_quiet env -u COSIGN_KEY -u COSIGN_PUB_KEY cosign verify-blob \
        --certificate /tmp/cosign.pem \
        --signature /tmp/cosign.sig \
        --certificate-identity keyless@projectsigstore.iam.gserviceaccount.com \
        --certificate-oidc-issuer https://accounts.google.com \
        /tmp/cosign \
        || gha_fail "cosign keyless signature verification FAILED — refusing to install unverified binary"
    anodizer::vok "cosign keyless signature verified"
}

cosign_install_linux() {
    cosign_install_download_verify cosign-linux-amd64 'sha256sum -c -' 'base64 -d'
}

cosign_install_macos() {
    # Homebrew installs the LATEST cosign (2.6+), bypassing the COSIGN_VERSION
    # pin; that newer cosign turned `--tlog-upload=false` into a hard error
    # under the now-default signing-config, which breaks the determinism
    # harness's offline keyed sign-blob. Direct download honours the pin (the
    # pinned 2.4.x still accepts `--tlog-upload=false`), matching the Linux and
    # Windows arms.
    local arch asset
    arch="$(uname -m)"
    case "$arch" in
        arm64)  asset="cosign-darwin-arm64" ;;
        x86_64) asset="cosign-darwin-amd64" ;;
        *)      gha_fail "Unsupported macOS arch for cosign: ${arch}" ;;
    esac
    # macOS has no sha256sum; `shasum -a 256 -c -` is the BSD equivalent. BSD
    # `base64 -d` is unreliable, so decode the keyless pem/sig with
    # `openssl base64 -d -A` (present on macOS and Linux).
    cosign_install_download_verify "$asset" 'shasum -a 256 -c -' 'openssl base64 -d -A'
}

cosign_install_windows() {
    # Chocolatey ships cosign 1.3.1, which pre-dates several flags
    # anodizer's sign blocks rely on (`--bundle`, `--output-key-prefix`).
    # Direct download from the sigstore release page gets us 2.x cleanly.
    # SHA256 verification mirrors the Linux path.
    local version="${COSIGN_VERSION:-v2.4.1}"
    local base="https://github.com/sigstore/cosign/releases/download/${version}"
    # Sigstore publishes no windows/arm64 cosign asset (verified through v3.1.1;
    # every Windows release ships only cosign-windows-amd64.exe). Install the
    # amd64 binary on both x64 and arm64 runners — on windows-11-arm it runs
    # under x64 emulation, mirroring the upx/syft rationale: cosign's output is
    # a deterministic function of input + version, so emulation cannot perturb
    # a determinism shard's within-run comparison.
    local arch=amd64
    local bin="cosign-windows-${arch}.exe"
    local install_dir="${RUNNER_TEMP:-/tmp}/cosign"
    mkdir -p "$install_dir"
    fetch_retry anodizer::fetch "${base}/${bin}" "${install_dir}/cosign.exe"
    fetch_retry anodizer::fetch "${base}/cosign_checksums.txt" "${install_dir}/cosign_checksums.txt"

    local expected actual
    expected=$(sha_from_checksums "${install_dir}/cosign_checksums.txt" "$bin")
    # `cd` into the install dir so sha256sum sees a bare filename; passing
    # a Windows-style path (with backslashes) triggers sha256sum's
    # GNU-coreutils escape format which prepends `\` to the hash and
    # breaks string equality below.
    actual=$(cd "$install_dir" && sha256sum cosign.exe | awk '{print $1}')
    [ "$expected" = "$actual" ] \
        || gha_fail "cosign SHA256 mismatch (expected ${expected}, got ${actual})"

    gha_add_path "$install_dir"
    anodizer::vok "cosign ${version} (${arch}) installed at ${install_dir}/cosign.exe"
    _INSTALLER_EMITTED_OK=1
}

install_cosign() {
    case "$RUNNER_OS" in
        Linux)   cosign_install_linux ;;
        macOS)   cosign_install_macos ;;
        Windows) cosign_install_windows ;;
    esac
}

install_syft() {
    case "$RUNNER_OS" in
        Linux)
            local version="${SYFT_VERSION:-v1.18.0}"
            fetch_retry anodizer::fetch "https://raw.githubusercontent.com/anchore/syft/main/install.sh" /tmp/syft-install.sh
            chmod +x /tmp/syft-install.sh
            # The tarball download lives INSIDE upstream's install.sh, so
            # retrying only the fetch of that script leaves the payload — the
            # part a CDN 302 actually breaks — unprotected.
            fetch_retry anodizer::run_quiet sudo /tmp/syft-install.sh -b /usr/local/bin "${version}"
            ;;
        macOS)   brew_install syft SYFT_VERSION ;;
        # No native windows-arm64 syft download here: the choco syft package
        # installs the amd64 binary, and the reference pin v1.18.0 (the Linux
        # default) predates upstream's windows_arm64 release assets, which first
        # shipped ~v1.43. On windows-11-arm choco's amd64 syft runs under x64
        # emulation. Acceptable: SBOM bytes are a pure function of input + syft
        # version, and both determinism runs on a shard take this same path, so
        # the within-shard comparison is unaffected. (Switching arm64 to a
        # native direct download would diverge the syft version per-arch and
        # require an arm64-only sha pin — a version-policy change, not a fix.)
        Windows) choco_install syft SYFT_VERSION ;;
    esac
}

install_zig() {
    case "$RUNNER_OS" in
        Linux)
            local version="${ZIG_VERSION:-$ZIG_DEFAULT_VERSION}"
            local arch
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64 ;;
                ARM64) arch=aarch64 ;;
                *)     gha_fail "Unsupported Linux arch for zig: $RUNNER_ARCH" ;;
            esac
            # ziglang.org's tarball naming scheme is not stable across
            # releases (`zig-linux-x86_64-0.13.0` flipped to
            # `zig-x86_64-linux-0.14.1` and later), and no per-tarball
            # .sha256 sidecars exist — download/index.json is the canonical
            # version → per-target {tarball URL, shasum} map. Deriving BOTH
            # from it keeps the installer naming-scheme-proof for any
            # ZIG_VERSION and makes a bad pin fail loudly here instead of
            # as a 404 mid-release.
            fetch_retry anodizer::fetch \
                "https://ziglang.org/download/index.json" /tmp/zig-index.json
            local url expected
            url=$(jq -r --arg v "$version" --arg k "${arch}-linux" \
                '.[$v][$k].tarball // empty' /tmp/zig-index.json)
            expected=$(jq -r --arg v "$version" --arg k "${arch}-linux" \
                '.[$v][$k].shasum // empty' /tmp/zig-index.json)
            { [ -n "$url" ] && [ -n "$expected" ]; } \
                || gha_fail "zig ${version} has no ${arch}-linux entry in ziglang.org/download/index.json"
            fetch_retry anodizer::fetch "$url" /tmp/zig.tar.xz
            anodizer::run_quiet bash -c "echo '${expected}  /tmp/zig.tar.xz' | sha256sum -c -"
            sudo mkdir -p /opt/zig
            sudo tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
            sudo ln -sf /opt/zig/zig /usr/local/bin/zig
            ;;
        macOS)   brew_install zig ZIG_VERSION ;;
        Windows) choco_install zig ZIG_VERSION ;;
    esac
}

install_node() {
    case "$RUNNER_OS" in
        Linux)
            local version="${NODE_VERSION:-$NODE_DEFAULT_VERSION}"
            local arch
            case "$RUNNER_ARCH" in
                # Node names its Linux assets x64/arm64, not x86_64/aarch64.
                X64)   arch=x64 ;;
                ARM64) arch=arm64 ;;
                *)     gha_fail "Unsupported Linux arch for node: $RUNNER_ARCH" ;;
            esac
            local tarball="node-v${version}-linux-${arch}.tar.xz"
            local base="https://nodejs.org/dist/v${version}"
            # nodejs.org publishes per-release SHASUMS256.txt (`<sha>  <file>`
            # per line) rather than per-tarball sidecars; verify against it so
            # no sha is hardcoded — the dated dist dir is immutable.
            fetch_retry anodizer::fetch "${base}/${tarball}" /tmp/node.tar.xz
            local expected
            # NOT routed through anodizer::fetch/run_quiet: this curl's stdout
            # feeds the `$(... | grep ...)` capture, which a file-writing fetch
            # helper would swallow. Resilience comes from curl's own
            # --retry/--retry-all-errors instead — curl retries internally and
            # emits only the final successful body, so the grep pipe never sees a
            # partial transfer (the fetch_retry loop can't wrap a pipe-into-
            # capture without concatenating bytes across attempts).
            expected=$(curl -sSfL --retry 3 --retry-all-errors --retry-delay 2 \
                "${base}/SHASUMS256.txt" \
                | grep " ${tarball}\$" | awk '{print $1}')
            [ -n "$expected" ] \
                || gha_fail "node sha256 missing from SHASUMS256.txt for ${tarball}"
            anodizer::run_quiet bash -c "echo '${expected}  /tmp/node.tar.xz' | sha256sum -c -"
            sudo mkdir -p /opt/node
            sudo tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
            sudo ln -sf /opt/node/bin/node /usr/local/bin/node
            sudo ln -sf /opt/node/bin/npm /usr/local/bin/npm
            sudo ln -sf /opt/node/bin/npx /usr/local/bin/npx
            ;;
        macOS)   brew_install node NODE_VERSION ;;
        Windows) choco_install nodejs NODE_VERSION ;;
    esac
    # node's bundled npm is below the 11.5.1 Trusted-Publishing floor on every
    # supported node line; upgrade the active npm so OIDC publishing works.
    install_npm_floor
}

# Upgrade the active npm to NPM_VERSION (>= the 11.5.1 OIDC floor). Runs after
# every install_node path so `npm --version` meets the floor regardless of
# which npm node bundled. `npm install -g npm@...` rewrites npm in place using
# the just-installed node, so no node-line-specific bundle quirk leaks through.
install_npm_floor() {
    local version="${NPM_VERSION:-$NPM_DEFAULT_VERSION}"
    case "$RUNNER_OS" in
        # The Linux node tree lives at /opt/node owned by root (symlinked into
        # /usr/local/bin); the global npm prefix is under it, so the self-update
        # needs sudo. macOS brew / Windows choco install npm writable by the
        # job user, so a plain `npm install -g` suffices there.
        Linux)   anodizer::run_quiet sudo npm install -g "npm@${version}" ;;
        *)       anodizer::run_quiet npm install -g "npm@${version}" ;;
    esac
    anodizer::vok "npm ${version} active (>= 11.5.1 Trusted-Publishing floor)"
}

install_cargo_zigbuild() {
    command -v cargo > /dev/null 2>&1 \
        || gha_fail "cargo-zigbuild requires Rust; set install-rust: true"
    anodizer::run_quiet cargo install --locked cargo-zigbuild
}

install_upx() {
    case "$RUNNER_OS" in
        Linux)   apt_queue upx upx ;;
        macOS)   brew_install upx UPX_VERSION ;;
        # upstream upx publishes only win32/win64 (both x86) assets — there is
        # no windows-arm64 build — so choco's x64 upx is the only option on
        # windows-11-arm, running under x64 emulation. Acceptable: UPX output is
        # a deterministic function of input + version, identical across a
        # shard's two determinism runs.
        Windows) choco_install upx UPX_VERSION ;;
    esac
}

# nsis drives anodizer's `nsis:` (Windows installer) stage, which shells out to
# `makensis`. The choco `nsis` package installs makensis.exe into the NSIS ROOT
# (e.g. C:\Program Files (x86)\NSIS\makensis.exe — no `bin` subdir, unlike WiX)
# but drops no PATH shim, and NSIS is not pre-installed on the windows runner
# image, so a later step can't find makensis. Discover the root and surface it
# on PATH, mirroring install_wix3.
install_nsis() {
    case "$RUNNER_OS" in
        Linux)   apt_queue nsis nsis ;;
        macOS)   brew_install makensis NSIS_VERSION ;;
        Windows)
            choco_install nsis NSIS_VERSION
            local nsisdir=""
            if command -v makensis > /dev/null 2>&1; then
                nsisdir="$(dirname "$(command -v makensis)")"
            elif command -v where.exe > /dev/null 2>&1; then
                # `dirname ""` returns ".", which would poison PATH with the
                # cwd; only resolve a dir when the lookup actually found
                # makensis, else fall through to the glob fallback below.
                # `|| true` + an explicit `if` keep the lookup set -e-safe:
                # right after the choco install makensis is not yet on PATH, so
                # `where.exe` exits non-zero — without the guard pipefail would
                # abort the whole install before the glob fallback below runs.
                local found
                found="$(where.exe makensis 2>/dev/null | head -1 | tr -d '\r' || true)"
                if [ -n "$found" ]; then nsisdir="$(dirname "$found")"; fi
            fi
            if [ -z "$nsisdir" ]; then
                # NSIS_GLOB_ROOT_PREFIX rebases the search roots for hermetic
                # tests (empty in production); the makensis.exe lives directly in
                # the NSIS install root, with no `bin` subdir.
                local prefix="${NSIS_GLOB_ROOT_PREFIX:-}"
                local candidate
                for candidate in "${prefix}/c/Program Files (x86)/NSIS" \
                                 "${prefix}/c/Program Files/NSIS"; do
                    if [ -x "${candidate}/makensis.exe" ]; then
                        nsisdir="$candidate"
                        break
                    fi
                done
            fi
            if [ -n "$nsisdir" ]; then
                gha_add_path "$nsisdir"
            else
                gha_warning "nsis: makensis dir not found after install; relying on choco's PATH shims"
            fi
            anodizer::vok "NSIS (makensis) installed via choco nsis"
            _INSTALLER_EMITTED_OK=1
            ;;
    esac
}

install_create_dmg() {
    case "$RUNNER_OS" in
        macOS)   brew_install create-dmg CREATE_DMG_VERSION ;;
        # anodizer's dmg stage prefers macOS `hdiutil` and falls back to
        # `genisoimage` on Linux, so the Linux .dmg build needs genisoimage.
        Linux)   apt_queue genisoimage genisoimage ;;
        Windows) skip_unsupported_os create-dmg "macOS/Linux only (dmgs: needs hdiutil or genisoimage)" ;;
    esac
}

# flatpak drives anodizer's `flatpaks:` stage: the stage shells out to
# `flatpak-builder --repo=repo build <manifest>` then `flatpak build-bundle`,
# so BOTH the `flatpak` CLI (build-bundle) and `flatpak-builder` must be on
# PATH. flatpak-builder also needs the runtime + SDK the manifest pins
# (org.freedesktop.Platform / org.freedesktop.Sdk) staged into a flatpak
# installation before the build, or it fails resolving the base.
#
# The stage bundles EVERY Linux build arch anodizer produces (its gnu build
# yields both x86_64 and aarch64), so the Platform + Sdk are staged for each
# arch in FLATPAK_ARCHES — a runner cross-bundling the aarch64 app resolves
# the aarch64 base and hard-fails on a missing org.freedesktop.Sdk/aarch64.
# Cross-bundling also has to EXECUTE target-arch binaries: flatpak-builder
# runs the manifest's build-commands inside the target-arch sandbox (bwrap +
# the target Sdk's own /bin/sh), which an x86_64 host can only run through
# qemu-user emulation. qemu-user-static ships the STATIC qemu-aarch64 (bwrap's
# sandbox carries no host libraries) and, via binfmt-support, registers the
# handler with the F ("fix-binary") flag so it survives the sandbox's mount
# namespace — without it flatpak-builder dies with
# `bwrap: execvp /bin/sh: Exec format error`.
#
# RUNTIME_VERSION tracks the branch anodizer's flatpaks: blocks pin
# (`runtime_version: "24.08"`); override with FLATPAK_RUNTIME_VERSION to
# pre-stage a different branch. The runtimes come from flathub, so the
# flathub remote is added first (idempotent via --if-not-exists).
FLATPAK_DEFAULT_RUNTIME_VERSION="24.08"
FLATPAK_DEFAULT_ARCHES="x86_64 aarch64"
install_flatpak() {
    case "$RUNNER_OS" in
        Linux)
            # apt_queue + an inline flush: the runtime install below needs the
            # `flatpak` binary present, so the batch must land before it runs.
            # qemu-user-static + binfmt-support enable the aarch64 sandbox exec
            # described above; they queue with flatpak so one apt round installs all.
            apt_queue flatpak flatpak
            apt_queue flatpak-builder flatpak-builder
            apt_queue qemu-user-static qemu-user-static
            apt_queue binfmt-support binfmt-support
            apt_flush
            local runtime_version="${FLATPAK_RUNTIME_VERSION:-$FLATPAK_DEFAULT_RUNTIME_VERSION}"
            local fp_arches="${FLATPAK_ARCHES:-$FLATPAK_DEFAULT_ARCHES}"
            # System-wide remote + runtimes so a non-root `flatpak-builder` and
            # the later `anodizer release` step share one installation.
            anodizer::run_quiet sudo flatpak remote-add --if-not-exists flathub \
                https://flathub.org/repo/flathub.flatpakrepo \
                || gha_fail "flatpak: adding the flathub remote failed"
            local fp_arch
            for fp_arch in $fp_arches; do
                anodizer::run_quiet sudo flatpak install -y --noninteractive --arch="$fp_arch" flathub \
                    "org.freedesktop.Platform//${runtime_version}" \
                    "org.freedesktop.Sdk//${runtime_version}" \
                    || gha_fail "flatpak: installing org.freedesktop.Platform + Sdk (${fp_arch}//${runtime_version}) failed"
            done
            anodizer::vok "flatpak + flatpak-builder + qemu-user-static + runtime ${runtime_version} (Platform + Sdk: ${fp_arches}) installed"
            _INSTALLER_EMITTED_OK=1
            ;;
        macOS|Windows) skip_unsupported_os flatpak-builder "Linux-only (flatpaks: config requires a Linux runner)" ;;
    esac
}

install_pkgbuild() {
    case "$RUNNER_OS" in
        # macOS ships pkgbuild with the Xcode Command Line Tools; nothing to do.
        macOS)   anodizer::vdetail "pkgbuild ships with Xcode CLT on macOS" ;;
        Linux)
            # The Linux .pkg path assembles the flat XAR package by hand:
            # cpio+gzip (base image) for the Payload, xar to flatten, and mkbom
            # for the Bom. Neither is packaged for Ubuntu 24.04 — noble dropped
            # the `xar` package and bomutils was never packaged — so build both
            # from source. The command-v guards let a runner image that already
            # ships them (e.g. the self-hosted base image) skip the build, and
            # gate the autotools build-deps so they are only pulled when needed.
            if ! command -v xar > /dev/null 2>&1; then
                apt_queue libxml2-dev libxml2-dev
                apt_queue libssl-dev libssl-dev
                apt_queue zlib1g-dev zlib1g-dev
                apt_queue autoconf autoconf
                apt_queue automake automake
                apt_queue libtool libtool
                apt_queue pkg-config pkg-config
            fi
            apt_flush
            if ! command -v xar > /dev/null 2>&1; then
                local xsrc="${RUNNER_TEMP:-/tmp}/xar"
                rm -rf "$xsrc"
                anodizer::run_quiet git clone --depth 1 https://github.com/mackyle/xar.git "$xsrc" \
                    || gha_fail "xar clone failed"
                # OpenSSL >= 1.1 turned OpenSSL_add_all_ciphers (and the digest /
                # EVP_MD_CTX_create helpers xar uses) into header MACROS, so no
                # such symbol is exported by libcrypto. xar's autoconf probe
                # AC_CHECK_LIB([crypto],[OpenSSL_add_all_ciphers]) is a link test
                # that ignores the macro and aborts configure ("Cannot build
                # without libcrypto") on Ubuntu 24.04's OpenSSL 3 — even though
                # libcrypto is present and the sources compile against the macro
                # form. Prime the autoconf cache to skip the bogus probe (the
                # standard distro fix) and silence the deprecation warnings the
                # legacy macros emit so a -Werror default cannot fail the build.
                # EXPORT the override (xar's autogen.sh runs ./configure itself,
                # which must inherit it) and pass --noconfigure so autogen only
                # generates configure — we run the primed configure exactly once.
                # Single-quoted body: $1 must expand in the spawned bash (xsrc
                # is passed as a positional arg), not the parent shell.
                # shellcheck disable=SC2016
                anodizer::run_quiet bash -c '
                    cd "$1/xar" \
                        && export ac_cv_lib_crypto_OpenSSL_add_all_ciphers=yes \
                                  CFLAGS="-O2 -Wno-deprecated-declarations" \
                        && ./autogen.sh --noconfigure \
                        && ./configure \
                        && make' _ "$xsrc" \
                    || gha_fail "xar build failed"
                anodizer::run_quiet sudo make -C "$xsrc/xar" install \
                    || gha_fail "xar install failed"
                # libxar lands in /usr/local/lib; refresh the linker cache so the
                # freshly built `xar` binary resolves it.
                sudo ldconfig
                rm -rf "$xsrc"
            fi
            if ! command -v mkbom > /dev/null 2>&1; then
                local src="${RUNNER_TEMP:-/tmp}/bomutils"
                rm -rf "$src"
                anodizer::run_quiet git clone --depth 1 https://github.com/hogliux/bomutils.git "$src" \
                    || gha_fail "bomutils clone failed"
                anodizer::run_quiet make -C "$src" \
                    || gha_fail "bomutils build failed"
                anodizer::run_quiet sudo make -C "$src" install \
                    || gha_fail "bomutils install failed"
                rm -rf "$src"
            fi
            anodizer::vok "Linux flat-pkg toolchain (xar + mkbom) installed"
            _INSTALLER_EMITTED_OK=1
            ;;
        Windows) skip_unsupported_os pkgbuild "macOS/Linux only (pkgs: macOS installer format)" ;;
    esac
}

install_alejandra() {
    case "$RUNNER_OS" in
        Linux)
            local version="${ALEJANDRA_VERSION:-$ALEJANDRA_DEFAULT_VERSION}"
            local arch sha
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64;  sha="$ALEJANDRA_DEFAULT_SHA_AMD64" ;;
                ARM64) arch=aarch64; sha="$ALEJANDRA_DEFAULT_SHA_ARM64" ;;
                *)     gha_fail "Unsupported Linux arch for alejandra: $RUNNER_ARCH" ;;
            esac
            if [ "$version" != "$ALEJANDRA_DEFAULT_VERSION" ]; then
                # Upstream publishes no checksums file, so a version
                # override MUST come with its own sha — refusing
                # unverified installs.
                local override_sha="${ALEJANDRA_SHA256:-}"
                [ -n "$override_sha" ] \
                    || gha_fail "ALEJANDRA_VERSION=$version requires ALEJANDRA_SHA256 (upstream publishes no checksums file)"
                sha="$override_sha"
            fi
            local bin="alejandra-${arch}-unknown-linux-musl"
            fetch_retry anodizer::fetch "https://github.com/kamadorueda/alejandra/releases/download/${version}/${bin}" /tmp/alejandra
            anodizer::run_quiet bash -c "echo '${sha}  /tmp/alejandra' | sha256sum -c -"
            sudo install -m 0755 /tmp/alejandra /usr/local/bin/alejandra
            rm -f /tmp/alejandra
            ;;
        macOS)   brew_install alejandra ALEJANDRA_VERSION ;;
        Windows) skip_unsupported_os alejandra "Linux/macOS only (nix publisher targets Unix runners)" ;;
    esac
}

# linuxdeploy drives anodizer's `appimages:` stage. It is itself an AppImage,
# as is the appimage output plugin it needs to emit a `.AppImage` (anodizer
# invokes `linuxdeploy --output appimage`, which is a no-op without
# linuxdeploy-plugin-appimage on PATH). Both are installed side by side into
# one PATH dir.
#
# CI runners frequently lack FUSE (no /dev/fuse), so an AppImage can't
# self-mount. APPIMAGE_EXTRACT_AND_RUN=1 is linuxdeploy's documented escape
# hatch: each AppImage extracts itself to a temp dir and runs from there
# instead of FUSE-mounting. It is exported into $GITHUB_ENV so anodizer's
# stage sees it when it later spawns linuxdeploy, and the plugin is named
# `linuxdeploy-plugin-appimage` (no extension) so linuxdeploy's plugin
# discovery finds it on PATH.
install_linuxdeploy() {
    case "$RUNNER_OS" in
        Linux)
            local version="${LINUXDEPLOY_VERSION:-$LINUXDEPLOY_DEFAULT_VERSION}"
            # linuxdeploy and the plugin version independently (different dated
            # tags upstream), so the plugin URL is built from its own tag.
            local plugin_version="${LINUXDEPLOY_PLUGIN_VERSION:-$LINUXDEPLOY_PLUGIN_DEFAULT_VERSION}"
            local arch ld_sha plugin_sha
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64;  ld_sha="$LINUXDEPLOY_DEFAULT_SHA_AMD64"; plugin_sha="$LINUXDEPLOY_PLUGIN_DEFAULT_SHA_AMD64" ;;
                ARM64) arch=aarch64; ld_sha="$LINUXDEPLOY_DEFAULT_SHA_ARM64"; plugin_sha="$LINUXDEPLOY_PLUGIN_DEFAULT_SHA_ARM64" ;;
                *)     gha_fail "Unsupported Linux arch for linuxdeploy: $RUNNER_ARCH" ;;
            esac
            if [ "$version" != "$LINUXDEPLOY_DEFAULT_VERSION" ] \
                || [ "$plugin_version" != "$LINUXDEPLOY_PLUGIN_DEFAULT_VERSION" ]; then
                # Any tag override moves off the verified default bytes, so it
                # MUST carry its own shas — refusing unverified installs (no
                # upstream checksums file exists).
                ld_sha="${LINUXDEPLOY_SHA256:-}"
                plugin_sha="${LINUXDEPLOY_PLUGIN_SHA256:-}"
                { [ -n "$ld_sha" ] && [ -n "$plugin_sha" ]; } \
                    || gha_fail "LINUXDEPLOY_VERSION/LINUXDEPLOY_PLUGIN_VERSION override requires LINUXDEPLOY_SHA256 and LINUXDEPLOY_PLUGIN_SHA256 (upstream publishes no checksums file)"
            fi

            local install_dir="${RUNNER_TEMP:-/tmp}/linuxdeploy"
            mkdir -p "$install_dir"

            local ld_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/${version}/linuxdeploy-${arch}.AppImage"
            fetch_retry anodizer::fetch "$ld_url" "${install_dir}/linuxdeploy"
            anodizer::run_quiet bash -c "echo '${ld_sha}  ${install_dir}/linuxdeploy' | sha256sum -c -"
            chmod +x "${install_dir}/linuxdeploy"

            local plugin_url="https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/${plugin_version}/linuxdeploy-plugin-appimage-${arch}.AppImage"
            fetch_retry anodizer::fetch "$plugin_url" "${install_dir}/linuxdeploy-plugin-appimage"
            anodizer::run_quiet bash -c "echo '${plugin_sha}  ${install_dir}/linuxdeploy-plugin-appimage' | sha256sum -c -"
            chmod +x "${install_dir}/linuxdeploy-plugin-appimage"

            gha_add_path "$install_dir"
            # Persist for the later `anodizer release` step (which spawns
            # linuxdeploy itself) — $GITHUB_ENV survives across steps; a bare
            # `export` would not.
            gha_set_env APPIMAGE_EXTRACT_AND_RUN 1
            anodizer::vok "linuxdeploy ${version} + appimage plugin ${plugin_version} (${arch}) installed at ${install_dir}"
            _INSTALLER_EMITTED_OK=1
            ;;
        macOS|Windows) skip_unsupported_os linuxdeploy "Linux-only (appimages: config requires a Linux runner)" ;;
    esac
}

# rcodesign (apple-codesign) drives anodizer's cross-platform
# `notarize.macos:` path (`rcodesign sign` / `rcodesign notary-submit`). It runs
# on Linux, macOS, and Windows, so this installs a pinned, sha-verified release
# binary on each. The tarball carries `rcodesign` one directory deep, so
# `tar --strip-components=1` lands the bare binary; macOS uses the
# `macos-universal`-equivalent per-arch tarballs (x86_64 / aarch64 darwin).
# Windows has no clean musl/release-binary story here (upstream ships a
# *-pc-windows-msvc.zip, not a tarball), so the Windows arm falls back to
# `cargo install apple-codesign --locked` — a Rust toolchain is available in
# the action via install-rust (the cross-platform notarize path is the only
# notarize mode usable on a Windows runner anyway). Override the pinned binary
# with RCODESIGN_VERSION + the matching *_SHA_* env vars (all required
# together).
install_rcodesign() {
    case "$RUNNER_OS" in
        Linux|macOS)
            local version="${RCODESIGN_VERSION:-$RCODESIGN_DEFAULT_VERSION}"
            local triple sha
            case "${RUNNER_OS}:${RUNNER_ARCH}" in
                Linux:X64)    triple="x86_64-unknown-linux-musl"; sha="$RCODESIGN_DEFAULT_SHA_LINUX_AMD64" ;;
                Linux:ARM64)  triple="aarch64-unknown-linux-musl"; sha="$RCODESIGN_DEFAULT_SHA_LINUX_ARM64" ;;
                macOS:X64)    triple="x86_64-apple-darwin";  sha="$RCODESIGN_DEFAULT_SHA_MACOS_AMD64" ;;
                macOS:ARM64)  triple="aarch64-apple-darwin"; sha="$RCODESIGN_DEFAULT_SHA_MACOS_ARM64" ;;
                *) gha_fail "Unsupported ${RUNNER_OS} arch for rcodesign: $RUNNER_ARCH" ;;
            esac
            if [ "$version" != "$RCODESIGN_DEFAULT_VERSION" ]; then
                # Upstream publishes no checksums file, so a version override
                # MUST come with its own sha — refusing unverified installs.
                local override_sha="${RCODESIGN_SHA256:-}"
                [ -n "$override_sha" ] \
                    || gha_fail "RCODESIGN_VERSION=$version requires RCODESIGN_SHA256 (upstream publishes no checksums file)"
                sha="$override_sha"
            fi

            local install_dir="${RUNNER_TEMP:-/tmp}/rcodesign"
            mkdir -p "$install_dir"
            local tarball="apple-codesign-${version}-${triple}.tar.gz"
            # The release tag is URL-encoded (`apple-codesign/<ver>` → `%2F`).
            local url="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${version}/${tarball}"
            fetch_retry anodizer::fetch "$url" "${install_dir}/${tarball}"
            anodizer::run_quiet bash -c "echo '${sha}  ${install_dir}/${tarball}' | sha256sum -c -"
            # `rcodesign` sits one dir deep (apple-codesign-<ver>-<triple>/rcodesign);
            # strip the leading component and extract only the binary.
            tar -xzf "${install_dir}/${tarball}" -C "$install_dir" --strip-components=1 \
                "apple-codesign-${version}-${triple}/rcodesign"
            chmod +x "${install_dir}/rcodesign"
            gha_add_path "$install_dir"
            anodizer::vok "rcodesign ${version} (${triple}) installed at ${install_dir}/rcodesign"
            _INSTALLER_EMITTED_OK=1
            ;;
        Windows)
            # No clean release tarball for Windows (upstream ships a
            # *-pc-windows-msvc.zip), so build from crates.io via the action's
            # Rust toolchain. The cross-platform notarize.macos path is the only
            # notarize mode usable on a Windows runner.
            command -v cargo > /dev/null 2>&1 \
                || gha_fail "rcodesign on Windows requires Rust; set install-rust: true"
            local version="${RCODESIGN_VERSION:-$RCODESIGN_DEFAULT_VERSION}"
            anodizer::run_quiet cargo install apple-codesign --locked --version "$version"
            ;;
    esac
}

# msitools taught wixl the WiX `<Environment>` element in 0.105; before that its
# parser has no such node type and aborts the whole build with
# `wix.vala: unhandled child Component node Environment` on any .wxs that puts
# the install dir on PATH — the shape every CLI installer needs. Ubuntu 24.04
# (the current `ubuntu-latest`) ships 0.103, so the msis stage cannot build there
# at all. Nor is a prebuilt 0.106 .deb installable on 24.04 directly: it links
# libxml2-16, whose soname 24.04 does not carry. 26.04 LTS supplies all three
# missing pieces, and its libxml2-16 needs only libc6/zlib1g that 24.04 already
# exceeds, so overlay exactly those and pin the rest of that suite away.
WIXL_MIN_VERSION="0.105"
WIXL_BACKPORT_SUITE="resolute"

# Reads the numeric version out of `wixl --version` (which prints a bare
# `0.106`), empty when wixl is absent or unparseable. `|| true` keeps this
# set -e-safe: a wixl that is on PATH but exits non-zero (a half-installed or
# ABI-broken package) would otherwise abort the whole dep install through
# pipefail, with no diagnostic naming wixl.
_wixl_version() {
    command -v wixl > /dev/null 2>&1 || return 0
    local raw
    raw="$(wixl --version 2> /dev/null || true)"
    printf '%s' "$raw" | head -n1 | tr -cd '0-9.'
}

# Runs after apt_flush, so it sees the version the distro actually installed.
# A runner whose own wixl already carries `<Environment>` is left untouched,
# which retires this overlay by itself once `ubuntu-latest` moves past 24.04.
wixl_backport_if_too_old() {
    [ "$RUNNER_OS" = "Linux" ] || return 0
    command -v apt-get > /dev/null 2>&1 || return 0

    local have
    have="$(_wixl_version)"
    [ -n "$have" ] || return 0
    if dpkg --compare-versions "$have" ge "$WIXL_MIN_VERSION"; then
        anodizer::vok "wixl ${have} supports <Environment>"
        return 0
    fi

    anodizer::vstep "wixl ${have} predates <Environment> support; overlaying ${WIXL_BACKPORT_SUITE}"
    local arch host
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        # Only amd64/i386 live on archive.ubuntu.com; every other port is
        # published under ports.ubuntu.com.
        amd64 | i386) host="http://archive.ubuntu.com/ubuntu" ;;
        *) host="http://ports.ubuntu.com/ubuntu-ports" ;;
    esac
    # WIXL_APT_ROOT_PREFIX rebases both config writes under a sandbox so the
    # tests can assert on them without touching the host's /etc (same knob shape
    # as WIX_GLOB_ROOT_PREFIX); empty in production.
    local apt_etc="${WIXL_APT_ROOT_PREFIX:-}/etc/apt"
    anodizer::run_quiet sudo mkdir -p "${apt_etc}/sources.list.d" "${apt_etc}/preferences.d" \
        || gha_fail "wixl backport: could not create ${apt_etc}"
    # Both components are required: wixl and wixl-data are universe, but
    # libxml2-16 is main — indexing only universe leaves the dep unresolvable
    # and apt refuses the whole transaction.
    printf 'deb [arch=%s] %s %s main universe\n' "$arch" "$host" "$WIXL_BACKPORT_SUITE" \
        | anodizer::run_quiet sudo tee "${apt_etc}/sources.list.d/wixl-backport.list" \
        || gha_fail "wixl backport: could not write the ${WIXL_BACKPORT_SUITE} apt source"
    # Priority 1 keeps every other package in the suite installable-but-never-
    # preferred, so adding this source cannot silently upgrade anything else.
    printf 'Package: *\nPin: release n=%s\nPin-Priority: 1\n\nPackage: wixl wixl-data libxml2-16\nPin: release n=%s\nPin-Priority: 990\n' \
        "$WIXL_BACKPORT_SUITE" "$WIXL_BACKPORT_SUITE" \
        | anodizer::run_quiet sudo tee "${apt_etc}/preferences.d/wixl-backport" \
        || gha_fail "wixl backport: could not write the ${WIXL_BACKPORT_SUITE} apt pin"

    # Index ONLY the new list: a full `apt-get update` re-fetches every suite the
    # image configures, which costs far more than the one package being fixed.
    DEBIAN_FRONTEND=noninteractive anodizer::run_quiet sudo apt-get update -q \
        -o Dir::Etc::sourcelist="sources.list.d/wixl-backport.list" \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" \
        || gha_fail "wixl backport: apt-get update failed for ${WIXL_BACKPORT_SUITE}"
    DEBIAN_FRONTEND=noninteractive \
        anodizer::run_quiet sudo apt-get install -yq wixl wixl-data < /dev/null \
        || gha_fail "wixl backport: installing wixl from ${WIXL_BACKPORT_SUITE} failed"

    have="$(_wixl_version)"
    dpkg --compare-versions "${have:-0}" ge "$WIXL_MIN_VERSION" \
        || gha_fail "wixl backport: wixl is still ${have:-absent} after installing from ${WIXL_BACKPORT_SUITE}; the msis stage would fail on <Environment>"
    anodizer::vok "wixl ${have} installed from ${WIXL_BACKPORT_SUITE}"
}

# WiX drives anodizer's `msis:` stage (crates/stage-msi — v4 `wix build`). The
# v4 CLI is the `wix` dotnet global tool, installed via the dotnet SDK that is
# preinstalled on the GitHub windows runner images. dotnet global tools land in
# `%USERPROFILE%\.dotnet\tools`, which the dotnet installer adds to PATH on the
# hosted images; we add it explicitly so a fresh shell in the same job sees it.
# Pin the version with WIX_VERSION (default tracks WiX v4, anodizer's default).
# WiX v4 dialect (default): the `wix build` CLI is the `wix` dotnet global
# tool on Windows; Linux uses `wixl` (msitools), which consumes a v3-dialect
# .wxs but is also the only Linux MSI path regardless of dialect.
install_wix() {
    case "$RUNNER_OS" in
        Windows)
            local version="${WIX_VERSION:-$WIX_DEFAULT_VERSION}"
            dotnet tool install --global wix --version "$version" \
                || gha_fail "dotnet tool install wix@${version} failed"
            # dotnet global tools install to $HOME/.dotnet/tools; surface it on
            # PATH for later steps in case the image's default PATH lacks it.
            gha_add_path "${USERPROFILE:-$HOME}/.dotnet/tools"
            anodizer::vok "wix ${version} installed via dotnet global tool"
            _INSTALLER_EMITTED_OK=1
            ;;
        Linux)
            # WiX itself is Windows-only and EULA-gated, so the Linux MSI path is
            # `wixl` (msitools), which anodizer's msi stage drives directly. It
            # consumes the v3-dialect .wxs and emits the .msi in one step.
            apt_queue wixl wixl
            ;;
        macOS) skip_unsupported_os wix "Windows/Linux only (msis: needs wixl on macOS, not packaged)" ;;
    esac
}

# WiX v3 dialect: anodizer's msi stage selects candle+light (not `wix build`)
# when the .wxs uses the v3 namespace or the config pins `version: v3`/`wixl`.
# On Windows the WiX v3 toolset ships candle.exe/light.exe — installed via
# the `wixtoolset` choco package, NOT the `wix` dotnet global tool (v4). The
# toolset's versioned bin dir is discovered at runtime (the major version is
# not hardcoded) and surfaced on PATH. On Linux the path is `wixl` (msitools),
# identical to the v4 arm since wixl consumes the v3-dialect .wxs either way.
install_wix3() {
    case "$RUNNER_OS" in
        Windows)
            choco_install wixtoolset WIX3_VERSION
            # candle.exe/light.exe land under "WiX Toolset v<major>.<minor>\bin".
            # Discover that dir robustly rather than hardcoding a version: prefer
            # the shim choco drops on PATH, then a `where` lookup, then a glob of
            # the toolset install root.
            local bindir=""
            if command -v candle > /dev/null 2>&1; then
                bindir="$(dirname "$(command -v candle)")"
            elif command -v where.exe > /dev/null 2>&1; then
                # `dirname ""` returns ".", which would poison PATH with the
                # cwd; only resolve a dir when the lookup actually found candle,
                # else fall through to the glob fallback below.
                # `|| true` + an explicit `if` keep the lookup set -e-safe:
                # right after the choco install candle is not yet on PATH, so
                # `where.exe` exits non-zero — without the guard pipefail would
                # abort the whole install before the glob fallback below runs.
                local found
                found="$(where.exe candle 2>/dev/null | head -1 | tr -d '\r' || true)"
                if [ -n "$found" ]; then bindir="$(dirname "$found")"; fi
            fi
            if [ -z "$bindir" ]; then
                # WIX_GLOB_ROOT_PREFIX rebases the search roots for hermetic
                # tests (empty in production); candle.exe/light.exe live under
                # the versioned "WiX Toolset v<major>.<minor>\bin" subdir.
                local prefix="${WIX_GLOB_ROOT_PREFIX:-}"
                local candidate
                for candidate in "${prefix}/c/Program Files (x86)/WiX Toolset v"*/bin \
                                 "${prefix}/c/Program Files/WiX Toolset v"*/bin; do
                    if [ -x "${candidate}/candle.exe" ]; then
                        bindir="$candidate"
                        break
                    fi
                done
            fi
            if [ -n "$bindir" ]; then
                gha_add_path "$bindir"
            else
                gha_warning "wix3: candle/light bin dir not found after install; relying on choco's PATH shims"
            fi
            anodizer::vok "WiX v3 (candle+light) installed via choco wixtoolset"
            _INSTALLER_EMITTED_OK=1
            ;;
        Linux)
            apt_queue wixl wixl
            ;;
        macOS) skip_unsupported_os wix3 "Windows/Linux only (msis: needs wixl on macOS, not packaged)" ;;
    esac
}

# clang-cl provisioning for anodizer's determinism harness, which HARD-REQUIRES
# clang-cl on PATH for windows-msvc builds — pinning it as the C/C++ compiler
# fixes an intermittent cl.exe C-object codegen non-determinism (identical
# source, differing object bytes across otherwise-identical runs). The
# GitHub-hosted windows image ships LLVM 20.1.8 with its bin dir already on the
# machine PATH (runner-images' own Install-LLVM.ps1 calls Add-MachinePathItem),
# so the on-PATH check below is a no-op on stock images; the fallbacks exist
# for images/configurations where that PATH entry is missing.
install_clang_cl() {
    case "$RUNNER_OS" in
        Windows)
            if command -v clang-cl > /dev/null 2>&1; then
                anodizer::vok "clang-cl already on PATH"
                _INSTALLER_EMITTED_OK=1
                return 0
            fi
            # Two known locations ship clang-cl without adding it to PATH: the
            # standalone LLVM package (the target of runner-images' own
            # Install-LLVM.ps1) and Visual Studio's bundled ClangCL toolset
            # component (Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset).
            # CLANG_GLOB_ROOT_PREFIX rebases the search roots for hermetic
            # tests (empty in production).
            local prefix="${CLANG_GLOB_ROOT_PREFIX:-}" clangdir="" candidate
            for candidate in "${prefix}/c/Program Files/LLVM/bin" \
                             "${prefix}/c/Program Files/Microsoft Visual Studio"/*/*/VC/Tools/Llvm/x64/bin; do
                if [ -x "${candidate}/clang-cl.exe" ]; then
                    clangdir="$candidate"
                    break
                fi
            done
            if [ -n "$clangdir" ]; then
                gha_add_path "$clangdir"
                anodizer::vok "clang-cl found at ${clangdir}, added to PATH"
                _INSTALLER_EMITTED_OK=1
                return 0
            fi
            # Neither known location has it — install standalone LLVM (the
            # same choco package runner-images' Install-LLVM.ps1 uses for x64)
            # and discover its bin dir the way install_nsis/install_wix3 do: a
            # choco package can land without its PATH shim reaching the
            # current shell.
            choco_install llvm LLVM_VERSION
            if command -v clang-cl > /dev/null 2>&1; then
                clangdir="$(dirname "$(command -v clang-cl)")"
            elif command -v where.exe > /dev/null 2>&1; then
                # `dirname ""` returns ".", which would poison PATH with the
                # cwd; only resolve a dir when the lookup actually found
                # clang-cl. `|| true` + the explicit `if` keep this
                # set -e-safe — right after the choco install clang-cl is not
                # yet on PATH, so where.exe exits non-zero, and without the
                # guard pipefail would abort the whole install before the
                # glob fallback below runs.
                local found
                found="$(where.exe clang-cl 2>/dev/null | head -1 | tr -d '\r' || true)"
                if [ -n "$found" ]; then clangdir="$(dirname "$found")"; fi
            fi
            if [ -z "$clangdir" ] && [ -x "${prefix}/c/Program Files/LLVM/bin/clang-cl.exe" ]; then
                clangdir="${prefix}/c/Program Files/LLVM/bin"
            fi
            if [ -n "$clangdir" ]; then
                gha_add_path "$clangdir"
            else
                gha_warning "clang-cl: bin dir not found after choco install llvm; relying on choco's PATH shims"
            fi
            anodizer::vok "clang-cl (LLVM) installed via choco llvm"
            _INSTALLER_EMITTED_OK=1
            ;;
        Linux) skip_unsupported_os clang-cl "Windows-only (MSVC C-object determinism pin)" ;;
        macOS) skip_unsupported_os clang-cl "Windows-only (MSVC C-object determinism pin)" ;;
    esac
}

# nasm provisioning: aws-lc-sys (pulled in transitively via octocrab's
# aws-lc-rs JWT provider — see the root Cargo.toml's `jwt-aws-lc-rs` comment)
# hard-requires nasm on PATH to assemble its perlasm .asm on windows-msvc; its
# build script panics with no fallback when nasm is missing. The GitHub-hosted
# windows image ships NASM with its install dir already on the machine PATH,
# so the on-PATH check below is a no-op on stock images; the choco fallback
# exists for images/configurations where that PATH entry is missing.
#
# Consumed two ways: as the `nasm` dep (dispatched below, parallel to
# clang-cl in determinism-deps.sh) AND directly by from-source.sh, which
# builds anodizer itself — and therefore aws-lc-sys — before the "Install
# dependencies" step (where the dispatch loop below runs) ever executes.
install_nasm() {
    case "$RUNNER_OS" in
        Windows)
            if command -v nasm > /dev/null 2>&1; then
                anodizer::vok "nasm already on PATH"
                _INSTALLER_EMITTED_OK=1
                return 0
            fi
            # choco's nasm package lands here without adding it to PATH.
            # NASM_GLOB_ROOT_PREFIX rebases the search root for hermetic tests
            # (empty in production).
            local prefix="${NASM_GLOB_ROOT_PREFIX:-}" nasmdir=""
            if [ -x "${prefix}/c/Program Files/NASM/nasm.exe" ]; then
                nasmdir="${prefix}/c/Program Files/NASM"
            fi
            if [ -n "$nasmdir" ]; then
                gha_add_path "$nasmdir"
                # aws-lc-sys may compile in THIS SAME process (from-source.sh
                # invokes cargo build right after calling install_nasm) —
                # unlike clang-cl, which is only ever consumed by a later
                # step — so export PATH immediately, not just for future
                # steps via GITHUB_PATH.
                export PATH="${nasmdir}:${PATH}"
                anodizer::vok "nasm found at ${nasmdir}, added to PATH"
                _INSTALLER_EMITTED_OK=1
                return 0
            fi
            # Neither on PATH nor the known install dir — install via choco
            # and discover its bin dir the way install_nsis/install_wix3/
            # install_clang_cl do: a choco package can land without its PATH
            # shim reaching the current shell.
            choco_install nasm NASM_VERSION
            if command -v nasm > /dev/null 2>&1; then
                nasmdir="$(dirname "$(command -v nasm)")"
            elif command -v where.exe > /dev/null 2>&1; then
                # `dirname ""` returns ".", which would poison PATH with the
                # cwd; only resolve a dir when the lookup actually found nasm.
                # `|| true` + the explicit `if` keep this set -e-safe — right
                # after the choco install nasm is not yet on PATH, so
                # where.exe exits non-zero, and without the guard pipefail
                # would abort the whole install before the glob fallback
                # below runs.
                local found
                found="$(where.exe nasm 2>/dev/null | head -1 | tr -d '\r' || true)"
                if [ -n "$found" ]; then nasmdir="$(dirname "$found")"; fi
            fi
            if [ -z "$nasmdir" ] && [ -x "${prefix}/c/Program Files/NASM/nasm.exe" ]; then
                nasmdir="${prefix}/c/Program Files/NASM"
            fi
            if [ -n "$nasmdir" ]; then
                gha_add_path "$nasmdir"
                export PATH="${nasmdir}:${PATH}"
            else
                gha_warning "nasm: bin dir not found after choco install nasm; relying on choco's PATH shims"
            fi
            anodizer::vok "nasm installed via choco nasm"
            _INSTALLER_EMITTED_OK=1
            ;;
        Linux) skip_unsupported_os nasm "Windows-only (aws-lc-sys perlasm assembly on windows-msvc)" ;;
        macOS) skip_unsupported_os nasm "Windows-only (aws-lc-sys perlasm assembly on windows-msvc)" ;;
    esac
}

# xmllint backs anodizer's chocolatey prepublish guard, which hard-requires it
# to schema-validate the generated .nuspec before push. On Linux it ships in
# libxml2-utils (the Debian/Ubuntu package providing /usr/bin/xmllint). macOS
# needs no install: libxml2 is part of the base system, so every GitHub macOS
# runner already has /usr/bin/xmllint. Windows is skipped rather than
# installed: the chocolatey push itself is plain HTTPS (no xmllint involved,
# the validating runner in practice is Linux), and choco ships no standalone
# xmllint package — only xsltproc bundles it as a side effect.
install_xmllint() {
    case "$RUNNER_OS" in
        Linux)   apt_queue libxml2-utils xmllint ;;
        macOS)   anodizer::vdetail "xmllint ships with the OS on macOS" ;;
        Windows) skip_unsupported_os xmllint "Linux/macOS only (chocolateys: nuspec validation runs on the packaging runner)" ;;
    esac
}

# ── dispatch ─────────────────────────────────────────────────────────

dispatch_install() {
    local dep pre_queue
    for dep in "${DEPS[@]}"; do
        # Apt-batched deps are logged by the batch header + per-package `✓`; the
        # generic per-tool "installing X" would duplicate that, so skip it for
        # them. Every other tool gets its leading "installing X" up front.
        _is_apt_batched "$dep" || anodizer::vstep "installing ${dep}"
        pre_queue=${#APT_PKGS[@]}
        # Self-logging installers set this to suppress the generic completion
        # line below. The apt-queue-delta heuristic alone is insufficient: an
        # installer that flushes apt internally (pkgbuild, flatpak) drains the
        # queue back to pre_queue, and a direct-download installer (rcodesign,
        # linuxdeploy, wix/cosign on their non-apt arms) never touches it — both
        # would otherwise print the generic line on top of their own.
        _INSTALLER_EMITTED_OK=""
        case "$dep" in
            nfpm)           install_nfpm ;;
            makeself)       install_makeself ;;
            snapcraft)      install_snapcraft ;;
            rpmbuild)       install_rpmbuild ;;
            cosign)         install_cosign ;;
            syft)           install_syft ;;
            zig)            install_zig ;;
            node)           install_node ;;
            cargo-zigbuild) install_cargo_zigbuild ;;
            upx)            install_upx ;;
            nsis)           install_nsis ;;
            create-dmg)     install_create_dmg ;;
            flatpak)        install_flatpak ;;
            alejandra)      install_alejandra ;;
            linuxdeploy)    install_linuxdeploy ;;
            rcodesign)      install_rcodesign ;;
            wix)            install_wix ;;
            wix3)           install_wix3 ;;
            pkgbuild)       install_pkgbuild ;;
            clang-cl)       install_clang_cl ;;
            nasm)           install_nasm ;;
            xmllint)        install_xmllint ;;
            # Cloud KMS CLIs — a closed set emitted by auto-detect from a
            # `blobs.kms_key:` URL scheme (awskms:// / gcpkms:// / azurekeyvault://).
            # anodizer ships no installer for them (they are preinstalled on
            # GitHub-hosted runners and provisioned on self-hosted images), so
            # ensure-on-PATH with a scheme-specific, actionable message.
            #
            # Cosmetic collision: a user who literally names `sboms.cmd: aws`
            # also lands here and gets the "(awskms://)" trigger phrase. The
            # ensure-on-PATH behavior is identical (present → no-op, absent →
            # actionable fail); only the diagnostic phrase is off. Left as-is —
            # `aws`/`gcloud`/`az` as an SBOM generator name is implausible, and
            # distinguishing the two callers would need the dispatcher to thread
            # the originating config field through for no behavioral gain.
            aws)            ensure_on_path aws "blobs.kms_key (awskms://)" ;;
            gcloud)         ensure_on_path gcloud "blobs.kms_key (gcpkms://)" ;;
            az)             ensure_on_path az "blobs.kms_key (azurekeyvault://)" ;;
            # Any remaining dep name is a user-supplied SBOM generator binary
            # named in `sboms.cmd:` (e.g. cyclonedx) — syft, the default/auto-
            # installable generator, has its own real installer above and never
            # reaches here. Route it to the same ensure-on-PATH contract: present
            # → no-op, absent → actionable fail.
            #
            # This catch-all is safe rather than a typo-masking hazard because
            # dep names are not free-typed: every name reaching the dispatcher is
            # synthesized by auto-detect from a SPECIFIC config field (a fixed
            # tool name per stage, the kms URL scheme, or `sboms.cmd:`), and
            # anodizer validates the config upstream before the action runs. The
            # only open-ended field is `sboms.cmd:`, so an unrecognized name here
            # is, by construction, that generator — fail loudly if it is absent,
            # naming the field, instead of the opaque "Unknown dependency".
            *)              ensure_on_path "$dep" "sboms.cmd" ;;
        esac
        # Skip the generic "installed" line when either (a) the installer left
        # something apt-queued — apt_flush emits one line per package after the
        # batch lands — or (b) the installer already emitted its own completion
        # line (_INSTALLER_EMITTED_OK).
        if [ "${#APT_PKGS[@]}" -eq "$pre_queue" ] && [ -z "$_INSTALLER_EMITTED_OK" ]; then
            anodizer::vok "${dep} installed"
        fi
    done
}

main() {
    local combined
    combined=$(merge_dep_inputs)
    dedupe_deps "$combined"

    if [ "${#DEPS[@]}" -eq 0 ]; then
        anodizer::detail "no dependencies requested"
        exit 0
    fi

    local noun=dependencies
    [ "${#DEPS[@]}" -eq 1 ] && noun=dependency
    anodizer::verb Installing "${#DEPS[@]} ${noun}"
    dispatch_install
    apt_flush
    # Only the two WiX deps put wixl on PATH; anything else on the box keeping an
    # old wixl around is not this run's problem to upgrade.
    case " ${DEPS[*]} " in
        *" wix "* | *" wix3 "*) wixl_backport_if_too_old ;;
    esac
    # Default-visible one-line summary of what landed (the per-tool progress is
    # verbose-only ::v* now), mirroring the detect phase's `detected` row. A
    # green run shows the header + this line; --debug expands the play-by-play.
    anodizer::kv installed "$(IFS=','; echo "${DEPS[*]}")"
}

# Source-safe: only run `main` when executed directly. Lets tests source
# this file to exercise individual installer helpers without the dispatch
# loop firing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
