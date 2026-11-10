#!/bin/bash
#
# Gnosis VPN Post-Installation Script
#
# Configures the service after files are installed; no service account: root spawns the worker as the requesting user.
# Upgrades move the legacy identity into the installing user's home (gnosis_vpn-migrate) before the service starts.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#
# Networks shipped are baked into /usr/share/gnosisvpn/networks (first = default); consult that, not the files on disk.
#

set -euo pipefail

LOG_PREFIX="[GnosisVPN postinstall]"

# Set by migrate_legacy_identity; gate the service start and the legacy account removal.
MIGRATION_OK=false
MIGRATION_FAILED=false
MIGRATION_STATUS=0
MIGRATION_USER=""
MIGRATE_LOG=/var/log/gnosisvpn/migrate.log
# Set by configure_network_selection to the replaced networks being left, oldest first; per-user identities follow.
SOURCE_NETWORKS=""
# The network those identities move to, passed as `switch-network --to`.
SWITCH_TARGET=""
SWITCH_FAILED=false
# The toolkit's ways forward from its `next:` line, ` | `-separated; the failure summary lists them instead of rebuilding them.
TOOLKIT_NEXT=""
# The replaced networks moves are leaving, oldest first; appended before config.toml moves, removed once every identity followed.
PENDING_SWITCH_FILE=/var/lib/gnosisvpn/network-switch-pending

# TODO: remove by December 2027. Pre-rename names of the same networks (NETWORK_RENAMES in config/channels.sh).
renamed_network() {
    case "$1" in
    jura) echo "jura-prod" ;;
    rotsee) echo "jura-dev" ;;
    *) echo "$1" ;;
    esac
}

# Networks no installer line ships any more, filled in by generate-package-linux.sh.
RETIRED_CONFFILES="__RETIRED_CONFFILES__"
# rm_conffile must appear in pre/post/postun to coordinate the dpkg helper; DPKG_MAINTSCRIPT_NAME gates non-dpkg hosts.
remove_retired_conffiles() {
    # env var also gates rpm/pacman hosts that happen to have dpkg installed
    [[ -n ${DPKG_MAINTSCRIPT_NAME:-} ]] && command -v dpkg-maintscript-helper >/dev/null 2>&1 || return 0
    local conffile
    for conffile in $RETIRED_CONFFILES; do
        dpkg-maintscript-helper rm_conffile "/etc/gnosisvpn/$conffile" "" gnosisvpn -- "$@"
    done
}

# Networks shipped by this package (first = default), baked by generate-package-linux.sh; older packages fall back to the historical default.
SHIPPED_NETWORKS=()
load_shipped_networks() {
    if [[ -r /usr/share/gnosisvpn/networks ]]; then
        read -r -a SHIPPED_NETWORKS </usr/share/gnosisvpn/networks || true
    fi
    if [[ ${#SHIPPED_NETWORKS[@]} -eq 0 ]]; then
        echo "$LOG_PREFIX WARNING: /usr/share/gnosisvpn/networks missing or empty — assuming 'jura-prod'"
        SHIPPED_NETWORKS=(jura-prod)
    fi
}

is_shipped_network() {
    local candidate="$1" network
    for network in "${SHIPPED_NETWORKS[@]}"; do
        [[ $network == "$candidate" ]] && return 0
    done
    return 1
}

# Replaced networks (`old:new`), baked by generate-package-linux.sh.
NETWORK_SUCCESSORS=()
load_network_successors() {
    if [[ -r /usr/share/gnosisvpn/network-successors ]]; then
        read -r -a NETWORK_SUCCESSORS </usr/share/gnosisvpn/network-successors || true
    fi
}

# Empty arrays are guarded: bash before 4.4 (RHEL 7) calls their expansion unbound under set -u.
network_successor() {
    [[ ${#NETWORK_SUCCESSORS[@]} -gt 0 ]] || return 0
    local pair
    for pair in "${NETWORK_SUCCESSORS[@]}"; do
        if [[ ${pair%%:*} == "$1" ]]; then
            echo "${pair#*:}"
            return 0
        fi
    done
}

# The shipped network an install on a renamed or replaced one moves to, across several replacements; empty when the chain ships none.
shipped_successor() {
    local network _
    network="$(renamed_network "$1")"
    for _ in 1 2 3 4; do
        if is_shipped_network "$network"; then
            echo "$network"
            return 0
        fi
        network="$(network_successor "$network")"
        [[ -n $network ]] || return 0
    done
}

# The network the config.toml symlink names; empty for a regular file or none.
linked_network() {
    [[ -L /etc/gnosisvpn/config.toml ]] || return 0
    local network
    network="$(basename "$(readlink /etc/gnosisvpn/config.toml)")"
    network="${network#config-}"
    echo "${network%.toml}"
}

# Appended, never overwritten: an unfinished older move still holds identities a newer one would skip.
# rm first and noclobber, so a link planted at the path is replaced, never written through.
record_pending_switch() {
    local networks
    networks="$(pending_switches)"
    case " $networks " in
    *" $1 "*) return 0 ;;
    esac
    rm -f "$PENDING_SWITCH_FILE"
    (
        set -C
        echo "${networks:+$networks }$1" >"$PENDING_SWITCH_FILE"
    )
}

# The networks recorded moves leave, oldest first; never sourced, and only replaced networks this package does not ship count.
pending_switches() {
    [[ -f $PENDING_SWITCH_FILE && ! -L $PENDING_SWITCH_FILE ]] || return 0
    local line="" network kept="" recorded=()
    IFS= read -r line <"$PENDING_SWITCH_FILE" || true
    read -r -a recorded <<<"$line"
    [[ ${#recorded[@]} -gt 0 ]] || return 0
    for network in "${recorded[@]}"; do
        if [[ $network =~ ^[a-z0-9-]+$ ]] && ! is_shipped_network "$network" &&
            [[ -n "$(network_successor "$network")" ]]; then
            kept="${kept:+$kept }$network"
        fi
    done
    echo "$kept"
}

# Newest first: a user's most recent identity wins, an older network only fills in users the newer one lacked.
newest_first() {
    local network reversed=""
    for network in $SOURCE_NETWORKS; do
        reversed="$network${reversed:+ $reversed}"
    done
    echo "$reversed"
}

# The retry for every recorded network, in the order switch_network_if_left runs them.
switch_steps() {
    local network steps=""
    for network in $(newest_first); do
        steps="${steps:+$steps && }sudo gnosis_vpn-migrate switch-network --from ${network} --to ${SWITCH_TARGET}"
    done
    echo "$steps"
}

# Root-owned, world-readable: the worker runs as any user and only reads here; binaries keep nfpm's root:root 755.
configure_filesystem_permissions() {
    echo "$LOG_PREFIX INFO: Setting up directory permissions..."

    # nfpm may have created it with a numeric UID; fix ownership here.
    mkdir -p /etc/gnosisvpn
    chown root:root /etc/gnosisvpn
    chmod 755 /etc/gnosisvpn
    chown root:root /etc/gnosisvpn/*.toml 2>/dev/null || true
    chmod 644 /etc/gnosisvpn/*.toml 2>/dev/null || true

    mkdir -p /var/log/gnosisvpn
    chown -R root:root /var/log/gnosisvpn
    chmod 755 /var/log/gnosisvpn
    # match logrotate's create mode so the app can still read the log after a rotation
    find /var/log/gnosisvpn -type f -exec chmod 644 {} +

    # Updater state and legacy identity backups; not recursive, the legacy .config keeps its owner until migrated.
    mkdir -p /var/lib/gnosisvpn
    chown root:root /var/lib/gnosisvpn
    chmod 755 /var/lib/gnosisvpn

    echo "$LOG_PREFIX SUCCESS: Directory permissions configured"
}

# TODO: remove by December 2027.
# A locally modified gnosisvpn.env survives --force-confold; its old keys would pin the service to a deleted account.
remove_legacy_env_keys() {
    [[ -f /etc/gnosisvpn/gnosisvpn.env ]] || return 0
    if grep -qE '^(GNOSISVPN_WORKER_USER|HOME)=' /etc/gnosisvpn/gnosisvpn.env; then
        echo "$LOG_PREFIX INFO: Removing GNOSISVPN_WORKER_USER and HOME from /etc/gnosisvpn/gnosisvpn.env (multi-user layout)"
        sed -i -E '/^(GNOSISVPN_WORKER_USER|HOME)=/d' /etc/gnosisvpn/gnosisvpn.env
    fi
}

# TODO: remove by June 2027.
# Only dpkg passes the previous version (`configure <old-version>`); rpm/pacman upgrades keep the log.
remove_pre_0_96_log() {
    [[ ${1:-} == "configure" && -n ${2:-} ]] || return 0
    dpkg --compare-versions "$2" lt 0.96.0 2>/dev/null || return 0
    local log_file=/var/log/gnosisvpn/gnosisvpn.log
    [[ -f $log_file ]] || return 0
    echo "$LOG_PREFIX INFO: Upgrading from $2 (below 0.96.0) — removing $log_file"
    rm -f "$log_file"
}

get_blokli_url() {
    # Network name is <network_prefix>-<network_env>; endpoint is derived from it.
    local network_name="$1"
    local network_prefix="${network_name%-*}"
    local network_env="${network_name##*-}"
    local blokli_url
    if [[ $network_env == "prod" ]]; then
        blokli_url="https://blokli.${network_prefix}.gnosisvpn.io"
    else
        blokli_url="https://blokli.${network_prefix}.${network_env}.gnosisvpn.io"
    fi
    echo "$blokli_url"
}

# Point /etc/gnosisvpn/config.toml at the selected network and write its Blokli endpoint.
configure_network_selection() {
    # Precedence: explicit GNOSISVPN_HOPR_BLOKLI_URL > derived from network > pre-existing/legacy value.
    local network_name blokli_url default_network="${SHIPPED_NETWORKS[0]}" previous_network
    network_name="${GNOSISVPN_NETWORK:-$default_network}"
    # Read before any link below changes: the previous install's per-user state is filed under this network.
    previous_network="$(linked_network)"
    # Recorded before the link moves off a replaced network (not a rename), so a failed or interrupted move resumes later.
    local previous_canonical
    previous_canonical="$(renamed_network "$previous_network")"
    if [[ -n $previous_canonical ]] && ! is_shipped_network "$previous_canonical" &&
        [[ -n "$(network_successor "$previous_canonical")" ]]; then
        record_pending_switch "$previous_canonical"
    fi

    # Accept renamed or replaced names, but only when what replaces them ships in this package.
    if ! is_shipped_network "$network_name"; then
        local successor
        successor="$(shipped_successor "$network_name")"
        if [[ -n $successor ]]; then
            echo "$LOG_PREFIX INFO: Network '${network_name}' is now '${successor}' — using '${successor}'"
            network_name="$successor"
        fi
    fi

    # Checked against the baked list, not `ls config-*.toml`, which would also offer the other line's leftover conffiles.
    if ! is_shipped_network "$network_name"; then
        echo "$LOG_PREFIX ERROR: Network '${network_name}' is not shipped by this package" >&2
        echo "$LOG_PREFIX ERROR: Supported networks: ${SHIPPED_NETWORKS[*]}" >&2
        exit 1
    fi

    # Until a recorded move completes it picks the network, as on macOS: an EOA only moves to its own environment's successor.
    local pending pending_target=""
    pending="$(pending_switches)"
    [[ -z $pending ]] || pending_target="$(shipped_successor "${pending%% *}")"
    if [[ -n ${GNOSISVPN_NETWORK:-} && -n $pending_target && $network_name != "$pending_target" ]]; then
        echo "$LOG_PREFIX WARNING: Using '${pending_target}' instead of GNOSISVPN_NETWORK '${network_name}' until the move off '${pending}' completes; set it again afterwards" >&2
        # install.sh passes the endpoint it derived from that network; a custom one stays.
        if [[ ${GNOSISVPN_HOPR_BLOKLI_URL:-} == "$(get_blokli_url "$network_name")" ]]; then
            GNOSISVPN_HOPR_BLOKLI_URL=""
        fi
        network_name="$pending_target"
    fi

    # dpkg never restores conffiles deleted outside of it, so failing here would brick every later apt run.
    if [[ ! -f /etc/gnosisvpn/config-${network_name}.toml ]]; then
        echo "$LOG_PREFIX ERROR: Missing /etc/gnosisvpn/config-${network_name}.toml" >&2
        echo "$LOG_PREFIX ERROR: Restore it with: sudo dpkg -i --force-confmiss /path/to/gnosisvpn_*.deb" >&2
        echo "$LOG_PREFIX WARNING: Skipping network setup — the service cannot start until the file is back" >&2
        return 0
    fi

    blokli_url=$(get_blokli_url "$network_name")
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        # Reject non-http(s) URLs to prevent env injection via EnvironmentFile.
        if [[ $GNOSISVPN_HOPR_BLOKLI_URL =~ ^https?://[^[:space:]]+$ ]]; then
            blokli_url="$GNOSISVPN_HOPR_BLOKLI_URL"
        else
            echo "$LOG_PREFIX ERROR: GNOSISVPN_HOPR_BLOKLI_URL must be a single-line http(s) URL (got: '${GNOSISVPN_HOPR_BLOKLI_URL}')" >&2
            exit 1
        fi
    fi

    # Explicit GNOSISVPN_NETWORK wins; plain upgrade keeps the user's choice unless the link targets a retired config.
    local migrated_from="" migrated_blokli_url=""
    if [[ -n ${GNOSISVPN_NETWORK:-} ]]; then
        ln -sf /etc/gnosisvpn/config-"$network_name".toml /etc/gnosisvpn/config.toml
    # Check -L before -e: a dangling link (retired target just deregistered) must migrate, not be reset to default.
    elif [[ -L /etc/gnosisvpn/config.toml ]]; then
        # Repoint only symlinks; an admin-placed regular file is left alone.
        local current="$previous_network" successor=""
        if is_shipped_network "$current" && [[ -f /etc/gnosisvpn/config-${current}.toml ]]; then
            # The kept link is the user's network; the message and Blokli URL below must follow it, not the default.
            network_name="$current"
            [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]] || blokli_url="$(get_blokli_url "$current")"
        else
            # Not shipped by this package, or the target is gone: what replaces it, else the resolved default.
            is_shipped_network "$current" || successor="$(shipped_successor "$current")"
            successor="${successor:-$network_name}"
        fi
        if [[ -n $successor && $successor != "$current" ]]; then
            if [[ -f /etc/gnosisvpn/config-${successor}.toml ]]; then
                echo "$LOG_PREFIX INFO: Re-pointing /etc/gnosisvpn/config.toml: config-${current}.toml (not shipped by this package) -> config-${successor}.toml"
                ln -sf /etc/gnosisvpn/config-"$successor".toml /etc/gnosisvpn/config.toml
                migrated_from="$current"
                network_name="$successor"
                # Endpoint follows the network; skip if user overrode the URL.
                if [[ -z ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
                    migrated_blokli_url="$(get_blokli_url "$successor")"
                fi
            else
                # Better a stale-but-readable config than a dangling symlink.
                echo "$LOG_PREFIX WARNING: config.toml points at unshipped config-${current}.toml and its replacement config-${successor}.toml is missing — leaving the link untouched" >&2
            fi
        fi
    elif [[ ! -e /etc/gnosisvpn/config.toml ]]; then
        ln -sf /etc/gnosisvpn/config-"$network_name".toml /etc/gnosisvpn/config.toml
    fi

    # Recorded moves, this install's and unfinished earlier ones: identities follow to the linked network in migrate_legacy_identity.
    local linked
    linked="$(linked_network)"
    SOURCE_NETWORKS="$(pending_switches)"
    if [[ -z $SOURCE_NETWORKS ]]; then
        rm -f "$PENDING_SWITCH_FILE"
    elif [[ -z $linked ]] || ! is_shipped_network "$linked"; then
        # config.toml names no shipped network to move to (an admin file, a missing replacement config); the move waits.
        SOURCE_NETWORKS=""
    else
        SWITCH_TARGET="$linked"
        echo "$LOG_PREFIX INFO: Leaving '${SOURCE_NETWORKS}' for '${linked}'; identities move along after the legacy migration"
    fi

    # Overrides go here, not in the dpkg conffile gnosisvpn.env (editing it triggers interactive upgrade prompts).
    local dynamic_env=/etc/gnosisvpn/gnosisvpn-dynamic.env

    # Carry a URL previously sed-ed into gnosisvpn.env by older postinstalls.
    local legacy_url=""
    if [[ -f /etc/gnosisvpn/gnosisvpn.env ]]; then
        legacy_url="$(grep -m1 '^GNOSISVPN_HOPR_BLOKLI_URL=.' /etc/gnosisvpn/gnosisvpn.env || true)"
        legacy_url="${legacy_url#GNOSISVPN_HOPR_BLOKLI_URL=}"
    fi
    if [[ -z ${GNOSISVPN_HOPR_BLOKLI_URL:-} && -z ${GNOSISVPN_NETWORK:-} && ! -f $dynamic_env && -n $legacy_url ]]; then
        blokli_url="$legacy_url"
    fi

    # Move the endpoint with the network unless the operator chose a custom URL.
    if [[ -n $migrated_blokli_url ]]; then
        local stored_url="" migrated_from_url
        migrated_from_url="$(get_blokli_url "$migrated_from")"
        if [[ -f $dynamic_env ]]; then
            stored_url="$(grep -m1 '^GNOSISVPN_HOPR_BLOKLI_URL=' "$dynamic_env" || true)"
            stored_url="${stored_url#GNOSISVPN_HOPR_BLOKLI_URL=}"
        fi
        if [[ -z $stored_url || $stored_url == "$migrated_from_url" ]]; then
            echo "$LOG_PREFIX INFO: Moving Blokli endpoint with the network: ${stored_url:-<unset>} -> ${migrated_blokli_url}"
            blokli_url="$migrated_blokli_url"
        else
            echo "$LOG_PREFIX INFO: Keeping custom Blokli endpoint ${stored_url}"
            migrated_blokli_url=""
        fi
    fi

    # The hoprnet.link endpoints were retired in favour of gnosisvpn.io; any other (custom) URL is kept.
    # TODO: remove by January 2027.
    local moved_from_hoprnet=""
    if [[ -z ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        local current_url=""
        if [[ -f $dynamic_env ]]; then
            current_url="$(grep -m1 '^GNOSISVPN_HOPR_BLOKLI_URL=' "$dynamic_env" || true)"
            current_url="${current_url#GNOSISVPN_HOPR_BLOKLI_URL=}"
        else
            current_url="$legacy_url"
        fi
        if [[ $current_url =~ ^https://blokli-(jura|piz-palu)\.(dev|staging|prod)\.hoprnet\.link$ ]]; then
            blokli_url="$(get_blokli_url "$network_name")"
            echo "$LOG_PREFIX INFO: Migrating Blokli endpoint off hoprnet.link: ${current_url} -> ${blokli_url}"
            moved_from_hoprnet="true"
        fi
    fi

    # Only (re)write on first install or when network/URL changed.
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} || -n ${GNOSISVPN_NETWORK:-} || -n $migrated_blokli_url || -n $moved_from_hoprnet || ! -f $dynamic_env ]]; then
        cat >"$dynamic_env" <<EOF
# Generated by GnosisVPN postinstall — do not edit.
# Values here override /etc/gnosisvpn/gnosisvpn.env.
GNOSISVPN_HOPR_BLOKLI_URL=$blokli_url
EOF
    fi

    # 644 root:root — unprivileged worker must not write this EnvironmentFile (would allow env injection into root service).
    if [[ -f $dynamic_env ]]; then
        chmod 644 "$dynamic_env"
        chown root:root "$dynamic_env"
    fi

    # Restore empty value so gnosisvpn.env matches dpkg's recorded checksum (avoids upgrade prompts).
    if [[ -f /etc/gnosisvpn/gnosisvpn.env ]]; then
        sed -i 's|^GNOSISVPN_HOPR_BLOKLI_URL=.\+$|GNOSISVPN_HOPR_BLOKLI_URL=|' /etc/gnosisvpn/gnosisvpn.env
    fi

    echo "$LOG_PREFIX SUCCESS: Network '${network_name}' configured"
}

# TODO: remove the removal code by December 2026.
# TODO: remove by December 2026.
# Strip the retired mirror before register_apt_repo; a dead mirror fails every apt-get update.
remove_legacy_apt_mirror() {
    local legacy_uri="https://downloads.vpn.gnosis.eth.limo/linux/apt"
    local sources_path="/etc/apt/sources.list.d/gnosisvpn.sources"
    [[ -f $sources_path ]] || return 0
    grep -qF "$legacy_uri" "$sources_path" || return 0
    echo "$LOG_PREFIX INFO: Removing retired APT mirror $legacy_uri from $sources_path"
    # Escape dots so sed matches the URI literally.
    local legacy_uri_re="${legacy_uri//./\\.}"
    sed -i "/^[Uu][Rr][Ii][Ss]:/ s|[[:space:]]*${legacy_uri_re}||g" "$sources_path"
    # Drop the file if the URI survived (continuation-line layout) or the URIs: field is now empty.
    if grep -qF "$legacy_uri" "$sources_path" ||
        ! grep -Eq '^[Uu][Rr][Ii][Ss]:[[:space:]]*[^[:space:]]' "$sources_path"; then
        echo "$LOG_PREFIX INFO: Retired mirror still present or no mirrors left in $sources_path — removing it (re-registered below when possible)"
        rm -f "$sources_path"
    fi
}

register_apt_repo() {
    if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi

    local sources_path="/etc/apt/sources.list.d/gnosisvpn.sources"
    local keyring_src="/usr/share/gnosisvpn/gnosisvpn-archive-keyring.gpg"
    local keyring_dst="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"

    # The channel is encoded in the version; ".experimental" is snapshot-shaped underneath, so it MUST be tested first.
    local version channel component uris
    version="$(cat /etc/gnosisvpn/version.txt 2>/dev/null || echo "")"
    if [[ -z $version ]]; then
        # Can't tell the channel without a version; don't guess (stable would point a snapshot host at the wrong suite).
        if [[ -f $sources_path ]]; then
            echo "$LOG_PREFIX WARNING: Cannot determine channel (missing/empty /etc/gnosisvpn/version.txt) — leaving $sources_path untouched"
        else
            echo "$LOG_PREFIX WARNING: Cannot determine channel (missing/empty /etc/gnosisvpn/version.txt) — skipping APT source registration"
        fi
        return 0
    fi
    case "$version" in
    *.experimental | *.experimental.*)
        channel="experimental"
        component="experimental"
        # Only gnosisvpn.io publishes dists/experimental/.
        uris="https://download.gnosisvpn.io/linux/apt"
        ;;
    *"+"*)
        channel="snapshot"
        component="snapshot"
        # Only gnosisvpn.io publishes dists/snapshot/.
        uris="https://download.gnosisvpn.io/linux/apt"
        ;;
    *)
        channel="stable"
        component="main"
        uris="https://download.vpn.gnosis.eth.limo/linux/apt https://download.gnosisvpn.io/linux/apt"
        ;;
    esac

    # Always restore the keyring so a user who deleted it gets it back on the next upgrade.
    if [[ ! -f $keyring_src ]]; then
        echo "$LOG_PREFIX WARNING: Keyring not found at $keyring_src — skipping APT source registration"
        return 0
    fi
    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "$keyring_src" "$keyring_dst"

    if [[ -f $sources_path ]]; then
        # Rewrite when channel or mirrors drifted; keep when already canonical.
        local existing_suites existing_uris
        existing_suites="$(awk 'tolower($1) == "suites:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[[:space:]\r]+$/, ""); print; exit }' \
            "$sources_path" 2>/dev/null || true)"
        existing_uris="$(awk 'tolower($1) == "uris:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[[:space:]\r]+$/, ""); print; exit }' \
            "$sources_path" 2>/dev/null || true)"

        if [[ -z $existing_suites ]]; then
            echo "$LOG_PREFIX WARNING: No parseable 'Suites:' line in $sources_path — leaving it untouched"
            return 0
        fi

        # Compare order-independently so a stale mirror list is healed even when the suite matches.
        local want_uris got_uris
        want_uris="$(printf '%s\n' $uris | sort | tr '\n' ' ')"
        got_uris="$(printf '%s\n' $existing_uris | sort | tr '\n' ' ')"

        if [[ $existing_suites == "$channel" && $got_uris == "$want_uris" ]]; then
            echo "$LOG_PREFIX INFO: APT source already tracks the '$channel' channel with the expected mirrors at $sources_path (leaving as-is)"
            return 0
        fi
        if [[ $existing_suites == "$channel" ]]; then
            echo "$LOG_PREFIX INFO: APT source tracks '$channel' but its mirror list is stale — rewriting $sources_path"
        else
            echo "$LOG_PREFIX INFO: APT source tracks '$existing_suites' but this package is from the '$channel' channel — rewriting $sources_path"
        fi
    fi

    local arch
    arch="$(dpkg --print-architecture)"

    echo "$LOG_PREFIX INFO: Registering GnosisVPN APT source (channel: $channel, arch: $arch)"
    cat >"$sources_path" <<EOF
Types: deb
URIs: ${uris}
Suites: ${channel}
Components: ${component}
Architectures: ${arch}
Signed-By: ${keyring_dst}
EOF
    chmod 0644 "$sources_path"
    echo "$LOG_PREFIX SUCCESS: APT source registered at $sources_path"
    echo "$LOG_PREFIX INFO: Run 'sudo apt-get update' to refresh the package cache"
}

# Moves the legacy identity aside through the toolkit so the service gets a fresh identity on next start.
reset_identity_if_requested() {
    if [[ -z ${GNOSISVPN_RESET_IDENTITY:-} || ${GNOSISVPN_RESET_IDENTITY} == "false" ]]; then
        return 0
    fi
    if [[ ${GNOSISVPN_RESET_IDENTITY} != "true" ]]; then
        echo "$LOG_PREFIX ERROR: GNOSISVPN_RESET_IDENTITY must be 'true' or 'false' (got: '${GNOSISVPN_RESET_IDENTITY}')" >&2
        exit 1
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
        echo "$LOG_PREFIX INFO: Stopping gnosisvpn.service to reset the HOPR identity..."
        systemctl stop gnosisvpn.service || true
    fi

    # The toolkit owns legacy moves (GNO-810): start-clean renames .config to .config.<ts>.bak and locks it down to 0700.
    echo "$LOG_PREFIX INFO: Moving the legacy identity aside (gnosis_vpn-migrate start-clean)..."
    /usr/bin/gnosis_vpn-migrate start-clean

    # Leave gnosisvpn-dynamic.env intact; it holds GNOSISVPN_HOPR_BLOKLI_URL — deleting it would leave the service with an empty URL (clap rejects that).
}

# Class user* only (user, user-early): the display manager's greeter also holds seat0 and must never receive the identity.
session_human_user() {
    local key value uid="" name="" class=""
    while IFS='=' read -r key value; do
        case $key in
        User) uid=$value ;;
        Name) name=$value ;;
        Class) class=$value ;;
        esac
    done < <(loginctl show-session "$1" -p User -p Name -p Class 2>/dev/null)
    [[ $class == user* && ${uid:-0} -ge 1000 && $name != "root" ]] || return 0
    echo "$name"
}

# seat0's active session only, like the macOS console user: SUDO_USER/USER would hand the identity to whoever ran apt over ssh.
resolve_installing_user() {
    command -v loginctl >/dev/null 2>&1 || return 0
    local active
    active="$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null || true)"
    # Nobody at the keyboard (headless host, greeter) defers the migration.
    [[ -n $active ]] || return 0
    session_human_user "$active"
}

# Same lock-down as the toolkit's migration (GNO-1006): the old package left the key and password world-readable (775).
lock_down_legacy_identity() {
    local legacy_config=/var/lib/gnosisvpn/.config
    [[ -d $legacy_config && ! -L $legacy_config ]] || return 0
    chown root:root "$legacy_config"
    chmod 700 "$legacy_config"
}

# Moves the legacy /var/lib/gnosisvpn/.config identity into the installing user's home, then off a replaced network; a failure keeps the service stopped.
# Replays the toolkit's stderr and keeps its ways forward for print_migration_failure.
run_identity_migration() {
    local stderr_file
    stderr_file="$(mktemp)"
    # The `||` list keeps a failing toolkit from aborting (or rolling back) the postinstall.
    /usr/bin/gnosis_vpn-migrate identity "$@" 2>"$stderr_file" || MIGRATION_STATUS=$?
    cat "$stderr_file" >&2
    TOOLKIT_NEXT="$(sed -n 's/^log: .* | next: //p' "$stderr_file")"
    rm -f "$stderr_file"
}

# One numbered line per toolkit option; upload-log alone when the toolkit died before naming any.
toolkit_options() {
    if [[ -z $TOOLKIT_NEXT ]]; then
        echo "  1. sudo gnosis_vpn-migrate upload-log"
        return 0
    fi
    echo "$TOOLKIT_NEXT" | awk -F' [|] ' '{ for (i = 1; i <= NF; i++) printf "  %d. %s\n", i, $i }'
}

migrate_legacy_identity() {
    # preinstall stops it too; repeated so the migration never runs against a live service.
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
        echo "$LOG_PREFIX INFO: Stopping gnosisvpn.service before the identity migration..."
        systemctl stop gnosisvpn.service || true
    fi

    MIGRATION_USER="$(resolve_installing_user)"
    if [[ -z $MIGRATION_USER ]]; then
        echo "$LOG_PREFIX WARNING: Nobody is logged in at the desktop (seat0): the legacy identity (if any) stays in /var/lib/gnosisvpn/.config" >&2
        # --replace: by then a connection may have created a per-user identity that must give way to the legacy one.
        echo "$LOG_PREFIX WARNING: Migrate it later with: sudo gnosis_vpn-migrate identity --user <name> --replace" >&2
        lock_down_legacy_identity
        return 0
    fi

    # Moves the previous release's app settings and logs into their current dirs; a failure is logged, never blocking.
    /usr/bin/gnosis_vpn-migrate layout --user "$MIGRATION_USER" || echo "$LOG_PREFIX WARNING: layout relocation reported problems, see $MIGRATE_LOG" >&2

    echo "$LOG_PREFIX INFO: Migrating the legacy identity to user '${MIGRATION_USER}' (the desktop/console user)..."
    if [[ -n $SOURCE_NETWORKS ]]; then
        # Onto the oldest network being left, where the legacy identity was used, next to its safe; switch_network_if_left moves it on.
        run_identity_migration --user "$MIGRATION_USER" --network "${SOURCE_NETWORKS%% *}"
    else
        run_identity_migration --user "$MIGRATION_USER"
    fi
    if [[ $MIGRATION_STATUS -ne 0 ]]; then
        MIGRATION_FAILED=true
        # The old postrm already freed the service uid; the key must not wait for a retry to leave it.
        lock_down_legacy_identity
        echo "$LOG_PREFIX ERROR: Identity migration failed — gnosisvpn.service will be installed but not started" >&2
        return 0
    fi
    MIGRATION_OK=true
}

# Every user's identity on the replaced networks follows to the new one; the old safes stay behind, backed up.
switch_network_if_left() {
    [[ -n $SOURCE_NETWORKS ]] || return 0
    local network
    for network in $(newest_first); do
        echo "$LOG_PREFIX INFO: Moving every user's identity off network '${network}'..."
        if ! /usr/bin/gnosis_vpn-migrate switch-network --from "$network" --to "$SWITCH_TARGET"; then
            SWITCH_FAILED=true
            MIGRATION_FAILED=true
            echo "$LOG_PREFIX ERROR: Moving identities off '${network}' failed — gnosisvpn.service will be installed but not started" >&2
            return 0
        fi
    done
    rm -f "$PENDING_SWITCH_FILE"
}

# Shared wording with the macOS postinstall; the start command must stay the last line.
print_migration_failure() {
    [[ $MIGRATION_FAILED == true ]] || return 0
    local switch_step
    switch_step="$(switch_steps)"
    if [[ $SWITCH_FAILED == true ]]; then
        cat >&2 <<EOF

Moving identities off '${SOURCE_NETWORKS}' failed — see the toolkit output above.
Log: ${MIGRATE_LOG}
The service was installed but left disabled and NOT started; the next package upgrade retries. Choose one:
  1. Retry after fixing the cause:   ${switch_step}
  2. Send the logs to support:        sudo gnosis_vpn-migrate upload-log
Then start the service:               sudo systemctl enable --now gnosisvpn
EOF
        return 0
    fi
    local then_switch=""
    [[ -z $SOURCE_NETWORKS ]] || then_switch=$'\n'"Then move the identities along:       ${switch_step}"
    cat >&2 <<EOF

Identity migration failed — see the toolkit output above.
Log: ${MIGRATE_LOG}
The service was installed but left disabled and NOT started. Choose one:
$(toolkit_options)${then_switch}
Then start the service:               sudo systemctl enable --now gnosisvpn
EOF
}

# TODO: remove by December 2027.
# Unconditional: the previous package's postrm drops the account on every upgrade, and a kept conffile naming it would stop rotation.
reown_legacy_logrotate_rule() {
    [[ -f /etc/logrotate.d/gnosisvpn ]] || return 0
    grep -qE '^[[:space:]]*create[[:space:]]+[0-7]+[[:space:]]+gnosisvpn[[:space:]]+gnosisvpn' /etc/logrotate.d/gnosisvpn || return 0
    echo "$LOG_PREFIX INFO: Re-owning the logrotate create rule in /etc/logrotate.d/gnosisvpn to root"
    sed -i -E 's/^([[:space:]]*create[[:space:]]+[0-7]+[[:space:]]+)gnosisvpn[[:space:]]+gnosisvpn/\1root root/' /etc/logrotate.d/gnosisvpn
}

# TODO: remove by December 2027.
# Only after an OK migration; a host without userdel/groupdel must warn, not abort the postinstall under set -e.
remove_legacy_account() {
    [[ $MIGRATION_OK == true ]] || return 0
    if getent passwd gnosisvpn >/dev/null 2>&1; then
        if command -v userdel >/dev/null 2>&1; then
            echo "$LOG_PREFIX INFO: Removing the legacy service user 'gnosisvpn'..."
            userdel gnosisvpn 2>/dev/null || echo "$LOG_PREFIX WARNING: Could not remove user 'gnosisvpn'; remove it by hand" >&2
        else
            echo "$LOG_PREFIX WARNING: userdel not found; the legacy user 'gnosisvpn' stays (harmless)" >&2
        fi
    fi
    if getent group gnosisvpn >/dev/null 2>&1; then
        if command -v groupdel >/dev/null 2>&1; then
            echo "$LOG_PREFIX INFO: Removing the legacy group 'gnosisvpn'..."
            groupdel gnosisvpn 2>/dev/null || echo "$LOG_PREFIX WARNING: Could not remove group 'gnosisvpn'; remove it by hand" >&2
        else
            echo "$LOG_PREFIX WARNING: groupdel not found; the legacy group 'gnosisvpn' stays (harmless)" >&2
        fi
    fi
}

# Conffile: deleting it is the documented opt-out. dpkg keeps it deleted; rpm/pacman reinstate it on upgrade.
SYSCTL_BBR_FILE=/etc/sysctl.d/99-gnosisvpn-bbr.conf
CONGESTION_CONTROL_KEY=net.ipv4.tcp_congestion_control
QDISC_KEY=net.core.default_qdisc

read_sysctl() {
    cat "/proc/sys/${1//.//}" 2>/dev/null || true
}

# sysctl --system reads every sysctl.d directory and then /etc/sysctl.conf, in the same order as
# boot, so a file that outranks ours keeps its value here too and no reboot is needed.
configure_tcp_bbr() {
    [[ -f $SYSCTL_BBR_FILE ]] || return 0
    if ! command -v sysctl >/dev/null 2>&1; then
        echo "$LOG_PREFIX WARNING: sysctl not found; $SYSCTL_BBR_FILE takes effect on the next boot" >&2
        return 0
    fi
    # Kernel autoload goes through kmod; load it here in case that is restricted.
    modprobe tcp_bbr >/dev/null 2>&1 || true
    # Errors belong to whichever file caused them, not to this package.
    sysctl --system >/dev/null 2>&1 || true
}

print_tcp_bbr_summary() {
    [[ -f $SYSCTL_BBR_FILE ]] || return 0
    local cc qdisc
    cc="$(read_sysctl "$CONGESTION_CONTROL_KEY")"
    qdisc="$(read_sysctl "$QDISC_KEY")"
    echo "$LOG_PREFIX INFO: ----------------------------------------------------------------"
    echo "$LOG_PREFIX INFO: Network tuning from $SYSCTL_BBR_FILE:"
    echo "$LOG_PREFIX INFO:   ${CONGESTION_CONTROL_KEY} = ${cc:-unknown}"
    echo "$LOG_PREFIX INFO:   ${QDISC_KEY} = ${qdisc:-unknown}"
    if [[ $cc != "bbr" ]]; then
        echo "$LOG_PREFIX INFO: The file asks for bbr; this kernel or another sysctl file overrides it."
    fi
    echo "$LOG_PREFIX INFO: To disable:"
    echo "$LOG_PREFIX INFO:   sudo rm $SYSCTL_BBR_FILE"
    echo "$LOG_PREFIX INFO:   sudo sysctl -w ${CONGESTION_CONTROL_KEY}=cubic"
    echo "$LOG_PREFIX INFO:   sudo sysctl -w ${QDISC_KEY}=fq_codel"
    echo "$LOG_PREFIX INFO: ----------------------------------------------------------------"
}

RESOLV_CONF=/etc/resolv.conf

resolv_conf_has_nameserver() {
    grep -qs '^nameserver[[:space:]]' "$RESOLV_CONF"
}

# The resolvconf dep of earlier releases (GNO-667) leaves /etc/resolv.conf empty until NetworkManager re-registers (GNO-898).
repair_resolver_after_resolvconf() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    [[ "$(dpkg-query -W -f '${db:Status-Status}' resolvconf 2>/dev/null)" == installed ]] || return 0
    [[ "$(readlink -f "$RESOLV_CONF")" == /run/resolvconf/* ]] || return 0
    resolv_conf_has_nameserver && return 0

    echo "$LOG_PREFIX WARNING: $RESOLV_CONF has no nameserver; the resolvconf package pulled in by an earlier gnosisvpn release left it empty. Repairing..."
    # resolvconf kept the pre-install file under /run/resolvconf/interface; -u regenerates from it.
    resolvconf -u >/dev/null 2>&1 || true
    if ! resolv_conf_has_nameserver && systemctl is-active --quiet NetworkManager; then
        systemctl try-restart NetworkManager || true
        for _ in $(seq 10); do
            resolv_conf_has_nameserver && break
            sleep 0.5
        done
    fi

    if resolv_conf_has_nameserver; then
        echo "$LOG_PREFIX SUCCESS: System resolver restored"
        echo "$LOG_PREFIX INFO: gnosisvpn no longer needs the resolvconf package; 'apt-get autoremove' removes it (restart NetworkManager afterwards)."
    else
        echo "$LOG_PREFIX WARNING: Could not restore $RESOLV_CONF. Run 'systemctl restart NetworkManager' or reboot. Details: https://github.com/gnosis/gnosis_vpn/issues/494"
    fi
}

# Tunnel DNS only reaches applications when /etc/resolv.conf points at the systemd-resolved stub or at resolvconf.
warn_if_dns_not_diverted() {
    if ! resolv_conf_has_nameserver; then
        echo "$LOG_PREFIX WARNING: $RESOLV_CONF has no nameserver line; name resolution on this host is broken independent of gnosisvpn."
    fi

    local resolved_running=false resolved_stub=false resolvconf_owner=false
    if resolvectl status >/dev/null 2>&1; then
        resolved_running=true
    fi
    if [[ $resolved_running == true ]] && grep -qsE '^nameserver[[:space:]]+127\.0\.0\.5[34]\b' "$RESOLV_CONF"; then
        resolved_stub=true
    fi
    if command -v resolvconf >/dev/null 2>&1 && [[ "$(readlink -f "$RESOLV_CONF")" == /run/resolvconf/* ]]; then
        resolvconf_owner=true
    fi
    if [[ $resolved_stub == true || $resolvconf_owner == true ]]; then
        return 0
    fi

    echo "$LOG_PREFIX WARNING: While connected, DNS queries keep using the host resolver instead of the tunnel; with 'lan_lockdown = true' they are blocked."
    if [[ $resolved_running == true ]]; then
        echo "$LOG_PREFIX WARNING: systemd-resolved is running, but $RESOLV_CONF does not point at its local stub, so applications bypass the per-interface tunnel DNS."
        echo "$LOG_PREFIX WARNING: To divert DNS: 'sudo ln -sf /run/systemd/resolve/stub-resolv.conf $RESOLV_CONF', then reconnect."
    else
        echo "$LOG_PREFIX WARNING: Neither systemd-resolved nor resolvconf manages $RESOLV_CONF."
        echo "$LOG_PREFIX WARNING: To divert DNS: install and enable systemd-resolved (or resolvconf) with your package manager, restart your network manager, then reconnect."
    fi
}

# Enable and start the systemd service
enable_and_start_systemd_service() {
    echo "$LOG_PREFIX INFO: Setting up systemd service..."

    systemctl daemon-reload || true

    # Enable and start service
    systemctl unmask gnosisvpn.service || true
    echo "$LOG_PREFIX INFO: Enabling gnosisvpn-logrotate.timer..."
    systemctl enable --now gnosisvpn-logrotate.timer || true
    # Starting now, or at the next boot, would generate a fresh identity and turn the retry path into a conflict.
    if [[ $MIGRATION_FAILED == true ]]; then
        echo "$LOG_PREFIX WARNING: Not enabling or starting gnosisvpn.service: the identity migration failed (see the end of this output)"
        systemctl disable gnosisvpn.service || true
        return 0
    fi
    echo "$LOG_PREFIX INFO: Enabling gnosisvpn.service..."
    systemctl enable gnosisvpn.service || true
    echo "$LOG_PREFIX INFO: Starting gnosisvpn.service..."
    # Clear start-limit counter; a prior crash-loop would otherwise reject the start for StartLimitIntervalSec.
    systemctl reset-failed gnosisvpn.service 2>/dev/null || true
    systemctl start gnosisvpn.service || true

    sleep 2

    if systemctl is-active --quiet gnosisvpn.service; then
        echo "$LOG_PREFIX SUCCESS: Service started successfully"
    else
        echo "$LOG_PREFIX WARNING: Service failed to start. Check logs with: journalctl -u gnosisvpn.service"
    fi

    echo "$LOG_PREFIX INFO: Service status: $(systemctl is-enabled gnosisvpn.service 2>/dev/null || echo 'unknown')"
}

# Main execution
main() {
    remove_retired_conffiles "$@"
    load_shipped_networks
    load_network_successors
    configure_filesystem_permissions
    # TODO: remove the removal code by December 2027 (see remove_legacy_env_keys).
    remove_legacy_env_keys
    # TODO: remove the removal code by June 2027 (see remove_pre_0_96_log).
    remove_pre_0_96_log "$@"
    configure_network_selection
    # TODO: remove the removal code by December 2026 (see remove_legacy_apt_mirror).
    remove_legacy_apt_mirror
    register_apt_repo
    # --reset-identity moves the legacy dir aside first, so the migration then finds nothing to migrate.
    reset_identity_if_requested
    migrate_legacy_identity
    # Once, after the legacy identity sits on its old network; a failed migration leaves the move pending for the next install.
    [[ $MIGRATION_FAILED == true ]] || switch_network_if_left
    # TODO: remove the removal code by December 2027 (see reown_legacy_logrotate_rule, remove_legacy_account).
    reown_legacy_logrotate_rule
    remove_legacy_account
    configure_tcp_bbr
    repair_resolver_after_resolvconf
    warn_if_dns_not_diverted
    enable_and_start_systemd_service

    echo "$LOG_PREFIX SUCCESS: Post-installation completed successfully"
    print_tcp_bbr_summary
    # Last on purpose: its final line is the start command the user has to run.
    print_migration_failure
}

# Args forwarded for dpkg-maintscript-helper and the previous version (see remove_retired_conffiles, remove_pre_0_96_log).
main "$@"
