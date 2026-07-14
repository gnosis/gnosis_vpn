#!/usr/bin/env bash
#
# Gnosis VPN APT repository installer (Debian / Ubuntu).
#
# Usage:
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --channel=snapshot
#
# Configures /etc/apt/sources.list.d/gnosisvpn.sources to pull signed packages
# from the Gnosis VPN APT repository, installs the public keyring, runs
# `apt-get update`, and installs the `gnosisvpn` package.

set -Eeuo pipefail

# APT repository mirrors, tried in order.
# Both serve identical stable content, gnosisvpn.io also snapshots.
REPO_URL_PRIMARY="https://downloads.vpn.gnosis.eth.limo/linux/apt"
REPO_URL_BACKUP="https://download.gnosisvpn.io/linux/apt"
KEYRING_PATH="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/gnosisvpn.sources"

CHANNEL="${GNOSISVPN_CHANNEL:-stable}"
ARCH=""

log() { printf '\033[0;34m[gnosisvpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gnosisvpn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[gnosisvpn]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Install the Gnosis VPN APT repository and the gnosisvpn package.

Usage: linux.sh [--channel=stable|snapshot] [--help]

Options:
  --channel=<stable|snapshot>   APT channel to subscribe to (default: stable).
                                Also configurable via GNOSISVPN_CHANNEL env var.
  -h, --help                    Show this help and exit.

Supported distributions:
  Debian 11, 12, 13, 14
  Ubuntu 22.04, 24.04, 26.04 LTS

After install, the gnosisvpn service should be running. To pick a non-default
network, re-run the package's postinstall with BOTH env vars set explicitly —
the Blokli URL default is hardcoded to the jura endpoint, so it must be paired
with a matching network override (a piped \$(curl | sudo bash) cannot forward
them):
  sudo GNOSISVPN_NETWORK=rotsee \\
       GNOSISVPN_HOPR_BLOKLI_URL=https://… \\
       apt-get install --reinstall \\
       -o Dpkg::Options::="--force-confdef" \\
       -o Dpkg::Options::="--force-confold" \\
       gnosisvpn

Accepted values:
  GNOSISVPN_NETWORK            jura | rotsee (default: jura)
  GNOSISVPN_HOPR_BLOKLI_URL    Blokli endpoint matching the chosen network
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --channel=*)
            CHANNEL="${1#*=}"
            shift
            ;;
        --channel)
            if [[ -z ${2:-} ]]; then
                err "--channel requires a value (stable | snapshot)"
                exit 1
            fi
            CHANNEL="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            usage >&2
            exit 1
            ;;
        esac
    done

    if [[ $CHANNEL != "stable" && $CHANNEL != "snapshot" ]]; then
        err "--channel must be 'stable' or 'snapshot' (got: '${CHANNEL}')"
        exit 1
    fi
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "This script must run as root. Try: curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash"
        exit 1
    fi
}

detect_arch() {
    if ! command -v dpkg >/dev/null 2>&1; then
        err "dpkg not found — this installer only supports Debian and Ubuntu."
        exit 1
    fi
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
    amd64 | arm64) ;;
    *)
        err "Unsupported architecture: ${ARCH}. Only amd64 and arm64 are published."
        exit 1
        ;;
    esac
    log "Detected architecture: ${ARCH}"
}

detect_distro() {
    if [[ ! -r /etc/os-release ]]; then
        warn "/etc/os-release not found — skipping distribution check."
        return
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    local id="${ID:-unknown}"
    local ver="${VERSION_ID:-unknown}"

    local supported=0
    case "${id}:${ver}" in
    debian:11 | debian:12 | debian:13 | debian:14) supported=1 ;;
    ubuntu:22.04 | ubuntu:24.04 | ubuntu:26.04) supported=1 ;;
    esac

    if [[ $supported -eq 1 ]]; then
        log "Detected distribution: ${id} ${ver} (supported)"
    else
        warn "Detected distribution: ${id} ${ver} (not in the officially supported list; continuing)"
    fi
}

ensure_prereqs() {
    log "Ensuring prerequisites: ca-certificates, curl"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
}

install_keyring() {
    log "Installing repository signing key to ${KEYRING_PATH}"
    install -d -m 0755 /etc/apt/keyrings
    local tmp url
    tmp="$(mktemp)"
    for url in "${REPO_URL_PRIMARY}/gnosisvpn-archive-keyring.gpg" \
        "${REPO_URL_BACKUP}/gnosisvpn-archive-keyring.gpg"; do
        if curl -fsSL "$url" -o "$tmp"; then
            log "Downloaded signing key from ${url}"
            install -m 0644 "$tmp" "$KEYRING_PATH"
            rm -f "$tmp"
            return
        fi
        warn "Failed to download keyring from ${url}; trying next source"
    done
    err "Failed to download keyring from all sources"
    rm -f "$tmp"
    exit 1
}

write_sources() {
    # Component name must match the Components: field in linux/apt/conf/distributions
    # for the channel being subscribed to (stable→main, snapshot→snapshot). Reprepro
    # derives the on-bucket pool path from that field, and apt fetches Packages from
    # dists/<suite>/<component>/binary-<arch>/.
    local component
    case "$CHANNEL" in
    stable) component="main" ;;
    snapshot) component="snapshot" ;;
    esac
    log "Writing APT source to ${SOURCES_PATH} (channel: ${CHANNEL}, component: ${component}, arch: ${ARCH})"
    # Two space-separated URIs: apt prefers the first and falls back to the second
    # when it is unavailable. Both mirrors serve the same key-signed content.
    cat >"$SOURCES_PATH" <<EOF
Types: deb
URIs: ${REPO_URL_PRIMARY} ${REPO_URL_BACKUP}
Suites: ${CHANNEL}
Components: ${component}
Architectures: ${ARCH}
Signed-By: ${KEYRING_PATH}
EOF
    chmod 0644 "$SOURCES_PATH"
}

apt_install() {
    log "Refreshing APT cache and installing gnosisvpn ..."
    apt-get update
    # DEBIAN_FRONTEND silences debconf but not dpkg conffile prompts, which abort
    # under `curl | sudo bash` (no stdin). --force-confdef/--force-confold answer
    # them non-interactively (keep the existing file unless dpkg has a safe default).
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        gnosisvpn
}

print_postinstall() {
    cat <<'EOF'

[gnosisvpn] Installed. Quick checks:
    sudo systemctl status gnosisvpn
    gnosis_vpn-ctl --help

[gnosisvpn] Signing key installed at /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
    To verify:            gpg --show-keys /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
    Details:  https://github.com/hoprnet/gnosis_vpn/blob/main/SECURITY.md

To upgrade later:   sudo apt-get update && sudo apt-get install --only-upgrade gnosisvpn
To uninstall:       sudo apt-get remove gnosisvpn
EOF
}

main() {
    parse_args "$@"
    require_root
    detect_arch
    detect_distro
    ensure_prereqs
    install_keyring
    write_sources
    apt_install
    print_postinstall
}

main "$@"
