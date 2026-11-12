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

Every build packages the main line (client/app `0.100.0` and above) with the networks in `NETWORKS` from
`config/channels.sh`. CI sets the channel (see `build-binary.yaml`); a local build without it carries none.

| Variable             | Values                                         | Effect                                                    |
| -------------------- | ---------------------------------------------- | --------------------------------------------------------- |
| `GNOSISVPN_CHANNEL`  | `stable`, `snapshot`, unset                    | Checked against the version                               |
| `GNOSISVPN_NETWORKS` | space-separated network names, first = default | Which `config-<network>.toml` conffiles the package ships |

`GNOSISVPN_NETWORKS` defaults to `NETWORKS` from `config/channels.sh`, and is baked into the package as
`/usr/share/gnosisvpn/networks` so the postinstall can pick a default and re-point `/etc/gnosisvpn/config.toml` after a
channel switch. `NETWORK_SUCCESSORS` from the same file is baked as `/usr/share/gnosisvpn/network-successors`, the
replaced networks the postinstall moves an install off. The maintainer scripts are rendered into `build/linux-scripts/`
with `RETIRED_CONFFILES` filled in: the conffiles of renamed or replaced networks the package no longer ships, which
upgrades remove. `scripts/check-network-retirement.sh` (a `nix flake check`) renders them without a build and checks
that `install/linux.sh` mirrors the network list and maps. The build refuses a toolkit whose `gnosis_vpn-migrate` has no
`switch-network`, since the postinstall needs it to carry identities off a replaced network.

Whether the package ships the GeoIP database (`/usr/share/gnosisvpn/geoip.mmdb`) follows the packaged client:
`GNOSISVPN_CLIENT_VERSION` at or above `COMPONENT_VERSION_BOUNDARY` ships it, and so does a build without a numeric
client version. See "GeoIP database" in the top-level README.

The build refuses a channel/version mismatch, because the installed package infers its APT suite from its own version
string: a `snapshot` build needs a `+` version, a `stable` build a plain `x.y.z`.

```bash
GNOSISVPN_CHANNEL=snapshot \
  GNOSISVPN_PACKAGE_VERSION="$(date -u +%Y.%m.%d+build.%H%M%S)" \
  just package deb x86_64-linux
```

## Distribution Channels

The APT repository serves the `stable` and `snapshot` suites, plus the retired `experimental` suite as a snapshot alias,
each with its own component and pool. See the APT repository section of the top-level `README.md`.

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
