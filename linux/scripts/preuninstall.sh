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

# Stop service
if systemctl is-active --quiet gnosisvpn.service 2>/dev/null; then
  echo "$LOG_PREFIX INFO: Stopping gnosisvpn.service service..."
  if deb-systemd-invoke stop gnosisvpn.service; then
    echo "$LOG_PREFIX SUCCESS: Service stopped successfully"
  else
    echo "$LOG_PREFIX WARNING: Failed to stop service gracefully, forcing stop..."
    deb-systemd-invoke kill gnosisvpn.service || true
  fi
fi

# Disable service
if systemctl is-enabled --quiet gnosisvpn.service 2>/dev/null; then
  echo "$LOG_PREFIX INFO: Disabling gnosisvpn.service service..."
  deb-systemd-helper disable gnosisvpn.service || true
  echo "$LOG_PREFIX SUCCESS: Service disabled successfully"
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
