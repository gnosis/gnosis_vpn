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

# GPG signing variables (from justfile sign recipe)
: "${GNOSISVPN_GPG_PRIVATE_KEY_PATH:=}"
: "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD:=}"
: "${DEBSIGN_KEYID:=}"

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

# Import GPG private key if provided
import_gpg_key() {
    if [[ -n "${GNOSISVPN_GPG_PRIVATE_KEY_PATH}" && -f "${GNOSISVPN_GPG_PRIVATE_KEY_PATH}" ]]; then
        log_info "Importing GPG private key from ${GNOSISVPN_GPG_PRIVATE_KEY_PATH}..."
        
        if [[ -n "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD}" ]]; then
            echo "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD}" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import "${GNOSISVPN_GPG_PRIVATE_KEY_PATH}" 2>&1 | grep -v "already in secret keyring" || true
        else
            gpg --import "${GNOSISVPN_GPG_PRIVATE_KEY_PATH}" 2>&1 | grep -v "already in secret keyring" || true
        fi
        
        log_success "GPG key imported"
    else
        log_info "No GPG key path provided (GNOSISVPN_GPG_PRIVATE_KEY_PATH not set)"
    fi
}

# Sign the Debian package
sign_debian_package() {
    local changes_file="$1"
    
    if ! command -v debsign &>/dev/null; then
        log_warn "debsign not found. Install devscripts package to enable signing."
        log_warn "To sign manually: debsign ${changes_file}"
        return 1
    fi
    
    log_info "Signing package with debsign..."
    
    # Build debsign command
    local sign_cmd="debsign"
    
    # Use DEBSIGN_KEYID if set
    if [[ -n "${DEBSIGN_KEYID}" ]]; then
        log_info "Using GPG key: ${DEBSIGN_KEYID}"
        sign_cmd="debsign -k${DEBSIGN_KEYID}"
    else
        log_info "Using default GPG key (set DEBSIGN_KEYID to specify)"
    fi
    
    # Sign with or without password
    if [[ -n "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD}" ]]; then
        if echo "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD}" | ${sign_cmd} --re-sign "${changes_file}" 2>&1; then
            log_success "Package signed successfully"
            return 0
        fi
    else
        if ${sign_cmd} "${changes_file}" 2>&1; then
            log_success "Package signed successfully"
            return 0
        fi
    fi
    
    log_warn "Package signing failed. You can sign manually with:"
    log_warn "  debsign ${changes_file}"
    log_warn "Or with specific key: debsign -kKEYID ${changes_file}"
    return 1
}

# Generate Debian source package
generate_debian_package() {
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
    
    # Copy changelog (dpkg-buildpackage requires it before build starts)
    if [[ ! -f "${BUILD_DIR}/changelog/changelog" ]]; then
        log_error "Changelog not found at ${BUILD_DIR}/changelog/changelog"
        log_error "Run 'just changelog' first"
        exit 1
    fi
    
    cp "${BUILD_DIR}/changelog/changelog" "${SCRIPT_DIR}/../debian/changelog"
    log_info "Copied changelog to debian/changelog"
    
    # Import GPG key if provided
    import_gpg_key
    
    # Build source package
    log_info "Building Debian source package version ${GNOSISVPN_PACKAGE_VERSION}..."
    dpkg-buildpackage -S -sa -d --no-sign
    
    PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    CHANGES_FILE="../gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.changes"
    
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
    ls -lh ../gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}.* 2>/dev/null | awk '{printf "  %-50s %6s  %s\n", $9, $5, $6" "$7" "$8}' || true
    echo ""
    echo "Files:"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}.dsc          - Package description"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}.tar.xz       - Source tarball"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.changes - Upload control file"
    echo "  • gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.buildinfo - Build metadata"
    echo ""
    echo "Next steps:"
    echo "  1. Test:   dput mentors ../gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.changes"
    echo "  2. Upload: dput ftp-master ../gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_source.changes"
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

# Execute
parse_args "$@"
main

exit 0
