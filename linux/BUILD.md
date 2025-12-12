# Linux Packaging Scripts

This directory contains scripts for building GnosisVPN packages for Linux distributions.


## Quick Start with justfile

The easiest way to build packages is using the justfile recipes:

### For GitHub Releases (nfpm packages)
```bash
# Build .deb package for x86_64
just package-nfpm deb x86_64-linux

# Sign the package
just sign deb x86_64-linux
```

### For Official Distribution Repositories
```bash
# Build Debian source package
just package deb x86_64-linux
```

## Workflow

### GitHub Releases (nfpm)
1. **Download binaries**: `download-binaries.sh` fetches pre-built binaries from GCP
2. **Generate changelog**: `just changelog` creates release notes
3. **Generate manuals**: `just manual` creates man pages (Linux only)
4. **Build package**: `build-nfpm-package.sh` creates the distribution package (.deb, .rpm, .pkg.tar.zst)
5. **Sign package**: `just sign` creates `.asc` and `.sha256` files

### Official Repositories (source packages)
1. **Download binaries**: `download-binaries.sh` fetches pre-built binaries from GCP
2. **Generate changelog**: `just changelog` creates release notes
3. **Generate manuals**: `just manual` creates man pages (Linux only)
4. **Build source package**: `generate-package.sh` creates distribution source package (.dsc, .changes)
5. **Sign & upload**: Use `debsign` and `dput` for Debian

## Directory Structure

```
linux/
├── download-binaries.sh    # Downloads binaries from GCP
├── build-nfpm-package.sh   # Builds nfpm packages (GitHub releases)
├── generate-manual.sh      # Generates manual pages
├── generate-package.sh     # Generates source packages (official repos)
├── common.sh               # Shared functions
├── nfpm-template.yaml      # nfpm configuration template
├── justfile                # Task definitions
├── debian/                 # Debian packaging (for official repos)
├── build/                  # Build artifacts (gitignored)
│   ├── binaries/          # Downloaded binaries
│   ├── packages/          # Built packages
│   ├── changelog/         # Generated changelogs
│   └── man/               # Generated man pages
└── resources/             # Static resources (configs, templates)
```

## Distribution Channels

### GitHub Releases (Current)
- Uses nfpm for multi-distribution packages
- Detached GPG signatures (`.asc` files)
- SHA256 checksums
- Fast iteration and direct user downloads

### Official Repositories (Future)
- Debian: Uses `debian/` directory structure
- Build source packages with `just package deb x86_64-linux`
- Requires Linux environment or Docker
- See `debian/README.md` for details
