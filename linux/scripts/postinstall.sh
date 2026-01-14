#!/bin/bash
#
# Gnosis VPN Post-Installation Script
#
# Creates system user/group and configures the service after files are installed.
# Compatible with: deb (apt/dpkg), rpm (yum/dnf), archlinux (pacman)
#

set -euo pipefail

LOG_PREFIX="[GnosisVPN postinstall]"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "$LOG_PREFIX ERROR: This script must be run as root" >&2
  exit 1
fi

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

# Configure ownership and permissions for directories and binaries
configure_filesystem_permissions() {
    echo "$LOG_PREFIX INFO: Setting up directory permissions..."
    
    # Fix ownership of configuration files (nfpm may have created them with numeric UID)
    if [[ ! -d /etc/gnosisvpn ]]; then
        mkdir -p /etc/gnosisvpn
    fi
    chown gnosisvpn:gnosisvpn /etc/gnosisvpn
    chmod 755 /etc/gnosisvpn
    chown gnosisvpn:gnosisvpn /etc/gnosisvpn/*.toml 2>/dev/null || true
    chmod 644 /etc/gnosisvpn/*.toml 2>/dev/null || true

    # Ensure log directory exists with correct permissions
    if [[ ! -d /var/log/gnosisvpn ]]; then
        mkdir -p /var/log/gnosisvpn
    fi
    chown gnosisvpn:gnosisvpn /var/log/gnosisvpn
    chmod 750 /var/log/gnosisvpn
    # Ensure state directory exists with correct permissions
    if [[ ! -d /var/lib/gnosisvpn ]]; then
        mkdir -p /var/lib/gnosisvpn
    fi
    chown gnosisvpn:gnosisvpn /var/lib/gnosisvpn
    chmod 750 /var/lib/gnosisvpn

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

# Enable and start the systemd service
enable_and_start_systemd_service() {
    echo "$LOG_PREFIX INFO: Setting up systemd service..."
    
    # Reload systemd to pick up the service file
    deb-systemd-helper daemon-reload

    # Enable and start service
    echo "$LOG_PREFIX INFO: Enabling gnosisvpn.service..."
    deb-systemd-helper enable gnosisvpn.service

    echo "$LOG_PREFIX INFO: Starting gnosisvpn.service..."
    deb-systemd-invoke start gnosisvpn.service

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
    local target_user="$SUDO_USER"
    
    # If no SUDO_USER, try current USER
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        target_user="$USER"
    fi
    
    # Skip if still no user identified or if root
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        echo "$LOG_PREFIX INFO: No desktop user identified, skipping desktop shortcut"
        return
    fi
    
    # Get the user's home directory
    local user_home
    user_home=$(getent passwd "$target_user" | cut -d: -f6)
    
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
    
    local desktop_file="Gnosis VPN.desktop"
    local dest_file="$desktop_dir/$desktop_file"
    
    # Copy the desktop file to the user's Desktop
    if ! cp "/usr/share/applications/$desktop_file" "$dest_file" 2>/dev/null; then
        echo "$LOG_PREFIX WARNING: Failed to copy desktop file"
        return
    fi
    
    # Make it executable (required for desktop shortcuts)
    chmod +x "$dest_file"
    chown "$target_user":"$target_user" "$dest_file"
    
    # Try to mark as trusted if tools are available (optional, not in dependencies)
    local trusted_set=false
    if command -v gio >/dev/null 2>&1; then
        if sudo -u "$target_user" gio set "$dest_file" metadata::trusted true 2>/dev/null; then
            trusted_set=true
        fi
    elif command -v gvfs-set-attribute >/dev/null 2>&1; then
        if sudo -u "$target_user" gvfs-set-attribute "$dest_file" metadata::trusted true 2>/dev/null; then
            trusted_set=true
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
    configure_filesystem_permissions
    enable_and_start_systemd_service
    install_desktop_shortcut_for_user
    
    echo "$LOG_PREFIX SUCCESS: Post-installation completed successfully"
}

# Run main function
main