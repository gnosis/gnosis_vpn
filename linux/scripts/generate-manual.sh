#!/bin/bash
#
# Generate manual pages for GnosisVPN binaries
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

# Generate manual pages
main() {
    # Check if running on macOS
    if [[ "$(uname -s)" == "Darwin" ]]; then
        log_warn "Skipping manual generation on macOS (Linux binaries cannot run natively)"
        log_info "Manual pages will be generated in CI/CD pipeline on Linux"
        mkdir -p ${BUILD_DIR}/man/man1
        # Create empty placeholder files so the build doesn't fail
        touch ${BUILD_DIR}/man/man1/gnosis_vpn.1.gz
        touch ${BUILD_DIR}/man/man1/gnosis_vpn-ctl.1.gz
        touch ${BUILD_DIR}/man/man1/gnosis_vpn-app.1.gz
        log_info "Created placeholder manual page files"
        exit 0
    fi
    
    log_info "Generating manual pages..."
    mkdir -p ${BUILD_DIR}/man/man1
    
    # Generate man page for gnosis_vpn
    if [[ -f "${BUILD_DIR}/binaries/gnosis_vpn" ]]; then
        help2man --no-info \
            --name="GnosisVPN - Daemon" \
            --section=1 \
            --output ${BUILD_DIR}/man/man1/gnosis_vpn.1 \
            ${BUILD_DIR}/binaries/gnosis_vpn
        gzip -9n ${BUILD_DIR}/man/man1/gnosis_vpn.1
        log_success "Generated gnosis_vpn.1.gz"
    else
        log_warn "Binary not found: ${BUILD_DIR}/binaries/gnosis_vpn"
    fi
    
    # Generate man page for gnosis_vpn-ctl
    if [[ -f "${BUILD_DIR}/binaries/gnosis_vpn-ctl" ]]; then
        help2man --no-info \
            --name="GnosisVPN Control - CLI tool for managing GnosisVPN" \
            --section=1 \
            --output ${BUILD_DIR}/man/man1/gnosis_vpn-ctl.1 \
            ${BUILD_DIR}/binaries/gnosis_vpn-ctl
        gzip -9n ${BUILD_DIR}/man/man1/gnosis_vpn-ctl.1
        log_success "Generated gnosis_vpn-ctl.1.gz"
    else
        log_warn "Binary not found: ${BUILD_DIR}/binaries/gnosis_vpn-ctl"
    fi
    
    # Copy and compress man page for gnosis_vpn-app (GUI application)
    if [[ -f "${SCRIPT_DIR}/../resources/gnosis_vpn-app.1" ]]; then
        gzip -9n -c ${SCRIPT_DIR}/../resources/gnosis_vpn-app.1 > ${BUILD_DIR}/man/man1/gnosis_vpn-app.1.gz
        log_success "Generated gnosis_vpn-app.1.gz"
    else
        log_warn "Manual page source not found: ${SCRIPT_DIR}/../resources/gnosis_vpn-app.1"
    fi
    
    log_success "🎉 Manual pages generated and compressed"
}

# Execute
main

exit 0
