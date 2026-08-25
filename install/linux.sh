#!/usr/bin/env bash
#
# Gnosis VPN APT repository installer (Debian / Ubuntu).
#
# Usage:
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash -s -- --channel=snapshot
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash -s -- --network=jura-dev
#
# Prompts for sudo up front when not already root. For headless/non-interactive
# use (no controlling terminal for the sudo password prompt), pipe into
# `sudo bash` instead.
#
# Configures /etc/apt/sources.list.d/gnosisvpn.sources to pull signed packages
# from the Gnosis VPN APT repository, installs the public keyring, runs
# `apt-get update`, and installs the `gnosisvpn` package.

set -Eeuo pipefail

# APT repository mirrors. Both serve identical key-signed stable content;
# only gnosisvpn.io also serves the snapshot suite.
REPO_URL_PRIMARY="https://download.vpn.gnosis.eth.limo/linux/apt"
REPO_URL_BACKUP="https://download.gnosisvpn.io/linux/apt"
KEYRING_PATH="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/gnosisvpn.sources"

CHANNEL="${GNOSISVPN_CHANNEL:-stable}"
# Empty = leave the network alone (postinstall defaults to jura-prod on fresh install, keeps existing choice on re-runs).
NETWORK="${GNOSISVPN_NETWORK:-}"
RESET_IDENTITY="${GNOSISVPN_RESET_IDENTITY:-false}"
ARCH=""

log() { printf '\033[0;34m[gnosisvpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gnosisvpn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[gnosisvpn]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Install the Gnosis VPN APT repository and the gnosisvpn package.

Usage: linux.sh [--channel=stable|snapshot] [--network=jura-prod|jura-dev|piz-palu-dev] [--reset-identity] [--help]

Options:
  --channel=<stable|snapshot>   APT channel to subscribe to (default: stable).
                                Also configurable via GNOSISVPN_CHANNEL env var.
  --network=<jura-prod|jura-dev|piz-palu-dev>
                                Network to configure (default: jura-prod on
                                first install; omitting keeps an existing
                                choice). Also configurable via GNOSISVPN_NETWORK
                                env var.
  --reset-identity              Back up the worker config dir (/var/lib/gnosisvpn/
                                .config: HOPR identity, safe, node db) to
                                .config.<timestamp>.bak, so the service generates
                                a fresh identity on next start. The network
                                selection and Blokli endpoint are kept.
                                Also configurable via GNOSISVPN_RESET_IDENTITY.
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
  GNOSISVPN_NETWORK            jura-prod | jura-dev | piz-palu-dev (default: jura-prod)
  GNOSISVPN_RESET_IDENTITY     true | false (default: false); same as
                               --reset-identity
  GNOSISVPN_HOPR_BLOKLI_URL    Custom Blokli endpoint; defaults to the one
                               matching the chosen network
                               (https://blokli-<prefix>.<env>.hoprnet.link
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
                err "--network requires a value (jura-prod | jura-dev | piz-palu-dev)"
                exit 1
            fi
            NETWORK="$2"
            shift 2
            ;;
        --reset-identity)
            RESET_IDENTITY="true"
            shift
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

    # TODO: remove by December 2027. Accept pre-rename network names.
    local old_network="$NETWORK"
    case "$NETWORK" in
    jura) NETWORK="jura-prod" ;;
    rotsee) NETWORK="jura-dev" ;;
    piz-palu-staging) NETWORK="piz-palu-dev" ;;
    esac
    [[ $NETWORK == "$old_network" ]] || log "Network '${old_network}' was renamed to '${NETWORK}' — using '${NETWORK}'"

    if [[ -n $NETWORK && $NETWORK != "jura-prod" && $NETWORK != "jura-dev" &&
        $NETWORK != "piz-palu-dev" ]]; then
        err "--network must be one of 'jura-prod', 'jura-dev', 'piz-palu-dev' (got: '${NETWORK}')"
        exit 1
    fi

    if [[ $RESET_IDENTITY != "true" && $RESET_IDENTITY != "false" ]]; then
        err "GNOSISVPN_RESET_IDENTITY must be 'true' or 'false' (got: '${RESET_IDENTITY}')"
        exit 1
    fi

    # Reject non-http(s) URLs early; postinstall writes the value verbatim into the root EnvironmentFile.
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]] &&
        [[ ! ${GNOSISVPN_HOPR_BLOKLI_URL} =~ ^https?://[^[:space:]]+$ ]]; then
        err "GNOSISVPN_HOPR_BLOKLI_URL must be a single-line http(s) URL (got: '${GNOSISVPN_HOPR_BLOKLI_URL}')"
        exit 1
    fi
}

ensure_sudo() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        SUDO=""
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        err "sudo not found. Re-run as root, or install sudo first."
        exit 1
    fi

    log "GnosisVPN needs sudo to add its APT repository, install the gnosisvpn package, and manage its systemd service."
    if ! sudo -v; then
        err "Could not obtain sudo access. If this is a non-interactive/headless environment (no terminal for the sudo password prompt), re-run with: curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash"
        exit 1
    fi
    SUDO="sudo"

    # Keep the sudo timestamp alive so a hardened box with a short timestamp_timeout
    # doesn't force a second prompt mid-install on a slow mirror.
    while true; do
        sudo -n true || true
        sleep 60
    done 2>/dev/null &
    KEEPALIVE_PID=$!
    trap 'kill "$KEEPALIVE_PID" 2>/dev/null' EXIT
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
    # Drop a stale source before the first apt-get update so a broken prior config doesn't abort the run.
    ${SUDO} rm -f "$SOURCES_PATH"
    ${SUDO} apt-get update
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
}

install_keyring() {
    log "Installing repository signing key to ${KEYRING_PATH}"
    ${SUDO} install -d -m 0755 /etc/apt/keyrings
    local tmp url
    tmp="$(mktemp)"
    for url in "${REPO_URL_PRIMARY}/gnosisvpn-archive-keyring.gpg" \
        "${REPO_URL_BACKUP}/gnosisvpn-archive-keyring.gpg"; do
        if curl -fsSL "$url" -o "$tmp"; then
            log "Downloaded signing key from ${url}"
            ${SUDO} install -m 0644 "$tmp" "$KEYRING_PATH"
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
    # Mirrors register_apt_repo in the deb postinstall (can't delegate to it — this runs before the package is installed).
    # Component must match linux/apt/conf/distributions; only mirrors that publish the suite are listed (unlisted suite → apt-get update fails).
    local component uris
    case "$CHANNEL" in
    stable)
        component="main"
        uris="${REPO_URL_PRIMARY} ${REPO_URL_BACKUP}"
        ;;
    snapshot)
        component="snapshot"
        # Only gnosisvpn.io publishes the snapshot suite.
        uris="${REPO_URL_BACKUP}"
        ;;
    esac
    log "Writing APT source to ${SOURCES_PATH} (channel: ${CHANNEL}, component: ${component}, arch: ${ARCH})"
    cat <<EOF | ${SUDO} tee "$SOURCES_PATH" >/dev/null
Types: deb
URIs: ${uris}
Suites: ${CHANNEL}
Components: ${component}
Architectures: ${ARCH}
Signed-By: ${KEYRING_PATH}
EOF
    ${SUDO} chmod 0644 "$SOURCES_PATH"
}

apt_install() {
    log "Refreshing APT cache ..."
    ${SUDO} apt-get update

    # Query against an empty dpkg status file so apt reports the true channel candidate, not the installed version (which would hide downgrades).
    local candidate installed
    candidate="$(LC_ALL=C apt-cache -o Dir::State::status=/dev/null policy gnosisvpn 2>/dev/null |
        sed -n 's/^ *Candidate: *//p' || true)"
    if [[ -z $candidate || $candidate == "(none)" ]]; then
        err "No installable gnosisvpn package found on the '${CHANNEL}' channel for ${ARCH}."
        err "Check ${SOURCES_PATH} and the 'apt-get update' output above."
        exit 1
    fi

    # Config-files-only remnants of a removed package count as not installed.
    installed="$(dpkg-query -W -f='${db:Status-Status} ${Version}' gnosisvpn 2>/dev/null || true)"
    case "$installed" in
    "installed "*) installed="${installed#installed }" ;;
    *) installed="" ;;
    esac

    # --force-confdef/confold: answer dpkg conffile prompts non-interactively (stdin absent in curl|bash).
    # --allow-downgrades: required for snapshot→stable channel switch; harmless otherwise.
    local apt_opts=(-y --allow-downgrades -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    local package="gnosisvpn"
    if [[ -n $installed ]] && dpkg --compare-versions "$installed" gt "$candidate"; then
        # Channel downgrade: pin the candidate so apt doesn't skip it.
        log "Installed gnosisvpn ${installed} is newer than the '${CHANNEL}' channel candidate ${candidate}; downgrading to match the channel."
        package="gnosisvpn=${candidate}"
    elif [[ -n $NETWORK || -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} || $RESET_IDENTITY == "true" ]]; then
        # --reinstall forces postinstall to run (apply network/URL/identity override) when version is unchanged.
        apt_opts+=(--reinstall)
    fi

    log "Installing ${package} ..."
    # Forward env vars to postinstall; without them it keeps the existing network/URL (defaulting to jura-prod on fresh install).
    local install_env=(DEBIAN_FRONTEND=noninteractive)
    if [[ -n $NETWORK ]]; then
        # Derive the endpoint for older postinstalls that don't compute it themselves.
        local network_prefix="${NETWORK%-*}"
        local network_env="${NETWORK##*-}"
        local blokli_url="${GNOSISVPN_HOPR_BLOKLI_URL:-https://blokli-${network_prefix}.${network_env}.hoprnet.link}"
        log "Selecting network: ${NETWORK} (Blokli endpoint: ${blokli_url})"
        install_env+=(GNOSISVPN_NETWORK="$NETWORK" GNOSISVPN_HOPR_BLOKLI_URL="$blokli_url")
    elif [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        log "Using Blokli endpoint: ${GNOSISVPN_HOPR_BLOKLI_URL}"
        install_env+=(GNOSISVPN_HOPR_BLOKLI_URL="$GNOSISVPN_HOPR_BLOKLI_URL")
    fi
    # Delegate identity reset to postinstall (reset_identity_if_requested) so it runs before the service starts.
    if [[ $RESET_IDENTITY == "true" ]]; then
        log "Reset identity requested — the package postinstall will back up the current identity and generate a fresh one."
        install_env+=(GNOSISVPN_RESET_IDENTITY=true)
    fi
    ${SUDO} env "${install_env[@]}" apt-get install "${apt_opts[@]}" "$package"
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
To switch networks:  re-run this installer with --network=<jura-prod|jura-dev|piz-palu-dev>
To switch channels:  re-run this installer with --channel=<stable|snapshot>
To reset identity:   re-run this installer with --reset-identity
To uninstall:        sudo apt-get remove gnosisvpn
EOF
}

main() {
    parse_args "$@"
    ensure_sudo
    detect_arch
    detect_distro
    ensure_prereqs
    install_keyring
    write_sources
    apt_install
    print_postinstall
}

main "$@"
