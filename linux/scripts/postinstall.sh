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

# TODO: remove the migration code by December 2027.
# Migration only: 0.92.0 and earlier shipped config-jura.toml / config-rotsee.toml
# (and snapshots briefly shipped config-piz-palu-staging.toml). Those files were
# renamed away, but dpkg keeps obsolete conffiles on disk until purge and the
# plain-upgrade guard in configure_filesystem_permissions only relinks
# config.toml on a fresh install — so an upgraded host silently keeps loading a
# config this package no longer maintains (nothing dangles, nothing errors).
# Maps a retired network name to its successor so the user's choice survives the
# rename; echoes nothing for a name we do not recognise.
retired_network_successor() {
    case "$1" in
    jura) echo "jura-prod" ;;
    rotsee) echo "jura-dev" ;;
    piz-palu-staging) echo "piz-palu-dev" ;;
    *) echo "" ;;
    esac
}

# TODO: remove the removal code by December 2027.
# Migration only: deregister the conffiles retired by the network rename. dpkg
# does not drop a conffile that a newer version stopped shipping (it may have
# been dropped by accident), so they linger in `dpkg status` and stay on disk,
# which is exactly what lets a stale config.toml symlink keep resolving.
#
# prior-version is intentionally empty ("tried on every upgrade", see
# dpkg-maintscript-helper(1)): the package mixes release versions (0.93.x) with
# date-based snapshot versions (%Y.%m.%d+build.%H%M%S), and dpkg compares
# 2026 > 0, so no single prior-version covers both directions. These names are
# permanently retired and rm_conffile is a no-op once the file is neither
# registered nor present, so an unconditional attempt is safe.
#
# The same call has to appear in preinstall/postinstall/postuninstall, which is
# how the helper coordinates the steps.
remove_retired_conffiles() {
    # DPKG_MAINTSCRIPT_NAME is set only by dpkg, and is what the helper
    # dispatches on. Testing it (not just the binary) keeps this a no-op when
    # rpm/pacman runs the script on a host that also happens to have dpkg,
    # where the maintainer script arguments mean something else entirely.
    [[ -n ${DPKG_MAINTSCRIPT_NAME:-} ]] || return 0
    command -v dpkg-maintscript-helper >/dev/null 2>&1 || return 0
    local conffile
    for conffile in config-jura.toml config-rotsee.toml config-piz-palu-staging.toml; do
        dpkg-maintscript-helper rm_conffile "/etc/gnosisvpn/$conffile" "" gnosisvpn -- "$@"
    done
}

# Configure ownership and permissions for directories and binaries
configure_filesystem_permissions() {
    # Blokli endpoint precedence: explicit GNOSISVPN_HOPR_BLOKLI_URL, else
    # derived from the selected network (jura-prod when none selected), else a
    # pre-existing/legacy value is preserved below.
    local network_name blokli_url
    network_name="${GNOSISVPN_NETWORK:-jura-prod}"

    # An explicitly requested network may still use a pre-rename name (old docs,
    # a pinned install script). Translate it instead of aborting below, but only
    # when nothing ships under that name, so a future network reusing a retired
    # name would win over the mapping.
    if [[ ! -f /etc/gnosisvpn/config-${network_name}.toml ]]; then
        local requested_successor
        requested_successor="$(retired_network_successor "$network_name")"
        if [[ -n $requested_successor && -f /etc/gnosisvpn/config-${requested_successor}.toml ]]; then
            echo "$LOG_PREFIX INFO: Network '${network_name}' was renamed to '${requested_successor}' — using '${requested_successor}'"
            network_name="$requested_successor"
        fi
    fi

    # Validate the requested network maps to a shipped config before using it to
    # (re)link config.toml or derive the default endpoint. A typo would
    # otherwise create a dangling config.toml symlink and a bogus default URL.
    if [[ ! -f /etc/gnosisvpn/config-${network_name}.toml ]]; then
        echo "$LOG_PREFIX ERROR: Unknown network '${network_name}': /etc/gnosisvpn/config-${network_name}.toml not found" >&2
        local available
        available="$(cd /etc/gnosisvpn 2>/dev/null && ls config-*.toml 2>/dev/null |
            sed 's/^config-//; s/\.toml$//' | paste -sd', ' - || true)"
        echo "$LOG_PREFIX ERROR: Supported networks: ${available:-none}" >&2
        exit 1
    fi

    # Default the Blokli endpoint from the network; honor an explicit override
    # only after validating it. The value is written verbatim into
    # gnosisvpn-dynamic.env, which the root systemd service loads via
    # EnvironmentFile — reject anything that isn't a single-line http(s) URL so
    # a stray newline or space cannot inject extra entries into the root env.
    #
    # Network names are <prefix>-<env> (env is the segment after the last '-',
    # e.g. jura-prod -> prefix=jura env=prod, piz-palu-dev -> prefix=piz-palu
    # env=dev); the Blokli endpoint mirrors that split.
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

    # Fix ownership of configuration files (nfpm may have created them with numeric UID)
    if [[ ! -d /etc/gnosisvpn ]]; then
        mkdir -p /etc/gnosisvpn
    fi
    # Directory is root-owned so the unprivileged 'gnosisvpn' worker cannot
    # replace files loaded by the root service (e.g. gnosisvpn-dynamic.env).
    # 'gnosisvpn' group + 755 keeps read/traverse for the worker.
    chown root:gnosisvpn /etc/gnosisvpn
    chmod 755 /etc/gnosisvpn
    chown gnosisvpn:gnosisvpn /etc/gnosisvpn/*.toml 2>/dev/null || true
    chmod 644 /etc/gnosisvpn/*.toml 2>/dev/null || true

    # Ensure log directory exists with correct permissions
    mkdir -p /var/log/gnosisvpn
    chown -R gnosisvpn:gnosisvpn /var/log/gnosisvpn
    chmod -R 755 /var/log/gnosisvpn

    # Ensure state directory exists with correct permissions
    mkdir -p /var/lib/gnosisvpn
    chown -R gnosisvpn:gnosisvpn /var/lib/gnosisvpn
    chmod -R 775 /var/lib/gnosisvpn

    # Create symlink for current network config. An explicit GNOSISVPN_NETWORK
    # always wins; otherwise a plain upgrade keeps the user's network choice,
    # except when the existing link points at a config this package no longer
    # ships — that is repaired below.
    #
    # The symlink branch must be tested before the "missing" one: -e follows
    # symlinks, so a link whose retired target remove_retired_conffiles just
    # moved aside looks absent, and relinking it straight to the default would
    # silently drop a non-default choice (rotsee) and leave the Blokli endpoint
    # pointing at the pre-rename host.
    local migrated_from="" migrated_blokli_url=""
    if [[ -n ${GNOSISVPN_NETWORK:-} ]]; then
        ln -sf /etc/gnosisvpn/config-"$network_name".toml /etc/gnosisvpn/config.toml
    elif [[ -L /etc/gnosisvpn/config.toml ]]; then
        # Only touch a symlink: a config.toml the admin replaced with a real
        # file is their own, not ours to repoint. Plain readlink (not -f) so the
        # name is still recoverable when the target is already gone.
        local current_network current_successor
        current_network="$(basename "$(readlink /etc/gnosisvpn/config.toml)")"
        current_network="${current_network#config-}"
        current_network="${current_network%.toml}"
        current_successor="$(retired_network_successor "$current_network")"
        # Unknown name whose target is gone (dangling link, or a config dropped
        # without a mapping): fall back to the resolved default rather than
        # leaving the daemon on an unmaintained config. A target that is still
        # shipped is left alone.
        if [[ -z $current_successor && ! -f /etc/gnosisvpn/config-${current_network}.toml ]]; then
            current_successor="$network_name"
        fi
        if [[ -n $current_successor && $current_successor != "$current_network" ]]; then
            if [[ -f /etc/gnosisvpn/config-${current_successor}.toml ]]; then
                echo "$LOG_PREFIX INFO: Re-pointing /etc/gnosisvpn/config.toml: config-${current_network}.toml (no longer shipped) -> config-${current_successor}.toml"
                ln -sf /etc/gnosisvpn/config-"$current_successor".toml /etc/gnosisvpn/config.toml
                migrated_from="$current_network"
                network_name="$current_successor"
                # The Blokli endpoint follows the network. Recomputed with the
                # same <prefix>-<env> split used above; applied further down only
                # if the stored value is still the one we derived pre-rename.
                if [[ -z ${GNOSISVPN_HOPR_BLOKLI_URL:-} ]]; then
                    migrated_blokli_url="https://blokli-${current_successor%-*}.${current_successor##*-}.hoprnet.link"
                fi
            else
                # Don't trade a stale-but-readable config for a dangling symlink.
                echo "$LOG_PREFIX WARNING: /etc/gnosisvpn/config.toml points at config-${current_network}.toml, which this package does not ship, but its replacement config-${current_successor}.toml is missing — leaving the link untouched" >&2
            fi
        fi
    elif [[ ! -e /etc/gnosisvpn/config.toml ]]; then
        # Fresh install.
        ln -sf /etc/gnosisvpn/config-"$network_name".toml /etc/gnosisvpn/config.toml
    fi

    # Write dynamic env overrides to a script-generated file instead of editing
    # gnosisvpn.env: that's a dpkg conffile, and modifying it here triggers an
    # interactive conffile prompt on upgrades (fatal for `curl | sudo bash`).
    local dynamic_env=/etc/gnosisvpn/gnosisvpn-dynamic.env

    # Migration: older postinstalls sed-ed the Blokli URL directly into the
    # gnosisvpn.env conffile. Carry that value over (unless a URL or network
    # is explicitly chosen) so an upgrade keeps the user's endpoint.
    local legacy_url=""
    if [[ -f /etc/gnosisvpn/gnosisvpn.env ]]; then
        legacy_url="$(grep -m1 '^GNOSISVPN_HOPR_BLOKLI_URL=.' /etc/gnosisvpn/gnosisvpn.env || true)"
        legacy_url="${legacy_url#GNOSISVPN_HOPR_BLOKLI_URL=}"
    fi
    if [[ -z ${GNOSISVPN_HOPR_BLOKLI_URL:-} && -z ${GNOSISVPN_NETWORK:-} && ! -f $dynamic_env && -n $legacy_url ]]; then
        blokli_url="$legacy_url"
    fi

    # A retired network was re-pointed above: move the endpoint along with it,
    # otherwise the host runs the new config against a pre-rename Blokli host.
    # Only rewrite when the stored value is still the one the pre-rename
    # postinstall (and pre-rename install/linux.sh) derived — anything else is an
    # operator choice and must survive. Wins over the legacy_url carry-over
    # above, which would otherwise restore the same retired endpoint.
    if [[ -n $migrated_blokli_url ]]; then
        local stored_url=""
        if [[ -f $dynamic_env ]]; then
            stored_url="$(grep -m1 '^GNOSISVPN_HOPR_BLOKLI_URL=' "$dynamic_env" || true)"
            stored_url="${stored_url#GNOSISVPN_HOPR_BLOKLI_URL=}"
        fi
        if [[ -z $stored_url || $stored_url == "https://blokli.${migrated_from}.hoprnet.link" ]]; then
            echo "$LOG_PREFIX INFO: Moving Blokli endpoint with the network: ${stored_url:-<unset>} -> ${migrated_blokli_url}"
            blokli_url="$migrated_blokli_url"
        else
            # Custom endpoint: keep it, and don't let it trigger a rewrite below.
            echo "$LOG_PREFIX INFO: Keeping custom Blokli endpoint ${stored_url} after re-pointing config.toml"
            migrated_blokli_url=""
        fi
    fi

    # Only (re)write on first install or when explicitly overridden, so
    # upgrades keep the user's choice. An explicit network counts as an
    # override: switching networks moves the Blokli endpoint along with it, as
    # does repairing a config.toml that pointed at a retired network.
    if [[ -n ${GNOSISVPN_HOPR_BLOKLI_URL:-} || -n ${GNOSISVPN_NETWORK:-} || -n $migrated_blokli_url || ! -f $dynamic_env ]]; then
        cat >"$dynamic_env" <<EOF
# Generated by GnosisVPN postinstall — do not edit.
# Values here override /etc/gnosisvpn/gnosisvpn.env.
GNOSISVPN_HOPR_BLOKLI_URL=$blokli_url
EOF
    fi

    # Root-owned: this file is loaded by the root systemd service via
    # EnvironmentFile, so it must not be writable by the unprivileged
    # 'gnosisvpn' user (would allow env injection, e.g. LD_PRELOAD, into the
    # root service). 644 lets the service read it. Applied unconditionally so an
    # upgrade also hardens a pre-existing file, not only a freshly written one.
    if [[ -f $dynamic_env ]]; then
        chmod 644 "$dynamic_env"
        chown root:root "$dynamic_env"
    fi

    # Restore the packaged (empty) value in the conffile so it matches dpkg's
    # recorded checksum again and future upgrades stay prompt-free. No-op on
    # clean installs. The dynamic env file above carries the effective URL.
    if [[ -f /etc/gnosisvpn/gnosisvpn.env ]]; then
        sed -i 's|^GNOSISVPN_HOPR_BLOKLI_URL=.\+$|GNOSISVPN_HOPR_BLOKLI_URL=|' /etc/gnosisvpn/gnosisvpn.env
    fi

    # Fix binary ownership and permissions. Cannot be done in nfpm as the user may not exist yet.
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
# Migration only: installs configured before the mirror rename still list the
# retired downloads.vpn.gnosis.eth.limo mirror; a dead mirror fails every
# apt-get update, and register_apt_repo leaves the file untouched in some
# cases (unknown channel, missing keyring, unparseable file), so strip the
# retired URI here first.
remove_legacy_apt_mirror() {
    local legacy_uri="https://downloads.vpn.gnosis.eth.limo/linux/apt"
    local sources_path="/etc/apt/sources.list.d/gnosisvpn.sources"
    [[ -f $sources_path ]] || return 0
    grep -qF "$legacy_uri" "$sources_path" || return 0
    echo "$LOG_PREFIX INFO: Removing retired APT mirror $legacy_uri from $sources_path"
    # Escape the dots so sed matches the URI literally, not as a regex.
    local legacy_uri_re="${legacy_uri//./\\.}"
    sed -i "/^[Uu][Rr][Ii][Ss]:/ s|[[:space:]]*${legacy_uri_re}||g" "$sources_path"
    # The sed only handles inline "URIs: <a> <b>" lists — the only layout our
    # installers write. If the retired URI survived (hand-edited file folding
    # URIs over deb822 continuation lines) or no inline mirror remains (apt
    # rejects an empty URIs: field), drop the file; register_apt_repo below
    # recreates it when possible.
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

    # Channel matches the .deb the user just installed. Any "+" in the version
    # (date-based snapshots, +pr., +commit. builds) means the snapshot channel.
    local version channel component uris
    version="$(cat /etc/gnosisvpn/version.txt 2>/dev/null || echo "")"
    if [[ -z $version ]]; then
        # Without a version we cannot tell which channel this package belongs to.
        # Don't guess (assuming stable could point a snapshot host at the wrong
        # suite): keep any existing source and skip fresh registration.
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
        # Only gnosisvpn.io publishes dists/snapshot/; listing the IPFS mirror
        # here would hard-fail every apt-get update.
        uris="https://download.gnosisvpn.io/linux/apt"
    else
        channel="stable"
        component="main"
        # Both mirrors publish the stable suite (matches install/linux.sh).
        uris="https://download.vpn.gnosis.eth.limo/linux/apt https://download.gnosisvpn.io/linux/apt"
    fi

    # Install the signing key before the "leave as-is" paths below: if a user
    # removed the keyring but kept the sources file, apt-get update would fail
    # on a missing Signed-By key and no upgrade would ever restore it. install(1)
    # is idempotent, so running it on every upgrade is safe.
    if [[ ! -f $keyring_src ]]; then
        echo "$LOG_PREFIX WARNING: Keyring not found at $keyring_src — skipping APT source registration"
        return 0
    fi
    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "$keyring_src" "$keyring_dst"

    if [[ -f $sources_path ]]; then
        # Keep the file when it already tracks this package's channel with the
        # expected mirrors (also preserves the installer-written stable file
        # with both mirrors); rewrite it when the channel disagrees so a manual
        # cross-channel .deb install switches the update path along with the
        # package, or when the mirror list has drifted from canonical.
        local existing_suites existing_uris
        existing_suites="$(awk 'tolower($1) == "suites:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[[:space:]\r]+$/, ""); print; exit }' \
            "$sources_path" 2>/dev/null || true)"
        existing_uris="$(awk 'tolower($1) == "uris:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[[:space:]\r]+$/, ""); print; exit }' \
            "$sources_path" 2>/dev/null || true)"

        if [[ -z $existing_suites ]]; then
            echo "$LOG_PREFIX WARNING: No parseable 'Suites:' line in $sources_path — leaving it untouched"
            return 0
        fi

        # Compare URI sets order-independently so a stale mirror list (e.g. the
        # IPFS mirror pinned to snapshot, which it doesn't publish) is healed
        # even when the suite already matches.
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

# Remove the HOPR identity when explicitly requested (GNOSISVPN_RESET_IDENTITY=true,
# e.g. `sudo env GNOSISVPN_RESET_IDENTITY=true apt install ./gnosisvpn_*.deb`) so the
# service generates a fresh one on its next start. Runs before the service is
# (re)started below; preinstall already stopped a running service, but stop again
# best-effort in case something started it in between.
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

    # Back up the whole config dir (HOPR identity + safe + node db) instead of
    # deleting it; path layout matches gnosis_vpn-lib (dirs.rs: <state
    # home>/.config). The service recreates a fresh one on the next start.
    local config_dir=/var/lib/gnosisvpn/.config
    if [[ -d $config_dir ]]; then
        # Second-granularity timestamps can collide (two resets within the same
        # second, or a leftover backup). Bump a numeric suffix until the path is
        # free, so mv never merges into or fails on an existing dir (fatal under
        # set -e).
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

    # Intentionally leave /etc/gnosisvpn/gnosisvpn-dynamic.env in place. It carries
    # the network's Blokli endpoint (GNOSISVPN_HOPR_BLOKLI_URL), which is network-wide
    # infrastructure and independent of the HOPR identity. The base conffile ships that
    # var empty, so deleting the override here leaves the root service with an empty URL,
    # which clap rejects (exit 2) on the next start. A network switch is handled by
    # configure_filesystem_permissions via --network; identity reset must not touch it.
}

# Enable and start the systemd service
enable_and_start_systemd_service() {
    echo "$LOG_PREFIX INFO: Setting up systemd service..."

    # Reload systemd to pick up the service file
    systemctl daemon-reload || true

    # Enable and start service
    echo "$LOG_PREFIX INFO: Enabling gnosisvpn.service..."
    # Unmask first to ensure we can enable it
    systemctl unmask gnosisvpn.service || true
    systemctl enable gnosisvpn.service || true
    echo "$LOG_PREFIX INFO: Starting gnosisvpn.service..."
    # A prior crash-loop (e.g. the empty-Blokli-URL bug) trips the unit's start
    # limit; without clearing it, this start is rejected with "Start request
    # repeated too quickly" for up to StartLimitIntervalSec after the loop.
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
    # Get the user who ran sudo (or current user if run directly)
    local target_user="${SUDO_USER:-}"

    # If no SUDO_USER, try current USER
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        target_user="${USER:-}"
    fi

    # Still nothing: likely a PackageKit install (App Center / GNOME Software
    # double-click), which runs as root with no sudo context. Fall back to the
    # owner of the active graphical session, best-effort.
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        if command -v loginctl >/dev/null 2>&1; then
            target_user="$(loginctl list-sessions --no-legend 2>/dev/null |
                awk '$3 != "root" && ($4 == "seat0" || $4 == "-") {print $3; exit}' || true)"
        fi
    fi

    # Skip if still no user identified or if root
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        echo "$LOG_PREFIX INFO: No desktop user identified, skipping desktop shortcut"
        return
    fi

    # Get the user's home directory. The loginctl fallback above can yield a
    # user not present in passwd; keep the lookup non-fatal (|| true) so the
    # empty-home check below handles it instead of aborting postinstall under
    # `set -e`/`pipefail`.
    local user_home
    user_home=$(getent passwd "$target_user" | cut -d: -f6) || true

    if [ -z "$user_home" ]; then
        echo "$LOG_PREFIX WARNING: Could not find home directory for user $target_user"
        return
    fi

    local desktop_dir="$user_home/Desktop"

    # Check if Desktop directory exists
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
    # Before configure_filesystem_permissions, so the retired configs are gone
    # when it enumerates the shipped ones.
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

# Run main function. Arguments are forwarded because dpkg-maintscript-helper
# needs the maintainer script parameters (see remove_retired_conffiles).
main "$@"
