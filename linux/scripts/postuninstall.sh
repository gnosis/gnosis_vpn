#!/bin/bash
#
# Gnosis VPN Post-Uninstall Script
#
# Cleans up system resources after package removal.
# Preserves user data by default, provides option for complete removal.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#

set -euo pipefail

LOG_PREFIX="[GnosisVPN postuninstall]"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "$LOG_PREFIX ERROR: This script must be run as root" >&2
  exit 1
fi

# Detect package manager
PKG_MANAGER="unknown"
if command -v dpkg >/dev/null 2>&1; then
  PKG_MANAGER="deb"
elif command -v rpm >/dev/null 2>&1; then
  PKG_MANAGER="rpm"
elif command -v pacman >/dev/null 2>&1; then
  PKG_MANAGER="arch"
fi

# Reload systemd after service file removal
echo "$LOG_PREFIX INFO: Reloading systemd daemon..."
deb-systemd-helper daemon-reload || true

# Check if this is a complete purge
IS_PURGE=false
case "$PKG_MANAGER" in
  deb)
    # Debian/Ubuntu: Check DPKG variables or explicit "purge" argument
    if [[ "${1:-}" == "purge" ]] || [[ "${DPKG_MAINTSCRIPT_PACKAGE_REFCOUNT:-1}" == "0" ]]; then
      IS_PURGE=true
    fi
    ;;
  rpm)
    # RPM (RHEL/Fedora): $1 is 0 on full removal, 1+ on upgrade
    if [[ "${1:-1}" == "0" ]]; then
      IS_PURGE=true
    fi
    ;;
  arch)
    # Arch Linux: Always purge on removal
    IS_PURGE=true
    ;;
esac

if [[ "$IS_PURGE" == "true" ]]; then
  echo "$LOG_PREFIX INFO: Performing complete removal (purge)..."
  
  # Remove user data directories
  if [[ -d /var/lib/gnosis_vpn ]]; then
    echo "$LOG_PREFIX INFO: Removing state directory: /var/lib/gnosis_vpn"
    rm -rf /var/lib/gnosis_vpn
  fi
  
  if [[ -d /var/log/gnosis_vpn ]]; then
    echo "$LOG_PREFIX INFO: Removing log directory: /var/log/gnosis_vpn"
    rm -rf /var/log/gnosis_vpn
  fi
  
  # Remove configuration directory (including backups)
  if [[ -d /etc/gnosisvpn ]]; then
    echo "$LOG_PREFIX INFO: Removing configuration directory: /etc/gnosisvpn"
    rm -rf /etc/gnosisvpn
  fi
  
  # Remove logrotate configuration
  if [[ -f /etc/logrotate.d/gnosisvpn ]]; then
    echo "$LOG_PREFIX INFO: Removing logrotate configuration"
    rm -f /etc/logrotate.d/gnosisvpn
  fi
  
  # Remove documentation directory
  if [[ -d /usr/share/doc/gnosisvpn ]]; then
    echo "$LOG_PREFIX INFO: Removing documentation directory: /usr/share/doc/gnosisvpn"
    rm -rf /usr/share/doc/gnosisvpn
  fi
  
  # Remove user and group
  if getent passwd gnosisvpn >/dev/null 2>&1; then
    echo "$LOG_PREFIX INFO: Removing user 'gnosisvpn'..."
    userdel gnosisvpn 2>/dev/null || true
  fi
  
  if getent group gnosisvpn >/dev/null 2>&1; then
    echo "$LOG_PREFIX INFO: Removing group 'gnosisvpn'..."
    groupdel gnosisvpn 2>/dev/null || true
  fi
  
  echo "$LOG_PREFIX SUCCESS: Complete removal finished"
else
  echo "$LOG_PREFIX INFO: Package removed, user data preserved"
  echo "$LOG_PREFIX INFO: Configuration: /etc/gnosisvpn"
  echo "$LOG_PREFIX INFO: State data: /var/lib/gnosis_vpn"
  echo "$LOG_PREFIX INFO: Logs: /var/log/gnosis_vpn"
  
  # Get purge command based on package manager
  case "$PKG_MANAGER" in
    deb)
      echo "$LOG_PREFIX INFO: To completely remove all data, run: apt purge gnosis_vpn"
      ;;
    rpm)
      echo "$LOG_PREFIX INFO: To completely remove all data, run: yum remove gnosis_vpn (or dnf remove)"
      ;;
    arch)
      echo "$LOG_PREFIX INFO: To completely remove all data, run: pacman -R gnosis_vpn (automatic)"
      ;;
  esac
fi

echo "$LOG_PREFIX SUCCESS: Post-uninstall completed successfully"
exit 0
