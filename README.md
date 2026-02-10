# Gnosis VPN

This repository collects the binary artifacts that compose the Gnosis VPN project.

## Installation

### Debian / Ubuntu

Download packages from [releases](https://github.com/gnosis/gnosis_vpn/releases):
- Main package (`.deb`)
- SHA256 checksum (`.sha256`)
- GPG signature (`.asc`)

**Verify integrity before installing** - see [SECURITY.md](./SECURITY.md)

```bash
sudo apt-get update
sudo apt install ./gnosisvpn_*.deb
```

Uninstall:
```bash
sudo apt remove gnosisvpn
```

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

