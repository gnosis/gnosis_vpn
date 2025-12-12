#!/bin/bash
#
# Generate source package for distribution repositories
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

# Safe default values
: "${GNOSISVPN_PACKAGE_VERSION:=$(date +%Y.%m.%d+build.%H%M%S)}"
: "${GNOSISVPN_DISTRIBUTION:=deb}"
: "${GNOSISVPN_ARCHITECTURE:=x86_64-linux}"
: "${GNOSISVPN_GPG_PRIVATE_KEY_PATH:=gnosisvpn-private-key.asc}"

# Check prerequisites
check_prerequisites() {
    # Check if we're on macOS
    if [[ "$(uname -s)" == "Darwin" ]]; then
        log_error "Debian source packages must be built on Linux"
        exit 1
    fi

    # Copy changelog (dpkg-buildpackage requires it before build starts)
    if [[ ! -f "${BUILD_DIR}/changelog/changelog" ]]; then
        log_error "Changelog not found at ${BUILD_DIR}/changelog/changelog"
        log_error "Run 'just changelog' first"
        exit 1
    fi

    if [[ ! -f "${GNOSISVPN_GPG_PRIVATE_KEY_PATH}" ]]; then
        log_error "GPG key file not found: ${GNOSISVPN_GPG_PRIVATE_KEY_PATH}"
        exit 1
    fi

    # Required for non-interactive signing
    if [[ -z "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD:-}" ]]; then
        log_error "GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD is required for package signing"
        exit 1
    fi
}

# Usage help message
usage() {
    echo "Usage: $0 --package-version <version> --distribution <type> [options]"
    echo
    echo "Options:"
    echo "  --package-version <version>    Set the package version (e.g., 1.0.0)"
    echo "  --distribution <type>          Distribution type: deb (default: deb)"
    echo "  --architecture <arch>          Target architecture (x86_64-linux, aarch64-linux), default: x86_64-linux"
    echo "  -h, --help                     Show this help message"
    echo
    echo "Supported distributions:"
    echo "  deb        - Debian/Ubuntu source package (.dsc, .tar.gz, .changes)"
    echo
    echo "Note: Debian source packages require Linux environment. Use Docker on macOS."
    exit 1
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --package-version)
            GNOSISVPN_PACKAGE_VERSION="${2:-}"
            if [[ -z $GNOSISVPN_PACKAGE_VERSION ]]; then
                log_error "'--package-version <version>' requires a value"
                usage
            elif ! check_version_syntax "$GNOSISVPN_PACKAGE_VERSION"; then
                exit 1
            fi
            shift 2
            ;;
        --distribution)
            GNOSISVPN_DISTRIBUTION="${2:-}"
            if [[ -z $GNOSISVPN_DISTRIBUTION ]]; then
                log_error "'--distribution <type>' requires a value"
                usage
            fi
            shift 2
            ;;
        --architecture)
            GNOSISVPN_ARCHITECTURE="${2:-}"
            if [[ -z $GNOSISVPN_ARCHITECTURE ]]; then
                log_error "'--architecture <arch>' requires a value"
                usage
            elif ! validate_architecture "$GNOSISVPN_ARCHITECTURE"; then
                exit 1
            fi
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
        esac
    done

    log_success "Command-line arguments parsed successfully"
}

# Setup GPG environment and import key
setup_gpg() {
    # Create temporary GPG home to avoid interfering with existing config
    export GNUPGHOME=$(mktemp -d)
    log_info "Created temporary GPG home: ${GNUPGHOME}"
    
    # Configure gpg-agent for non-interactive signing
    cp "${SCRIPT_DIR}/../resources/gpg-agent.conf" "${GNUPGHOME}/gpg-agent.conf"
    
    # Start gpg-agent
    gpg-agent --homedir "${GNUPGHOME}" --daemon 2>/dev/null || true

    log_info "Importing GPG private key from ${GNOSISVPN_GPG_PRIVATE_KEY_PATH}..."
    echo "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD}" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import "${GNOSISVPN_GPG_PRIVATE_KEY_PATH}" 2>&1 | grep -v "already in secret keyring" || true
    
    log_success "GPG key imported"
}

# Sign the Debian package
sign_debian_package() {
    local changes_file="$1"

    log_info "Signing package with debsign..."

    # Use the GPG wrapper script for debsign
    if DEBSIGN_PROGRAM="${SCRIPT_DIR}/gpg-wrapper.sh" debsign --re-sign "${changes_file}" 2>&1; then
        log_success "Package signed successfully"
    else
        log_warn "Package signing failed"
        exit 1
    fi

}

# Generate Debian source package
generate_debian_package() {
    log_info "Generating Debian source package..."

    cp "${BUILD_DIR}/changelog/changelog" "${SCRIPT_DIR}/../debian/changelog"
    log_info "Copied changelog to debian/changelog"
    
    # Setup GPG environment
    setup_gpg
    
    # Build source package
    log_info "Building Debian source package version ${GNOSISVPN_PACKAGE_VERSION}..."
    cd "${SCRIPT_DIR}/.."
    dpkg-buildpackage -S -sa -d --no-sign
    
    PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && cd .. && pwd)"
    CHANGES_FILE="${PARENT_DIR}/gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.changes"
    
    # Sign the package
    sign_debian_package "${CHANGES_FILE}"
    
    # Print results
    echo ""
    echo "=========================================="
    echo "  Debian Source Package Created"
    echo "=========================================="
    echo "Version:           ${GNOSISVPN_PACKAGE_VERSION}"
    echo "Build Date:        $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "=========================================="
    echo ""
    echo "📦 Generated files in ${PARENT_DIR}:"
    echo ""
    ls -lh ${PARENT_DIR}/gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}.* 2>/dev/null | awk '{printf "  %-50s %6s  %s\n", $9, $5, $6" "$7" "$8}' || true
    echo ""
    echo "Files:"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}.dsc          - Package description"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}.tar.xz       - Source tarball"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.changes - Upload control file"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.buildinfo - Build metadata"
    echo ""
}

# Main
main() {
    case "${GNOSISVPN_DISTRIBUTION}" in
        deb)
            generate_debian_package
            ;;
        *)
            log_error "Unsupported distribution: ${GNOSISVPN_DISTRIBUTION}"
            log_error "Currently only 'deb' is supported"
            exit 1
            ;;
    esac
    
    log_success "🎉 Source package generation completed successfully!"
}

check_prerequisites
parse_args "$@"
main

exit 0
