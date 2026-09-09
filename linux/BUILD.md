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

## Build-time environment

Two installer lines are built from this repo, and two environment variables select which one a build belongs to. CI sets
both (see `build-binary.yaml`); a local build without them gets the standard line.

| Variable             | Values                                         | Effect                                                             |
| -------------------- | ---------------------------------------------- | ------------------------------------------------------------------ |
| `GNOSISVPN_CHANNEL`  | `stable`, `snapshot`, `experimental`, unset    | Selects the default network set and is checked against the version |
| `GNOSISVPN_NETWORKS` | space-separated network names, first = default | Which `config-<network>.toml` conffiles the package ships          |

`GNOSISVPN_NETWORKS` defaults to `NETWORKS_STANDARD` (or `NETWORKS_EXPERIMENTAL` when the channel is `experimental`)
from `scripts/config.sh`, and is baked into the package as `/usr/share/gnosisvpn/networks` so the postinstall can pick a
default and re-point `/etc/gnosisvpn/config.toml` after a channel switch.

The build refuses a channel/version mismatch, because the installed package infers its APT suite from its own version
string: an `experimental` build needs a version ending in `.experimental`, and `stable`/`snapshot` builds must not have
one.

```bash
# Experimental line (ships piz-palu-dev only)
GNOSISVPN_CHANNEL=experimental \
  GNOSISVPN_PACKAGE_VERSION="$(date -u +%Y.%m.%d+build.%H%M%S.experimental)" \
  just package deb x86_64-linux

# Standard line (ships jura-prod and jura-dev)
just package deb x86_64-linux
```

## Distribution Channels

The APT repository serves three suites — `stable`, `snapshot` and `experimental` — each with its own component and pool.
See the APT repository section of the top-level `README.md`.

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
