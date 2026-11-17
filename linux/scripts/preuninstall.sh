#!/bin/bash
#
# Gnosis VPN Pre-Uninstall Script
#
# Stops the service and prepares system for package removal.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#

set -euo pipefail

LOG_PREFIX="[GnosisVPN preuninstall]"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "$LOG_PREFIX ERROR: This script must be run as root" >&2
    exit 1
fi

# rpm runs the old %preun after the new %post on upgrade ($1 >= 1); stopping here would kill the new service.
if [[ ${1:-} =~ ^[0-9]+$ && $1 -ge 1 ]]; then
    exit 0
fi

# deb-systemd-* honour policy-rc.d and dpkg's enable state on Debian; rpm/pacman hosts only have systemctl.
SYSTEMD_INVOKE=systemctl
SYSTEMD_HELPER=systemctl
command -v deb-systemd-invoke >/dev/null 2>&1 && SYSTEMD_INVOKE=deb-systemd-invoke
command -v deb-systemd-helper >/dev/null 2>&1 && SYSTEMD_HELPER=deb-systemd-helper

# Stop service
if systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
    echo "$LOG_PREFIX INFO: Stopping gnosisvpn.service service..."
    if "$SYSTEMD_INVOKE" stop gnosisvpn.service; then
        echo "$LOG_PREFIX SUCCESS: Service stopped successfully"
    else
        echo "$LOG_PREFIX WARNING: Failed to stop service gracefully, forcing stop..."
        "$SYSTEMD_INVOKE" kill gnosisvpn.service || true
    fi
fi

# Disable service
if systemctl is-enabled --quiet gnosisvpn.service 2>/dev/null; then
    echo "$LOG_PREFIX INFO: Disabling gnosisvpn.service service..."
    "$SYSTEMD_HELPER" disable gnosisvpn.service || true
    echo "$LOG_PREFIX SUCCESS: Service disabled successfully"
fi

# Stop log rotation timer and any logrotate run it has in flight
for unit in gnosisvpn-logrotate.timer gnosisvpn-logrotate.service; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "$LOG_PREFIX INFO: Stopping $unit..."
        "$SYSTEMD_INVOKE" stop "$unit" || true
    fi
done
if systemctl is-enabled --quiet gnosisvpn-logrotate.timer 2>/dev/null; then
    echo "$LOG_PREFIX INFO: Disabling gnosisvpn-logrotate.timer..."
    "$SYSTEMD_HELPER" disable gnosisvpn-logrotate.timer || true
fi

# Kill any remaining gnosisvpn processes
if pgrep -x gnosis_vpn-root >/dev/null 2>&1; then
    echo "$LOG_PREFIX INFO: Terminating remaining gnosis_vpn-root processes..."
    pkill -TERM -x gnosis_vpn-root || true
    sleep 5

    # Force kill if still running
    if pgrep -x gnosis_vpn-root >/dev/null 2>&1; then
        echo "$LOG_PREFIX WARNING: Force killing remaining processes..."
        pkill -KILL -x gnosis_vpn-root || true
    fi
fi

echo "$LOG_PREFIX SUCCESS: Pre-uninstall completed successfully"
exit 0
