#!/bin/bash
#
# Build nfpm package for Gnosis VPN
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
    echo "Usage: $0 --package-version <version> [options]"
    echo
    echo "Options:"
    echo "  --package-version <version>    Set the package version (e.g., 1.0.0)"
    echo "  --distribution <type>          Set the distribution type (deb, rpm, archlinux), default: deb"
    echo "  --architecture <arch>          Set the target architecture (x86_64-linux, aarch64-linux), default: x86_64-linux"
    echo "  -h, --help                     Show this help message"
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
            elif ! validate_distribution "$GNOSISVPN_DISTRIBUTION"; then
                exit 1
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

# Check if binaries are available
check_binaries() {
    if [[ ! -d "${BUILD_DIR}/binaries" ]] || [[ ! -f "${BUILD_DIR}/binaries/gnosis_vpn-worker" ]]; then
        log_error "Binaries not found in ${BUILD_DIR}/binaries/"
        log_error "Run download-binaries.sh first to download binaries"
        exit 1
    fi
}

# Generate nfpm configuration
generate_nfpm_config() {
    log_info "Generating nfpm configuration..."
    
    # Modifies the architecture names to match nfpm expected values
    NFPM_ARCHITECTURE=${GNOSISVPN_ARCHITECTURE/x86_64-linux/amd64}
    export NFPM_ARCHITECTURE=${NFPM_ARCHITECTURE/aarch64-linux/arm64}
    ROOTFS="${BUILD_DIR}/app-contents/rootfs"
    
    # Generate app contents list
    nfpm_app_contents=$(mktemp)
    find "$ROOTFS" -type f -print0 | sort -z | while IFS= read -r -d '' src; do
        rel="${src#"$ROOTFS"/}"
        printf '  - src: "%s"\n    dst: "/%s"\n' "$src" "$rel"
    done > "$nfpm_app_contents"

    # Generate nfpm.yaml from template
    sed -e "/__GNOSIS_VPN_APP_CONTENTS__/{
    r $nfpm_app_contents
    d
    }" "${SCRIPT_DIR}/../nfpm-template.yaml" > "${SCRIPT_DIR}/../nfpm.yaml"
    
    # Remove license field for Debian (uses copyright file instead)
    if [[ "${GNOSISVPN_DISTRIBUTION}" == "deb" ]]; then
        sed -i.backup '/^license:.*/d' "${SCRIPT_DIR}/../nfpm.yaml"
        rm "${SCRIPT_DIR}/../nfpm.yaml.backup"
    fi
    
    log_success "Generated nfpm configuration for architecture: ${NFPM_ARCHITECTURE}"
}

# Build package with nfpm
build_package() {
    log_info "Building package with nfpm..."
    
    PKG_NAME="$(generate_package_name "${GNOSISVPN_PACKAGE_VERSION}" "${GNOSISVPN_DISTRIBUTION}" "${GNOSISVPN_ARCHITECTURE}")"
    mkdir -p ${BUILD_DIR}/packages
    
    nfpm package --config "${SCRIPT_DIR}/../nfpm.yaml" --packager "${GNOSISVPN_DISTRIBUTION}" --target "${BUILD_DIR}/packages/${PKG_NAME}"
    
    log_success "Package created: ${BUILD_DIR}/packages/${PKG_NAME}"
}

# Print summary
print_summary() {
    local package_name="${BUILD_DIR}/packages/$(generate_package_name "${GNOSISVPN_PACKAGE_VERSION}" "${GNOSISVPN_DISTRIBUTION}" "${GNOSISVPN_ARCHITECTURE}")"
    
    echo ""
    echo "=========================================="
    echo "  Build Summary"
    echo "=========================================="
    echo "Package Version:   ${GNOSISVPN_PACKAGE_VERSION}"
    echo "Distribution:      ${GNOSISVPN_DISTRIBUTION}"
    echo "Architecture:      ${GNOSISVPN_ARCHITECTURE}"
    echo "Package:           ${package_name}"
    echo "Build Date:        $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "=========================================="
    echo ""
}

# Main
main() {
    check_binaries
    generate_nfpm_config
    build_package
    print_summary
    log_success "🎉 Package build completed successfully!"
}

# Execute
parse_args "$@"
main

exit 0
