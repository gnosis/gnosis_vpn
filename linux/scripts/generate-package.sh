#!/bin/bash
#
# Build script for Gnosis VPN linux distributions using nfpm
#
# This script creates a linux distributable package (deb, rpm, archlinux)
# using nfpm for GitHub releases.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"
BINARY_DIR="${BUILD_DIR}/download"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

# Safe default values
: "${GNOSISVPN_PACKAGE_VERSION:=$(date +%Y.%m.%d+build.%H%M%S)}"
: "${GNOSISVPN_ENABLE_SIGNATURE:=false}"
: "${GNOSISVPN_DISTRIBUTION:=deb}"
: "${GNOSISVPN_ARCHITECTURE:=x86_64-linux}"
: "${GNOSISVPN_GPG_PRIVATE_KEY_PATH:=./gnosisvpn-private-key.asc}"
: "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD:=}"

generate_package_name() {
    local arch_name="${GNOSISVPN_ARCHITECTURE}"
    case "${GNOSISVPN_DISTRIBUTION}" in
        deb)
            arch_name="${arch_name/x86_64-linux/amd64}"
            arch_name="${arch_name/aarch64-linux/arm64}"
            echo "gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_${arch_name}.deb"
            ;;
        rpm)
            arch_name="${arch_name/x86_64-linux/x86_64}"
            arch_name="${arch_name/aarch64-linux/aarch64}"
            echo "gnosisvpn-${GNOSISVPN_PACKAGE_VERSION}.${arch_name}.rpm"
            ;;
        archlinux)
            arch_name="${arch_name/x86_64-linux/x86_64}"
            arch_name="${arch_name/aarch64-linux/aarch64}"
            echo "gnosisvpn-${GNOSISVPN_PACKAGE_VERSION}-${arch_name}.pkg.tar.zst"
            ;;
        *)
            echo "gnosisvpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}"
            ;;
    esac
}

usage() {
    echo "Usage: $0 --package-version <version> --distribution <type> --architecture <arch> [--sign] [options]"
    echo
    echo "Options:"
    echo "  --package-version <version>    Set the package version (e.g., 1.0.0)"
    echo "  --distribution <type>          Set the distribution type (deb, rpm, archlinux), default: deb"
    echo "  --architecture <arch>          Set the target architecture (x86_64-linux, aarch64-linux), default: x86_64-linux"
    echo "  --sign                         Enable code signing"
    echo "  --gpg-private-key-path <path>  Path to GPG private key for signing"
    echo "  -h, --help                     Show this help message"
    echo
    echo "Note: Assumes binaries, changelog, and manual pages already exist in build directory."
    echo "      Run 'just download', 'just changelog', and 'just manual' first if needed."
    exit 1
}

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
            if [[ -z $GNOSISVPN_DISTRIBUTION ]] || [[ ! $GNOSISVPN_DISTRIBUTION =~ ^(deb|rpm|archlinux)$ ]]; then
                log_error "'--distribution <type>' requires a value (deb, rpm, or archlinux)"
                usage
            fi
            shift 2
            ;;
        --architecture)
            GNOSISVPN_ARCHITECTURE="${2:-}"
            if [[ -z $GNOSISVPN_ARCHITECTURE ]] || [[ ! $GNOSISVPN_ARCHITECTURE =~ ^(x86_64-linux|aarch64-linux)$ ]]; then
                log_error "'--architecture <arch>' requires a value (x86_64-linux or aarch64-linux)"
                usage
            fi
            shift 2
            ;;
        --sign)
            GNOSISVPN_ENABLE_SIGNATURE=true
            shift
            ;;
        --gpg-private-key-path)
            GNOSISVPN_GPG_PRIVATE_KEY_PATH="${2:-}"
            if [[ -z $GNOSISVPN_GPG_PRIVATE_KEY_PATH ]]; then
                log_error "'--gpg-private-key-path <path>' requires a value"
                usage
            elif [[ ! -f $GNOSISVPN_GPG_PRIVATE_KEY_PATH ]]; then
                log_error "GPG private key file not found: $GNOSISVPN_GPG_PRIVATE_KEY_PATH"
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

    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        if [[ -z $GNOSISVPN_GPG_PRIVATE_KEY_PATH ]]; then
            log_error "'--gpg-private-key-path <path>' is required when --sign is enabled, or set GNOSISVPN_GPG_PRIVATE_KEY_PATH environment variable"
            usage
        fi
        if [[ -z $GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD ]]; then
            log_error "The environment variable GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD must be set when --sign is enabled"
            usage
        fi
        export GNOSISVPN_GPG_PRIVATE_KEY_PATH=$GNOSISVPN_GPG_PRIVATE_KEY_PATH
        export NFPM_PASSPHRASE=$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD
    fi
    # Set package names after all args are parsed
    PKG_NAME="$(generate_package_name)"
    SIGNED_PKG_NAME="${PKG_NAME}.asc"
    HASH_PKG_NAME="${PKG_NAME}.sha256"
    log_success "Command-line arguments parsed successfully"
}

print_banner() {
    echo ""
    echo "=========================================="
    echo "  Create package for GnosisVPN"
    echo "=========================================="
    echo "Package Version:            ${GNOSISVPN_PACKAGE_VERSION}"
    echo "Distribution:               ${GNOSISVPN_DISTRIBUTION}"
    echo "Architecture:               ${GNOSISVPN_ARCHITECTURE}"
    echo "Signing:                    $(if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then echo "Enabled"; else echo "Disabled"; fi)"
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        echo "GPG private key path:       $GNOSISVPN_GPG_PRIVATE_KEY_PATH"
    fi
    echo "=========================================="
    echo ""
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing=0
    if [[ ! -d "${BINARY_DIR}" ]] || [[ ! -f "${BINARY_DIR}/gnosis_vpn-root" ]]; then
        log_error "Binaries not found in ${BINARY_DIR}/"
        log_error "Run 'just download ${GNOSISVPN_DISTRIBUTION} ${GNOSISVPN_ARCHITECTURE}' first"
        missing=$((missing + 1))
    fi
    if [[ ! -f "${BUILD_DIR}/changelog/changelog.gz" ]]; then
        log_error "Changelog not found at ${BUILD_DIR}/changelog/changelog.gz"
        log_error "Run 'just changelog' first"
        missing=$((missing + 1))
    fi
    if [[ ! -f "${BUILD_DIR}/man/man1/gnosis_vpn-worker.1.gz" ]]; then
        log_error "Manual page not found: ${BUILD_DIR}/man/man1/gnosis_vpn-worker.1.gz"
        log_error "Run 'just manual' first"
        missing=$((missing + 1))
    fi
    if [[ ! -f "${BUILD_DIR}/man/man1/gnosis_vpn-root.1.gz" ]]; then
        log_error "Manual page not found: ${BUILD_DIR}/man/man1/gnosis_vpn-root.1.gz"
        log_error "Run 'just manual' first"
        missing=$((missing + 1))
    fi
    if [[ ! -f "${BUILD_DIR}/man/man1/gnosis_vpn-ctl.1.gz" ]]; then
        log_error "Manual page not found: ${BUILD_DIR}/man/man1/gnosis_vpn-ctl.1.gz"
        log_error "Run 'just manual' first"
        missing=$((missing + 1))
    fi
    if [[ ! -f "${BUILD_DIR}/man/man1/gnosis_vpn-app.1.gz" ]]; then
        log_error "Manual page not found: ${BUILD_DIR}/man/man1/gnosis_vpn-app.1.gz"
        log_error "Run 'just manual' first"
        missing=$((missing + 1))
    fi
    if [[ $missing -gt 0 ]]; then
        log_error "Prerequisites check failed. Please install missing tools and run prerequisite steps."
        exit 1
    fi
    log_success "Prerequisites check passed"
}

prepare_app_contents() {
    log_info "Preparing application contents from package..."
    local app_contents_dir="${BUILD_DIR}/app-contents"
    local rootfs_dir="${app_contents_dir}/rootfs"
    rm -rf "${app_contents_dir}"
    mkdir -p "${rootfs_dir}"
    cd "${app_contents_dir}"
    ar -x "${BINARY_DIR}/gnosis_vpn-app.${GNOSISVPN_DISTRIBUTION}"
    tar -xf "${app_contents_dir}/data.tar.gz" -C "${rootfs_dir}"

    mkdir -p "${BINARY_DIR}"
    mv "${rootfs_dir}/usr/bin/gnosis_vpn-app" "${BUILD_DIR}/gnosis_vpn-app"
    strip "${BUILD_DIR}/gnosis_vpn-app"
    rm -rf "${app_contents_dir}"/*.tar.gz
    log_success "Prepared application contents from package"
    cd "${SCRIPT_DIR}/.."
}

generate_nfpm_config() {
    log_info "Generating nfpm configuration..."
    local nfpm_arch="${GNOSISVPN_ARCHITECTURE/x86_64-linux/amd64}"
    nfpm_arch="${nfpm_arch/aarch64-linux/arm64}"
    export NFPM_ARCHITECTURE="${nfpm_arch}"
    # Always use absolute path for rootfs
    local rootfs
    rootfs="$(cd "${BUILD_DIR}/app-contents/rootfs" && pwd)"
    local nfpm_app_contents
    nfpm_app_contents=$(mktemp)
    find "$rootfs" -type f -print0 | sort -z | while IFS= read -r -d '' src; do
        local rel="${src#"$rootfs"/}"
        printf '  - src: "%s"\n    dst: "/%s"\n' "$src" "$rel"
    done > "$nfpm_app_contents"
    sed -e "/__GNOSIS_VPN_APP_CONTENTS__/{
    r $nfpm_app_contents
    d
    }" "${SCRIPT_DIR}/../nfpm-template.yaml" > "${SCRIPT_DIR}/../nfpm.yaml"
    if [[ "${GNOSISVPN_DISTRIBUTION}" == "deb" ]]; then
        sed -i.backup '/^license:.*/d' "${SCRIPT_DIR}/../nfpm.yaml"
        rm -f "${SCRIPT_DIR}/../nfpm.yaml.backup"
    fi
    rm -f "$nfpm_app_contents"
    log_success "Generated nfpm configuration for ${GNOSISVPN_DISTRIBUTION} (${nfpm_arch})"
}

generate_package() {
    log_info "Generating ${GNOSISVPN_DISTRIBUTION} package..."
    mkdir -p "${BUILD_DIR}/packages"
    nfpm package \
        --config "${SCRIPT_DIR}/../nfpm.yaml" \
        --packager "${GNOSISVPN_DISTRIBUTION}" \
        --target "${BUILD_DIR}/packages/${PKG_NAME}"
    log_success "Package created: ${BUILD_DIR}/packages/${PKG_NAME}"
}

sign_package() {
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        log_info "Signing package..."
        local gnupghome
        gnupghome="$(mktemp -d)"
        export GNUPGHOME="$gnupghome"
        echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" | \
            gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
            --import "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"
        log_info "GPG private key imported into temporary keyring"
        shasum -a 256 "${BUILD_DIR}/packages/${PKG_NAME}" > "${BUILD_DIR}/packages/${HASH_PKG_NAME}"
        log_success "Hash written to ${BUILD_DIR}/packages/${HASH_PKG_NAME}"
        echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" | \
            gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
            --armor --output "${BUILD_DIR}/packages/${SIGNED_PKG_NAME}" \
            --detach-sign "${BUILD_DIR}/packages/${PKG_NAME}"
        log_success "Detached signature written to ${BUILD_DIR}/packages/${SIGNED_PKG_NAME}"
        rm -rf "$gnupghome"
    fi
}

print_summary() {
    local package_path="${BUILD_DIR}/packages/${PKG_NAME}"
    echo ""
    echo "=========================================="
    echo "  Build Summary"
    echo "=========================================="
    echo "Version:           $GNOSISVPN_PACKAGE_VERSION"
    echo "Distribution:      $GNOSISVPN_DISTRIBUTION"
    echo "Architecture:      $GNOSISVPN_ARCHITECTURE"
    echo "Build Date:        $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "Package:           $package_path"
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        echo "Package signature: ${BUILD_DIR}/packages/${SIGNED_PKG_NAME}"
        echo "SHA256:            ${BUILD_DIR}/packages/${HASH_PKG_NAME}"
    fi
    echo "=========================================="
    echo ""
}

main() {
    print_banner
    check_prerequisites
    prepare_app_contents
    generate_nfpm_config
    generate_package
    sign_package
    print_summary
    log_success "Package generation completed successfully!"
    echo ""
}

parse_args "$@"
main

exit 0
