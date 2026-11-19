#!/bin/bash
#
# Gnosis VPN Uninstaller for macOS
#
# This script removes all files installed by the Gnosis VPN installer.
#
# Usage:
#   sudo ./uninstall.sh            # software only; settings, logs and user data stay
#   sudo ./uninstall.sh --purge    # also settings, logs and every user's caches and app data
#
# Identities are never deleted: they are the only key to the user's funds.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PKG_ID="com.gnosisvpn.gnosisvpnclient"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/gnosisvpn"
LOG_DIR="/Library/Logs/GnosisVPN"
SHARE_DIR="/usr/local/share/gnosisvpn"
STATE_DIR="/Library/Application Support/GnosisVPN"
CACHE_DIR="/Library/Caches/GnosisVPN"
APP_ID="com.gnosisvpn.gnosisvpnclient"

PURGE=false
case "${1:-}" in
"") ;;
--purge) PURGE=true ;;
*)
    echo "Usage: sudo $0 [--purge]" >&2
    exit 64
    ;;
esac

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

# Print banner
print_banner() {
    echo "=========================================="
    echo "  Gnosis VPN Uninstaller"
    echo "=========================================="
    echo ""
}

# Confirm uninstallation
confirm_uninstall() {
    echo "This will remove:"
    echo "  - Binaries: $BIN_DIR/gnosis_vpn-root, $BIN_DIR/gnosis_vpn-worker, $BIN_DIR/gnosis_vpn-ctl, $BIN_DIR/gnosis_vpn-update, $BIN_DIR/gnosis_vpn-migrate, $BIN_DIR/gnosis_vpn-manager"
    echo "  - Launchd service: /Library/LaunchDaemons/com.gnosisvpn.gnosisvpnclient.plist"
    echo "  - Log rotation timer: /Library/LaunchDaemons/com.gnosisvpn.newsyslog.plist"
    echo "  - Update downloads: $CACHE_DIR"
    echo "  - Package receipt: $PKG_ID"
    echo ""
    read -p "Are you sure you want to uninstall Gnosis VPN? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
    echo ""

    [[ $PURGE == false ]] || return 0
    echo "Settings, logs and user data stay by default, so a reinstall picks up where you left off:"
    echo "  - Configuration: $CONFIG_DIR/"
    echo "  - Logs: $LOG_DIR"
    echo "  - Installer choices: $STATE_DIR/installer"
    echo "  - Every user's caches, logs and app settings under ~/Library"
    echo "Identities (the keys to your funds) are kept either way."
    echo ""
    read -p "Delete settings, logs and user data as well? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PURGE=true
    fi
    echo ""
}

# Remove launchd service plist (service is already stopped by stop_processes)
remove_launchd_service() {
    log_info "Removing launchd service plist..."

    if [[ -f $PLIST_PATH ]]; then
        rm -f "$PLIST_PATH"
        log_success "Removed launchd service plist: $PLIST_PATH"
    else
        log_info "No launchd service plist found"
    fi
    echo ""
}

# Older installers created this group as the sudoers principal
remove_system_group() {
    log_info "Removing system group..."

    local groupname="gnosisvpn"

    if dscl . -read "/Groups/$groupname" >/dev/null 2>&1; then
        log_info "Found system group: $groupname"

        # Remove all users from the group first
        local members
        members=$(dscl . -read "/Groups/$groupname" GroupMembership 2>/dev/null | cut -d' ' -f2- || echo "")

        if [[ -n $members ]]; then
            log_info "Removing users from group: $members"
            for member in $members; do
                dseditgroup -o edit -d "$member" -t user "$groupname" 2>/dev/null || true
            done
        fi

        # Delete the group
        dscl . -delete "/Groups/$groupname"
        log_success "Removed system group: $groupname"
    else
        log_info "No system group '$groupname' found"
    fi
}

# The single-user layout's service account; the installer leaves it, as deleting it raises macOS 27's admin prompt.
remove_legacy_account() {
    if ! dscl . -read "/Users/gnosisvpn" >/dev/null 2>&1; then
        return 0
    fi
    log_info "Removing the legacy service user 'gnosisvpn'..."
    if dscl . -delete "/Users/gnosisvpn"; then
        log_success "Legacy service user removed"
    else
        log_warn "Could not remove user 'gnosisvpn'; remove it by hand: sudo dscl . -delete /Users/gnosisvpn"
    fi
}

# Clean up system files created for the service; settings, logs and $STATE_DIR stay unless purged
cleanup_system_directories() {
    log_info "Cleaning up system directories..."

    if [[ -d $CACHE_DIR ]]; then
        log_info "Removing directory: $CACHE_DIR"
        rm -rf "$CACHE_DIR"
    fi

    # Remove log rotation timer
    local newsyslog_plist="/Library/LaunchDaemons/com.gnosisvpn.newsyslog.plist"
    if [[ -f $newsyslog_plist ]]; then
        log_info "Removing log rotation timer: $newsyslog_plist"
        launchctl bootout system "$newsyslog_plist" 2>/dev/null || true
        rm -f "$newsyslog_plist"
        log_success "Log rotation timer removed"
    fi

    # Remove log rotation config
    local logrotate_conf="/etc/newsyslog.d/gnosisvpn.conf"
    if [[ -f $logrotate_conf ]]; then
        log_info "Removing log rotation config: $logrotate_conf"
        rm -f "$logrotate_conf"
        log_success "Log rotation config removed"
    fi

    log_success "System directories cleaned up"
    echo ""
}

# Older installers granted passwordless service control here
remove_sudo_privileges() {
    log_info "Removing sudo privileges configuration..."

    local sudoers_file="/etc/sudoers.d/gnosis-vpn"

    if [[ -f $sudoers_file ]]; then
        log_info "Removing sudoers configuration: $sudoers_file"
        rm -f "$sudoers_file"
        log_success "Sudo privileges configuration removed"
    else
        log_info "No sudo privileges configuration found"
    fi
}

# Source shared process-control helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/process-control.sh"

# Stop running processes
stop_processes() {
    log_info "Checking for running Gnosis VPN processes..."
    stop_vpn_service
    stop_ui_app
    echo ""
}

# A deleted config.toml link would hide a replaced network from the next install, which then skips moving identities off it.
remember_linked_network() {
    [[ -L "$CONFIG_DIR/config.toml" ]] || return 0
    local network pending="$STATE_DIR/network-switch-pending" recorded=""
    network="$(basename "$(readlink "$CONFIG_DIR/config.toml")" .toml)"
    if [[ -f $pending && ! -L $pending ]]; then
        IFS= read -r recorded <"$pending" || true
    fi
    case " $recorded " in
    *" $network "*) return 0 ;;
    esac
    # postinstall keeps only replaced networks from this file, so recording a current one is harmless.
    mkdir -p "$STATE_DIR"
    rm -f "$pending"
    echo "${recorded:+$recorded }$network" >"$pending"
    log_info "Recorded network '$network' for the next install's network move"
}

# Identity, pass and PIX state stay: they hold the keys to the user's funds.
purge_user_data() {
    log_info "Removing every user's caches, logs and app data..."

    local home owner
    for home in /Users/*; do
        [[ -d "$home/Library" ]] || continue
        owner="$(stat -f %Su "$home")"
        [[ $owner != "root" ]] || continue
        # As the owner: root must not follow links a user placed in their home.
        if sudo -u "$owner" rm -rf \
            "$home/Library/Caches/GnosisVPN" \
            "$home/Library/Logs/GnosisVPN" \
            "$home/Library/Application Support/$APP_ID" \
            "$home/Library/Caches/$APP_ID" \
            "$home/Library/Logs/$APP_ID" \
            "$home/Library/WebKit/$APP_ID" \
            "$home/Library/HTTPStorages/$APP_ID" \
            "$home/Library/Saved Application State/$APP_ID.savedState" \
            "$home/Library/Preferences/$APP_ID.plist"; then
            log_success "Removed caches, logs and app data of user $owner"
        else
            log_warn "Could not remove all caches, logs and app data of user $owner"
        fi
        # Without it, reused ticket indices get dropped by relays until they catch up; accepted for a purge.
        sudo -u "$owner" find "$home/Library/Application Support/GnosisVPN/networks" -mindepth 2 -maxdepth 2 \
            -type f -name tickets.redb -print -delete 2>/dev/null || true
    done
    echo ""
}

# Backup configuration
backup_config() {
    if [[ -d $CONFIG_DIR ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        local backup_dir="${HOME}/gnosis-vpn-config-backup-${timestamp}"

        log_info "Backing up configuration to: $backup_dir"
        if cp -R "$CONFIG_DIR" "$backup_dir"; then
            log_success "Configuration backed up to $backup_dir"
        else
            log_warn "Failed to backup configuration"
        fi
        echo ""
    fi
}

# Remove binaries
remove_binaries() {
    log_info "Removing binaries..."

    local removed=0

    for binary in "gnosis_vpn-root" "gnosis_vpn-worker" "gnosis_vpn-ctl" "gnosis_vpn-update" "gnosis_vpn-migrate" "gnosis_vpn-manager"; do
        if [[ -f "$BIN_DIR/$binary" ]]; then
            rm -f "$BIN_DIR/$binary"
            log_success "Removed $BIN_DIR/$binary"
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -eq 0 ]]; then
        log_warn "No binaries found to remove"
    fi

    echo ""
}

# Remove UI application
remove_ui_app() {
    log_info "Removing UI application..."

    local ui_app_path="/Applications/Gnosis VPN.app"

    if [[ -d $ui_app_path ]]; then
        log_info "Removing UI app: $ui_app_path"
        rm -rf "$ui_app_path"
        log_success "Removed $ui_app_path"
    fi

    # Clean up LaunchServices registrations for the UI app
    log_info "Cleaning up LaunchServices registrations..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null || true

    echo ""
}

# Remove configuration
remove_config() {
    log_info "Removing configuration..."

    if [[ -d $CONFIG_DIR ]]; then
        rm -rf "$CONFIG_DIR"
        log_success "Removed $CONFIG_DIR"
    else
        log_warn "Configuration directory not found"
    fi

    echo ""
}

# Remove logs
remove_logs() {
    log_info "Removing logs..."
    if [[ -d $LOG_DIR ]]; then
        rm -rf "$LOG_DIR"
        log_success "Removed $LOG_DIR"
    else
        log_warn "Log directory not found"
    fi
    echo ""
}

# Remove the GeoIP database and its notice
remove_geoip_data() {
    log_info "Removing GeoIP database..."
    if [[ ! -d $SHARE_DIR ]]; then
        log_warn "GeoIP directory not found"
        echo ""
        return
    fi
    rm -f "$SHARE_DIR/geoip.mmdb" "$SHARE_DIR/geoip.NOTICE"
    rm -rf "$SHARE_DIR/curvy-zk"
    # Anything else in there is not ours to delete.
    rmdir "$SHARE_DIR" 2>/dev/null || log_warn "Kept non-empty $SHARE_DIR"
    log_success "Removed GeoIP database"
    echo ""
}

# Forget package receipt
forget_package() {
    log_info "Removing package receipt..."

    if pkgutil --pkgs | grep -q "^${PKG_ID}$"; then
        pkgutil --forget "$PKG_ID"
        log_success "Forgot package: $PKG_ID"
    else
        log_warn "Package receipt not found: $PKG_ID"
    fi

    echo ""
}

# Verify uninstallation
verify_uninstall() {
    log_info "Verifying uninstallation..."

    local errors=0

    if [[ -f "$BIN_DIR/gnosis_vpn-root" ]]; then
        log_error "Binary still exists: $BIN_DIR/gnosis_vpn-root"
        errors=$((errors + 1))
    fi

    if [[ -f "$BIN_DIR/gnosis_vpn-worker" ]]; then
        log_error "Binary still exists: $BIN_DIR/gnosis_vpn-worker"
        errors=$((errors + 1))
    fi

    if [[ -f "$BIN_DIR/gnosis_vpn-ctl" ]]; then
        log_error "Binary still exists: $BIN_DIR/gnosis_vpn-ctl"
        errors=$((errors + 1))
    fi

    if [[ -f "$BIN_DIR/gnosis_vpn-update" ]]; then
        log_error "Binary still exists: $BIN_DIR/gnosis_vpn-update"
        errors=$((errors + 1))
    fi

    if [[ -f "$BIN_DIR/gnosis_vpn-migrate" ]]; then
        log_error "Binary still exists: $BIN_DIR/gnosis_vpn-migrate"
        errors=$((errors + 1))
    fi

    if [[ -f "$BIN_DIR/gnosis_vpn-manager" ]]; then
        log_error "Management script still exists: $BIN_DIR/gnosis_vpn-manager"
        errors=$((errors + 1))
    fi

    if [[ -f "/Library/LaunchDaemons/com.gnosisvpn.gnosisvpnclient.plist" ]]; then
        log_error "Launchd service still exists: /Library/LaunchDaemons/com.gnosisvpn.gnosisvpnclient.plist"
        errors=$((errors + 1))
    fi

    if launchctl print system/com.gnosisvpn.gnosisvpnclient >/dev/null 2>&1; then
        log_error "Launchd service is still loaded"
        errors=$((errors + 1))
    fi

    if [[ -f "/Library/LaunchDaemons/com.gnosisvpn.newsyslog.plist" ]]; then
        log_error "Log rotation timer still exists: /Library/LaunchDaemons/com.gnosisvpn.newsyslog.plist"
        errors=$((errors + 1))
    fi

    if [[ $PURGE == true ]]; then
        local dir
        for dir in "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR/installer" /Users/*/Library/Caches/GnosisVPN; do
            if [[ -d $dir ]]; then
                log_error "Directory still exists: $dir"
                errors=$((errors + 1))
            fi
        done
    fi

    for file in "$SHARE_DIR/geoip.mmdb" "$SHARE_DIR/geoip.NOTICE"; do
        if [[ -f $file ]]; then
            log_error "GeoIP file still exists: $file"
            errors=$((errors + 1))
        fi
    done

    if [[ -d "$SHARE_DIR/curvy-zk" ]]; then
        log_error "Curvy proving files still exist: $SHARE_DIR/curvy-zk"
        errors=$((errors + 1))
    fi

    if pkgutil --pkgs | grep -q "^${PKG_ID}$"; then
        log_error "Package receipt still exists: $PKG_ID"
        errors=$((errors + 1))
    fi

    # Check system group removal
    if dscl . -read "/Groups/gnosisvpn" >/dev/null 2>&1; then
        log_error "System group still exists: gnosisvpn"
        errors=$((errors + 1))
    fi

    if dscl . -read "/Users/gnosisvpn" >/dev/null 2>&1; then
        log_error "Legacy service user still exists: gnosisvpn"
        errors=$((errors + 1))
    fi

    if [[ -d $CACHE_DIR ]]; then
        log_error "System directory still exists: $CACHE_DIR"
        errors=$((errors + 1))
    fi

    # Check sudo privileges removal
    if [[ -f "/etc/sudoers.d/gnosis-vpn" ]]; then
        log_error "Sudo privileges configuration still exists: /etc/sudoers.d/gnosis-vpn"
        errors=$((errors + 1))
    fi

    if [[ $errors -eq 0 ]]; then
        log_success "Uninstallation verified successfully"
    else
        log_warn "Uninstallation completed with $errors warning(s)"
    fi

    echo ""
}

# Print summary
print_summary() {
    echo "=========================================="
    echo "  Uninstallation Summary"
    echo "=========================================="
    echo ""
    echo "Gnosis VPN has been uninstalled from your system."
    echo ""
    echo "What was removed:"
    echo "  ✓ Binaries"
    echo "  ✓ UI Application (if installed)"
    echo "  ✓ Launchd service"
    echo "  ✓ System group and legacy user (gnosisvpn)"
    echo "  ✓ Sudo privileges configuration"
    echo "  ✓ GeoIP database"
    echo "  ✓ Curvy proving files"
    echo "  ✓ Update downloads"
    echo "  ✓ Package receipt"
    echo "  ✓ LaunchServices registrations"
    if [[ $PURGE == true ]]; then
        echo "  ✓ Configuration (backed up to ~/gnosis-vpn-config-backup-*)"
        echo "  ✓ Service and installation logs"
        echo "  ✓ Installer choices"
        echo "  ✓ Every user's caches, logs and app data"
    fi
    echo ""
    echo "Left in place:"
    echo "  - Per-user identities: ~/Library/Application Support/GnosisVPN/ (the keys to your funds)"
    echo "  - $STATE_DIR (updater state, legacy identity backups)"
    if [[ $PURGE == false ]]; then
        echo "  - Configuration, logs and every user's app data (remove with: sudo $0 --purge)"
    fi
    echo ""
    echo "To reinstall, download and run the installer again."
    echo "=========================================="
}

# Main uninstallation process
main() {
    print_banner
    check_root
    confirm_uninstall
    stop_processes
    remove_launchd_service
    remove_binaries
    remove_ui_app
    remove_geoip_data
    cleanup_system_directories
    if [[ $PURGE == true ]]; then
        remember_linked_network
        backup_config
        remove_config
        remove_logs
        rm -rf "$STATE_DIR/installer"
        purge_user_data
    fi
    remove_sudo_privileges
    remove_system_group
    remove_legacy_account
    forget_package
    verify_uninstall
    print_summary
}

# Execute main
main

exit 0
