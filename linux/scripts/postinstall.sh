#!/bin/bash
#
# Gnosis VPN Post-Installation Script
#
# Creates system user/group and configures the service after files are installed.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#
# Networks shipped are baked into /usr/share/gnosisvpn/networks (first = default); consult that, not the files on disk.
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

# Configure ownership and permissions for directories and binaries
configure_filesystem_permissions() {
    echo "$LOG_PREFIX INFO: Setting up directory permissions..."

    # nfpm may have created it with a numeric UID; fix ownership here.
    mkdir -p /etc/gnosisvpn
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

# System-wide TCP BBR drop-in shipped by this package. It is a conffile: on Debian/Ubuntu an admin
# who deletes it keeps it deleted across upgrades, which is the documented way to opt out. (rpm and
# pacman reinstate a missing config file on upgrade, so their deletion holds only until the next one.)
SYSCTL_BBR_FILE=/etc/sysctl.d/99-gnosisvpn-bbr.conf
CONGESTION_CONTROL_KEY=net.ipv4.tcp_congestion_control
QDISC_KEY=net.core.default_qdisc
BBR_STATUS="skipped"
BBR_PREVIOUS_CONGESTION_CONTROL=""
BBR_PREVIOUS_QDISC=""
# What the local copy of the drop-in asks for — an admin may have edited it — and what, if
# anything, outranks each of those at boot.
BBR_REQUESTED_CC=""
BBR_REQUESTED_QDISC=""
BBR_CONFLICT=""
BBR_QDISC_CONFLICT=""
# Keys the file asked for that are not live yet (partial apply).
BBR_PENDING_KEYS=""

read_sysctl() {
    cat "/proc/sys/${1//.//}" 2>/dev/null || true
}

# Directories the boot-time loader reads, most specific first. A basename found in an earlier
# directory shadows the same basename in the later ones, and the merged set is applied in bytewise
# basename order — systemd-sysctl's rule, which is what runs at boot on a systemd host.
SYSCTL_DIRS=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d)

# Last assignment affecting $2 in the sysctl file $1, if any. Handles everything the loaders accept
# besides a plain key: a leading "-" (assign, ignore failures), "/" instead of "." as the name
# separator, and a glob as the variable name — each applies a value, so none may hide an override.
# A non-regular file (a /dev/null symlink masking this basename) yields nothing, which is correct:
# it assigns nothing.
sysctl_value_in_file() {
    local file="$1" key="$2" file_key raw_value value result=""
    [[ -f $file ]] || return 0
    while IFS='=' read -r file_key raw_value; do
        # Keys carry no whitespace; drop the ignore-failures marker and normalise the separator.
        file_key="${file_key//[[:space:]]/}"
        file_key="${file_key#-}"
        file_key="${file_key//\//.}"
        value="${raw_value%%#*}"
        value="${value//[[:space:]]/}"
        [[ -n $file_key && -n $value ]] || continue
        # Unquoted on purpose: an unglobbed key matches literally, a globbed one as a pattern.
        # shellcheck disable=SC2053
        if [[ $key == $file_key ]]; then
            result="$value"
        fi
    done < <(grep -E '^[[:space:]]*-?[[:space:]]*[^#;[:space:]]+[[:space:]]*=' "$file" || true)
    [[ -n $result ]] && echo "$result"
    return 0
}

# Echoes "<file>=<value>" when something the loader reads after our drop-in pins $1 to anything
# but $2: the files sorting after ours, plus /etc/sysctl.conf, which is always read last. The last
# of them to set the key is the one that wins.
conflicting_setting() {
    local key="$1" want="$2" our_base dir file base value winner="" winner_value=""
    our_base="$(basename "$SYSCTL_BBR_FILE")"

    local -A path_by_base=()
    for dir in "${SYSCTL_DIRS[@]}"; do
        for file in "$dir"/*.conf; do
            # -e || -L, not -f: a symlink to /dev/null masks the basename entirely, so it has to
            # claim the name here — sysctl_value_in_file then reads no assignment from it.
            if [[ -e $file || -L $file ]]; then
                base="${file##*/}"
                # First directory to carry a basename shadows the rest.
                [[ -n ${path_by_base[$base]:-} ]] || path_by_base[$base]="$file"
            fi
        done
    done
    path_by_base[$our_base]="$SYSCTL_BBR_FILE"

    # Sorted with LC_ALL=C for the bytewise order the loader uses; bash's own `>` would follow
    # the caller's LC_COLLATE, which can disagree on case and punctuation.
    local later_files=() seen_ours=false
    while IFS= read -r base; do
        if [[ $base == "$our_base" ]]; then
            seen_ours=true
        elif [[ $seen_ours == true ]]; then
            later_files+=("${path_by_base[$base]}")
        fi
    done < <(printf '%s\n' "${!path_by_base[@]}" | LC_ALL=C sort)

    for file in "${later_files[@]}" /etc/sysctl.conf; do
        value="$(sysctl_value_in_file "$file" "$key")"
        if [[ -n $value ]]; then
            winner="$file"
            winner_value="$value"
        fi
    done

    if [[ -n $winner && $winner_value != "$want" ]]; then
        echo "${winner}=${winner_value}"
    fi
    # Explicit success: the caller runs under `set -e`, where a loop ending on a failed test would abort.
    return 0
}

# Turn on what the drop-in asks for now; the file itself keeps it that way across reboots.
configure_tcp_bbr() {
    if [[ ! -f $SYSCTL_BBR_FILE ]]; then
        echo "$LOG_PREFIX INFO: $SYSCTL_BBR_FILE is absent — leaving TCP congestion control alone"
        BBR_STATUS="absent"
        return 0
    fi

    # Read the local copy rather than assuming the shipped values: it is an editable conffile.
    BBR_REQUESTED_CC="$(sysctl_value_in_file "$SYSCTL_BBR_FILE" "$CONGESTION_CONTROL_KEY")"
    BBR_REQUESTED_QDISC="$(sysctl_value_in_file "$SYSCTL_BBR_FILE" "$QDISC_KEY")"
    BBR_PREVIOUS_CONGESTION_CONTROL="$(read_sysctl "$CONGESTION_CONTROL_KEY")"
    BBR_PREVIOUS_QDISC="$(read_sysctl "$QDISC_KEY")"

    # Checked per key, so nothing later claims a value another file wins at boot.
    if [[ -n $BBR_REQUESTED_QDISC ]]; then
        BBR_QDISC_CONFLICT="$(conflicting_setting "$QDISC_KEY" "$BBR_REQUESTED_QDISC")"
    fi

    if [[ -n $BBR_REQUESTED_CC ]]; then
        # Checked before kernel support: an override decides the outcome whatever the kernel offers,
        # and reporting "unsupported" would promise an activation that override keeps blocking.
        BBR_CONFLICT="$(conflicting_setting "$CONGESTION_CONTROL_KEY" "$BBR_REQUESTED_CC")"
        if [[ -n $BBR_CONFLICT ]]; then
            echo "$LOG_PREFIX INFO: ${BBR_CONFLICT%%=*} sets ${CONGESTION_CONTROL_KEY}=${BBR_CONFLICT#*=} and takes precedence over $SYSCTL_BBR_FILE — not enabling BBR"
            BBR_STATUS="overridden"
            return 0
        fi

        # Congestion control usually ships as a module that is only autoloaded on demand, named
        # tcp_<value>. Checked for whatever the local copy asks for: a value this kernel does not
        # have is rejected at boot too, so it must not be reported as merely waiting for one.
        # -F because the value comes from an editable file and is not a regular expression.
        if ! grep -qwF "$BBR_REQUESTED_CC" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            modprobe "tcp_${BBR_REQUESTED_CC}" >/dev/null 2>&1 || true
        fi
        if ! grep -qwF "$BBR_REQUESTED_CC" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            echo "$LOG_PREFIX WARNING: This kernel does not offer ${CONGESTION_CONTROL_KEY}=${BBR_REQUESTED_CC} — keeping $SYSCTL_BBR_FILE as it is" >&2
            BBR_STATUS="unsupported"
            return 0
        fi
    fi

    if ! command -v sysctl >/dev/null 2>&1; then
        echo "$LOG_PREFIX WARNING: sysctl not found — $SYSCTL_BBR_FILE takes effect on the next boot" >&2
        BBR_STATUS="deferred"
        return 0
    fi

    # Containers without CAP_SYS_ADMIN cannot write these knobs, and `sysctl -p` carries on after a
    # key it could not set — so the outcome comes from reading the keys back, not from its status.
    sysctl -q -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1 || true
    local landed=0 pending=0
    if [[ -n $BBR_REQUESTED_CC ]]; then
        if [[ "$(read_sysctl "$CONGESTION_CONTROL_KEY")" == "$BBR_REQUESTED_CC" ]]; then
            landed=$((landed + 1))
        else
            pending=$((pending + 1))
            BBR_PENDING_KEYS="$CONGESTION_CONTROL_KEY"
        fi
    fi
    if [[ -n $BBR_REQUESTED_QDISC ]]; then
        if [[ "$(read_sysctl "$QDISC_KEY")" == "$BBR_REQUESTED_QDISC" ]]; then
            landed=$((landed + 1))
        else
            pending=$((pending + 1))
            BBR_PENDING_KEYS="${BBR_PENDING_KEYS:+$BBR_PENDING_KEYS, }$QDISC_KEY"
        fi
    fi

    if [[ $pending -eq 0 ]]; then
        BBR_STATUS="applied"
    elif [[ $landed -gt 0 ]]; then
        echo "$LOG_PREFIX WARNING: Could not set ${BBR_PENDING_KEYS} now — it takes effect on the next boot" >&2
        BBR_STATUS="partial"
    else
        echo "$LOG_PREFIX WARNING: Could not apply $SYSCTL_BBR_FILE now — it takes effect on the next boot" >&2
        BBR_STATUS="deferred"
    fi
}

# The qdisc setting is a default for interfaces created afterwards, and another file may outrank
# it, so say what it will and will not do rather than implying a running tunnel changes under it.
print_qdisc_note() {
    if [[ -z $BBR_REQUESTED_QDISC ]]; then
        echo "$LOG_PREFIX INFO: The local copy sets no ${QDISC_KEY}."
    elif [[ -n $BBR_QDISC_CONFLICT ]]; then
        echo "$LOG_PREFIX INFO: ${BBR_QDISC_CONFLICT%%=*} sets ${QDISC_KEY}=${BBR_QDISC_CONFLICT#*=} after it,"
        echo "$LOG_PREFIX INFO: so the file's ${QDISC_KEY} does not decide the boot-time value."
    else
        echo "$LOG_PREFIX INFO: The file sets ${QDISC_KEY} = ${BBR_REQUESTED_QDISC} at boot, for interfaces"
        echo "$LOG_PREFIX INFO: created after that — one already up keeps its queueing discipline."
    fi
}

# Final notice about the system-wide network tuning this package installs — printed for every
# outcome, so the end of the install always says what happened.
print_tcp_bbr_summary() {
    # Reported as read, never normalised: this script has no record of who set them.
    local previous_cc="${BBR_PREVIOUS_CONGESTION_CONTROL:-unknown}"
    local previous_qdisc="${BBR_PREVIOUS_QDISC:-unknown}"

    # What to reset to when disabling: the captured value, which is what the file changed it from.
    # Where the host already ran what the file asks for, the package changed nothing and cannot
    # claim to own that value, so name the kernel default and say so instead.
    local reset_cc="$previous_cc" reset_qdisc="$previous_qdisc" reset_is_kernel_default=false
    if [[ $previous_cc == "$BBR_REQUESTED_CC" || $previous_cc == "unknown" ]]; then
        reset_cc="cubic"
        reset_is_kernel_default=true
    fi
    if [[ $previous_qdisc == "$BBR_REQUESTED_QDISC" || $previous_qdisc == "unknown" ]]; then
        reset_qdisc="fq_codel"
        reset_is_kernel_default=true
    fi

    echo "$LOG_PREFIX INFO: ----------------------------------------------------------------"
    if [[ $BBR_STATUS == "absent" ]]; then
        echo "$LOG_PREFIX INFO: $SYSCTL_BBR_FILE is not installed — TCP congestion control left untouched."
        echo "$LOG_PREFIX INFO: ----------------------------------------------------------------"
        return 0
    fi

    echo "$LOG_PREFIX INFO: New file: $SYSCTL_BBR_FILE"
    local live_cc live_qdisc
    case "$BBR_STATUS" in
    applied | partial)
        live_cc="$(read_sysctl "$CONGESTION_CONTROL_KEY")"
        live_qdisc="$(read_sysctl "$QDISC_KEY")"
        # What the local copy asks for decides the headline: it is a conffile and may be edited.
        if [[ -z $BBR_REQUESTED_CC ]]; then
            echo "$LOG_PREFIX INFO: Applied $SYSCTL_BBR_FILE as it stands on this host — the local copy"
            echo "$LOG_PREFIX INFO: no longer sets ${CONGESTION_CONTROL_KEY}, so BBR was not enabled."
        elif [[ $BBR_REQUESTED_CC != "bbr" ]]; then
            echo "$LOG_PREFIX INFO: Applied $SYSCTL_BBR_FILE as it stands on this host: it asks for"
            echo "$LOG_PREFIX INFO: ${CONGESTION_CONTROL_KEY} = ${BBR_REQUESTED_CC}, not bbr — edited locally?"
        elif [[ $live_cc != "bbr" ]]; then
            # Partial apply: the file asks for bbr but the write did not land, so claim nothing.
            echo "$LOG_PREFIX INFO: TCP BBR congestion control could not be set now — the file asks for it"
            echo "$LOG_PREFIX INFO: and the next boot applies it."
        elif [[ $previous_cc == "bbr" ]]; then
            echo "$LOG_PREFIX INFO: TCP BBR congestion control was already active here; the file keeps it that way."
        else
            echo "$LOG_PREFIX INFO: TCP BBR congestion control is now enabled system-wide."
            echo "$LOG_PREFIX INFO: It speeds up traffic sent through the VPN tunnel."
        fi
        echo "$LOG_PREFIX INFO:   ${CONGESTION_CONTROL_KEY} = ${live_cc:-unknown} (was: ${previous_cc})"
        echo "$LOG_PREFIX INFO:   ${QDISC_KEY} = ${live_qdisc:-unknown} (was: ${previous_qdisc})"
        if [[ $BBR_STATUS == "partial" ]]; then
            echo "$LOG_PREFIX INFO: Not set yet, and waiting for the next boot: ${BBR_PENDING_KEYS}"
        fi
        print_qdisc_note
        echo "$LOG_PREFIX INFO: To disable it:"
        echo "$LOG_PREFIX INFO:   sudo rm $SYSCTL_BBR_FILE"
        echo "$LOG_PREFIX INFO:   sudo sysctl -w ${CONGESTION_CONTROL_KEY}=${reset_cc}"
        echo "$LOG_PREFIX INFO:   sudo sysctl -w ${QDISC_KEY}=${reset_qdisc}"
        if [[ $reset_is_kernel_default == true ]]; then
            echo "$LOG_PREFIX INFO: (kernel defaults — this host already ran what the file sets, so something"
            echo "$LOG_PREFIX INFO:  else may set it too: check /etc/sysctl.conf and /etc/sysctl.d)"
        fi
        ;;
    deferred)
        echo "$LOG_PREFIX INFO: Nothing could be set now; the file takes effect on the next boot."
        echo "$LOG_PREFIX INFO: Unchanged for now:"
        echo "$LOG_PREFIX INFO:   ${CONGESTION_CONTROL_KEY} = ${previous_cc}"
        echo "$LOG_PREFIX INFO:   ${QDISC_KEY} = ${previous_qdisc}"
        if [[ $BBR_REQUESTED_CC == "bbr" ]]; then
            echo "$LOG_PREFIX INFO: TCP BBR congestion control comes on then — it speeds up traffic sent"
            echo "$LOG_PREFIX INFO: through the VPN tunnel."
        fi
        print_qdisc_note
        echo "$LOG_PREFIX INFO: To disable it, remove the file before rebooting:"
        echo "$LOG_PREFIX INFO:   sudo rm $SYSCTL_BBR_FILE"
        ;;
    overridden)
        echo "$LOG_PREFIX INFO: TCP BBR was NOT enabled: ${BBR_CONFLICT%%=*} sets"
        echo "$LOG_PREFIX INFO: ${CONGESTION_CONTROL_KEY}=${BBR_CONFLICT#*=} and is read after the file above."
        echo "$LOG_PREFIX INFO: Unchanged by this install:"
        echo "$LOG_PREFIX INFO:   ${CONGESTION_CONTROL_KEY} = ${previous_cc}"
        echo "$LOG_PREFIX INFO:   ${QDISC_KEY} = ${previous_qdisc}"
        print_qdisc_note
        echo "$LOG_PREFIX INFO: Remove the file to keep the system as it is:"
        echo "$LOG_PREFIX INFO:   sudo rm $SYSCTL_BBR_FILE"
        ;;
    unsupported)
        if [[ $BBR_REQUESTED_CC == "bbr" ]]; then
            echo "$LOG_PREFIX INFO: TCP BBR was NOT enabled: this kernel does not offer it."
            echo "$LOG_PREFIX INFO: The file is kept, so BBR comes on once a kernel that supports it is booted."
        else
            echo "$LOG_PREFIX INFO: Nothing was applied: this kernel does not offer"
            echo "$LOG_PREFIX INFO: ${CONGESTION_CONTROL_KEY} = ${BBR_REQUESTED_CC}, which the local copy asks for."
            echo "$LOG_PREFIX INFO: The next boot rejects it too — fix or remove the file."
        fi
        echo "$LOG_PREFIX INFO: Unchanged by this install:"
        echo "$LOG_PREFIX INFO:   ${CONGESTION_CONTROL_KEY} = ${previous_cc}"
        echo "$LOG_PREFIX INFO:   ${QDISC_KEY} = ${previous_qdisc}"
        print_qdisc_note
        echo "$LOG_PREFIX INFO: Remove the file to keep the system as it is:"
        echo "$LOG_PREFIX INFO:   sudo rm $SYSCTL_BBR_FILE"
        ;;
    *)
        # Unreachable: configure_tcp_bbr sets a status on every path. Kept so an added status
        # cannot silently borrow another branch's wording.
        echo "$LOG_PREFIX INFO: TCP tuning state: ${BBR_STATUS}."
        ;;
    esac
    echo "$LOG_PREFIX INFO: ----------------------------------------------------------------"
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
    load_shipped_networks
    configure_filesystem_permissions
    configure_network_selection
    # TODO: remove the removal code by December 2026 (see remove_legacy_apt_mirror).
    remove_legacy_apt_mirror
    register_apt_repo
    reset_identity_if_requested
    configure_tcp_bbr
    enable_and_start_systemd_service
    install_desktop_shortcut_for_user

    echo "$LOG_PREFIX SUCCESS: Post-installation completed successfully"
    print_tcp_bbr_summary
}

# Args forwarded for dpkg-maintscript-helper (see remove_retired_conffiles).
main "$@"
