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

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "$LOG_PREFIX ERROR: This script must be run as root" >&2
  exit 1
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

# Verify kernel module support for WireGuard (dependency installs package, not kernel module)
if ! modinfo wireguard >/dev/null 2>&1; then
  echo "$LOG_PREFIX WARNING: WireGuard kernel module not found"
  echo "$LOG_PREFIX WARNING: You may need to install linux-headers and reboot"
  echo "$LOG_PREFIX WARNING: Or ensure wireguard-dkms is installed"
  # This is a warning, not a fatal error - user might fix it later
fi

echo "$LOG_PREFIX INFO: Pre-installation checks completed successfully"
exit 0
