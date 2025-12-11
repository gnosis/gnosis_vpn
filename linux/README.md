# Linux Packages

## Installation

Download packages from [releases](https://github.com/gnosis/gnosis_vpn/releases):
- Main package (`.deb`)
- SHA256 checksum (`.sha256`)
- GPG signature (`.asc`)

**⚠️ Verify integrity before installing** - see [SECURITY.md](../SECURITY.md)

### Debian/Ubuntu

```bash
sudo apt-get update
sudo apt install ./gnosisvpn_*.deb
```

Uninstall:
```bash
sudo apt remove gnosisvpn
```

---

## Building

### Requirements

- [just](https://github.com/casey/just) - Command runner
- [nfpm](https://nfpm.goreleaser.com/) - Package builder
- [Nix](https://nixos.org) (recommended) - Provides all build dependencies
- Google Cloud SDK - For downloading binaries

### Quick Start

**GitHub releases (nfpm packages):**
```bash
just package-nfpm deb x86_64-linux
just sign deb x86_64-linux
```

**Debian repositories (source packages):**
```bash
just package deb x86_64-linux
# Then sign & upload: debsign, dput
```

### Scripts

- `download-binaries.sh` - Downloads pre-built binaries from GCP
- `build-nfpm-package.sh` - Builds packages for GitHub releases (.deb, .rpm, .pkg.tar.zst)
- `generate-package.sh` - Generates Debian source packages (.dsc, .changes)
- `generate-manual.sh` - Creates man pages (Linux only)
- `common.sh` - Shared utility functions

### Workflow

**GitHub Releases:**
1. Download binaries → 2. Generate changelog/manual → 3. Build package → 4. Sign

**Official Repos:**
1. Download binaries → 2. Generate changelog/manual → 3. Build source package → 4. Sign & upload

### Directory Structure

```
linux/
├── download-binaries.sh    # Fetches binaries from GCP
├── build-nfpm-package.sh   # GitHub release packages
├── generate-package.sh     # Debian source packages
├── generate-manual.sh      # Man pages
├── common.sh               # Shared functions
├── nfpm-template.yaml      # nfpm configuration
├── justfile                # Task orchestration
├── debian/                 # Debian packaging (official repos)
│   └── README.md          # Debian-specific instructions
├── build/                  # Build artifacts (gitignored)
│   ├── binaries/          # Downloaded binaries
│   ├── packages/          # Built packages
│   ├── changelog/         # Generated changelogs
│   └── man/               # Generated man pages
└── resources/             # Static configs, templates
```

---

## Testing

### Prerequisites

- Google Cloud SDK (`gcloud`)
- just
- GCP project access

### Console Testing

Test in headless VMs (CI/CD recommended):

```bash
just test-package deb x86_64-linux
```

### Desktop Testing

Test with GUI (XFCE + xrdp):

```bash
just test-package-desktop deb x86_64-linux
# In new terminal:
just rdp-connect deb x86_64-linux
```

**⚠️ Desktop VMs are not auto-deleted:**
```bash
just delete-test-vm deb x86_64-linux

```bash
# Build Debian package
just package deb x86_64-linux
```

**Build with signing:**

```
