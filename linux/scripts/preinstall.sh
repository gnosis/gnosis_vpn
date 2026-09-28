#!/bin/bash
#
# Gnosis VPN Pre-Installation Script
#
# Performs environment checks and prepares system for installation.
# Package manager has already verified all dependencies before running this script.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#

set -euo pipefail

LOG_PREFIX="[GnosisVPN preinstall]"

# Check if running with proper privileges: root - sudo, a root shell, or PackageKit
if [[ $EUID -ne 0 ]]; then
    echo "$LOG_PREFIX ERROR: This script must be run as root" >&2
    echo "$LOG_PREFIX ERROR: Install the package with your package manager (e.g., 'sudo apt install -y ./gnosisvpn_*.deb') or via your software center" >&2
    exit 1
fi

# TODO: remove by December 2027.
# rm_conffile must appear in pre/post/postun to coordinate the dpkg helper; DPKG_MAINTSCRIPT_NAME gates non-dpkg hosts.
if [[ -n ${DPKG_MAINTSCRIPT_NAME:-} ]] && command -v dpkg-maintscript-helper >/dev/null 2>&1; then
    for conffile in config-jura.toml config-rotsee.toml config-piz-palu-staging.toml; do
        dpkg-maintscript-helper rm_conffile "/etc/gnosisvpn/$conffile" "" gnosisvpn -- "$@"
    done
fi

# Stop running service to prevent file conflicts during upgrade
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet gnosisvpn 2>/dev/null; then
        echo "$LOG_PREFIX INFO: Stopping existing gnosisvpn service..."
        deb-systemd-invoke stop gnosisvpn || true
    fi
fi

# Backup existing configuration if modified
if [[ -f /etc/gnosisvpn/config.toml ]]; then
    backup_path="/etc/gnosisvpn/config.toml.backup.$(date +%Y%m%d_%H%M%S)"
    echo "$LOG_PREFIX INFO: Backing up existing configuration to $backup_path"
    cp -a /etc/gnosisvpn/config.toml "$backup_path" || true
fi

# Userspace WireGuard needs the TUN device to create its network interface.
# Present on virtually all systems, but absent on some minimal/container hosts.
if [[ ! -c /dev/net/tun ]]; then
    echo "$LOG_PREFIX WARNING: TUN device /dev/net/tun not found"
    echo "$LOG_PREFIX WARNING: GnosisVPN needs it to create its network interface"
    echo "$LOG_PREFIX WARNING: Load the module with 'sudo modprobe tun' (and ensure it is available after reboot)"
    # This is a warning, not a fatal error - user might fix it later
fi

echo "$LOG_PREFIX INFO: Pre-installation checks completed successfully"
exit 0
