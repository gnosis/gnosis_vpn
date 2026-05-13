#!/usr/bin/env bash
#
# Gnosis VPN APT repository installer (Debian / Ubuntu).
#
# Usage:
#   curl -fsSL https://download.gnosisvpn.io/install/linux.sh | sudo bash
#   curl -fsSL https://download.gnosisvpn.io/install/linux.sh | sudo bash -s -- --channel=snapshot
#
# Configures /etc/apt/sources.list.d/gnosisvpn.sources to pull signed packages
# from https://download.gnosisvpn.io/apt, installs the public keyring, runs
# `apt-get update`, and installs the `gnosisvpn` package.

set -Eeuo pipefail

REPO_URL="https://download.gnosisvpn.io/apt"
KEYRING_URL="${REPO_URL}/gnosisvpn-archive-keyring.gpg"
KEYRING_PATH="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/gnosisvpn.sources"

CHANNEL="${GNOSISVPN_CHANNEL:-stable}"

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

After install, the gnosisvpn service should be running. Optional env vars
read by the package's postinstall (see https://github.com/gnosis/gnosis_vpn):
  GNOSISVPN_NETWORK            jura | rotsee | dufour (default: jura)
  GNOSISVPN_HOPR_BLOKLI_URL    Override the HOPR Blokli URL
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
            CHANNEL="${2:-}"
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
        err "This script must run as root. Try: curl -fsSL https://download.gnosisvpn.io/install/linux.sh | sudo bash"
        exit 1
    fi
}

detect_arch() {
    if ! command -v dpkg >/dev/null 2>&1; then
        err "dpkg not found — this installer only supports Debian and Ubuntu."
        exit 1
    fi
    local arch
    arch="$(dpkg --print-architecture)"
    case "$arch" in
    amd64 | arm64) ;;
    *)
        err "Unsupported architecture: ${arch}. Only amd64 and arm64 are published."
        exit 1
        ;;
    esac
    log "Detected architecture: ${arch}"
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
    local missing=()
    for cmd in curl gpg; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing prerequisites: ${missing[*]}"
        apt-get update -y
        local pkgs=()
        for cmd in "${missing[@]}"; do
            case "$cmd" in
            curl) pkgs+=(curl) ;;
            gpg) pkgs+=(gnupg) ;;
            esac
        done
        pkgs+=(ca-certificates)
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    fi
}

install_keyring() {
    log "Installing repository signing key to ${KEYRING_PATH}"
    install -d -m 0755 /etc/apt/keyrings
    local tmp
    tmp="$(mktemp)"
    if ! curl -fsSL "$KEYRING_URL" -o "$tmp"; then
        err "Failed to download keyring from ${KEYRING_URL}"
        rm -f "$tmp"
        exit 1
    fi
    install -m 0644 "$tmp" "$KEYRING_PATH"
    rm -f "$tmp"
}

write_sources() {
    log "Writing APT source to ${SOURCES_PATH} (channel: ${CHANNEL})"
    cat >"$SOURCES_PATH" <<EOF
Types: deb
URIs: ${REPO_URL}
Suites: ${CHANNEL}
Components: main
Architectures: amd64 arm64
Signed-By: ${KEYRING_PATH}
EOF
    chmod 0644 "$SOURCES_PATH"
}

apt_install() {
    log "Refreshing APT cache and installing gnosisvpn ..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y gnosisvpn
}

print_postinstall() {
    cat <<'EOF'

[gnosisvpn] Installed. Quick checks:
    sudo systemctl status gnosisvpn
    gnosis_vpn-ctl --help

Optional environment variables (see README):
    GNOSISVPN_NETWORK             jura | rotsee | dufour  (default: jura)
    GNOSISVPN_HOPR_BLOKLI_URL     Override HOPR Blokli URL

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
