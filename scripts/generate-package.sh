#!/bin/bash
#
# Build script for Gnosis VPN package
#
# This script creates a linux distributable package (deb, dmg) using nfpm for GitHub releases.
#

set -euo pipefail

# Safe default values
: "${GNOSISVPN_PACKAGE_VERSION:=$(date +%Y.%m.%d+build.%H%M%S)}"
: "${GNOSISVPN_ENABLE_SIGNATURE:=false}"

: "${GNOSISVPN_ARCHITECTURE:=x86_64-linux}"

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"


# shellcheck disable=SC2317
cleanup() {
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]] && [[ -n "${KEYCHAIN_NAME:-}" ]]; then
        security delete-keychain "${KEYCHAIN_NAME}" >/dev/null 2>&1 || true
    fi
}
trap 'cleanup' EXIT INT TERM

usage() {
    echo "Usage: $0 --package-version <version> --distribution <type> --architecture <arch> [--sign] [options]"
    echo
    echo "Options:"
    echo "  -h, --help                     Show this help message"
    echo "  --package-version <version>    Set the package version (e.g., 1.0.0)"
    echo "  --distribution <type>          Set the distribution type (deb, dmg), default: deb"
    echo "  --architecture <arch>          Set the target architecture (x86_64-linux, aarch64-darwin), default: x86_64-linux"
    echo "  --sign                         Enable code signing"
    usage_platform
}

parse_args() {
    local platform_args=()
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
        --sign)
            GNOSISVPN_ENABLE_SIGNATURE=true
            shift
            ;;
        -h | --help)
            usage
            ;;
        *)
            platform_args+=("$1")
            shift
            ;;
        esac
    done

    if [[ -z "${GNOSISVPN_DISTRIBUTION:-}" ]]; then
        GNOSISVPN_DISTRIBUTION="deb"
    fi
    if [[ "${GNOSISVPN_DISTRIBUTION}" == "dmg"  ]] && [[ "$(uname)" == "Darwin" ]]; then
        source "${SCRIPT_DIR}/generate-package-mac.sh"
    else
        source "${SCRIPT_DIR}/generate-package-linux.sh"
    fi

    # Set package names after some args are parsed
    PKG_NAME="$(generate_package_name)"

    if [[ ${#platform_args[@]} -gt 0 ]]; then
        parse_platform_args "${platform_args[@]}"
    else
        parse_platform_args
    fi

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
    print_platform_banner
    echo "=========================================="
    echo ""
}

print_summary() {
    local package_path="${BUILD_DIR}/packages/${PKG_NAME}"
    echo ""
    echo "=========================================="
    echo "  Build Summary"
    echo "=========================================="
    echo "Version:           ${GNOSISVPN_PACKAGE_VERSION}"
    echo "Distribution:      ${GNOSISVPN_DISTRIBUTION}"
    echo "Architecture:      ${GNOSISVPN_ARCHITECTURE}"
    if [[ "${GNOSISVPN_CLI_VERSION:-}" != "" ]]; then
        echo "CLI Version:       ${GNOSISVPN_CLI_VERSION}"
    fi
    if [[ "${GNOSISVPN_APP_VERSION:-}" != "" ]]; then
        echo "App Version:       ${GNOSISVPN_APP_VERSION}"
    fi
    echo "Build Date:        $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    print_platform_summary
    echo "=========================================="
    echo ""
}

main() {
    print_banner
    check_platform_prerequisites
    build_platform_package
    sign_platform_package
    print_summary
    log_success "Package generation completed successfully!"
    echo ""
}

parse_args "$@"
main

exit 0
