#!/usr/bin/env bash
#
# Gnosis VPN package repository installer (Debian / Ubuntu via APT, Fedora / EL10 via dnf).
#
# Usage:
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash -s -- --channel=snapshot
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash -s -- --channel=experimental
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash -s -- --network=jura-dev
#   curl -fsSL https://download.gnosisvpn.io/linux/install.sh | bash -s -- --enable-epel=y --enable-resolved=y
#
# Stable and snapshot ship the jura networks, experimental ships the piz-palu networks; a network is only selectable on the channel that ships it.
#
# Prompts for sudo when not already root; use `sudo bash` instead for headless/non-interactive installs (no TTY for the password prompt).
#
# On Debian / Ubuntu: configures /etc/apt/sources.list.d/gnosisvpn.sources to pull signed packages
# from the Gnosis VPN APT repository, installs the public keyring, runs
# `apt-get update`, and installs the `gnosisvpn` package.
#
# On Fedora / EL10: configures /etc/yum.repos.d/gnosisvpn.repo, imports the signing key, enables EPEL and
# systemd-resolved on EL10 when confirmed, and installs the `gnosisvpn` package with dnf.

# APT repository mirrors. Both serve identical key-signed stable content;
# only gnosisvpn.io also serves the snapshot and experimental suites.
REPO_URL_PRIMARY="https://download.vpn.gnosis.eth.limo/linux/apt"
REPO_URL_BACKUP="https://download.gnosisvpn.io/linux/apt"
KEYRING_PATH="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/gnosisvpn.sources"

# dnf repository base URLs. GCS comes first: dnf treats baseurl as ordered mirrors, and the IPFS copy lags behind
# a release until its ENS update lands. Only gnosisvpn.io serves the snapshot and experimental repositories.
RPM_REPO_URL_PRIMARY="https://download.gnosisvpn.io/linux/rpm"
RPM_REPO_URL_IPFS="https://download.vpn.gnosis.eth.limo/linux/rpm"
RPM_REPO_PATH="/etc/yum.repos.d/gnosisvpn.repo"
RPM_KEY_PATH="/etc/pki/rpm-gpg/RPM-GPG-KEY-gnosisvpn"

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

CHANNEL="${GNOSISVPN_CHANNEL:-stable}"
# Empty = leave the network alone (postinstall defaults to jura-prod on fresh install, keeps existing choice on re-runs).
NETWORK="${GNOSISVPN_NETWORK:-}"
RESET_IDENTITY="${GNOSISVPN_RESET_IDENTITY:-false}"
# Empty = ask on the terminal (EL10 only).
ENABLE_EPEL="${GNOSISVPN_ENABLE_EPEL:-}"
ENABLE_RESOLVED="${GNOSISVPN_ENABLE_RESOLVED:-}"
ARCH=""
# apt | dnf, set by main.
FAMILY=""
# Environment forwarded to the package scripts, filled by build_install_env.
INSTALL_ENV=()

log() { printf '\033[0;34m[gnosisvpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gnosisvpn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[gnosisvpn]\033[0m %s\n' "$*" >&2; }

# Networks per channel (first = default); mirrors NETWORKS_* in config/channels.sh, keep in sync.
channel_networks() {
    case "$1" in
    experimental) echo "piz-palu-dev piz-palu-staging piz-palu-prod" ;;
    *) echo "jura-prod jura-staging jura-dev" ;;
    esac
}

# TODO: remove by December 2027. Map pre-rename network names.
canonical_network() {
    case "$1" in
    jura) echo "jura-prod" ;;
    rotsee) echo "jura-dev" ;;
    *) echo "$1" ;;
    esac
}

in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

# Networks the selected channel ships; filled in by parse_args.
CHANNEL_NETWORKS=()

usage() {
    cat <<EOF
Install the Gnosis VPN package repository (APT or dnf) and the gnosisvpn package.

Usage: linux.sh [--channel=stable|snapshot|experimental] [--network=<name>] [--reset-identity]
                [--enable-epel=y|n] [--enable-resolved=y|n] [--help]

Options:
  --channel=<stable|snapshot|experimental>
                                Channel to subscribe to (default: stable).
                                Also configurable via GNOSISVPN_CHANNEL env var.
  --network=<name>              Network to configure. Which networks are
                                available depends on the channel:
                                  stable, snapshot  jura-prod (default), jura-staging,
                                                    jura-dev
                                  experimental      piz-palu-dev (default),
                                                    piz-palu-staging, piz-palu-prod
                                Omitting this keeps an existing choice that the
                                channel ships, otherwise the channel default is
                                used. Also configurable via GNOSISVPN_NETWORK
                                env var.
  --reset-identity              Move the legacy single-user identity dir
                                (/var/lib/gnosisvpn/.config: HOPR identity, safe,
                                node db) aside to .config.<timestamp>.bak. Only
                                the legacy layout: it does nothing to migrated,
                                per-user identities. To reset one of those, stop
                                the client and move
                                ~/.local/share/gnosisvpn/networks/<network>/
                                aside as that user. The network selection and
                                Blokli endpoint are kept.
                                Also configurable via GNOSISVPN_RESET_IDENTITY.
  --enable-epel=<y|n>           EL10 only: answer the prompt to enable EPEL and
                                CRB, which provide webkit2gtk4.1 and the tray
                                library. Required on EL10; without a terminal
                                the installer stops unless this is set.
                                Also configurable via GNOSISVPN_ENABLE_EPEL.
  --enable-resolved=<y|n>       EL10 only: answer the prompt to enable
                                systemd-resolved, which the service needs to
                                send DNS through the tunnel. Without it DNS
                                bypasses the VPN. Without a terminal the step is
                                skipped unless this is set.
                                Also configurable via GNOSISVPN_ENABLE_RESOLVED.
  -h, --help                    Show this help and exit.

Supported distributions:
  Debian 11, 12, 13, 14
  Ubuntu 22.04, 24.04, 26.04 LTS
  Fedora 43, 44
  RHEL, AlmaLinux, Rocky Linux, CentOS Stream, Oracle Linux 10
  (EL9 is not supported: it has no webkit2gtk4.1.)

After install, the gnosisvpn service should be running. To switch networks
later, re-run this installer with --network=<name>; to switch channels, re-run
with --channel=<stable|snapshot|experimental> (switching to a channel whose
newest package is older than the installed one performs a pinned downgrade).

Switching channels also switches installer lines, so the configured network may
change: when the current network is not shipped by the target channel, the
channel default is selected instead.

Caution: a re-run without --channel selects the default (stable). On a snapshot
or experimental installation, pass that channel again when re-running (e.g. to
switch networks), or the installer will move the package to stable.

Environment variables:
  GNOSISVPN_CHANNEL            stable | snapshot | experimental (default: stable)
  GNOSISVPN_NETWORK            a network shipped by the selected channel
                               (default: that channel's first network)
  GNOSISVPN_RESET_IDENTITY     true | false (default: false); same as
                               --reset-identity
  GNOSISVPN_HOPR_BLOKLI_URL    Custom Blokli endpoint; defaults to the one
                               matching the chosen network
  GNOSISVPN_ENABLE_EPEL        y | n; same as --enable-epel
  GNOSISVPN_ENABLE_RESOLVED    y | n; same as --enable-resolved
EOF
}

# Normalizes a yes/no answer to y or n; prints nothing for anything else.
normalize_yes_no() {
    case "${1,,}" in
    y | yes) echo "y" ;;
    n | no) echo "n" ;;
    esac
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
                err "--channel requires a value (stable | snapshot | experimental)"
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
                err "--network requires a value (see --help for the networks each channel ships)"
                exit 1
            fi
            NETWORK="$2"
            shift 2
            ;;
        --reset-identity)
            RESET_IDENTITY="true"
            shift
            ;;
        --enable-epel=*)
            ENABLE_EPEL="${1#*=}"
            shift
            ;;
        --enable-epel)
            if [[ -z ${2:-} ]]; then
                err "--enable-epel requires a value (y | n)"
                exit 1
            fi
            ENABLE_EPEL="$2"
            shift 2
            ;;
        --enable-resolved=*)
            ENABLE_RESOLVED="${1#*=}"
            shift
            ;;
        --enable-resolved)
            if [[ -z ${2:-} ]]; then
                err "--enable-resolved requires a value (y | n)"
                exit 1
            fi
            ENABLE_RESOLVED="$2"
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

    case "$CHANNEL" in
    stable | snapshot | experimental) ;;
    *)
        err "--channel must be 'stable', 'snapshot' or 'experimental' (got: '${CHANNEL}')"
        exit 1
        ;;
    esac

    # TODO: remove by December 2027. Accept pre-rename network names.
    local old_network="$NETWORK"
    NETWORK="$(canonical_network "$NETWORK")"
    [[ $NETWORK == "$old_network" ]] || log "Network '${old_network}' was renamed to '${NETWORK}' — using '${NETWORK}'"

    read -r -a CHANNEL_NETWORKS <<<"$(channel_networks "$CHANNEL")"
    if [[ -n $NETWORK ]] && ! in_list "$NETWORK" "${CHANNEL_NETWORKS[@]}"; then
        err "--network must be one of '${CHANNEL_NETWORKS[*]}' on the '${CHANNEL}' channel (got: '${NETWORK}')"
        # Point at the channel that does ship it, when there is one.
        local standard_networks=() experimental_networks=()
        read -r -a standard_networks <<<"$(channel_networks stable)"
        read -r -a experimental_networks <<<"$(channel_networks experimental)"
        if in_list "$NETWORK" "${standard_networks[@]}"; then
            err "'${NETWORK}' ships on the stable and snapshot channels"
        elif in_list "$NETWORK" "${experimental_networks[@]}"; then
            err "'${NETWORK}' ships on the experimental channel only: add --channel=experimental"
        fi
        exit 1
    fi

    if [[ $RESET_IDENTITY != "true" && $RESET_IDENTITY != "false" ]]; then
        err "GNOSISVPN_RESET_IDENTITY must be 'true' or 'false' (got: '${RESET_IDENTITY}')"
        exit 1
    fi

    if [[ -n $ENABLE_EPEL ]]; then
        local epel="$ENABLE_EPEL"
        ENABLE_EPEL="$(normalize_yes_no "$epel")"
        if [[ -z $ENABLE_EPEL ]]; then
            err "--enable-epel must be 'y' or 'n' (got: '${epel}')"
            exit 1
        fi
    fi
    if [[ -n $ENABLE_RESOLVED ]]; then
        local resolved="$ENABLE_RESOLVED"
        ENABLE_RESOLVED="$(normalize_yes_no "$resolved")"
        if [[ -z $ENABLE_RESOLVED ]]; then
            err "--enable-resolved must be 'y' or 'n' (got: '${resolved}')"
            exit 1
        fi
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

    log "GnosisVPN needs sudo to add its package repository, install the gnosisvpn package, and manage its systemd service."
    if ! sudo -v; then
        err "Could not obtain sudo access. If this is a non-interactive/headless environment (no terminal for the sudo password prompt), re-run with: curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash"
        exit 1
    fi
    SUDO="sudo"

    # Refreshes the sudo timestamp so a slow apt-get run doesn't force a second password prompt.
    while true; do
        sudo -n true || true
        sleep 60
    done 2>/dev/null &
    KEEPALIVE_PID=$!
    trap 'kill "$KEEPALIVE_PID" 2>/dev/null' EXIT
}

# Prints one os-release field (ID, ID_LIKE or VERSION_ID) without leaking the file's variables into the installer.
os_release_value() {
    [[ -r $OS_RELEASE_FILE ]] || return 0
    (
        # shellcheck disable=SC1090
        . "$OS_RELEASE_FILE"
        case "$1" in
        ID) printf '%s\n' "${ID:-}" ;;
        ID_LIKE) printf '%s\n' "${ID_LIKE:-}" ;;
        VERSION_ID) printf '%s\n' "${VERSION_ID:-}" ;;
        esac
    )
}

# apt or dnf, from os-release; the tools alone are not enough because Fedora can have apt-get and dpkg installed.
detect_family() {
    local word
    for word in $(os_release_value ID) $(os_release_value ID_LIKE); do
        case "$word" in
        debian | ubuntu)
            echo "apt"
            return 0
            ;;
        fedora | rhel | centos | almalinux | rocky | ol)
            echo "dnf"
            return 0
            ;;
        esac
    done
    # Without os-release, fall back to the tools: only the Debian family ships both dpkg and apt-get.
    if [[ ! -r $OS_RELEASE_FILE ]]; then
        if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
            echo "apt"
            return 0
        fi
        err "/etc/os-release not found; cannot tell whether this host uses apt or dnf."
        exit 1
    fi
    err "Unsupported distribution '$(os_release_value ID)': this installer supports Debian, Ubuntu, Fedora and EL10."
    exit 1
}

is_enterprise_linux() {
    case "$(os_release_value ID)" in
    rhel | almalinux | rocky | centos | ol) return 0 ;;
    *) return 1 ;;
    esac
}

check_dnf_distro() {
    local id ver major
    id="$(os_release_value ID)"
    ver="$(os_release_value VERSION_ID)"
    major="${ver%%.*}"

    local supported=0
    case "$id" in
    fedora)
        case "$major" in
        43 | 44) supported=1 ;;
        esac
        ;;
    rhel | almalinux | rocky | centos | ol)
        if [[ $major =~ ^[0-9]+$ && $major -lt 10 ]]; then
            err "Detected distribution: ${id} ${ver} (not supported)"
            err "EL${major} provides no webkit2gtk4.1 (not even in EPEL), which the GnosisVPN app requires. Use an EL10 or Fedora 43/44 host."
            exit 1
        fi
        [[ $major == "10" ]] && supported=1
        ;;
    esac

    if [[ $supported -eq 1 ]]; then
        log "Detected distribution: ${id} ${ver} (supported)"
    else
        warn "Detected distribution: ${id} ${ver} (not in the officially supported list; continuing)"
    fi
}

detect_arch_dnf() {
    ARCH="$(uname -m)"
    case "$ARCH" in
    x86_64 | aarch64) ;;
    *)
        err "Unsupported architecture: ${ARCH}. Only x86_64 and aarch64 are published."
        exit 1
        ;;
    esac
    log "Detected architecture: ${ARCH}"
}

# Prints y or n: the preset answer when given, else the answer typed on the terminal, else nothing.
ask_yes_no() {
    local preset="$1" question="$2" answer
    if [[ -n $preset ]]; then
        echo "$preset"
        return 0
    fi
    # stdin is the script itself under `curl | bash`, so the prompt must read the controlling terminal.
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        return 0
    fi
    while true; do
        read -r -u 3 -p "[gnosisvpn] ${question} [y/n] " answer || break
        answer="$(normalize_yes_no "$answer")"
        if [[ -n $answer ]]; then
            echo "$answer"
            break
        fi
    done
    exec 3<&-
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
    if [[ ! -r $OS_RELEASE_FILE ]]; then
        warn "${OS_RELEASE_FILE} not found — skipping distribution check."
        return
    fi
    local id ver
    id="$(os_release_value ID)"
    ver="$(os_release_value VERSION_ID)"
    id="${id:-unknown}"
    ver="${ver:-unknown}"

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
    experimental)
        component="experimental"
        # Only gnosisvpn.io publishes the experimental suite.
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

    resolve_channel_network

    # --force-confdef/confold: answer dpkg conffile prompts non-interactively (stdin absent in curl|bash).
    # --allow-downgrades: required for channel switches that move to an older package; harmless otherwise.
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
    build_install_env
    ${SUDO} env DEBIAN_FRONTEND=noninteractive "${INSTALL_ENV[@]}" apt-get install "${apt_opts[@]}" "$package"
}

# A channel switch leaves the old line's config behind as an obsolete conffile; install.sh ships ahead of the postinstalls that detect that.
resolve_channel_network() {
    if [[ -z $NETWORK && -L /etc/gnosisvpn/config.toml ]]; then
        local current_network
        current_network="$(basename "$(readlink /etc/gnosisvpn/config.toml)")"
        current_network="${current_network#config-}"
        current_network="${current_network%.toml}"
        if ! in_list "$(canonical_network "$current_network")" "${CHANNEL_NETWORKS[@]}"; then
            NETWORK="${CHANNEL_NETWORKS[0]}"
            log "Current network '${current_network}' is not shipped on the '${CHANNEL}' channel; selecting ${NETWORK} (pass --network to choose another)."
        fi
    fi
}

# True when postinstall has something to apply, so an unchanged version must be reinstalled to run it.
has_install_overrides() {
    [[ -n $NETWORK || -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} || $RESET_IDENTITY == "true" ]]
}

build_install_env() {
    # Forward env vars to postinstall; without them it keeps the existing network/URL (defaulting to jura-prod on fresh install).
    INSTALL_ENV=()
    if [[ -n $NETWORK ]]; then
        # Derive the endpoint for older postinstalls that don't compute it themselves.
        local network_prefix="${NETWORK%-*}"
        local network_env="${NETWORK##*-}"
        local subdomain
        if [[ $network_env == "prod" ]]; then # Prod environment does not have a subdomain
            subdomain="gnosisvpn.io"
        else
            subdomain="${network_env}.gnosisvpn.io"
        fi
        local blokli_url="${GNOSISVPN_HOPR_BLOKLI_URL:-https://blokli.${network_prefix}.${subdomain}}"
        log "Selecting network: ${NETWORK} (Blokli endpoint: ${blokli_url})"
        INSTALL_ENV+=(GNOSISVPN_NETWORK="$NETWORK" GNOSISVPN_HOPR_BLOKLI_URL="$blokli_url")
    elif [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        log "Using Blokli endpoint: ${GNOSISVPN_HOPR_BLOKLI_URL}"
        INSTALL_ENV+=(GNOSISVPN_HOPR_BLOKLI_URL="$GNOSISVPN_HOPR_BLOKLI_URL")
    fi
    # Delegate identity reset to postinstall (reset_identity_if_requested) so it runs before the service starts.
    if [[ $RESET_IDENTITY == "true" ]]; then
        log "Reset identity requested — the package postinstall will move the legacy identity aside (per-user identities are not touched)."
        INSTALL_ENV+=(GNOSISVPN_RESET_IDENTITY=true)
    fi
}

ensure_prereqs_dnf() {
    log "Ensuring prerequisites: ca-certificates, curl"
    # Drop a stale repository before the first dnf run so a broken prior config doesn't abort it.
    ${SUDO} rm -f "$RPM_REPO_PATH"
    ${SUDO} dnf -y install ca-certificates
    # Fedora ships curl-minimal, which provides curl but conflicts with the full package.
    if ! command -v curl >/dev/null 2>&1; then
        ${SUDO} dnf -y install curl
    fi
}

webkit_is_installable() {
    [[ -n "$(${SUDO} dnf -y -q repoquery --whatprovides 'libwebkit2gtk-4.1.so.0()(64bit)' 2>/dev/null)" ]]
}

# CRB (CodeReady Builder) repository id; named differently per EL distribution and on RHUI-based cloud images.
find_crb_repo() {
    ${SUDO} dnf repolist --all 2>/dev/null |
        awk 'NR > 1 { id = tolower($1); if (id == "crb" || id ~ /codeready.builder/) { print $1; exit } }'
}

# EPEL (with CRB) provides webkit2gtk4.1 and the tray library on EL10.
ensure_epel() {
    is_enterprise_linux || return 0
    if webkit_is_installable; then
        log "webkit2gtk4.1 is available from the enabled repositories"
        return 0
    fi

    local answer
    answer="$(ask_yes_no "$ENABLE_EPEL" "GnosisVPN needs webkit2gtk4.1 from EPEL. Enable the EPEL and CRB repositories?")"
    case "$answer" in
    n)
        err "GnosisVPN cannot be installed without EPEL on $(os_release_value ID) $(os_release_value VERSION_ID)."
        err "Enable EPEL yourself, or re-run with --enable-epel=y"
        exit 1
        ;;
    "")
        err "EPEL is required and no terminal is available to confirm enabling it."
        err "Re-run with --enable-epel=y (or --enable-epel=n to stop here)"
        exit 1
        ;;
    esac

    local id major crb_repo
    id="$(os_release_value ID)"
    major="$(os_release_value VERSION_ID)"
    major="${major%%.*}"

    log "Enabling the CRB repository ..."
    ${SUDO} dnf -y install dnf-plugins-core
    crb_repo="$(find_crb_repo)"
    if [[ -n $crb_repo ]]; then
        ${SUDO} dnf config-manager --set-enabled "$crb_repo"
        log "Enabled ${crb_repo}"
    else
        warn "No CRB / CodeReady Builder repository found; continuing without it"
    fi

    log "Enabling EPEL ..."
    case "$id" in
    rhel)
        ${SUDO} dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
        ;;
    ol)
        ${SUDO} dnf -y install "oracle-epel-release-el${major}"
        ;;
    *)
        ${SUDO} dnf -y install epel-release
        ;;
    esac

    if ! webkit_is_installable; then
        err "webkit2gtk4.1 is still not available after enabling EPEL; check 'dnf repolist' output."
        exit 1
    fi
}

# The service sends DNS through the tunnel with resolvectl; EL10 runs NetworkManager without systemd-resolved.
ensure_resolved() {
    is_enterprise_linux || return 0
    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        return 0
    fi

    local answer
    answer="$(ask_yes_no "$ENABLE_RESOLVED" "DNS will bypass the VPN without systemd-resolved. Enable systemd-resolved (changes this host's DNS setup)?")"
    case "$answer" in
    n)
        warn "Skipping systemd-resolved: DNS queries will bypass the VPN tunnel."
        return 0
        ;;
    "")
        warn "No terminal to confirm enabling systemd-resolved; skipping. DNS queries will bypass the VPN tunnel."
        warn "Re-run with --enable-resolved=y to enable it."
        return 0
        ;;
    esac

    log "Enabling systemd-resolved ..."
    ${SUDO} dnf -y install systemd-resolved
    ${SUDO} systemctl enable --now systemd-resolved
    ${SUDO} install -d -m 0755 /etc/NetworkManager/conf.d
    printf '[main]\ndns=systemd-resolved\n' | ${SUDO} tee /etc/NetworkManager/conf.d/90-gnosisvpn-dns.conf >/dev/null
    if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
        ${SUDO} cp -a /etc/resolv.conf /etc/resolv.conf.gnosisvpn-backup
        log "Backed up /etc/resolv.conf to /etc/resolv.conf.gnosisvpn-backup"
    fi
    ${SUDO} ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    if command -v restorecon >/dev/null 2>&1; then
        ${SUDO} restorecon -v /etc/resolv.conf || true
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        ${SUDO} systemctl restart NetworkManager
    fi
}

install_rpm_key() {
    log "Installing repository signing key to ${RPM_KEY_PATH}"
    ${SUDO} install -d -m 0755 "$(dirname "$RPM_KEY_PATH")"
    local tmp url
    tmp="$(mktemp)"
    for url in "${RPM_REPO_URL_PRIMARY}/RPM-GPG-KEY-gnosisvpn" "${RPM_REPO_URL_IPFS}/RPM-GPG-KEY-gnosisvpn"; do
        if curl -fsSL "$url" -o "$tmp"; then
            log "Downloaded signing key from ${url}"
            ${SUDO} install -m 0644 "$tmp" "$RPM_KEY_PATH"
            rm -f "$tmp"
            ${SUDO} rpm --import "$RPM_KEY_PATH"
            return
        fi
        warn "Failed to download signing key from ${url}; trying next source"
    done
    err "Failed to download signing key from all sources"
    rm -f "$tmp"
    exit 1
}

# dnf repository definition for a channel; MUST match render_rpm_repo in linux/scripts/postinstall.sh (checked by the unit tests).
render_rpm_repo() {
    local channel="$1" baseurl="${RPM_REPO_URL_PRIMARY}/$1"
    # Only stable is mirrored to IPFS.
    if [[ $channel == "stable" ]]; then
        baseurl="${baseurl} ${RPM_REPO_URL_IPFS}/stable"
    fi
    cat <<EOF
[gnosisvpn]
name=GnosisVPN (${channel})
baseurl=${baseurl}
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://${RPM_KEY_PATH}
metadata_expire=6h
EOF
}

write_rpm_repo() {
    log "Writing dnf repository to ${RPM_REPO_PATH} (channel: ${CHANNEL})"
    render_rpm_repo "$CHANNEL" | ${SUDO} tee "$RPM_REPO_PATH" >/dev/null
    ${SUDO} chmod 0644 "$RPM_REPO_PATH"
}

# dnf4 repoquery pads its output with blank lines.
first_nonempty_line() {
    awk 'NF { print; exit }'
}

dnf_install() {
    log "Refreshing the '${CHANNEL}' dnf repository ..."
    # -y also answers the one-time repository key import, which has no terminal under curl | bash.
    if ! ${SUDO} dnf -y makecache --refresh --repo gnosisvpn; then
        err "Could not load the '${CHANNEL}' dnf repository; check ${RPM_REPO_PATH} and the dnf output above."
        if [[ $CHANNEL == "stable" ]]; then
            err "The stable RPM repository is published with the next stable release; until then use --channel=snapshot."
        fi
        exit 1
    fi

    local candidate installed=""
    candidate="$(${SUDO} dnf -y -q repoquery --repo gnosisvpn --latest-limit 1 --qf '%{version}\n' gnosisvpn 2>/dev/null |
        first_nonempty_line || true)"
    if [[ -z $candidate ]]; then
        err "No installable gnosisvpn package found on the '${CHANNEL}' channel for ${ARCH}."
        exit 1
    fi
    if rpm -q gnosisvpn >/dev/null 2>&1; then
        installed="$(rpm -q --qf '%{VERSION}' gnosisvpn)"
    fi

    resolve_channel_network

    local action="install"
    if [[ -n $installed && $installed != "$candidate" ]]; then
        # distro-sync moves to the repository's version in either direction, covering channel downgrades.
        log "Installed gnosisvpn ${installed} differs from the '${CHANNEL}' channel candidate ${candidate}; syncing to the channel."
        action="distro-sync"
    elif [[ -n $installed ]] && has_install_overrides; then
        # reinstall runs the package scripts again to apply the network/URL/identity override.
        action="reinstall"
    fi

    log "Installing gnosisvpn ${candidate} (dnf ${action}) ..."
    build_install_env
    ${SUDO} env "${INSTALL_ENV[@]}" dnf -y "$action" gnosisvpn

    # A failing %post does not fail the dnf transaction.
    if ! systemctl is-active --quiet gnosisvpn 2>/dev/null; then
        warn "gnosisvpn.service is not running; check: sudo journalctl -u gnosisvpn.service"
    fi
}

print_postinstall_dnf() {
    cat <<'EOF'

[gnosisvpn] Installed. Quick checks:
    sudo systemctl status gnosisvpn
    gnosis_vpn-ctl --help

[gnosisvpn] Signing key installed at /etc/pki/rpm-gpg/RPM-GPG-KEY-gnosisvpn
    To verify:            gpg --show-keys /etc/pki/rpm-gpg/RPM-GPG-KEY-gnosisvpn
    Details:  https://github.com/hoprnet/gnosis_vpn/blob/main/SECURITY.md

To upgrade later:    sudo dnf upgrade --refresh gnosisvpn
To switch networks:  re-run this installer with --network=<name> (see --help for
                     the networks each channel ships)
To switch channels:  re-run this installer with --channel=<stable|snapshot|experimental>
To reset identity:   re-run this installer with --reset-identity
To uninstall:        sudo dnf remove gnosisvpn  (keeps /etc/gnosisvpn and /var/lib/gnosisvpn)
EOF
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
To switch networks:  re-run this installer with --network=<name> (see --help for
                     the networks each channel ships)
To switch channels:  re-run this installer with --channel=<stable|snapshot|experimental>
To uninstall:        sudo apt-get remove gnosisvpn
EOF
}

main() {
    set -Eeuo pipefail
    parse_args "$@"
    FAMILY="$(detect_family)"
    case "$FAMILY" in
    apt)
        ensure_sudo
        detect_arch
        detect_distro
        ensure_prereqs
        install_keyring
        write_sources
        apt_install
        print_postinstall
        ;;
    dnf)
        # Refuse unsupported releases before asking for sudo.
        check_dnf_distro
        ensure_sudo
        detect_arch_dnf
        ensure_prereqs_dnf
        ensure_epel
        ensure_resolved
        install_rpm_key
        write_rpm_repo
        dnf_install
        print_postinstall_dnf
        ;;
    esac
}

# Sourced by the unit tests; under `curl | bash` BASH_SOURCE is empty.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
