#!/bin/bash
#
# Download binaries for Gnosis VPN packaging
#

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Safe default values
: "${GNOSISVPN_CLI_VERSION:=}"
: "${GNOSISVPN_APP_VERSION:=}"
: "${GNOSISVPN_ARCHITECTURE:=x86_64-linux}"
: "${GNOSISVPN_DISTRIBUTION:=deb}"


# Usage help message
usage() {
    echo "Usage: $0 --cli-version <version> --app-version <version> [options]"
    echo
    echo "Options:"
    echo "  --cli-version <version>        Set the CLI version (e.g., latest, v0.50.7, 0.50.7+pr.465)"
    echo "  --app-version <version>        Set the App version (e.g., latest, v0.2.2, 0.2.2+pr.10)"
    echo "  --architecture <arch>          Set the target architecture (x86_64-linux, x86_64-darwin, aarch64-darwin), default: x86_64-linux"
    echo "  --distribution <type>          Set the distribution type (deb, dmg), default: deb"
    echo "  -h, --help                     Show this help message"
    exit 1
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --cli-version)
            GNOSISVPN_CLI_VERSION="${2:-}"
            if [[ -z $GNOSISVPN_CLI_VERSION ]]; then
                log_error "'--cli-version <version>' requires a value"
                usage
            elif ! check_version_syntax "$GNOSISVPN_CLI_VERSION"; then
                exit 1
            fi
            shift 2
            ;;
        --app-version)
            GNOSISVPN_APP_VERSION="${2:-}"
            if [[ -z $GNOSISVPN_APP_VERSION ]]; then
                log_error "'--app-version <version>' requires a value"
                usage
            elif ! check_version_syntax "$GNOSISVPN_APP_VERSION"; then
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
        -h | --help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
        esac
    done

    if [[ -z $GNOSISVPN_CLI_VERSION ]]; then
        GNOSISVPN_CLI_VERSION=$(get_latest_release "gnosis/gnosis_vpn-client")
        log_info "Parameter '--cli-version' not specified, defaulting to latest release"
    fi

    if [[ -z $GNOSISVPN_APP_VERSION ]]; then
        GNOSISVPN_APP_VERSION=$(get_latest_release "gnosis/gnosis_vpn-app")
        log_info "Parameter '--app-version' not specified, defaulting to latest release"
    fi

    log_success "Command-line arguments parsed successfully"
}

# Clean and prepare build directory
prepare_build_dir() {
    log_info "Preparing build directory..."

    # Clean existing build directory
    if [[ -d ${BUILD_DIR} ]]; then
        log_info "Cleaning existing build directory..."
        rm -rf "${BUILD_DIR}"
    fi

    mkdir -p ${BINARY_DIR}
    chmod 700 "${BINARY_DIR}"

    log_success "Build directory prepared"
}

# Download binaries from GCP
download_linux_binaries() {
    log_info "Downloading binaries from GCP Artifact Registry..."

    for artifact in gnosis_vpn-root gnosis_vpn-worker gnosis_vpn-ctl; do
        gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BINARY_DIR}" \
            "gnosis_vpn:${GNOSISVPN_CLI_VERSION}:${artifact}-${GNOSISVPN_ARCHITECTURE}" --local-filename=${artifact}
        # Set execute permissions on downloaded binaries
        chmod +x "${BINARY_DIR}/${artifact}"
    done

    gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BINARY_DIR}" \
        "gnosis_vpn-app:${GNOSISVPN_APP_VERSION}:gnosis_vpn-app-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}" --local-filename=gnosis_vpn-app.${GNOSISVPN_DISTRIBUTION}

    log_success "All binaries downloaded"
}

download_darwin_binaries() {
log_info "Downloading binaries from GCP Artifact Registry..."

    for artifact in gnosis_vpn-root gnosis_vpn-worker gnosis_vpn-ctl; do
        for arch in aarch64-darwin x86_64-darwin; do
            gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BINARY_DIR}" \
                "gnosis_vpn:${GNOSISVPN_CLI_VERSION}:${artifact}-${arch}" --local-filename=${artifact}-${arch}
        done
        lipo -create -output "${BINARY_DIR}/${artifact}" "${BINARY_DIR}/${artifact}-aarch64-darwin" "${BINARY_DIR}/${artifact}-x86_64-darwin"
        chmod 755 "${BINARY_DIR}/${artifact}"
        lipo -info "${BINARY_DIR}/${artifact}" || true
        echo "Created universal binary for ${artifact}"
    done

    gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BINARY_DIR}" \
        "gnosis_vpn-app:${GNOSISVPN_APP_VERSION}:gnosis_vpn-app-universal-darwin.dmg" --local-filename=gnosis_vpn-app-universal-darwin.dmg

    log_success "All downloads completed"

}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "  Download Summary"
    echo "=========================================="
    echo "Client Version:    ${GNOSISVPN_CLI_VERSION}"
    echo "App Version:       ${GNOSISVPN_APP_VERSION}"
    echo "Distribution:      ${GNOSISVPN_DISTRIBUTION}"
    echo "Architecture:      ${GNOSISVPN_ARCHITECTURE}"
    echo "Build Directory:   ${BUILD_DIR}"
    echo "=========================================="
    echo ""
    echo "Binaries downloaded:"
        ls -lh ${BINARY_DIR}/
    echo ""
}

# Main
main() {
    prepare_build_dir
    if [[ "${GNOSISVPN_ARCHITECTURE}" =~ ^(x86_64-linux)$ ]]; then
        download_linux_binaries
    else
        download_darwin_binaries
    fi
    print_summary
    log_success "🎉 Download completed successfully!"
}

# Execute
parse_args "$@"
main

exit 0
