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
MIGRATION_USER=""
MIGRATE_LOG=/var/log/gnosisvpn/migrate.log
# The old rpm %postun deletes /var/log/gnosisvpn after this script, so a copy lives where it survives.
MIGRATE_LOG_COPY=/var/lib/gnosisvpn/migrate.log

# TODO: remove by December 2027.
retired_network_successor() {
    case "$1" in
    jura) echo "jura-prod" ;;
    rotsee) echo "jura-dev" ;;
    esac
}

# TODO: remove by December 2027.
# rm_conffile must appear in pre/post/postun to coordinate the dpkg helper; DPKG_MAINTSCRIPT_NAME gates non-dpkg hosts.
remove_retired_conffiles() {
    # env var also gates rpm/pacman hosts that happen to have dpkg installed
    [[ -n ${DPKG_MAINTSCRIPT_NAME:-} ]] && command -v dpkg-maintscript-helper >/dev/null 2>&1 || return 0
    local conffile
    for conffile in config-jura.toml config-rotsee.toml; do
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
    local network_name blokli_url default_network="${SHIPPED_NETWORKS[0]}"
    network_name="${GNOSISVPN_NETWORK:-$default_network}"

    # Accept retired names, but only when the successor is one this package ships.
    if ! is_shipped_network "$network_name"; then
        local successor
        successor="$(retired_network_successor "$network_name")"
        if [[ -n $successor ]] && is_shipped_network "$successor"; then
            echo "$LOG_PREFIX INFO: Network '${network_name}' was renamed to '${successor}' — using '${successor}'"
            network_name="$successor"
        fi
    fi

    # Checked against the baked list, not `ls config-*.toml`, which would also offer the other line's leftover conffiles.
    if ! is_shipped_network "$network_name"; then
        echo "$LOG_PREFIX ERROR: Network '${network_name}' is not shipped by this package" >&2
        echo "$LOG_PREFIX ERROR: Supported networks: ${SHIPPED_NETWORKS[*]}" >&2
        exit 1
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
        local current successor
        current="$(basename "$(readlink /etc/gnosisvpn/config.toml)")"
        current="${current#config-}"
        current="${current%.toml}"
        # The kept link is the user's network; the message and Blokli URL below must follow it, not the default.
        if is_shipped_network "$current" && [[ -f /etc/gnosisvpn/config-${current}.toml ]]; then
            network_name="$current"
            [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]] || blokli_url="$(get_blokli_url "$current")"
        fi
        successor="$(retired_network_successor "$current")"
        # A rename to a network this line does not ship is no use; fall through to the default.
        if [[ -n $successor ]] && ! is_shipped_network "$successor"; then
            successor=""
        fi
        # Not shipped by this package, or the target is gone: fall back to the resolved default.
        if [[ -z $successor ]] &&
            { ! is_shipped_network "$current" || [[ ! -f /etc/gnosisvpn/config-${current}.toml ]]; }; then
            successor="$network_name"
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

# Backs up the worker config dir so the service gets a fresh identity on next start.
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

    # Back up rather than delete; service recreates it on next start.
    local config_dir=/var/lib/gnosisvpn/.config
    if [[ -d $config_dir ]]; then
        # Bump numeric suffix to avoid colliding with a same-second backup (fatal under set -e).
        local ts backup n
        ts="$(date +%Y%m%d%H%M%S)"
        backup="${config_dir}.${ts}.bak"
        n=1
        while [[ -e $backup ]]; do
            backup="${config_dir}.${ts}.${n}.bak"
            n=$((n + 1))
        done
        echo "$LOG_PREFIX INFO: Backing up worker config directory: $config_dir -> $backup"
        mv "$config_dir" "$backup"
    else
        echo "$LOG_PREFIX INFO: No worker config found at $config_dir — nothing to back up"
    fi

    # Leave gnosisvpn-dynamic.env intact; it holds GNOSISVPN_HOPR_BLOKLI_URL — deleting it would leave the service with an empty URL (clap rejects that).
}

# The desktop user, or nothing when unknown; root never owns a worker, so every root hit falls through.
# Class "user" only: the display manager's greeter also holds seat0 and must never receive the identity.
first_human_session_user() {
    local id key value uid name seat class
    for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        uid="" name="" seat="" class=""
        while IFS='=' read -r key value; do
            case $key in
            User) uid=$value ;;
            Name) name=$value ;;
            Seat) seat=$value ;;
            Class) class=$value ;;
            esac
        done < <(loginctl show-session "$id" -p User -p Name -p Seat -p Class 2>/dev/null)
        [[ $class == "user" && ${uid:-0} -ge 1000 && $name != "root" ]] || continue
        [[ -z $seat || $seat == "seat0" ]] || continue
        echo "$name"
        return 0
    done
    return 0
}

resolve_installing_user() {
    local user="${SUDO_USER:-}"
    if [[ -z $user || $user == "root" ]]; then
        user="${USER:-}"
    fi
    # PackageKit installs run as root with no SUDO_USER; fall back to a human's logind session.
    if [[ -z $user || $user == "root" ]] && command -v loginctl >/dev/null 2>&1; then
        user="$(first_human_session_user)"
    fi
    if [[ -z $user || $user == "root" ]]; then
        return 0
    fi
    echo "$user"
}

# Moves the legacy /var/lib/gnosisvpn/.config identity into the installing user's home; a failure keeps the service stopped.
migrate_legacy_identity() {
    # preinstall's deb-systemd-invoke is a no-op on rpm/arch, so the old service may still be running here.
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
        echo "$LOG_PREFIX INFO: Stopping gnosisvpn.service before the identity migration..."
        systemctl stop gnosisvpn.service || true
    fi

    MIGRATION_USER="$(resolve_installing_user)"
    if [[ -z $MIGRATION_USER ]]; then
        echo "$LOG_PREFIX WARNING: Cannot tell which user is installing — the legacy identity (if any) stays in /var/lib/gnosisvpn/.config" >&2
        echo "$LOG_PREFIX WARNING: Migrate it later with: sudo gnosis_vpn-migrate identity --user <name>" >&2
        return 0
    fi

    # Moves the previous release's app settings and logs into their current dirs; a failure is logged, never blocking.
    /usr/bin/gnosis_vpn-migrate layout --user "$MIGRATION_USER" || echo "$LOG_PREFIX WARNING: layout relocation reported problems, see $MIGRATE_LOG" >&2

    echo "$LOG_PREFIX INFO: Migrating the legacy identity to user '${MIGRATION_USER}' (the desktop/console user)..."
    if /usr/bin/gnosis_vpn-migrate identity --user "$MIGRATION_USER"; then
        MIGRATION_OK=true
        return 0
    fi
    MIGRATION_FAILED=true
    cp -f "$MIGRATE_LOG" "$MIGRATE_LOG_COPY" 2>/dev/null || true
    echo "$LOG_PREFIX ERROR: Identity migration failed — gnosisvpn.service will be installed but not started" >&2
}

# Shared wording with the macOS postinstall; the start command must stay the last line.
print_migration_failure() {
    [[ $MIGRATION_FAILED == true ]] || return 0
    cat >&2 <<EOF

Identity migration failed — see the toolkit output above.
Log: ${MIGRATE_LOG}   (also: ${MIGRATE_LOG_COPY})
The service was installed but NOT started. Choose one:
  1. Retry after fixing the cause:   sudo gnosis_vpn-migrate identity --user ${MIGRATION_USER}
  2. Send the logs to support:        sudo gnosis_vpn-migrate upload-log
  3. Start with a fresh identity:     sudo gnosis_vpn-migrate start-clean --user ${MIGRATION_USER}
Then start the service:               sudo systemctl start gnosisvpn
EOF
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
    echo "$LOG_PREFIX INFO: Enabling gnosisvpn.service..."
    systemctl unmask gnosisvpn.service || true
    systemctl enable gnosisvpn.service || true
    # Starting now would generate a fresh identity and turn the retry path into a conflict.
    if [[ $MIGRATION_FAILED == true ]]; then
        echo "$LOG_PREFIX WARNING: Not starting gnosisvpn.service: the identity migration failed (see the end of this output)"
        return 0
    fi
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

# Create desktop shortcut for a user
install_desktop_shortcut_for_user() {
    local target_user
    target_user="$(resolve_installing_user)"

    if [ -z "$target_user" ]; then
        echo "$LOG_PREFIX INFO: No desktop user identified, skipping desktop shortcut"
        return
    fi

    # loginctl may yield a user absent from passwd; keep non-fatal so set -e doesn't abort postinstall.
    local user_home
    user_home=$(getent passwd "$target_user" | cut -d: -f6) || true

    if [ -z "$user_home" ]; then
        echo "$LOG_PREFIX WARNING: Could not find home directory for user $target_user"
        return
    fi

    local desktop_dir="$user_home/Desktop"

    if [ ! -d "$desktop_dir" ]; then
        echo "$LOG_PREFIX INFO: Desktop directory not found for $target_user, skipping shortcut"
        return
    fi

    # Strip spaces from filename
    local dest_file="$desktop_dir/GnosisVPN.desktop"

    # Copy the desktop file to the user's Desktop
    if ! cp "/usr/share/applications/Gnosis VPN.desktop" "$dest_file" 2>/dev/null; then
        echo "$LOG_PREFIX WARNING: Failed to copy desktop file"
        return
    fi

    # Make it executable (required for desktop shortcuts)
    chown "$target_user":"$target_user" "$dest_file"
    chmod +x "$dest_file"

    # Try to mark as trusted if tools are available (optional, not in dependencies)
    local trusted_set=false

    # Try to find user's DBUS session to make gio work
    local user_dbus_addr=""
    if [ -d "/run/user/$(id -u "$target_user")" ]; then
        user_dbus_addr="unix:path=/run/user/$(id -u "$target_user")/bus"
    fi

    # Try to set metadata using gio (should be available from package dependencies)
    # We capture output because gio might return exit code 0 even if it prints "not supported"
    local gio_output=""

    if [ -n "$user_dbus_addr" ]; then
        # Try with explicit DBus session address
        # We append || true to prevent script exit on failure due to set -e
        gio_output=$(sudo -u "$target_user" DBUS_SESSION_BUS_ADDRESS="$user_dbus_addr" gio set "$dest_file" metadata::trusted true 2>&1 || true)
        if [[ -z $gio_output ]]; then
            trusted_set=true
        else
            echo "$LOG_PREFIX INFO: Could not set trusted metadata via gio for $target_user: $gio_output"
        fi
    fi

    # Fallback/Retry without explicit address if it failed above
    if [ "$trusted_set" = false ]; then
        gio_output=$(sudo -u "$target_user" gio set "$dest_file" metadata::trusted true 2>&1 || true)
        if [[ -z $gio_output ]]; then
            trusted_set=true
        else
            echo "$LOG_PREFIX INFO: Could not set trusted metadata via gio for $target_user: $gio_output"
        fi
    fi

    echo "$LOG_PREFIX INFO: Desktop shortcut created for $target_user"

    # Inform user they may need to trust manually
    if [ "$trusted_set" = false ]; then
        echo "$LOG_PREFIX INFO: Right-click the desktop icon and select 'Allow Launching' if prompted."
    fi
}

# Main execution
main() {
    # TODO: remove the removal code by December 2027 (see remove_retired_conffiles).
    remove_retired_conffiles "$@"
    load_shipped_networks
    configure_filesystem_permissions
    # TODO: remove the removal code by December 2027 (see remove_legacy_env_keys).
    remove_legacy_env_keys
    configure_network_selection
    # TODO: remove the removal code by December 2026 (see remove_legacy_apt_mirror).
    remove_legacy_apt_mirror
    register_apt_repo
    # --reset-identity moves the legacy dir aside first, so the migration then finds nothing to migrate.
    reset_identity_if_requested
    migrate_legacy_identity
    # TODO: remove the removal code by December 2027 (see remove_legacy_account).
    remove_legacy_account
    configure_tcp_bbr
    repair_resolver_after_resolvconf
    warn_if_dns_not_diverted
    enable_and_start_systemd_service
    install_desktop_shortcut_for_user

    echo "$LOG_PREFIX SUCCESS: Post-installation completed successfully"
    print_tcp_bbr_summary
    # Last on purpose: its final line is the start command the user has to run.
    print_migration_failure
}

# Args forwarded for dpkg-maintscript-helper (see remove_retired_conffiles).
main "$@"
