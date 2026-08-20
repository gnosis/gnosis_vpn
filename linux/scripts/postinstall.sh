#!/bin/bash
#
# Gnosis VPN Post-Installation Script
#
# Creates system user/group and configures the service after files are installed.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#

set -euo pipefail

LOG_PREFIX="[GnosisVPN postinstall]"

# Create system user and group for service
create_system_user_and_group() {
    # Create group if it doesn't exist
    if ! getent group gnosisvpn >/dev/null 2>&1; then
        echo "$LOG_PREFIX INFO: Creating group 'gnosisvpn'..."
        groupadd --system gnosisvpn
        echo "$LOG_PREFIX SUCCESS: Group 'gnosisvpn' created successfully"
    else
        echo "$LOG_PREFIX INFO: Group 'gnosisvpn' already exists"
    fi

    # Create user if it doesn't exist
    if ! getent passwd gnosisvpn >/dev/null 2>&1; then
        echo "$LOG_PREFIX INFO: Creating system user 'gnosisvpn'..."
        useradd --system \
            --gid gnosisvpn \
            --home-dir /var/lib/gnosisvpn \
            --shell /usr/sbin/nologin \
            --comment "Gnosis VPN Service User" \
            gnosisvpn
        echo "$LOG_PREFIX SUCCESS: User 'gnosisvpn' created successfully"
    else
        echo "$LOG_PREFIX INFO: User 'gnosisvpn' already exists"
    fi
}

# TODO: remove by December 2027.
retired_network_successor() {
    case "$1" in
    jura) echo "jura-prod" ;;
    rotsee) echo "jura-dev" ;;
    piz-palu-staging) echo "piz-palu-dev" ;;
    esac
}

# TODO: remove by December 2027.
# rm_conffile must appear in pre/post/postun to coordinate the dpkg helper; DPKG_MAINTSCRIPT_NAME gates non-dpkg hosts.
remove_retired_conffiles() {
    # env var also gates rpm/pacman hosts that happen to have dpkg installed
    [[ -n ${DPKG_MAINTSCRIPT_NAME:-} ]] && command -v dpkg-maintscript-helper >/dev/null 2>&1 || return 0
    local conffile
    for conffile in config-jura.toml config-rotsee.toml config-piz-palu-staging.toml; do
        dpkg-maintscript-helper rm_conffile "/etc/gnosisvpn/$conffile" "" gnosisvpn -- "$@"
    done
}

# Configure ownership and permissions for directories and binaries
configure_filesystem_permissions() {
    # Precedence: explicit GNOSISVPN_HOPR_BLOKLI_URL > derived from network > pre-existing/legacy value.
    local network_name blokli_url
    network_name="${GNOSISVPN_NETWORK:-jura-prod}"

    # Accept retired names from old docs/pinned scripts without aborting.
    if [[ ! -f /etc/gnosisvpn/config-${network_name}.toml ]]; then
        local successor
        successor="$(retired_network_successor "$network_name")"
        if [[ -n $successor && -f /etc/gnosisvpn/config-${successor}.toml ]]; then
            echo "$LOG_PREFIX INFO: Network '${network_name}' was renamed to '${successor}' — using '${successor}'"
            network_name="$successor"
        fi
    fi

    # Guard against a dangling config.toml or bogus default URL from a typo.
    if [[ ! -f /etc/gnosisvpn/config-${network_name}.toml ]]; then
        echo "$LOG_PREFIX ERROR: Unknown network '${network_name}': /etc/gnosisvpn/config-${network_name}.toml not found" >&2
        local available
        available="$(cd /etc/gnosisvpn 2>/dev/null && ls config-*.toml 2>/dev/null |
            sed 's/^config-//; s/\.toml$//' | paste -sd', ' - || true)"
        echo "$LOG_PREFIX ERROR: Supported networks: ${available:-none}" >&2
        exit 1
    fi

    # Network name is <prefix>-<env>; endpoint mirrors that split. Reject non-http(s) URLs to prevent env injection via EnvironmentFile.
    local network_prefix="${network_name%-*}"
    local network_env="${network_name##*-}"
    blokli_url="https://blokli-${network_prefix}.${network_env}.hoprnet.link"
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
        if [[ $GNOSISVPN_HOPR_BLOKLI_URL =~ ^https?://[^[:space:]]+$ ]]; then
            blokli_url="$GNOSISVPN_HOPR_BLOKLI_URL"
        else
            echo "$LOG_PREFIX ERROR: GNOSISVPN_HOPR_BLOKLI_URL must be a single-line http(s) URL (got: '${GNOSISVPN_HOPR_BLOKLI_URL}')" >&2
            exit 1
        fi
    fi
    echo "$LOG_PREFIX INFO: Setting up directory permissions..."

    # nfpm may have created config dir with numeric UID; fix it here.
    if [[ ! -d /etc/gnosisvpn ]]; then
        mkdir -p /etc/gnosisvpn
    fi
    # root-owned so the unprivileged worker cannot replace files loaded by the root service
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
        successor="$(retired_network_successor "$current")"
        # Unknown retired name with missing target: fall back to the resolved default.
        if [[ -z $successor && ! -f /etc/gnosisvpn/config-${current}.toml ]]; then
            successor="$network_name"
        fi
        if [[ -n $successor && $successor != "$current" ]]; then
            if [[ -f /etc/gnosisvpn/config-${successor}.toml ]]; then
                echo "$LOG_PREFIX INFO: Re-pointing /etc/gnosisvpn/config.toml: config-${current}.toml (no longer shipped) -> config-${successor}.toml"
                ln -sf /etc/gnosisvpn/config-"$successor".toml /etc/gnosisvpn/config.toml
                migrated_from="$current"
                network_name="$successor"
                # Endpoint follows the network; skip if user overrode the URL.
                if [[ -z ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
                    migrated_blokli_url="https://blokli-${successor%-*}.${successor##*-}.hoprnet.link"
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
        migrated_from_url="https://blokli-${migrated_from%-*}.${migrated_from##*-}.hoprnet.link"
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

    # Only (re)write on first install or when network/URL changed.
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} || -n ${GNOSISVPN_NETWORK:-} || -n $migrated_blokli_url || ! -f $dynamic_env ]]; then
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

    # nfpm installs binaries before the user exists; fix ownership here.
    if [[ -f /usr/bin/gnosis_vpn-worker ]]; then
        chown gnosisvpn:gnosisvpn /usr/bin/gnosis_vpn-worker
    fi
    if [[ -f /usr/bin/gnosis_vpn-ctl ]]; then
        chown gnosisvpn:gnosisvpn /usr/bin/gnosis_vpn-ctl
    fi
    if [[ -f /usr/bin/gnosis_vpn-app ]]; then
        chown gnosisvpn:gnosisvpn /usr/bin/gnosis_vpn-app
    fi

    echo "$LOG_PREFIX SUCCESS: Directory permissions configured"
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

    # Any "+" in version means snapshot channel.
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
    if [[ $version == *"+"* ]]; then
        channel="snapshot"
        component="snapshot"
        # Only gnosisvpn.io publishes dists/snapshot/.
        uris="https://download.gnosisvpn.io/linux/apt"
    else
        channel="stable"
        component="main"
        uris="https://download.vpn.gnosis.eth.limo/linux/apt https://download.gnosisvpn.io/linux/apt"
    fi

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

# Enable and start the systemd service
enable_and_start_systemd_service() {
    echo "$LOG_PREFIX INFO: Setting up systemd service..."

    systemctl daemon-reload || true

    # Enable and start service
    echo "$LOG_PREFIX INFO: Enabling gnosisvpn.service..."
    systemctl unmask gnosisvpn.service || true
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

# Create desktop shortcut for a user
install_desktop_shortcut_for_user() {
    local target_user="${SUDO_USER:-}"

    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        target_user="${USER:-}"
    fi

    # Fall back to the active graphical session owner (PackageKit installs run as root with no SUDO_USER).
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        if command -v loginctl >/dev/null 2>&1; then
            target_user="$(loginctl list-sessions --no-legend 2>/dev/null |
                awk '$3 != "root" && ($4 == "seat0" || $4 == "-") {print $3; exit}' || true)"
        fi
    fi

    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
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
    create_system_user_and_group
    # TODO: remove the removal code by December 2027 (see remove_retired_conffiles).
    remove_retired_conffiles "$@"
    configure_filesystem_permissions
    # TODO: remove the removal code by December 2026 (see remove_legacy_apt_mirror).
    remove_legacy_apt_mirror
    register_apt_repo
    reset_identity_if_requested
    enable_and_start_systemd_service
    install_desktop_shortcut_for_user

    echo "$LOG_PREFIX SUCCESS: Post-installation completed successfully"
}

# Args forwarded for dpkg-maintscript-helper (see remove_retired_conffiles).
main "$@"
