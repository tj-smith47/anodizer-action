# Anodizer Action

GitHub Action that installs [Anodizer](https://github.com/tj-smith47/anodizer)
— a Rust-native release automation tool — and runs any anodizer subcommand in a
single step.

The action installs anodizer (cached per version), auto-installs the pipeline
tools the engine itself reports via `anodizer tools` (nfpm, makeself, snapcraft,
rpmbuild, cosign, syft, zig, node, cargo-zigbuild, upx, nsis, create-dmg,
flatpak, alejandra, linuxdeploy, rcodesign, wix, pkgbuild, xmllint, ruby, and the
cloud KMS CLIs), imports signing keys, logs in to container registries, handles
split/merge artifact plumbing (uploads honor a custom `dist:` directory and the
preserved-dist determinism layout), and runs anodizer.

## Quick start

```yaml
- uses: actions/checkout@v6
  with:
    fetch-depth: 0
- uses: tj-smith47/anodizer-action@v1
  with:
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

That installs the latest stable anodizer, asks `anodizer tools` which external
tools the configured stages need and installs them, and runs
`anodizer release --clean`. For a dry run, swap `args:` for
`release --snapshot --clean`.

## Inputs

Every input is optional. Defaults are taken verbatim from `action.yml`; `—`
means the input has no default.

| Input | Description | Default | Required |
|-------|-------------|---------|----------|
| `apk-private-key` | PEM-format RSA private key for signing apk packages produced by nfpm (apk-tools uses RSA-PSS, not OpenPGP, so `gpg-private-key` does not work here). Written to a `0600` temp file and exported as `APK_PRIVATE_KEY_PATH`; the derived public key is exported as `APK_PUBLIC_KEY_PATH` and copied into `./dist/` as `<repo>-apk-signing-key.rsa.pub` for attachment via `release.extra_files`. See [Key material](#key-material). | `""` | no |
| `args` | Arguments to pass to anodizer (e.g. `release --snapshot`). Do **not** embed secrets here — this value appears in workflow logs; pass secrets via `env:`. Mutually exclusive with `determinism: true`. | `—` | no |
| `artifact-run-id` | Workflow run ID to download `from-artifact` from. Use `auto` to resolve the latest successful run of `artifact-workflow` for the current commit, a numeric ID for explicit control, or omit to download from the current run. | `—` | no |
| `artifact-workflow` | Workflow filename to search when `artifact-run-id` is `auto` (e.g. `ci.yml`). Ignored otherwise. | `ci.yml` | no |
| `auto-install` | Ask `anodizer tools --json` what the configured pipeline needs and install it — the engine's own report, not a config re-parse. The run's scope flags (`--publish-only`, `--skip`, `--publishers`, `-f/--config`) are read from `args` and forwarded, so the installed set matches exactly the stages this job runs. See [auto-install dependency map](#auto-install-dependency-map). | `false` | no |
| `cosign-key` | Cosign private key contents. Written to `cosign.key` in the workdir with mode `0600`. Pair with `COSIGN_PASSWORD` in `env:`. | `—` | no |
| `determinism` | Run the determinism harness (`anodizer check determinism`) on this shard: installs Rust, provisions the binary, installs the per-OS harness dep set, derives the configured-target CSV, and invokes the harness. Designed as the entire body of a per-OS harness shard. Mutually exclusive with `args`. See [Determinism harness](#determinism-harness-one-liner-cross-platform-shard). | `false` | no |
| `determinism-crate` | Scope the harness to a single workspace crate (`anodizer check determinism --crate <name>`). Required when a release workflow fans out per crate so each shard's preserved dist lands under its own `<crate>/` subdir for a collision-free downstream merge. | `""` | no |
| `determinism-runs` | N for `anodizer check determinism --runs=N`. | `2` | no |
| `determinism-stages` | Stages to validate (comma-separated). When unset, defaults to the stages configured-and-installable on the current runner: Linux `build,source,upx,archive,nfpm,makeself,snapcraft,sbom,sign,checksum`; macOS/Windows `build,source,upx,archive,sbom,sign,checksum`. Also accepts `cargo-package`, `docker`, `msi`, `nsis`, `dmg`, `pkg`, `srpm`, and the `installers` family selector (expands to `nfpm,makeself,srpm,msi,nsis,dmg,pkg`). | `""` | no |
| `determinism-targets` | Explicit target CSV override. When unset, derived by filtering `anodizer targets --json` to the current `RUNNER_OS`. Set when your shard runs on a non-standard runner label. | `—` | no |
| `docker-password` | Registry password or token (e.g. `secrets.GITHUB_TOKEN` for ghcr.io). | `—` | no |
| `docker-registry` | Container registry to log in to (e.g. `ghcr.io`). When set, the action logs in and sets up QEMU + buildx for multi-platform builds. | `—` | no |
| `docker-username` | Registry username. Defaults to `github.actor` (via `GITHUB_ACTOR`) when unset. | `—` | no |
| `download-dist` | Before running anodizer, download and merge all `dist-*` artifacts into the dist tree (the configured `dist:` directory, default `dist/`). Set to `true` in merge jobs. | `false` | no |
| `from-artifact` | Download a pre-built anodizer binary from a workflow artifact instead of GitHub releases. Set to the artifact name (e.g. `anodizer-linux`); pair with `artifact-run-id` for cross-workflow downloads. | `—` | no |
| `from-branch` | Shallow-clone `tj-smith47/anodizer` at the given branch (e.g. `my-feature`) and build it from source. Branch name only — the repo is hardcoded; no owner prefix or SHA. Rust is auto-installed. Mutually exclusive with `version`, `from-artifact`, and `from-source`. | `""` | no |
| `from-source` | Build anodizer from source in the current workdir (bootstrap mode). Rust is auto-installed — you do not also need `install-rust: true`. | `false` | no |
| `gpg-private-key` | GPG private key contents to import for signing. Piped into `gpg --batch --import`. See [Key material](#key-material). | `—` | no |
| `install` | Explicit comma-separated build/pipeline dependencies, bypassing auto-detection: `nfpm`, `makeself`, `snapcraft`, `rpmbuild`, `cosign`, `syft`, `zig`, `node`, `cargo-zigbuild`, `upx`, `nsis`, `create-dmg`, `flatpak`, `alejandra`, `linuxdeploy`, `rcodesign`, `wix`, `wix3`, `pkgbuild`, `xmllint`, `ruby`. (`wix` = WiX v4; `wix3` = WiX v3; both install `wixl` on Linux.) Uses the platform's native package manager. Use this for jobs that do **not** run the pipeline (so `anodizer tools` reports nothing) — e.g. a standalone `preflight` job — or to force a specific tool on. | `—` | no |
| `install-only` | Only install anodizer (and any requested dependencies/keys); skip running it. | `false` | no |
| `install-rust` | Install the stable Rust toolchain (`dtolnay/rust-toolchain`). | `false` | no |
| `preserve-dist` | When `determinism: true`, preserve the harness's byte-stable dist tree to `./preserved-dist/` for a downstream `release --publish-only` job. Manifests get a `-<shard-label>` suffix so sharded uploads don't collide under `merge-multiple`. Requires `shard-label`. | `false` | no |
| `reclaim-disk` | Reclaim large, build-irrelevant runner caches before heavy build/packaging so disk-tight runners don't fail with "No space left on device". `auto` reclaims caches a Rust release pipeline never uses (iOS/tvOS/watchOS simulator runtimes on macOS, large preinstalled SDKs on Linux) but **only** on GitHub-hosted runners; `true` forces it on any runner; `false` disables it. | `auto` | no |
| `resolve-workspace` | Resolve the triggering tag to a crate name via `anodizer resolve-tag`. Set to `true` on tag-triggered release workflows. Populates the `workspace`, `crate-path`, and `has-builds` outputs. | `false` | no |
| `shard-label` | Per-shard suffix appended to preserved-dist manifests (`context-<shard-label>.json`, etc.). The caller names each shard explicitly. Required when `preserve-dist: 'true'`. | `""` | no |
| `upload-dist` | After running anodizer, upload the dist tree (the configured `dist:` directory, default `dist/`) as a workflow artifact named `dist-$RUNNER_OS`. With `preserve-dist: 'true'` it uploads `preserved-dist/` as `dist-<shard-label>` instead. | `false` | no |
| `version` | Anodizer version to install from GitHub releases: an exact tag (e.g. `v0.8.0`), the literal `latest` (newest stable), or `nightly` (newest `vX.Y.Z-<sha>-nightly` tag). No semver ranges (`~> v2`). Must not be combined with `from-artifact`, `from-source`, or `from-branch`. | `latest` | no |
| `workdir` | Working directory (below repository root). | `.` | no |

### auto-install dependency map

With `auto-install: true`, the action does **not** read your config. It runs
`anodizer tools --json` (forwarding the run's scope flags from `args`) and lets
the engine report exactly which external binaries the configured stages and
publishers will spawn — the same per-stage / per-publisher source of truth the
preflight engine uses, so a new tool-bearing stage updates the set
automatically with no shell logic to drift. Each reported binary is then
translated to an installer keyword (this translation — _how_ to install — is the
action's job; _what_ to install is anodizer's). Tools already on `PATH`, or
provided by the runner (git, gpg, ssh, docker, cargo), are left alone; a
required tool with no install recipe is reported as a `::warning::` rather than
silently skipped.

Translation from the binary anodizer reports to the installer the action runs:

| anodizer reports (binary) | Action installs | Notes |
|---------------------------|-----------------|-------|
| `nfpm` | `nfpm` | |
| `makeself` | `makeself` | macOS too; deps.sh skips it on Windows. |
| `snapcraft`, `unsquashfs` | `snapcraft` | The snapcraft installer also provisions `squashfs-tools` (`unsquashfs`). Linux installs via snap; runners without snapd fall back to a pip install pinned by `SNAPCRAFT_VERSION`. |
| `rpmbuild` | `rpmbuild` | macOS too; deps.sh skips it on Windows. |
| `cosign` (and any `cosign*` variant, e.g. `cosign-fips`) | `cosign` | Reported whenever the sign / docker-sign / blob stages will spawn a cosign binary. |
| `syft` | `syft` | A custom `sboms.cmd` (e.g. `cyclonedx`) has no recipe and is reported as a warning — install it on the runner or via `install:`. |
| `upx` | `upx` | |
| `makensis` | `nsis` | |
| `hdiutil` / `genisoimage` / `mkisofs` | `create-dmg` | The dmg stage's interchangeable binaries; any already on `PATH` (macOS `hdiutil`) satisfies it with no install. |
| `flatpak`, `flatpak-builder` | `flatpak` | The flatpak installer provisions both, plus the freedesktop Platform+SDK for each `FLATPAK_ARCHES` arch and `qemu-user-static`/`binfmt-support` so an x86_64 runner can cross-bundle the aarch64 app (flatpak-builder executes the manifest's build-commands inside the target-arch sandbox). deps.sh skips it off Linux. |
| `linuxdeploy` | `linuxdeploy` | deps.sh skips it off Linux. |
| `alejandra` | `alejandra` | nix publisher formatter. **See the gap note below.** |
| `rcodesign` | `rcodesign` | Cross-platform notarization (`notarize.macos:`). |
| `npm` | `node` | The npm publisher uses Trusted Publishing (OIDC); `NODE_VERSION` / `NPM_VERSION` pin the floor. |
| `pkgbuild` / `xar` | `pkgbuild` | macOS native `pkgbuild` (Xcode CLT); Linux builds the flat-package toolchain (`xar` + `mkbom`). |
| `wix` | `wix` | WiX v4 (`wix build`, the dotnet global tool). |
| `candle` / `light` / `wixl` | `wix3` | WiX v3 dialect — `candle`+`light` on Windows, `wixl` (msitools) on Linux. anodizer resolves the dialect (explicit `version:` > `.wxs` namespace > installed tool) and reports the matching binary. |
| `xmllint` | `xmllint` | Chocolatey prepublish guard — schema-validates the generated `.nuspec` before push. Linux installs `libxml2-utils`; macOS ships `/usr/bin/xmllint` with the OS; deps.sh skips it on Windows (the choco push is plain HTTPS and the validating runner in practice is Linux). |
| `ruby` | `ruby` | Homebrew prepublish guard — `ruby -c` over the generated formula and cask before the tap push (advisory: the structural check stands in without it). Linux installs the distro `ruby`; macOS ships `/usr/bin/ruby` with the OS; deps.sh skips it on Windows. |
| `zig`, `cargo-zigbuild` | `zig` + `cargo-zigbuild` | Cross-compilation via zigbuild (advisory — the build degrades gracefully without them). |
| `aws` / `gcloud` / `az` | `aws` / `gcloud` / `az` | Client-side KMS CLI for a `blobs.kms_key:` URL scheme; ensured on `PATH`. |

> **Known gap — nix `formatter`.** anodizer's nix publisher currently declares
> only its git/ssh requirements, not the `formatter` binary
> (`alejandra` / `nixfmt`), so `anodizer tools` does not yet report it. The map
> above already routes `alejandra` for when anodizer closes that gap, but until
> then a config whose nix publisher sets `formatter: alejandra` must keep
> `alejandra` in the explicit `install:` list.

#### Dependency version pins (env vars)

Every installer honors an env var to pin (or bump) the version it installs.
Pass them via the job/step `env:` block.

| Env var | Default | Effect |
|---------|---------|--------|
| `NFPM_VERSION` | `2.46.3` | Pins nfpm on all platforms. Linux installs a checksum-verified GitHub-release download; macOS pins the brew formula, Windows the choco package. |
| `MAKESELF_VERSION` | (unpinned) | Pins makeself on macOS (brew). Linux installs via apt, unpinned. |
| `SNAPCRAFT_VERSION` | `8.14.5` | Version for the pip fallback on snapd-less Linux runners; also pins the macOS brew formula. |
| `RPM_VERSION` | (unpinned) | Pins the rpm formula on macOS (brew). Linux installs via apt, unpinned. |
| `COSIGN_VERSION` | `v2.4.1` | Direct-download version on Linux and Windows; pins brew on macOS. |
| `SYFT_VERSION` | `v1.18.0` | Version passed to the syft install script on Linux; pins brew/choco on macOS/Windows. |
| `ZIG_VERSION` | `0.16.0` | Direct-download version on Linux (tarball URL + SHA256 both resolved from ziglang.org's `download/index.json`, so any published version works without a companion sha var); pins brew/choco on macOS/Windows (unset there = the package manager's latest). The default tracks current stable zig — older zigs (≤ 0.13.0) ship incomplete freebsd libc headers and break C-crypto crates (ring, aws-lc-sys) on `x86_64-unknown-freebsd`. |
| `UPX_VERSION` | (unpinned) | Pins upx on macOS (brew) / Windows (choco). Linux installs via apt, unpinned. |
| `NSIS_VERSION` | (unpinned) | Pins makensis on macOS (brew) / nsis on Windows (choco). Linux installs via apt, unpinned. |
| `CREATE_DMG_VERSION` | (unpinned) | Pins create-dmg on macOS (brew). On Linux the dmg stage uses apt `genisoimage` (unpinned). |
| `FLATPAK_RUNTIME_VERSION` | `24.08` | Branch of the freedesktop runtime + SDK pre-staged from flathub before `flatpak-builder` runs (Linux). |
| `FLATPAK_ARCHES` | `x86_64 aarch64` | Space-separated Flatpak arches to stage the Platform+SDK for — anodizer's `flatpaks:` stage bundles every Linux build arch, so an x86_64 runner cross-bundling the aarch64 app needs its base staged too. Trim to a single arch (e.g. `x86_64`) if your config only ships one. |
| `ALEJANDRA_VERSION` | `4.0.0` | Linux direct-download version. Overriding **requires** `ALEJANDRA_SHA256`. Pins brew on macOS. |
| `ALEJANDRA_SHA256` | (built-in for the default version) | SHA256 of the alejandra binary; required alongside an `ALEJANDRA_VERSION` override. |
| `LINUXDEPLOY_VERSION` | `1-alpha-20251107-1` | linuxdeploy + appimage-plugin download version (a dated tag, not `continuous`, so the bytes don't silently drift). Overriding **requires** `LINUXDEPLOY_SHA256` and `LINUXDEPLOY_PLUGIN_SHA256`. |
| `LINUXDEPLOY_SHA256` / `LINUXDEPLOY_PLUGIN_SHA256` | (built-in for the default version) | SHA256 of the linuxdeploy binary / its appimage plugin; required alongside a `LINUXDEPLOY_VERSION` override. |
| `LINUXDEPLOY_PLUGIN_VERSION` | `1-alpha-20250213-1` | Pins the appimage output plugin's dated tag independently. Overriding also **requires** `LINUXDEPLOY_PLUGIN_SHA256`. |
| `RCODESIGN_VERSION` | `0.29.0` | rcodesign version — direct download on Linux/macOS, `cargo install` on Windows. Overriding **requires** `RCODESIGN_SHA256` on Linux/macOS. |
| `RCODESIGN_SHA256` | (built-in for the default version) | SHA256 of the rcodesign archive; required alongside an `RCODESIGN_VERSION` override on Linux/macOS. |
| `NODE_VERSION` | `22.22.3` | Node version backing the `npms:` publisher. Direct download on Linux (verified); pins brew on macOS and choco on Windows. Satisfies the Node ≥ 22.14.0 OIDC floor. |
| `NPM_VERSION` | `11.5.1` | npm version installed (via `npm install -g npm@…`) after node, on all platforms — node bundles npm 10.9.x, below the npm ≥ 11.5.1 OIDC floor. |
| `WIX_VERSION` | `4.0.6` | Version of the WiX v4 `wix` dotnet global tool (Windows). |
| `ANODIZER_ACTION_SKIP_COSIGN_VERIFY` | (unset) | Set to `1` to skip the keyless signature verification of the downloaded cosign binary (the SHA256 check still runs). Escape hatch for Sigstore-unreachable environments. |

## Outputs

| Output | Description |
|--------|-------------|
| `artifacts` | Contents of `dist/artifacts.json` (build result artifacts JSON). |
| `crate-path` | Path to the resolved crate directory (requires `resolve-workspace: true`). |
| `crates` | JSON array of crate names `anodizer tag` produced tags for (e.g. `["core","bin-a"]`). Empty array `[]` when nothing was tagged. Drive downstream matrices with `fromJson(...)`. |
| `has-builds` | Whether the resolved crate has binary builds configured (requires `resolve-workspace: true`). |
| `head-sha` | Commit at HEAD after `anodizer tag --push` (the tag target — the bump commit, or the original HEAD when no bump was needed). Check this out in downstream jobs so the tree matches the tag. |
| `irreversibly-published` | `'true'` when the run summary records a one-way-door publisher (crates.io, chocolatey, winget, snapcraft, …) whose publish landed — the version is burned at a registry that never accepts the same version twice. `'false'` when only reversible publishers succeeded or nothing was proven published. Gate custom destructive recovery on it. See [Manual recovery](#manual-recovery-advanced). |
| `irreversibly_published` | Deprecated snake_case alias of `irreversibly-published` (same value); retained for compatibility. New workflows should read `irreversibly-published`. |
| `metadata` | Contents of `dist/metadata.json` (build result metadata JSON). |
| `new-tag` | Tag `anodizer tag` created this run (e.g. `v1.2.3`), for single-crate and lockstep-workspace repos. Empty when no tag was cut. Per-crate workspaces use `crates`/`versions` instead. |
| `old-tag` | Previous tag `anodizer tag` bumped from. Empty on a first release. |
| `part` | Semver part bumped: `major` / `minor` / `patch` / `none` / `custom`. |
| `release-url` | URL of the created GitHub release (extracted from `metadata.json`). |
| `split-matrix` | JSON matrix for `strategy.matrix` covering all configured build targets, derived from the anodizer config when `install-only: true`. Each entry has `os`, `target`, and `artifact`. See [Derive the build matrix from config](#derive-the-build-matrix-from-config-split-matrix). |
| `tagged` | `'true'` when this run cut a new tag (`new-tag` non-empty and differs from `old-tag`), `'false'` on a no-op. Gate downstream release jobs on this for single-crate / lockstep repos. |
| `versions` | JSON object mapping crate name to bumped version (e.g. `{"core":"1.2.0","bin-a":"0.5.1"}`) from `anodizer tag`. Empty `{}` when nothing was tagged. Bracket-form for hyphenated crates: `fromJson(...)['my-crate']`. |
| `workspace` | Crate name resolved from the triggering tag (requires `resolve-workspace: true`). |

## Examples

### Publisher tokens

A release that only publishes back to **its own** repository — create the
GitHub Release, upload assets — works with the default `GITHUB_TOKEN`.

Publishers that open a pull request against **another** repository need a token
with write access to that repo; the default `GITHUB_TOKEN` cannot push to other
repositories. Provision a personal access token (classic `public_repo`, or a
fine-grained PAT scoped to the target repos) as a secret and pass it via `env:`.
Each publisher reads its own variable first, then falls back to
`ANODIZER_GITHUB_TOKEN`, then `GITHUB_TOKEN`:

| Publisher | Token env var | Target |
|-----------|---------------|--------|
| Homebrew | `HOMEBREW_TAP_TOKEN` | your tap repo |
| krew | `KREW_INDEX_TOKEN` | krew-index fork → PR |
| MCP | `MCP_GITHUB_TOKEN` | MCP registry (API publish) |
| Scoop | `SCOOP_BUCKET_TOKEN` | your bucket repo |
| winget | `WINGET_PKGS_TOKEN` | winget-pkgs fork → PR |
| Nix | `NIX_PKGS_TOKEN` | your nix repo |
| SchemaStore | `SCHEMASTORE_TOKEN` | SchemaStore fork → PR |

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    args: release
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}          # same-repo release
    SCHEMASTORE_TOKEN: ${{ secrets.SCHEMASTORE_PAT }}  # fork push + SchemaStore PR
```

The SchemaStore publisher pushes the updated catalog/schema to a fork of
`SchemaStore/schemastore` and opens a PR upstream, so `SCHEMASTORE_TOKEN` (or the
`ANODIZER_GITHUB_TOKEN` / `GITHUB_TOKEN` fallback) must be a PAT that can push to
your fork and open a pull request against the upstream repository.

The MCP publisher is the one row that is not a fork → PR: it exchanges
`MCP_GITHUB_TOKEN` (a GitHub PAT, or Actions OIDC when the job has
`id-token: write`) for an MCP registry JWT and publishes via the registry
API.

### Preflight and failure handling — in-process, no extra steps

The release step is self-contained. `anodizer release` runs the config-derived
preflight once, before any stage — the environment half (required tools,
secrets, endpoint reachability, parseable key material), a credential probe
against every selected publisher, and a reconcile sweep against the version it
is about to cut — and, on a pipeline failure, executes the
`release.on_failure` policy inside the binary — rolling back the tag and
version-bump commit by default, auto-degrading to `hold` once any one-way-door
publisher (crates.io, chocolatey, winget, snapcraft, …) has landed. Failure
policy is config, not workflow YAML:

```yaml
# .anodizer.yaml
release:
  on_failure: rollback   # rollback | hold; default rollback
```

To prove a runner can cut the release before a real tag is in flight — a
pre-tag gate job, a scheduled canary, or debugging a missing-secret failure —
run the same engine standalone; it derives the version it probes from the tag
at HEAD or, absent one, from the next version `anodizer tag` would cut:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    args: preflight
  env:
    # same secret env block as the release job
    GITHUB_TOKEN: ${{ secrets.GH_PAT }}
```

A release job that runs after such a gate passes `--skip=preflight` so the
engine runs once per release, not once per job:

```yaml
    args: release --publish-only --skip=preflight
```

### Manual recovery (advanced)

A run killed before the binary could execute its own policy (runner eviction,
cancellation), or one held by `on_failure: hold`, is recovered by hand with
`anodizer tag rollback` / `anodizer release --rollback-only`. `tag rollback`
reads the run summaries itself and refuses when the version is burned at a
one-way-door publisher (override with `--force`).

Workflows that wire their own destructive recovery step must gate it on the
`irreversibly-published` output so it never destroys a live release:

```yaml
- name: Run anodizer release
  id: release
  uses: tj-smith47/anodizer-action@v1
  with:
    args: release
    # ... other inputs ...

- name: Custom recovery
  if: always() && (steps.release.outcome == 'failure' || steps.release.outcome == 'cancelled') && steps.release.outputs.irreversibly-published != 'true'
  env:
    GH_TOKEN: ${{ secrets.GH_PAT }}
    GITHUB_TOKEN: ${{ secrets.GH_PAT }}
  run: anodizer tag rollback "$GITHUB_SHA"
```

- `id: release` is what makes `steps.release.outcome` and
  `steps.release.outputs.irreversibly-published` resolvable.
- `anodizer tag rollback "$GITHUB_SHA"` auto-derives the branch from the bump
  SHA, so no `--branch` flag is needed in the common case (a release workflow
  triggered by an `anodizer tag` push).
- For multi-job workflows where the release runs against a tagged bump commit
  produced by an earlier job, pass the SHA explicitly (e.g.
  `${{ needs.tag.outputs.head-sha }}`, mapping the action's `head-sha` output
  through the tag job's `outputs:`) instead of `$GITHUB_SHA`.

### Auto-install dependencies from config

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    auto-install: true
    gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GPG_FINGERPRINT: ${{ secrets.GPG_FINGERPRINT }}
    COSIGN_KEY: ${{ secrets.COSIGN_KEY }}
    COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
```

### Key material

| Input | Notes |
|-------|-------|
| `gpg-private-key` | Imported via `gpg --batch --import` (used by `signs:` blocks). Also written to `$RUNNER_TEMP/anodizer-signing.asc` and exported as `GPG_KEY_PATH` for nfpm package signing — `rpmsign` / `dpkg-sig` / `abuild-sign` read the key directly off disk. Loopback pinentry is enabled so any `GPG_PASSPHRASE` works non-interactively. |
| `apk-private-key` | apk-tools uses RSA-PSS, not OpenPGP, so `gpg-private-key` does not satisfy apk signing. Written to `$RUNNER_TEMP/anodizer-apk.rsa` (mode `0600`) and exported as `APK_PRIVATE_KEY_PATH`. Reference from `.anodizer.yaml` via `apk.signature.key_file: "{{ .Env.APK_PRIVATE_KEY_PATH }}"`. The matching public key is derived via `openssl rsa -pubout`, exported as `APK_PUBLIC_KEY_PATH`, and copied into `./dist/` as `<repo>-apk-signing-key.rsa.pub` so it can be attached to the GitHub Release via `release.extra_files`. |
| `cosign-key` | Written to `cosign.key` (mode `0600`). Pair with `COSIGN_PASSWORD` in `env:`. |

### Split/merge cross-platform build

`upload-dist` and `download-dist` replace the manual
`actions/upload-artifact` / `actions/download-artifact` pair for split
builds.

```yaml
jobs:
  build:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          install-rust: true
          install: zig,cargo-zigbuild,upx
          upload-dist: true                 # uploads dist/ as dist-$RUNNER_OS
          args: release --split --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          auto-install: true
          download-dist: true               # downloads + merges dist-* artifacts
          gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
          args: release --merge
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GPG_FINGERPRINT: ${{ secrets.GPG_FINGERPRINT }}
          COSIGN_KEY: ${{ secrets.COSIGN_KEY }}
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
```

### Derive the build matrix from config (`split-matrix`)

An `install-only: true` step also emits the `split-matrix` output —
`anodizer targets --json` rendered as an include-form matrix (`os`,
`target`, `artifact` per entry) — so the split-build fan-out is derived
from `.anodizer.yaml` instead of hand-maintained in workflow YAML. The
step fails loudly when the matrix cannot be derived (anodizer missing,
`targets --json` erroring); it is empty only when the workdir has no
anodizer config at all.

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.a.outputs.split-matrix }}
    steps:
      - uses: actions/checkout@v6
      - uses: tj-smith47/anodizer-action@v1
        id: a
        with:
          install-only: true

  build:
    needs: plan
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.plan.outputs.matrix) }}
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          upload-dist: true
          args: release --split --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Tag-triggered monorepo release (resolve tag → crate)

```yaml
on:
  push:
    tags: ["*-v*"]

jobs:
  resolve:
    runs-on: ubuntu-latest
    outputs:
      crate: ${{ steps.a.outputs.workspace }}
      has-builds: ${{ steps.a.outputs.has-builds }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        id: a
        with:
          resolve-workspace: true
          install-only: true

  release:
    needs: resolve
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          auto-install: true
          docker-registry: ghcr.io
          docker-password: ${{ secrets.GITHUB_TOKEN }}
          args: release --crate ${{ needs.resolve.outputs.crate }} --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Reuse CI-built binary across workflows

```yaml
# ci.yml — build and upload anodizer once per commit
- uses: actions/checkout@v6
- uses: dtolnay/rust-toolchain@stable
- run: cargo build --release -p anodizer
- uses: actions/upload-artifact@v4
  with:
    name: anodizer-linux
    path: target/release/anodizer

# release.yml — reuse the artifact
- uses: tj-smith47/anodizer-action@v1
  with:
    from-artifact: anodizer-linux
    artifact-run-id: auto                   # resolves latest ci.yml run for this SHA
    artifact-workflow: ci.yml
    auto-install: true
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Bootstrap from source

When `from-artifact` is only available for one platform and the current
runner needs a platform-native binary:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    install-rust: true
    from-source: true
    install: zig,cargo-zigbuild,upx
    args: release --split --clean
```

### Test an un-released branch of anodizer

For integration testing a downstream project against an in-flight anodizer
PR — or dogfooding a feature branch before it lands — use `from-branch`.
The action shallow-clones `tj-smith47/anodizer` at the branch you name,
builds it from source, and puts it on `PATH` for the rest of the job:

```yaml
- uses: actions/checkout@v6
- uses: tj-smith47/anodizer-action@v1
  with:
    from-branch: my-feature        # branch on tj-smith47/anodizer
    args: release --snapshot --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- Input accepts a **branch name only** — the repository is hardcoded to
  `tj-smith47/anodizer`. There is no `from-branch-repo` / `@ref` syntax.
- The Rust toolchain is auto-installed; you do not need `install-rust: true`.
- Cargo's `target/` directory is cached per branch via
  [`Swatinem/rust-cache`](https://github.com/Swatinem/rust-cache), so the
  second invocation of the same branch on a hot runner is fast.
- Clones to `${RUNNER_TEMP}/anodizer-src` — your `workdir:` is untouched.
- Mutually exclusive with `version:`, `from-artifact:`, and `from-source:`.

### Install only, drive anodizer yourself

Useful for multi-crate loops, tagging, and ad-hoc subcommands:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    install-only: true

- run: anodizer check config
- run: anodizer healthcheck
- run: |
    for crate in my-core my-cli my-operator; do
      anodizer tag --crate "$crate" || true
    done
    git push origin HEAD
```

> ⚠️ **Legacy pattern.** The per-crate loop above predates the atomic
> workspace flow. New configs should prefer a single `args: tag` step (see
> [Workspace orchestration](#workspace-orchestration) below) which bumps,
> tags, and pushes every changed crate in one atomic commit. The loop is
> retained here only because operators on older configs may still be
> driving per-crate tagging by hand.

### Determinism harness (one-liner cross-platform shard)

`anodizer check determinism` rebuilds your pipeline N times in a hermetic
worktree and diffs the artifact digests, surfacing non-deterministic
inputs (timestamps, build-id, randomized symbol layout, …) before they
poison a release. With `determinism: true`, a 3-OS matrix collapses to
~10 lines per shard — the action handles Rust toolchain install, the
per-OS harness dependency set (zig + cargo-zigbuild + upx + nfpm +
makeself + snapcraft + syft + cosign on Linux; upx + syft + cosign on
macOS/Windows), from-source build of anodizer, per-shard target-CSV
derivation via `anodizer targets --json`, `rustup target add` for each
triple, and harness invocation:

```yaml
determinism-check:
  name: Determinism Harness (${{ matrix.os }})
  strategy:
    fail-fast: false
    matrix:
      os: [ubuntu-latest, macos-latest, windows-latest]
  runs-on: ${{ matrix.os }}
  steps:
    - uses: actions/checkout@v6
      with:
        fetch-depth: 0
    - uses: tj-smith47/anodizer-action@v1
      with:
        determinism: true
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Per-shard target lists are auto-derived from `.anodizer.yaml` (only
targets whose `os` matches the current runner are validated). The CSV
is logged as a notice so a shard's scope is visible in the run log.

To feed a downstream `release --publish-only` job from the harness's
byte-stable dist, set `preserve-dist: 'true'` and pass an explicit
`shard-label` per matrix entry. The action renames each shard's
manifests with that suffix so `merge-multiple` doesn't collide.

Tune with `determinism-runs`, `determinism-stages`, `determinism-targets`,
and `determinism-crate` (see [Inputs](#inputs)). The harness step does
**not** retry on failure — it gates release quality, so a flaky retry would
mask drift. `determinism: true` is mutually exclusive with `args:` (the
action invokes the harness directly).

### Nightly builds

Anodizer publishes immutable nightly tags shaped `vX.Y.Z-<sha>-nightly`
(e.g. `v0.8.0-abc1234-nightly`) — every nightly is its own permanent
release rather than a moving `nightly` tag.

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    version: nightly                       # newest *-nightly tag
```

The action lists releases newest-first and installs the first non-draft
tag whose name ends in `-nightly`. Pin a specific nightly by passing the
exact tag instead:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    version: v0.8.0-abc1234-nightly        # exact pin, won't drift
```

## Build provenance (SLSA attestations)

When your `.anodizer.yaml` enables `attestations` in the default `subjects`
mode, anodizer writes a subjects manifest (`dist/attestation-subjects.json`, or
`dist/<crate>.attestation-subjects.json` in per-crate workspaces) listing every
release-uploadable artifact and its sha256. After anodizer runs, this action
flattens those manifests into a checksums file and mints a GitHub-trusted,
OIDC-backed SLSA build-provenance attestation over them via
[`actions/attest-build-provenance`][abp] — no attestation key is ever held by
anodizer or stored as a release asset.

It is automatic: producing the manifest is the opt-in, so you only set
`attestations.enabled: true` in your config. The step is a no-op when no
manifest is present. The calling workflow must grant the two permissions the
attestation API needs (alongside `contents: write` for the release itself):

```yaml
permissions:
  contents: write       # create the release / upload assets
  id-token: write       # OIDC identity for keyless attestation (and cosign)
  attestations: write   # write the SLSA provenance attestation
```

Consumers verify an artifact against its provenance with:

```bash
gh attestation verify <artifact> --repo <owner>/<repo>
```

[abp]: https://github.com/actions/attest-build-provenance

## Workspace orchestration

`anodizer tag` (without `--crate`) detects which crates in the workspace have changed since their last tag, bumps their versions, creates all per-crate tags in one bump commit, and pushes everything atomically. Two step outputs carry the result into downstream jobs:

| Output | Shape | Purpose |
|--------|-------|---------|
| `crates` | `["core","bin-a","bin-b"]` | Gate downstream jobs; drive a determinism matrix |
| `versions` | `{"core":"1.2.0","bin-a":"0.5.1"}` | Display, release-note generation, or conditional logic |

Skip all downstream jobs when nothing changed:

```yaml
jobs:
  tag:
    runs-on: ubuntu-latest
    outputs:
      crates: ${{ steps.t.outputs.crates }}
      head-sha: ${{ steps.t.outputs.head-sha }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
          token: ${{ secrets.GH_PAT }}
      - name: Configure git identity
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
      - uses: tj-smith47/anodizer-action@v1
        id: t
        with:
          args: tag
        env:
          GITHUB_TOKEN: ${{ secrets.GH_PAT }}

  determinism-check:
    needs: tag
    if: needs.tag.outputs.crates != '[]'
    strategy:
      fail-fast: false
      matrix:
        crate: ${{ fromJson(needs.tag.outputs.crates) }}
        shard: [linux, macos, windows-x86_64, windows-aarch64]
        # Windows can't validate both MSVC triples in one shard; the
        # per-shard targets CSV scopes each one (empty = auto-derive).
        include:
          - { shard: linux,           os: ubuntu-latest,  targets: '' }
          - { shard: macos,           os: macos-latest,   targets: '' }
          - { shard: windows-x86_64,  os: windows-latest, targets: 'x86_64-pc-windows-msvc' }
          - { shard: windows-aarch64, os: windows-latest, targets: 'aarch64-pc-windows-msvc' }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
          ref: ${{ needs.tag.outputs.head-sha }}
      - uses: tj-smith47/anodizer-action@v1
        with:
          determinism: "true"
          determinism-targets: ${{ matrix.targets }}
          determinism-crate: ${{ matrix.crate }}
          preserve-dist: "true"
          shard-label: ${{ matrix.crate }}-${{ matrix.shard }}
          # uploads preserved-dist/ as "dist-<crate>-<shard>"
          upload-dist: "true"
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  release:
    needs: [tag, determinism-check]
    if: needs.tag.outputs.crates != '[]'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
          ref: ${{ needs.tag.outputs.head-sha }}
      - uses: tj-smith47/anodizer-action@v1
        with:
          auto-install: true
          download-dist: true
          args: release --publish-only
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

The `determinism-crate` input scopes the harness to one crate per matrix entry, so each shard validates only the targets that belong to that crate. `release --publish-only` consumes all preserved-dist subdirs and publishes in topological order.

For the full decision tree (single-crate, lockstep workspace, per-crate workspace, hybrid groupings, split-CI governance) and copy-pasteable YAML for every strategy, see the [Release Workflow Strategies](https://tj-smith47.github.io/anodizer/docs/ci/release-workflows/) page in the anodize docs.

## Retry behavior

The `Run anodizer` step retries up to 3 times — but **only for invocations that
build no upstream state**. Build and preview legs (`--snapshot`, `--nightly`,
`--dry-run`, `--merge`, `--prepare`, `--split`, `--announce-only`) and the
standalone `preflight` subcommand retry on a transient failure (registry rate
limits, Docker push auth expiry, network blips). Between retries the step prunes
generated artifacts from the dist tree (the configured `dist:` directory) so the
rebuild can't hit "already exists" collisions — **unless** any split/preserved
context manifest is present (`context.json` / `context-<shard>.json` at the dist
root, or `context*.json` in any first-level subdir). In that case cleanup is
skipped entirely — all-or-nothing, not per-file — because those trees are
`--merge` / `--publish-only` inputs that a retry must never wipe.

A **plain `anodizer release`** (and the explicitly stateful `--publish-only`,
`--rollback-only`, and `tag rollback`) runs **exactly once — no retry**. A plain
release cuts the tag, creates the GitHub release, runs the publishers, and on
failure rolls back, *deleting the tag*. A blind whole-pipeline retry would then
re-run against a tagless HEAD, anodizer would short-circuit "no release tag —
nothing to do" and exit 0, and a **failed release would report green**.
Transient per-publisher failures are instead retried *inside* anodizer — the
only layer that can retry a single publisher without re-running rollback — so
the wrapper surfaces the real failure rather than masking it.

### Deterministic failures stop on the first attempt

Even in a retryable mode, a **deterministic** failure — an unknown flag, an
unparseable `.anodizer.yaml`, a bad `--targets` value, the dist-not-empty guard
— fails fast after one attempt instead of burning the retry budget on an
identical error. anodizer classifies these itself and the step reads both
signals: exit code `2`, and an `anodizer-error-class: deterministic` line on
stderr (which also classifies an older anodizer whose deterministic paths still
exit `1`). The step then reports:

```text
   ✗ anodizer failed with a deterministic error (exit 2); retrying cannot help — fix the reported config/usage error and re-run
```

Unclassified failures (network, 5xx, rate limits) are untouched by this and
still retry the full 3 attempts.

The run step re-states that classification in its **own exit code**, so it holds
for anything invoking `scripts/run/anodizer.sh` directly, not just for the
action:

| Outcome | Step exit code |
|---|---|
| success | `0` |
| deterministic failure (anodizer exit `2` *or* the stderr marker) | `2` |
| any other failure — retries exhausted, stateful single attempt | `1` |

A marker-classified failure exits `2` even when anodizer itself exited `1`: the
classification is what a caller acts on, not which of the two signals carried
it. GitHub Actions only distinguishes zero from nonzero, so nothing about the
workflow-level result changes.

## License

MIT
