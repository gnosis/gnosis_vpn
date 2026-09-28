#!/bin/bash
#
# Common functions for GnosisVPN packaging scripts
#

export BUILD_DIR="${SCRIPT_DIR}/../build"
export BINARY_DIR="${BUILD_DIR}/download"

# GCP Artifact Registry coordinates for client/app/toolkit binaries.
# gcloud reads these instead of per-call --project/--location/--repository
# flags. Process-scoped, unlike `gcloud config set`, which would persistently
# rewrite the operator's global gcloud configuration.
export CLOUDSDK_CORE_PROJECT="gnosisvpn-production"
export CLOUDSDK_ARTIFACTS_LOCATION="europe-west3"
export CLOUDSDK_ARTIFACTS_REPOSITORY="rust-binaries"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Validate version syntax
check_version_syntax() {
    local version="$1"
    # Matches 1.2.3, v1.2.3, +pr.123, +commit.abcdef, +build.020000[.experimental] and latest.
    local semver_regex='^v?[0-9]+\.[0-9]+\.[0-9]+(\+(pr|commit|build)(\.[0-9A-Za-z-]+)*)?$'
    if [[ ! $version =~ $semver_regex && $version != "latest" ]]; then
        log_error "Invalid version format: $version"
        log_error "Expected format: MAJOR.MINOR.PATCH(+pr.123|+commit.abcdef|+build.020000[.experimental]) or latest"
        return 1
    fi
    return 0
}

# Validate a space-separated network list: the names become filenames, choice-package ids and XML/YAML values.
validate_network_names() {
    local networks="$1" network ok=0
    if [[ -z ${networks// /} ]]; then
        log_error "No networks given (GNOSISVPN_NETWORKS is empty)"
        return 1
    fi
    for network in $networks; do
        if [[ ! $network =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            log_error "Invalid network name: '${network}'"
            log_error "Network names must be lowercase alphanumerics and hyphens, e.g. 'piz-palu-dev'"
            ok=1
        fi
    done
    return $ok
}

# Numeric MAJOR.MINOR.PATCH before any "+metadata", leading "v" stripped: "v0.96.1+pr.772" -> 0.96.1.
version_core() {
    local v="${1#v}"
    printf '%s\n' "${v%%+*}"
}

# True when the core is exactly three numeric components; the comparators below require it.
version_core_is_numeric() {
    [[ "$(version_core "$1")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Prints -1 / 0 / 1 comparing numeric cores. Pure bash for macOS 3.2; 10# forces base 10 so "09" is not octal.
version_core_cmp() {
    local a b a1 a2 a3 b1 b2 b3 rest pair x y
    a="$(version_core "$1")"
    b="$(version_core "$2")"
    IFS=. read -r a1 a2 a3 rest <<<"$a"
    IFS=. read -r b1 b2 b3 rest <<<"$b"
    for pair in "${a1:-0}:${b1:-0}" "${a2:-0}:${b2:-0}" "${a3:-0}:${b3:-0}"; do
        x="${pair%%:*}"
        y="${pair##*:}"
        if ((10#$x < 10#$y)); then
            echo -1
            return 0
        fi
        if ((10#$x > 10#$y)); then
            echo 1
            return 0
        fi
    done
    echo 0
}

# A <  B
version_core_lt() { [[ "$(version_core_cmp "$1" "$2")" == "-1" ]]; }
# A >= B
version_core_ge() { ! version_core_lt "$1" "$2"; }

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
    local arch_name
    # Convert architecture name based on distribution
    case "${GNOSISVPN_DISTRIBUTION}" in
    dmg)
        echo "GnosisVPN-${GNOSISVPN_PACKAGE_VERSION}-${GNOSISVPN_ARCHITECTURE}.dmg"
        ;;
    deb)
        # Convert architecture for debian packages
        if [[ $GNOSISVPN_ARCHITECTURE == "x86_64-linux" ]]; then
            arch_name="amd64"
        elif [[ $GNOSISVPN_ARCHITECTURE == "aarch64-linux" ]]; then
            arch_name="arm64"
        else
            arch_name="$GNOSISVPN_ARCHITECTURE"
        fi
        echo "gnosisvpn_${GNOSISVPN_PACKAGE_VERSION}_${arch_name}.deb"
        ;;
    rpm)
        # Convert architecture for rpm packages
        if [[ $GNOSISVPN_ARCHITECTURE == "x86_64-linux" ]]; then
            arch_name="x86_64"
        elif [[ $GNOSISVPN_ARCHITECTURE == "aarch64-linux" ]]; then
            arch_name="aarch64"
        else
            arch_name="$GNOSISVPN_ARCHITECTURE"
        fi
        echo "gnosisvpn-${GNOSISVPN_PACKAGE_VERSION}.${arch_name}.rpm"
        ;;
    archlinux)
        # Convert architecture for archlinux packages
        if [[ $GNOSISVPN_ARCHITECTURE == "x86_64-linux" ]]; then
            arch_name="x86_64"
        elif [[ $GNOSISVPN_ARCHITECTURE == "aarch64-linux" ]]; then
            arch_name="aarch64"
        else
            arch_name="$GNOSISVPN_ARCHITECTURE"
        fi
        echo "gnosisvpn-${GNOSISVPN_PACKAGE_VERSION}-${arch_name}.pkg.tar.zst"
        ;;
    *)
        echo "gnosisvpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}"
        ;;
    esac
}

# Validate distribution type
validate_distribution() {
    local distribution="$1"
    if [[ ! $distribution =~ ^(deb|dmg)$ ]]; then
        log_error "Invalid distribution: $distribution"
        log_error "Valid options: deb, dmg"
        return 1
    fi
    return 0
}

# Validate architecture
validate_architecture() {
    local architecture="$1"
    if [[ ! $architecture =~ ^(x86_64-linux|aarch64-linux|aarch64-darwin)$ ]]; then
        log_error "Invalid architecture: $architecture"
        log_error "Valid options: x86_64-linux, aarch64-linux, aarch64-darwin"
        return 1
    fi
    return 0
}
