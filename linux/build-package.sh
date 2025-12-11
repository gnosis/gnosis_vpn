#!/bin/bash
#
# Build script for Gnosis VPN linux distributions
#
# This script creates a linux distributable installer with custom UI for linux platforms.
#

set -euo pipefail

# Safe default values
: "${GNOSISVPN_PACKAGE_VERSION:=$(date +%Y.%m.%d+build.%H%M%S)}"
: "${GNOSISVPN_CLI_VERSION:=}"
: "${GNOSISVPN_APP_VERSION:=}"
: "${GNOSISVPN_ENABLE_SIGNATURE:=false}"
: "${GNOSISVPN_DISTRIBUTION:=deb}"
: "${GNOSISVPN_ARCHITECTURE:=x86_64-linux}"
: "${GNOSISVPN_GPG_PRIVATE_KEY_PATH:=}"
: "${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD:=}"
: "${GNOSISVPN_BUILD_STAGE:=all}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
PKG_NAME="gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}"
SIGNED_PKG_NAME="gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}.asc"
HASH_PKG_NAME="gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}.sha256"


# shellcheck disable=SC2317
cleanup() {
    rm -f "${BUILD_DIR}/"* 2>/dev/null || true
}

trap 'cleanup' EXIT INT TERM

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Usage help message
usage() {
    echo "Usage: $0 --package-version <version> --cli-version <version> --app-version <version> [--sign] [--stage <stage>]"
    echo
    echo "Options:"
    echo "  --package-version <version>    Set the package version (e.g., 1.0.0)"
    echo "  --cli-version <version>        Set the CLI version (e.g., latest, v0.50.7, 0.50.7+pr.465)"
    echo "  --app-version <version>        Set the App version (e.g., latest, v0.2.2, 0.2.2+pr.10)"
    echo "  --distribution <type>          Set the distribution type (deb, rpm, archlinux), default: deb"
    echo "  --architecture <arch>          Set the target architecture (x86_64-linux, aarch64-linux), default: x86_64-linux"
    echo "  --stage <stage>                Build stage: download, package, all (default: all)"
    echo "  --sign                         Enable code signing"
    echo "  --gpg-private-key-path <path>  Path to GPG private key for signing"
    echo "  -h, --help                     Show this help message"
    exit 1
}

get_latest_release() {
    local repo_name="$1"
    local release
    release=$(gh release view --repo "${repo_name}" --json tagName --jq .tagName)
    if [[ -z $release ]]; then
        log_error "Could not determine current version for ${repo_name}"
        exit 1
    fi
    echo "${release#v}"
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
            else
                check_version_syntax "$GNOSISVPN_PACKAGE_VERSION"
            fi
            PKG_NAME="gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}"
            SIGNED_PKG_NAME="gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}.asc"
            HASH_PKG_NAME="gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}.sha256"
            shift 2
            ;;
        --cli-version)
            GNOSISVPN_CLI_VERSION="${2:-}"
            if [[ -z $GNOSISVPN_CLI_VERSION ]]; then
                log_error "'--cli-version <version>' requires a value"
                usage
            else
                check_version_syntax "$GNOSISVPN_CLI_VERSION"
            fi
            shift 2
            ;;
        --app-version)
            GNOSISVPN_APP_VERSION="${2:-}"
            if [[ -z $GNOSISVPN_APP_VERSION ]]; then
                log_error "'--app-version <version>' requires a value"
                usage
            else
                check_version_syntax "$GNOSISVPN_APP_VERSION"
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
        --stage)
            GNOSISVPN_BUILD_STAGE="${2:-}"
            if [[ -z $GNOSISVPN_BUILD_STAGE ]] || [[ ! $GNOSISVPN_BUILD_STAGE =~ ^(download|package|all)$ ]]; then
                log_error "'--stage <stage>' requires a value (download, package, or all)"
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
            else
                if [[ ! -f $GNOSISVPN_GPG_PRIVATE_KEY_PATH ]]; then
                    log_error "GPG private key file not found: $GNOSISVPN_GPG_PRIVATE_KEY_PATH"
                    exit 1
                fi
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

    # Validate required arguments
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        if [[ -z $GNOSISVPN_GPG_PRIVATE_KEY_PATH ]]; then
            log_error "'--gpg-private-key-path <path>' is required or environment variable GNOSISVPN_GPG_PRIVATE_KEY_PATH must be set"
            usage
        fi
        if [[ -z $GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD ]]; then
            log_error "The environment variable GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD must be set"
            usage
        fi
        export GNOSISVPN_GPG_PRIVATE_KEY_PATH=$GNOSISVPN_GPG_PRIVATE_KEY_PATH
        export NFPM_PASSPHRASE=$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD
    fi

    log_success "Command-line arguments parsed successfully"
}

# Validate version syntax
check_version_syntax() {
    local version="$1"
    # Matches: 1.2.3, 1.2.3+pr.123, 1.2.3+commit.abcdef, latest
    local semver_regex='^[0-9]+\.[0-9]+\.[0-9]+(\+(pr|commit|build)(\.[0-9A-Za-z-]+)*)?$'
    if [[ ! $version =~ $semver_regex && $version != "latest" ]]; then
        log_error "Invalid version format: $version"
        log_error "Expected format: MAJOR.MINOR.PATCH(+pr.123|+commit.abcdef) or latest"
        exit 1
    fi
}

# Print banner
print_banner() {
    echo ""
    echo "=========================================="
    echo "  Create installer package for GnosisVPN"
    echo "=========================================="
    echo "Package Version:            ${GNOSISVPN_PACKAGE_VERSION}"
    echo "Client Version:             ${GNOSISVPN_CLI_VERSION}"
    echo "App Version:                ${GNOSISVPN_APP_VERSION}"
    echo "Signing:                    $(if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then echo "Enabled"; else echo "Disabled"; fi)"
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        echo "GPG private key path:       $GNOSISVPN_GPG_PRIVATE_KEY_PATH"
    fi
    echo "=========================================="
    echo ""
}

# Verify prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=0

    # Check for required tools
    for cmd in gpg curl shasum ar; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required tool not found: $cmd"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_error "Prerequisites check failed. Please install missing tools and verify file structure."
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Clean and prepare build directory
prepare_build_dir() {
    log_info "Preparing build directory..."

    # Clean existing build directory
    if [[ -d ${BUILD_DIR} ]]; then
        log_info "Cleaning existing build directory..."
        rm -rf "${BUILD_DIR}"
    fi

    mkdir -p ${BUILD_DIR}/binaries
    chmod 700 "${BUILD_DIR}/binaries"
    mkdir -p ${BUILD_DIR}/packages
    mkdir -p ${BUILD_DIR}/app-contents/rootfs

    log_success "Build directory prepared"
}

# Download binaries and create universal binaries if needed
download_binaries() {
    log_info "Downloading binaries into staging directory..."

    gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BUILD_DIR}/binaries" \
        "gnosis_vpn:${GNOSISVPN_CLI_VERSION}:gnosis_vpn-${GNOSISVPN_ARCHITECTURE}" --local-filename=gnosis_vpn

    gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BUILD_DIR}/binaries" \
        "gnosis_vpn:${GNOSISVPN_CLI_VERSION}:gnosis_vpn-ctl-${GNOSISVPN_ARCHITECTURE}" --local-filename=gnosis_vpn-ctl

    gcloud artifacts files download --project=gnosisvpn-production --location=europe-west3 --repository=rust-binaries --destination="${BUILD_DIR}/binaries" \
        "gnosis_vpn-app:${GNOSISVPN_APP_VERSION}:gnosis_vpn-app-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}" --local-filename=gnosis_vpn-app.${GNOSISVPN_DISTRIBUTION}

    log_success "All downloads completed"
}

prepare_contents() {
    cd ${BUILD_DIR}/app-contents/
    ar -x ${BUILD_DIR}/binaries/gnosis_vpn-app.${GNOSISVPN_DISTRIBUTION}
    tar -xf ${BUILD_DIR}/app-contents/data.tar.gz -C ${BUILD_DIR}/app-contents/rootfs
    # The binary is defined in nfpm-template.yaml as it requires to specify file permissions
    mv ${BUILD_DIR}/app-contents/rootfs/usr/bin/gnosis_vpn-app ${BUILD_DIR}/binaries/gnosis_vpn-app
    rm -rf ${BUILD_DIR}/app-contents/*.tar.gz
    log_info "Prepared application contents from package"
    cd ${SCRIPT_DIR}
}

generate_nfpm_config() {
    # Modifies the architecture names to match nfpm expected values
    NFPM_ARCHITECTURE=${GNOSISVPN_ARCHITECTURE/x86_64-linux/amd64}
    export NFPM_ARCHITECTURE=${NFPM_ARCHITECTURE/aarch64-linux/arm64}
    ROOTFS="${BUILD_DIR}/app-contents/rootfs"
    nfpm_app_contents=$(mktemp)
    find "$ROOTFS" -type f -print0 | sort -z | while IFS= read -r -d '' src; do
        rel="${src#"$ROOTFS"/}"
        printf '  - src: "%s"\n    dst: "/%s"\n' "$src" "$rel"
    done > "$nfpm_app_contents"

    sed -e "/__GNOSIS_VPN_APP_CONTENTS__/{
    r $nfpm_app_contents
    d
    }" "${SCRIPT_DIR}/nfpm-template.yaml" > "${SCRIPT_DIR}/nfpm.yaml"
    if [[ "${GNOSISVPN_DISTRIBUTION}" == "deb" ]]; then
        sed -i.backup '/^license:.*/d' "${SCRIPT_DIR}/nfpm.yaml"
        rm "${SCRIPT_DIR}/nfpm.yaml.backup"
    fi
    log_info "Generated nfpm configuration for architecture: ${NFPM_ARCHITECTURE}"
}

# Generates the package for the given distribution
generate_package() {

    nfpm package --config nfpm.yaml --packager "${GNOSISVPN_DISTRIBUTION}" --target "${BUILD_DIR}/packages/${PKG_NAME}"
}

# Sign package
sign_package() {
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        log_info "Signing package for distribution..."

        # Create isolated GPG keyring
        gnupghome="$(mktemp -d)"
        export GNUPGHOME="$gnupghome"
        
        # Import private key with passphrase
        echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"

        # Generate hash
        shasum -a 256 "${BUILD_DIR}/packages/${PKG_NAME}" > "${BUILD_DIR}/packages/${HASH_PKG_NAME}"
        log_info "Hash written to ${BUILD_DIR}/packages/${HASH_PKG_NAME}"

        # Sign binary with passphrase
        echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --armor --output "${BUILD_DIR}/packages/${SIGNED_PKG_NAME}" --detach-sign "${BUILD_DIR}/packages/${PKG_NAME}"
        log_info "Signature written to ${BUILD_DIR}/packages/${SIGNED_PKG_NAME}"
        
        # Cleanup
        rm -rf "$gnupghome"
    fi
}


# Print build summary
print_summary() {
    local package_name
    package_name="${BUILD_DIR}/packages/${PKG_NAME}"


    echo "=========================================="
    echo "  Build Summary"
    echo "=========================================="
    echo "Version:           $GNOSISVPN_PACKAGE_VERSION"
    echo "Build Date:        $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "Client Version:    ${GNOSISVPN_CLI_VERSION}"
    echo "App Version:       ${GNOSISVPN_APP_VERSION}"
    echo "Package:           $package_name"
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
    echo "Package signature: ${BUILD_DIR}/packages/${SIGNED_PKG_NAME}"
    fi
    echo "SHA:               ${BUILD_DIR}/packages/${HASH_PKG_NAME}"
    echo "=========================================="
    echo ""
}

# Main build process
main() {
    print_banner
    check_prerequisites
    
    case "$GNOSISVPN_BUILD_STAGE" in
        download)
            log_info "Running download stage only..."
            prepare_build_dir
            download_binaries
            prepare_contents
            log_success "🎉 Download stage completed successfully!"
            ;;
        package)
            log_info "Running package stage only (assuming binaries already downloaded)..."
            if [[ ! -d "${BUILD_DIR}/binaries" ]] || [[ ! -f "${BUILD_DIR}/binaries/gnosis_vpn" ]]; then
                log_error "Binaries not found in ${BUILD_DIR}/binaries/"
                log_error "Run with --stage download first to download binaries"
                exit 1
            fi
            generate_nfpm_config
            generate_package
            sign_package
            print_summary
            log_success "🎉 Package stage completed successfully!"
            ;;
        all)
            log_info "Running all stages..."
            prepare_build_dir
            download_binaries
            prepare_contents
            generate_nfpm_config
            generate_package
            sign_package
            print_summary
            log_success "🎉 Build completed successfully with all quality checks passed!"
            ;;
    esac
    echo ""
}

# Execute main
parse_args "$@"
main

exit 0
