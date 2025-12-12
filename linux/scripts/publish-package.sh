#!/bin/bash
#
# Publish Debian source package to repository
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

ENVIRONMENT="${1:-test}"

case "$ENVIRONMENT" in
    test)
        TARGET="mentors"
        ;;
    prod)
        TARGET="ftp-master"
        ;;
    *)
        log_error "Invalid environment: $ENVIRONMENT (must be 'test' or 'prod')"
        exit 1
        ;;
esac

log_info "Looking for .changes file..."

PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && cd .. && pwd)"
CHANGES_FILE=$(ls "${PARENT_DIR}"/gnosisvpn_*_source.changes 2>/dev/null | head -1)

if [[ -z "$CHANGES_FILE" ]]; then
    log_error "No .changes file found in ${PARENT_DIR}"
    log_error "Run 'just package deb <arch>' first"
    exit 1
fi

log_info "Found: $(basename "$CHANGES_FILE")"
log_info "Publishing to $TARGET..."

if dput "$TARGET" "$CHANGES_FILE"; then
    log_success "Package published successfully to ${ENVIRONMENT}!"
else
    log_error "Failed to publish package"
    exit 1
fi

exit 0
