# Gnosis VPN

This repository collects the binary artifacts that compose the Gnosis VPN project.

## Installation

### Debian / Ubuntu

Install via the APT repository (recommended — gives you `apt upgrade` for free):

```bash
curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash
```

Snapshot (nightly) channel:

```bash
curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --channel=snapshot
```

Manual repo setup (equivalent to what the installer does). The `$(dpkg --print-architecture)` command detects the host
architecture automatically:

```bash
# 1. Add the signing key
sudo install -dm 0755 /etc/apt/keyrings
curl -fsSL https://download.gnosisvpn.io/linux/apt/gnosisvpn-archive-keyring.gpg \
  | sudo install -m 0644 /dev/stdin /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg

# 2. Add the repository
sudo tee /etc/apt/sources.list.d/gnosisvpn.sources >/dev/null <<EOF
Types: deb
URIs: https://download.gnosisvpn.io/linux/apt
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
EOF

# 3. Install
sudo apt-get update && sudo apt-get install -y gnosisvpn
```

Manual `.deb` download is available directly from from
[the releases page](https://github.com/gnosis/gnosis_vpn/releases), or the APT pool at
`https://download.gnosisvpn.io/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_<version>_<arch>.deb` (with matching `.asc` and
`.sha256` sidecars at the same prefix). See [SECURITY.md](./SECURITY.md) for verification.

Install:

```bash
sudo apt install ./gnosisvpn_*.deb
```

Uninstall:

```bash
sudo apt remove gnosisvpn
```

### Linux Installation Environment Variables

**GNOSISVPN_NETWORK** Specifies the network configuration to use for GnosisVPN. Possible values include `jura`,
`rotsee`, `dufour`, etc. The default is `jura` if not set. This variable determines which configuration file is
symlinked to `/etc/gnosisvpn/config.toml` during installation.

**GNOSISVPN_HOPR_BLOKLI_URL** Defines the URL for the HOPR Blokli service used by GnosisVPN. If not set, defaults to
`https://blokli.jura.hoprnet.link`. This URL is written to `/etc/gnosisvpn/gnosisvpn.env` and used by the application
for network operations.

## Reporting Issues

To help us manage feedback and improve the project, we use a discussion-first process for all bug reports and feature
requests.

### How to report an issue

1. Search existing [Discussions](../../discussions) and [Issues](../../issues) to check if your topic is already
   covered.
1. If not, start a new Discussion in the [Issues & Bug Reports](../../discussions/new?category=issues-bug-reports)
   category.
1. Provide as much detail as possible using the provided template.

The team will review all discussions and promote confirmed bugs or planned features to actionable issues.

## Building

### Requirements

- [Nix](https://nixos.org) (recommended) - Provides all build dependencies
- macOS 11.0 or later for mac packages
- Xcode Command Line Tools installed: `$ xcode-select --install` for mac packages

### Quick Start

**Debian (x86_64)**

```bash
just download deb x86_64-linux
just changelog
just manual
just package deb x86_64-linux true
# Or execute all commands together with
just all deb x86_64-linux true
```

**Debian (ARM64)**

```bash
just download deb aarch64-linux
just changelog
just manual
just package deb aarch64-linux true
# Or execute all commands together with
just all deb aarch64-linux true
```

**Mac**

```bash
just download dmg aarch64-darwin
just package dmg aarch64-darwin true
# Or execute all commands together with
just all dmg aarch64-darwin true
```

### APT repository

The repository at `https://download.gnosisvpn.io/linux/apt` is built and signed by
[`scripts/publish-apt.sh`](scripts/publish-apt.sh), which uses [`reprepro`](https://salsa.debian.org/brlink/reprepro)
configured by [`linux/apt/conf/distributions`](linux/apt/conf/distributions) to assemble `Packages` indexes and sign
`InRelease`/`Release.gpg` with the GnosisVPN GPG key. The new `InRelease` is uploaded last so the swap is atomic and apt
clients never see a half-updated repo. Stable publishing is gated on the GitHub release job in `release.yaml`, so apt
clients can never see a stable version that lacks a matching GitHub release. Nightly builds publish to the `snapshot`
suite from `build-binary.yaml` right after the Linux build completes.

### GCS bucket layout

Everything end users see is served from `gs://download.gnosisvpn.io` (CDN: `https://download.gnosisvpn.io`):

```
download.gnosisvpn.io/
├── linux/
│   ├── install.sh                                      # end-user APT installer
│   └── apt/
│       ├── gnosisvpn-archive-keyring.gpg               # binary keyring (Signed-By:)
│       ├── dists/
│       │   ├── stable/
│       │   │   ├── InRelease                           # clearsigned, atomic pointer
│       │   │   ├── Release
│       │   │   ├── Release.gpg
│       │   │   └── main/binary-{amd64,arm64}/Packages(+.gz)
│       │   └── snapshot/                               # same shape, component is `snapshot/` (not `main/`)
│       └── pool/
│           ├── main/g/gnosisvpn/      gnosisvpn_<version>_{amd64,arm64}.deb(+.asc, +.sha256)   # stable, every release
│           └── snapshot/g/gnosisvpn/  gnosisvpn_<version>_{amd64,arm64}.deb(+.asc, +.sha256)   # nightly, append-only
├── macos/                                                  # <version> uses '-' in place of '+' (Artifact Registry compat)
│   ├── stable/   gnosisvpn_<version>_arm64.pkg(+.sha256)
│   └── latest/   gnosisvpn_<version>_arm64.pkg(+.sha256)   # snapshot
└── manifests/
    ├── linux-amd64.json
    ├── linux-arm64.json
    └── macos-arm64.json                                # consumed by the client app for auto-update
```

### Scripts

- `common.sh` — shared utility functions (logging, version checks)
- `config.sh` — static configuration (`MIN_OS_*`, `MIN_APP_VERSION`) used by build and manifest scripts
- `download-binaries.sh` — downloads pre-built upstream binaries (`gnosis_vpn-client`, `gnosis_vpn-app`) from GCP
  Artifact Registry
- `generate-changelog.ts` — aggregates merged PRs across the three repos; emits zulip/github/debian/json/rpm formats
  (requires Deno)
- `generate-manual.sh` — creates man pages (Linux only)
- `generate-package.sh` — dispatcher that invokes the Linux or macOS packaging script
- `generate-package-linux.sh` — builds the `.deb` via nfpm, GPG-signs it, writes `.asc` and `.sha256` sidecars
- `generate-package-mac.sh` — builds the macOS `.pkg` via `productbuild` and notarizes with Apple
- `generate-update-manifest.sh` — builds per-platform JSON manifests (`linux-amd64.json`, etc.) consumed by the client
  app for auto-update
- `publish-apt.sh` — builds and signs the APT repo (`Packages`, `InRelease`, `Release.gpg`) and publishes it to GCS

## Dependency Updates

Renovate runs on Renovate's `schedule:earlyMondays` preset with a 14-day minimum release age, so most PRs appear early
Monday morning and only for packages that have been released for at least two weeks.

Updates are grouped by ecosystem:

| Group               | What it covers                                        | Notes                                                                                                 |
| ------------------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `nix flake updates` | `flake.lock` inputs (nixpkgs, crane, rust-overlay, …) | digest/pinDigest updates; `pinDigests` disabled for the `nix` manager since nix pins via `flake.lock` |
| `github-actions`    | `.github/workflows` action refs                       | digest-pinned                                                                                         |
| _(individual PRs)_  | Cargo crates                                          | one PR per crate                                                                                      |

`prCreation: immediate` is intentional — CI only triggers on pull request events, so waiting for branch checks would
deadlock.
