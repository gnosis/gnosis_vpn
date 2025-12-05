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
if systemctl is-active --quiet gnosis_vpn.service 2>/dev/null; then
  echo "$LOG_PREFIX INFO: Stopping gnosis_vpn.service service..."
  if systemctl stop gnosis_vpn.service; then
    echo "$LOG_PREFIX SUCCESS: Service stopped successfully"
  else
    echo "$LOG_PREFIX WARNING: Failed to stop service gracefully, forcing stop..."
    systemctl kill gnosis_vpn.service 2>/dev/null || true
  fi
fi

# Disable service
if systemctl is-enabled --quiet gnosis_vpn.service 2>/dev/null; then
  echo "$LOG_PREFIX INFO: Disabling gnosis_vpn.service service..."
  systemctl disable gnosis_vpn.service || true
  echo "$LOG_PREFIX SUCCESS: Service disabled successfully"
fi

# Kill any remaining gnosis_vpn processes
if pgrep -x gnosis_vpn >/dev/null 2>&1; then
  echo "$LOG_PREFIX INFO: Terminating remaining gnosis_vpn processes..."
  pkill -TERM -x gnosis_vpn || true
  sleep 2
  
  # Force kill if still running
  if pgrep -x gnosis_vpn >/dev/null 2>&1; then
    echo "$LOG_PREFIX WARNING: Force killing remaining processes..."
    pkill -KILL -x gnosis_vpn || true
  fi
fi

echo "$LOG_PREFIX SUCCESS: Pre-uninstall completed successfully"
exit 0
