# Gnosis VPN

This repository collects the binary artifacts that compose the Gnosis VPN project.

## Installation

### Debian / Ubuntu

Install via the APT repository (recommended — gives you `apt upgrade` for free):

```bash
curl -fsSL https://download.gnosisvpn.io/install/linux.sh | sudo bash
```

Snapshot (nightly) channel:

```bash
curl -fsSL https://download.gnosisvpn.io/install/linux.sh | sudo bash -s -- --channel=snapshot
```

Manual repo setup (equivalent to what the installer does):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://download.gnosisvpn.io/apt/gnosisvpn-archive-keyring.gpg \
    -o /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
sudo tee /etc/apt/sources.list.d/gnosisvpn.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.gnosisvpn.io/apt
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
EOF
sudo apt-get update
sudo apt-get install -y gnosisvpn
```

Manual `.deb` download (one-off install, no automatic updates) is still available from
[releases](../../releases) — see [SECURITY.md](./SECURITY.md) for verification.

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

### Scripts

- `common.sh` - Shared utility functions
- `download-binaries.sh` - Downloads pre-built binaries from GCP Artifact registry
- `generate-manual.sh` - Creates man pages (Linux only)
- `generate-changelog.ts` - Creates the changelog (requires Deno)
- `generate-package.sh` - Generates packages (.deb, .dmg)
