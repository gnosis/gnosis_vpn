#!/bin/bash
#
# Shared process-control helpers for Gnosis VPN installer and uninstaller.
#
# Expects the caller to have already defined log_info / log_success / log_warn
# (either from logging.sh or the uninstaller's own colored loggers).
#
# Usage:
#   source "$(dirname "$0")/process-control.sh"
#   stop_ui_app
#   stop_vpn_service          # bootout + kill remaining processes
#

PLIST_PATH="/Library/LaunchDaemons/com.gnosisvpn.gnosisvpnclient.plist"
SERVICE_LABEL="system/com.gnosisvpn.gnosisvpnclient"

# Gracefully stop the Gnosis VPN UI app, escalating from TERM to KILL.
stop_ui_app() {
    if ! pgrep -f "Gnosis VPN" >/dev/null 2>&1; then
        log_info "No running Gnosis VPN UI app found"
        return 0
    fi

    log_info "Stopping Gnosis VPN UI app..."

    pkill -TERM -f "Gnosis VPN" 2>/dev/null || true
    sleep 2

    if pgrep -f "Gnosis VPN" >/dev/null 2>&1; then
        pkill -KILL -f "Gnosis VPN" 2>/dev/null || true
    fi

    log_success "Gnosis VPN UI app stopped"
}

# Stop the launchd service and kill any remaining gnosis_vpn-root processes.
stop_vpn_service() {
    if [[ -f $PLIST_PATH ]] && launchctl print "$SERVICE_LABEL" >/dev/null 2>&1; then
        log_info "Stopping Gnosis VPN launchd service..."
        launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
        sleep 2
    fi

    if pgrep -f gnosis_vpn-root >/dev/null 2>&1; then
        log_warn "Service processes still running, sending TERM..."
        pkill -TERM -f gnosis_vpn-root 2>/dev/null || true
        sleep 2

        if pgrep -f gnosis_vpn-root >/dev/null 2>&1; then
            pkill -KILL -f gnosis_vpn-root 2>/dev/null || true
        fi
    fi

    log_success "Gnosis VPN service stopped"
}
