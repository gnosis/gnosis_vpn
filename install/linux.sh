#!/usr/bin/env bash
#
# Gnosis VPN APT repository installer (Debian / Ubuntu).
#
# Usage:
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --channel=snapshot
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --network=rotsee
#
# Configures /etc/apt/sources.list.d/gnosisvpn.sources to pull signed packages
# from the Gnosis VPN APT repository, installs the public keyring, runs
# `apt-get update`, and installs the `gnosisvpn` package.

set -Eeuo pipefail

# APT repository mirrors. Both serve identical key-signed stable content;
# only gnosisvpn.io also serves the snapshot suite.
REPO_URL_PRIMARY="https://downloads.vpn.gnosis.eth.limo/linux/apt"
REPO_URL_BACKUP="https://download.gnosisvpn.io/linux/apt"
KEYRING_PATH="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/gnosisvpn.sources"

CHANNEL="${GNOSISVPN_CHANNEL:-stable}"
# Empty means "leave the network alone": postinstall defaults to jura on a
# fresh install and keeps the existing choice on re-runs.
NETWORK="${GNOSISVPN_NETWORK:-}"
ARCH=""

log() { printf '\033[0;34m[gnosisvpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gnosisvpn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[gnosisvpn]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Install the Gnosis VPN APT repository and the gnosisvpn package.

Usage: linux.sh [--channel=stable|snapshot] [--network=jura|rotsee] [--help]

Options:
  --channel=<stable|snapshot>   APT channel to subscribe to (default: stable).
                                Also configurable via GNOSISVPN_CHANNEL env var.
  --network=<jura|rotsee>       Network to configure (default: jura on first
                                install; omitting keeps an existing choice).
                                Also configurable via GNOSISVPN_NETWORK env var.
  -h, --help                    Show this help and exit.

Supported distributions:
  Debian 11, 12, 13, 14
  Ubuntu 22.04, 24.04, 26.04 LTS

After install, the gnosisvpn service should be running. To switch networks
later, re-run this installer with --network=<name>; to switch channels, re-run
with --channel=<stable|snapshot> (switching back to stable downgrades the
package to the newest stable release).

Caution: a re-run without --channel selects the default (stable). On a
snapshot installation, pass --channel=snapshot again when re-running (e.g. to
switch networks), or the installer will downgrade the package to stable.

Environment variables:
  GNOSISVPN_CHANNEL            stable | snapshot (default: stable)
  GNOSISVPN_NETWORK            jura | rotsee (default: jura)
  GNOSISVPN_HOPR_BLOKLI_URL    Custom Blokli endpoint; defaults to the one
                               matching the chosen network
                               (https://blokli.<network>.hoprnet.link)
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
        --network=*)
            NETWORK="${1#*=}"
            shift
            ;;
        --network)
            if [[ -z ${2:-} ]]; then
                err "--network requires a value (jura | rotsee)"
                exit 1
            fi
            NETWORK="$2"
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

    if [[ -n $NETWORK && $NETWORK != "jura" && $NETWORK != "rotsee" ]]; then
        err "--network must be 'jura' or 'rotsee' (got: '${NETWORK}')"
        exit 1
    fi

    # Forwarded verbatim to the package postinstall, which writes it into
    # gnosisvpn-dynamic.env (loaded by the root service). Reject anything that
    # isn't a single-line http(s) URL so a stray newline/space cannot inject
    # extra environment entries; fail here for a clear message before any apt work.
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]] &&
        [[ ! ${GNOSISVPN_HOPR_BLOKLI_URL} =~ ^https?://[^[:space:]]+$ ]]; then
        err "GNOSISVPN_HOPR_BLOKLI_URL must be a single-line http(s) URL (got: '${GNOSISVPN_HOPR_BLOKLI_URL}')"
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
    #
    # Multiple space-separated URIs are separate sources, not fallbacks: apt must
    # resolve the Release file of every listed source or `apt-get update` fails
    # hard. So each channel lists only the mirrors that publish its suite.
    local component uris
    case "$CHANNEL" in
    stable)
        component="main"
        # Both mirrors publish the stable suite; listing both gives apt a
        # second source to download identical signed packages from.
        uris="${REPO_URL_PRIMARY} ${REPO_URL_BACKUP}"
        ;;
    snapshot)
        component="snapshot"
        # Only the gnosisvpn.io mirror publishes the snapshot suite; the IPFS
        # mirror has no dists/snapshot/ and would break every apt-get update.
        uris="${REPO_URL_BACKUP}"
        ;;
    esac
    log "Writing APT source to ${SOURCES_PATH} (channel: ${CHANNEL}, component: ${component}, arch: ${ARCH})"
    cat >"$SOURCES_PATH" <<EOF
Types: deb
URIs: ${uris}
Suites: ${CHANNEL}
Components: ${component}
Architectures: ${ARCH}
Signed-By: ${KEYRING_PATH}
EOF
    chmod 0644 "$SOURCES_PATH"
}

apt_install() {
    log "Refreshing APT cache ..."
    apt-get update

    # Channel candidate, queried against an empty dpkg status file: apt never
    # reports a candidate below the installed version (downgrades need pins
    # > 1000), which would mask the stable candidate after a snapshot→stable
    # switch. LC_ALL=C keeps the "Candidate:" label unlocalized.
    local candidate installed
    candidate="$(LC_ALL=C apt-cache -o Dir::State::status=/dev/null policy gnosisvpn 2>/dev/null |
        sed -n 's/^ *Candidate: *//p' || true)"
    if [[ -z $candidate || $candidate == "(none)" ]]; then
        err "No installable gnosisvpn package found on the '${CHANNEL}' channel for ${ARCH}."
        err "Check ${SOURCES_PATH} and the 'apt-get update' output above."
        exit 1
    fi

    # Installed version; empty when not installed (config-files-only remnants
    # of a removed package count as not installed).
    installed="$(dpkg-query -W -f='${db:Status-Status} ${Version}' gnosisvpn 2>/dev/null || true)"
    case "$installed" in
    "installed "*) installed="${installed#installed }" ;;
    *) installed="" ;;
    esac

    # DEBIAN_FRONTEND silences debconf but not dpkg conffile prompts, which abort
    # under `curl | sudo bash` (no stdin). --force-confdef/--force-confold answer
    # them non-interactively (keep the existing file unless dpkg has a safe
    # default); conffile prompts are most likely during channel downgrades.
    # --allow-downgrades: apt refuses -y downgrades without it, which would
    # abort a snapshot→stable channel switch; harmless otherwise since apt
    # only downgrades when pointed at a lower version explicitly.
    local apt_opts=(-y --allow-downgrades -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    local package="gnosisvpn"
    if [[ -n $installed ]] && dpkg --compare-versions "$installed" gt "$candidate"; then
        # Channel switch (e.g. snapshot→stable): apt never downgrades on its
        # own, so pin the channel candidate.
        log "Installed gnosisvpn ${installed} is newer than the '${CHANNEL}' channel candidate ${candidate}; downgrading to match the channel."
        package="gnosisvpn=${candidate}"
    elif [[ -n $NETWORK || -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        # --reinstall forces the postinstall to run (to apply the network and/or
        # Blokli URL override) even when the package is already at the candidate
        # version. Not needed on the downgrade path: the version change runs it
        # anyway.
        apt_opts+=(--reinstall)
    fi

    log "Installing ${package} ..."
    # Forward explicit overrides to the package's postinstall through these env
    # vars; without them the postinstall keeps an existing network and Blokli
    # endpoint (defaulting to jura on a fresh install). A network choice fills
    # in a matching Blokli endpoint default: recent postinstalls derive that
    # themselves, but keep forwarding the derived URL for already-published
    # debs whose postinstall defaults to jura; an explicit
    # GNOSISVPN_HOPR_BLOKLI_URL is honored on its own, with or without a network.
    local install_env=(DEBIAN_FRONTEND=noninteractive)
    if [[ -n $NETWORK ]]; then
        local blokli_url="${GNOSISVPN_HOPR_BLOKLI_URL:-https://blokli.${NETWORK}.hoprnet.link}"
        log "Selecting network: ${NETWORK} (Blokli endpoint: ${blokli_url})"
        install_env+=(GNOSISVPN_NETWORK="$NETWORK" GNOSISVPN_HOPR_BLOKLI_URL="$blokli_url")
    elif [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        log "Using Blokli endpoint: ${GNOSISVPN_HOPR_BLOKLI_URL}"
        install_env+=(GNOSISVPN_HOPR_BLOKLI_URL="$GNOSISVPN_HOPR_BLOKLI_URL")
    fi
    env "${install_env[@]}" apt-get install "${apt_opts[@]}" "$package"
}

print_postinstall() {
    cat <<'EOF'

[gnosisvpn] Installed. Quick checks:
    sudo systemctl status gnosisvpn
    gnosis_vpn-ctl --help

[gnosisvpn] Signing key installed at /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
    To verify:            gpg --show-keys /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg
    Details:  https://github.com/hoprnet/gnosis_vpn/blob/main/SECURITY.md

To upgrade later:    sudo apt-get update && sudo apt-get install --only-upgrade gnosisvpn
To switch networks:  re-run this installer with --network=<jura|rotsee>
To switch channels:  re-run this installer with --channel=<stable|snapshot>
To uninstall:        sudo apt-get remove gnosisvpn
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
