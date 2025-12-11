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

# Generate Debian source package
generate_debian_source() {
    log_info "Generating Debian source package..."
    
    # Check if we're on macOS
    if [[ "$(uname -s)" == "Darwin" ]]; then
        log_error "Debian source packages must be built on Linux"
        echo ""
        echo "Use Docker:"
        echo "  docker run --rm -v \$(pwd):/work -w /work/linux debian:bookworm bash -c '"
        echo "    apt-get update && apt-get install -y dpkg-dev debhelper devscripts just && "
        echo "    ./generate-package.sh --package-version ${GNOSISVPN_PACKAGE_VERSION} --distribution deb"
        echo "  '"
        exit 1
    fi
    
    # Check prerequisites
    if ! command -v dpkg-buildpackage &>/dev/null; then
        log_error "dpkg-buildpackage not found. Install dpkg-dev package."
        exit 1
    fi
    
    # Verify changelog exists (will be used by debian/rules during build)
    if [[ ! -f "${BUILD_DIR}/changelog/changelog" ]]; then
        log_error "Changelog not found at ${BUILD_DIR}/changelog/changelog"
        log_error "Run 'just changelog' first"
        exit 1
    fi
    
    # Build source package
    DEBVERSION="${GNOSISVPN_PACKAGE_VERSION}-1"
    log_info "Building Debian source package version ${DEBVERSION}..."
    dpkg-buildpackage -S -sa -d --no-sign
    
    # Print results
    echo ""
    echo "=========================================="
    echo "  Debian Source Package Created"
    echo "=========================================="
    echo "Version:           ${DEBVERSION}"
    echo "Build Date:        $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "=========================================="
    echo ""
    echo "Files created in parent directory:"
    ls -lh ../gnosisvpn_${DEBVERSION}.* 2>/dev/null || true
    echo ""
    echo "To sign the .changes file:"
    echo "  debsign ../gnosisvpn_${DEBVERSION}_source.changes"
    echo ""
    echo "To upload to Debian:"
    echo "  dput mentors ../gnosisvpn_${DEBVERSION}_source.changes  # For testing"
    echo "  dput ftp-master ../gnosisvpn_${DEBVERSION}_source.changes  # For official upload"
    echo ""
}

# Main
main() {
    case "${GNOSISVPN_DISTRIBUTION}" in
        deb)
            generate_debian_source
            ;;
        *)
            log_error "Unsupported distribution: ${GNOSISVPN_DISTRIBUTION}"
            log_error "Currently only 'deb' is supported"
            exit 1
            ;;
    esac
    
    log_success "🎉 Source package generation completed successfully!"
}

# Execute
parse_args "$@"
main

exit 0
