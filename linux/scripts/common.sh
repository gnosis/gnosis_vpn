#!/bin/bash
#
# Common functions for GnosisVPN packaging scripts
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log_debug() {
    echo -e "${PURPLE}[DEBUG]${NC} $*"
}

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

# Validate version syntax
check_version_syntax() {
    local version="$1"
    # Matches: 1.2.3, 1.2.3+pr.123, 1.2.3+commit.abcdef, latest
    local semver_regex='^[0-9]+\.[0-9]+\.[0-9]+(\+(pr|commit|build)(\.[0-9A-Za-z-]+)*)?$'
    if [[ ! $version =~ $semver_regex && $version != "latest" ]]; then
        log_error "Invalid version format: $version"
        log_error "Expected format: MAJOR.MINOR.PATCH(+pr.123|+commit.abcdef) or latest"
        return 1
    fi
    return 0
}

# Get latest release from GitHub
get_latest_release() {
    local repo_name="$1"
    local release
    release=$(gh release view --repo "${repo_name}" --json tagName --jq .tagName)
    if [[ -z $release ]]; then
        log_error "Could not determine current version for ${repo_name}"
        return 1
    fi
    echo "${release#v}"
}

# Generate package name based on distribution conventions
generate_package_name() {
    local package_version="$1"
    local distribution="$2"
    local architecture="$3"
    local arch_name="${architecture}"
    
    # Convert architecture name based on distribution
    case "${distribution}" in
        deb)
            arch_name="${arch_name/x86_64-linux/amd64}"
            arch_name="${arch_name/aarch64-linux/arm64}"
            echo "gnosisvpn_${package_version}_${arch_name}.deb"
            ;;
        rpm)
            arch_name="${arch_name/x86_64-linux/x86_64}"
            arch_name="${arch_name/aarch64-linux/aarch64}"
            echo "gnosisvpn-${package_version}.${arch_name}.rpm"
            ;;
        archlinux)
            arch_name="${arch_name/x86_64-linux/x86_64}"
            arch_name="${arch_name/aarch64-linux/aarch64}"
            echo "gnosisvpn-${package_version}-${arch_name}.pkg.tar.zst"
            ;;
        *)
            echo "gnosisvpn-${architecture}.${distribution}"
            ;;
    esac
}

# Validate distribution type
validate_distribution() {
    local distribution="$1"
    if [[ ! $distribution =~ ^(deb|rpm|archlinux)$ ]]; then
        log_error "Invalid distribution: $distribution"
        log_error "Valid options: deb, rpm, archlinux"
        return 1
    fi
    return 0
}

# Validate architecture
validate_architecture() {
    local architecture="$1"
    if [[ ! $architecture =~ ^(x86_64-linux|aarch64-linux)$ ]]; then
        log_error "Invalid architecture: $architecture"
        log_error "Valid options: x86_64-linux, aarch64-linux"
        return 1
    fi
    return 0
}
