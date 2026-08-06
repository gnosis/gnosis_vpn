#!/usr/bin/env bash
#
# Gnosis VPN headless installer (Debian / Ubuntu, no GUI).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/gnosis/gnosis_vpn/main/install/linux-headless.sh | sudo bash
#   curl -fsSL .../linux-headless.sh | sudo bash -s -- --channel=snapshot
#   curl -fsSL .../linux-headless.sh | sudo bash -s -- --network=rotsee
#
# The published gnosisvpn .deb bundles the service (gnosis_vpn-root,
# gnosis_vpn-worker, gnosis_vpn-ctl) together with the gnosis_vpn-app tray GUI,
# and 'apt install gnosisvpn' always pulls in the GUI's hard dependencies
# (libwebkit2gtk, gtk3, libayatana-appindicator3-1, ...) even though nothing
# ever starts gnosis_vpn-app automatically.
#
# This script avoids that: it fetches the .deb with 'apt-get download', which
# resolves only the named package (not its Depends), then extracts it with
# 'dpkg-deb -x' (no dependency check, no maintainer scripts) and copies over
# only the service files, skipping gnosis_vpn-app and its GUI libraries
# entirely. It then replicates the relevant parts of the package's
# postinstall by hand: system user/group, file permissions, and the systemd
# unit.
#
# Caveat: because the package is never registered with dpkg, apt will not
# know gnosisvpn is installed. Re-run this script to upgrade. Do not later run
# 'apt-get install gnosisvpn' on this host without first removing the files
# this script placed — dpkg will refuse to overwrite files it doesn't own.

set -Eeuo pipefail

REPO_URL_PRIMARY="https://download.vpn.gnosis.eth.limo/linux/apt"
KEYRING_PATH="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/gnosisvpn.sources"

CHANNEL="${GNOSISVPN_CHANNEL:-stable}"
# Empty means "leave the network alone": defaults to jura on a fresh install
# and keeps the existing choice on re-runs.
NETWORK="${GNOSISVPN_NETWORK:-}"
RESET_IDENTITY="${GNOSISVPN_RESET_IDENTITY:-false}"
ARCH=""
CANDIDATE=""
DEB_FILE=""
EXTRACT_DIR=""

# Files copied unconditionally on every (re)install/upgrade.
BINARIES=(
    usr/bin/gnosis_vpn-root
    usr/bin/gnosis_vpn-worker
    usr/bin/gnosis_vpn-ctl
)
STATIC_FILES=(
    etc/gnosisvpn/version.txt
    etc/logrotate.d/gnosisvpn
    usr/lib/systemd/system/gnosisvpn.service
    usr/share/doc/gnosisvpn/copyright
    usr/share/doc/gnosisvpn/changelog.gz
    usr/share/lintian/overrides/gnosisvpn
    etc/apparmor.d/local/wg-quick
    usr/share/bash-completion/completions/gnosis_vpn-ctl
    usr/share/fish/vendor_completions.d/gnosis_vpn-ctl.fish
    usr/share/zsh/vendor-completions/_gnosis_vpn-ctl
    usr/share/man/man1/gnosis_vpn-root.1.gz
    usr/share/man/man1/gnosis_vpn-worker.1.gz
    usr/share/man/man1/gnosis_vpn-ctl.1.gz
)
# Conffile-like: only copied when missing, so a re-run never clobbers a user's
# edits (mirrors dpkg's --force-confold behavior used by install/linux.sh).
CONFIG_FILES=(
    etc/gnosisvpn/gnosisvpn.env
    etc/gnosisvpn/config-jura.toml
    etc/gnosisvpn/config-rotsee.toml
)

log() { printf '\033[0;34m[gnosisvpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gnosisvpn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[gnosisvpn]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Install the Gnosis VPN service on a headless host, without gnosis_vpn-app
(the desktop tray GUI) or its GTK/WebKit/AppIndicator dependencies.

Usage: linux-headless.sh [--channel=stable|snapshot] [--network=jura|rotsee] [--reset-identity] [--help]

Options:
  --channel=<stable|snapshot>   APT channel to subscribe to (default: stable).
                                Also configurable via GNOSISVPN_CHANNEL env var.
  --network=<jura|rotsee>       Network to configure (default: jura on first
                                install; omitting keeps an existing choice).
                                Also configurable via GNOSISVPN_NETWORK env var.
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

Only gnosis_vpn-root, gnosis_vpn-worker, and gnosis_vpn-ctl are installed —
there is no gnosis_vpn-app tray icon or desktop entry on this host. Control
the service with gnosis_vpn-ctl.

Re-run this script to upgrade. This install is not tracked by dpkg/apt; do
not run 'apt-get install gnosisvpn' afterwards without removing the files
listed in this script first.

Environment variables:
  GNOSISVPN_CHANNEL            stable | snapshot (default: stable)
  GNOSISVPN_NETWORK            jura | rotsee (default: jura)
  GNOSISVPN_RESET_IDENTITY     true | false (default: false); same as
                               --reset-identity
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

    if [[ -n $NETWORK && $NETWORK != "jura" && $NETWORK != "rotsee" ]]; then
        err "--network must be 'jura' or 'rotsee' (got: '${NETWORK}')"
        exit 1
    fi

    if [[ $RESET_IDENTITY != "true" && $RESET_IDENTITY != "false" ]]; then
        err "GNOSISVPN_RESET_IDENTITY must be 'true' or 'false' (got: '${RESET_IDENTITY}')"
        exit 1
    fi

    # See install/linux.sh: forwarded verbatim into gnosisvpn-dynamic.env, so
    # reject anything that isn't a single-line http(s) URL before any work starts.
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]] &&
        [[ ! ${GNOSISVPN_HOPR_BLOKLI_URL} =~ ^https?://[^[:space:]]+$ ]]; then
        err "GNOSISVPN_HOPR_BLOKLI_URL must be a single-line http(s) URL (got: '${GNOSISVPN_HOPR_BLOKLI_URL}')"
        exit 1
    fi
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "This script must run as root. Try: curl -fsSL .../linux-headless.sh | sudo bash"
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
    log "Ensuring prerequisites: ca-certificates, curl, and non-GUI runtime dependencies"
    rm -f "$SOURCES_PATH"
    apt-get update
    # ca-certificates/curl: fetch the signing key. The rest are gnosisvpn's real
    # runtime deps (see linux/nfpm-template.yaml) minus everything gnosis_vpn-app
    # needs (webkit2gtk, gtk3, libayatana-appindicator3-1, libglib2.0-bin).
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl iptables logrotate wireguard \
        resolvconf || DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl iptables logrotate wireguard systemd-resolved
}

install_keyring() {
    log "Installing repository signing key to ${KEYRING_PATH}"
    install -d -m 0755 /etc/apt/keyrings
    local url="${REPO_URL_PRIMARY}/gnosisvpn-archive-keyring.gpg"
    if ! curl -fsSL "$url" -o "$KEYRING_PATH"; then
        err "Failed to download keyring from ${url}"
        exit 1
    fi
    chmod 0644 "$KEYRING_PATH"
    log "Downloaded signing key from ${url}"
}

write_sources() {
    # See install/linux.sh for why the component per channel matters.
    local component
    case "$CHANNEL" in
    stable) component="main" ;;
    snapshot) component="snapshot" ;;
    esac
    log "Writing APT source to ${SOURCES_PATH} (channel: ${CHANNEL}, component: ${component}, arch: ${ARCH})"
    cat >"$SOURCES_PATH" <<EOF
Types: deb
URIs: ${REPO_URL_PRIMARY}
Suites: ${CHANNEL}
Components: ${component}
Architectures: ${ARCH}
Signed-By: ${KEYRING_PATH}
EOF
    chmod 0644 "$SOURCES_PATH"
}

determine_candidate() {
    log "Refreshing APT cache ..."
    apt-get update
    CANDIDATE="$(LC_ALL=C apt-cache policy gnosisvpn 2>/dev/null | sed -n 's/^ *Candidate: *//p' || true)"
    if [[ -z $CANDIDATE || $CANDIDATE == "(none)" ]]; then
        err "No installable gnosisvpn package found on the '${CHANNEL}' channel for ${ARCH}."
        err "Check ${SOURCES_PATH} and the 'apt-get update' output above."
        exit 1
    fi
    log "Selected gnosisvpn ${CANDIDATE} from the '${CHANNEL}' channel"
}

# `apt-get download` resolves and fetches only the named package — unlike
# `apt-get install`, it never touches Depends — so the GUI's libraries are
# never installed.
download_package() {
    local workdir="$1"
    log "Downloading gnosisvpn=${CANDIDATE} (dependencies intentionally not installed) ..."
    (cd "$workdir" && apt-get download "gnosisvpn=${CANDIDATE}")
    DEB_FILE="$(find "$workdir" -maxdepth 1 -name 'gnosisvpn_*.deb' -print -quit)"
    if [[ -z $DEB_FILE || ! -f $DEB_FILE ]]; then
        err "apt-get download did not produce a gnosisvpn .deb file"
        exit 1
    fi
    log "Downloaded ${DEB_FILE}"
}

# dpkg-deb -x extracts the package's file tree only — no dependency check, no
# maintainer scripts — so gnosis_vpn-app and its libraries can be left out.
extract_package() {
    local workdir="$1"
    EXTRACT_DIR="${workdir}/extract"
    mkdir -p "$EXTRACT_DIR"
    dpkg-deb -x "$DEB_FILE" "$EXTRACT_DIR"
}

stop_service_if_running() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
        log "Stopping gnosisvpn.service for upgrade..."
        systemctl stop gnosisvpn.service
    fi
}

install_selected_files() {
    log "Installing service files (gnosis_vpn-app and its GUI dependencies are skipped)"
    local rel dest
    for rel in "${BINARIES[@]}" "${STATIC_FILES[@]}"; do
        dest="/$rel"
        mkdir -p "$(dirname "$dest")"
        cp -a "${EXTRACT_DIR}/${rel}" "$dest"
    done
    for rel in "${CONFIG_FILES[@]}"; do
        dest="/$rel"
        if [[ -e $dest ]]; then
            log "Keeping existing ${dest} (not overwriting local edits)"
            continue
        fi
        mkdir -p "$(dirname "$dest")"
        cp -a "${EXTRACT_DIR}/${rel}" "$dest"
    done
}

create_system_user_and_group() {
    if ! getent group gnosisvpn >/dev/null 2>&1; then
        log "Creating group 'gnosisvpn'..."
        groupadd --system gnosisvpn
    fi
    if ! getent passwd gnosisvpn >/dev/null 2>&1; then
        log "Creating system user 'gnosisvpn'..."
        useradd --system \
            --gid gnosisvpn \
            --home-dir /var/lib/gnosisvpn \
            --shell /usr/sbin/nologin \
            --comment "Gnosis VPN Service User" \
            gnosisvpn
    fi
}

# Mirrors linux/scripts/postinstall.sh's configure_filesystem_permissions,
# minus the gnosis_vpn-app chown (that binary is never installed here).
configure_filesystem_permissions() {
    local network_name blokli_url
    network_name="${NETWORK:-jura}"

    if [[ ! -f /etc/gnosisvpn/config-${network_name}.toml ]]; then
        err "Unknown network '${network_name}': /etc/gnosisvpn/config-${network_name}.toml not found"
        exit 1
    fi

    blokli_url="https://blokli.${network_name}.hoprnet.link"
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        blokli_url="$GNOSISVPN_HOPR_BLOKLI_URL"
    fi

    chown root:gnosisvpn /etc/gnosisvpn
    chmod 755 /etc/gnosisvpn
    chown gnosisvpn:gnosisvpn /etc/gnosisvpn/*.toml 2>/dev/null || true
    chmod 644 /etc/gnosisvpn/*.toml 2>/dev/null || true

    mkdir -p /var/log/gnosisvpn
    chown -R gnosisvpn:gnosisvpn /var/log/gnosisvpn
    chmod -R 755 /var/log/gnosisvpn

    mkdir -p /var/lib/gnosisvpn
    chown -R gnosisvpn:gnosisvpn /var/lib/gnosisvpn
    chmod -R 775 /var/lib/gnosisvpn

    # Only (re)link on first install or an explicit --network, so a plain
    # upgrade run does not reset a user's network choice.
    if [[ -n $NETWORK || ! -e /etc/gnosisvpn/config.toml ]]; then
        ln -sf /etc/gnosisvpn/config-"$network_name".toml /etc/gnosisvpn/config.toml
    fi

    local dynamic_env=/etc/gnosisvpn/gnosisvpn-dynamic.env
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} || -n $NETWORK || ! -f $dynamic_env ]]; then
        cat >"$dynamic_env" <<EOF
# Generated by linux-headless.sh — do not edit.
# Values here override /etc/gnosisvpn/gnosisvpn.env.
GNOSISVPN_HOPR_BLOKLI_URL=$blokli_url
EOF
    fi
    chmod 644 "$dynamic_env"
    chown root:root "$dynamic_env"

    chown gnosisvpn:gnosisvpn /usr/bin/gnosis_vpn-worker /usr/bin/gnosis_vpn-ctl
}

reload_apparmor_wg_quick() {
    if [[ ! -e /etc/apparmor.d/wg-quick ]] || ! command -v apparmor_parser >/dev/null 2>&1; then
        return 0
    fi
    if [[ -r /sys/module/apparmor/parameters/enabled ]] &&
        [[ "$(cat /sys/module/apparmor/parameters/enabled)" != "Y" ]]; then
        return 0
    fi
    log "Reloading wg-quick AppArmor profile to allow the GnosisVPN config..."
    apparmor_parser -r -T -W /etc/apparmor.d/wg-quick ||
        warn "Failed to reload wg-quick AppArmor profile"
}

# Mirrors linux/scripts/postinstall.sh's reset_identity_if_requested.
reset_identity_if_requested() {
    [[ $RESET_IDENTITY == "true" ]] || return 0

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
        log "Stopping gnosisvpn.service to reset the HOPR identity..."
        systemctl stop gnosisvpn.service || true
    fi

    local config_dir=/var/lib/gnosisvpn/.config
    if [[ -d $config_dir ]]; then
        local ts backup n
        ts="$(date +%Y%m%d%H%M%S)"
        backup="${config_dir}.${ts}.bak"
        n=1
        while [[ -e $backup ]]; do
            backup="${config_dir}.${ts}.${n}.bak"
            n=$((n + 1))
        done
        log "Backing up worker config directory: ${config_dir} -> ${backup}"
        mv "$config_dir" "$backup"
    else
        log "No worker config found at ${config_dir} — nothing to back up"
    fi
}

enable_and_start_service() {
    log "Enabling and starting gnosisvpn.service..."
    systemctl daemon-reload
    systemctl unmask gnosisvpn.service || true
    systemctl enable gnosisvpn.service
    systemctl reset-failed gnosisvpn.service 2>/dev/null || true
    systemctl start gnosisvpn.service

    sleep 2
    if systemctl is-active --quiet gnosisvpn.service; then
        log "Service started successfully"
    else
        warn "Service failed to start. Check logs with: journalctl -u gnosisvpn.service"
    fi
}

print_summary() {
    cat <<'EOF'

[gnosisvpn] Installed (headless — no gnosis_vpn-app, no GTK/WebKit deps). Quick checks:
    sudo systemctl status gnosisvpn
    gnosis_vpn-ctl --help

To upgrade later:   re-run this script (re-downloads the current channel candidate)
To switch networks: re-run with --network=<jura|rotsee>
To switch channels: re-run with --channel=<stable|snapshot>
To reset identity:  re-run with --reset-identity
To uninstall:       systemctl disable --now gnosisvpn; rm -rf /etc/gnosisvpn /var/lib/gnosisvpn /var/log/gnosisvpn /usr/bin/gnosis_vpn-{root,worker,ctl} /usr/lib/systemd/system/gnosisvpn.service

Note: this install is not tracked by dpkg. Do not run
'apt-get install gnosisvpn' on this host without first removing the files
listed above — dpkg will refuse to overwrite files it doesn't own.
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
    determine_candidate

    local workdir
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    download_package "$workdir"
    extract_package "$workdir"
    stop_service_if_running
    install_selected_files
    create_system_user_and_group
    configure_filesystem_permissions
    reload_apparmor_wg_quick
    reset_identity_if_requested
    enable_and_start_service
    print_summary
}

main "$@"
