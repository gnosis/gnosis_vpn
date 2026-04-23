#!/usr/bin/env bash
# Generate signed update manifests using GCS (download.gnosisvpn.io) as the source.
# File metadata (size, sha256, signature) is fetched directly from GCS.
# Version and published_at are resolved from GitHub.
#
# For each platform/arch the script:
#   1. Resolves version and published_at from GitHub per channel.
#   2. Fetches size via HTTP HEAD, sha256 and signature directly from GCS.
#   3. Builds a manifest containing all channels.
#   4. Writes the manifest JSON to OUTPUT_DIR.
#
# Channel → GCS path mapping:
#   stable   → download.gnosisvpn.io/stable/
#   nightly  → download.gnosisvpn.io/latest/
#
# Required environment variables:
#   GH_TOKEN  GitHub token with read access to releases
#
# Optional environment variables:
#   OUTPUT_DIR                   Where to write manifest JSON files (default: ./build/manifests)
#   MIN_APP_VERSION              Minimum installed app version eligible for this update (default from config.sh)
#   MIN_OS_VERSION_LINUX_UBUNTU  Override minimum Linux version (default from config.sh)
#   MIN_OS_VERSION_MACOS         Override minimum macOS version (default from config.sh)

set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

GCS_BASE_URL="https://download.gnosisvpn.io"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_env() {
    local val="${!1:-}"
    [[ -n $val ]] || die "Required environment variable '$1' is not set or empty."
    echo "$val"
}

validate_version() {
    local version="$1"
    # Mirrors check_version_syntax in scripts/common.sh — covers stable (x.y.z),
    # date-based nightly builds (YYYY.MM.DD+build.HHMMSS), and PR/commit builds.
    local semver_regex='^[0-9]+\.[0-9]+\.[0-9]+(\+(pr|commit|build)(\.[0-9A-Za-z-]+)*)?$'
    [[ $version =~ $semver_regex ]] ||
        die "Version '$version' does not match expected format: x.y.z or x.y.z+(pr|commit|build).<meta>"
}

# Returns "tag version published_at" for the latest stable GitHub release.
get_stable_release_info() {
    local result
    result=$(gh release list \
        --repo "$REPO" \
        --exclude-pre-releases \
        --limit 1 \
        --json tagName,publishedAt |
        jq -r 'first | "\(.tagName) \(.publishedAt)"')

    [[ -n $result && $result != "null null" ]] ||
        die "No stable GitHub release found."

    local tag published_at
    read -r tag published_at <<<"$result"
    local version="${tag#v}"
    validate_version "$version"
    echo "$tag $version $published_at"
}

# Returns "version published_at" for the latest successful nightly build.
# Version is extracted from the Linux amd64 artifact name, which embeds the build timestamp.
get_nightly_run_info() {
    local run_id published_at version

    run_id=$(gh run list \
        --repo "$REPO" \
        --workflow "nightly-build.yaml" \
        --branch main \
        --status success \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId')

    [[ -n $run_id && $run_id != "null" ]] ||
        die "No successful nightly-build workflow run found."

    published_at=$(gh run view "$run_id" \
        --repo "$REPO" \
        --json createdAt \
        --jq '.createdAt')

    # All platforms in the run share the same GNOSISVPN_PACKAGE_VERSION.
    # Extract it from the Linux amd64 artifact name: gnosisvpn_VERSION_amd64.deb
    version=$(gh api "repos/$REPO/actions/runs/$run_id/artifacts" \
        --jq '[.artifacts[] | select(.name | test("^gnosisvpn_.*_amd64\\.deb$"))] | first | .name' |
        sed 's/^gnosisvpn_\(.*\)_amd64\.deb$/\1/')

    [[ -n $version && $version != "null" ]] ||
        die "Could not determine version from artifacts of run $run_id."
    validate_version "$version"

    echo "$version $published_at"
}

# ---------------------------------------------------------------------------
# Platform table: "manifest_name|gcs_artifact|os_family|default_min_os"
# gcs_artifact is the version-less filename as published to download.gnosisvpn.io.
# Linux artifacts are GPG-signed; macOS relies on Apple notarization instead.
# ---------------------------------------------------------------------------
PLATFORMS=(
    "linux-amd64|gnosisvpn_amd64.deb|linux|${MIN_OS_LINUX_UBUNTU}"
    "linux-arm64|gnosisvpn_arm64.deb|linux|${MIN_OS_LINUX_UBUNTU}"
    "macos-arm64|gnosisvpn_arm64.pkg|macos|${MIN_OS_MACOS}"
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

REPO="gnosis/gnosis_vpn"
require_env GH_TOKEN >/dev/null

CHANNELS="stable nightly"
OUTPUT_DIR="${OUTPUT_DIR:-./build/manifests}"

GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1: resolve each channel.
#   CHANNEL_DATA stores "gcs_prefix ref version published_at" where:
#     gcs_prefix = GCS path component ("stable" or "latest")
#     ref        = git tag (stable, used for release notes) or "-" (nightly)
# ---------------------------------------------------------------------------
declare -A CHANNEL_DATA

echo "Resolving stable channel ..."
read -r tag version published_at <<<"$(get_stable_release_info)"
CHANNEL_DATA["stable"]="stable $tag $version $published_at"
echo "  -> $tag ($version) published $published_at"

echo "Resolving nightly channel ..."
read -r version published_at <<<"$(get_nightly_run_info)"
CHANNEL_DATA["nightly"]="latest - $version $published_at"
echo "  -> ($version) published $published_at"

# ---------------------------------------------------------------------------
# Step 2: for each platform, build a manifest with all channels.
# ---------------------------------------------------------------------------
ERRORS=0

for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r MANIFEST_NAME GCS_ARTIFACT OS_FAMILY DEFAULT_MIN_OS <<<"$entry"

    case "$OS_FAMILY" in
    linux) MIN_OS="${MIN_OS_VERSION_LINUX_UBUNTU:-$DEFAULT_MIN_OS}" ;;
    macos) MIN_OS="${MIN_OS_VERSION_MACOS:-$DEFAULT_MIN_OS}" ;;
    *) MIN_OS="$DEFAULT_MIN_OS" ;;
    esac

    echo "Processing platform $MANIFEST_NAME ..."

    CHANNELS_JSON='{}'

    for channel in $CHANNELS; do
        read -r gcs_prefix ref version published_at <<<"${CHANNEL_DATA[$channel]}"

        GCS_URL="${GCS_BASE_URL}/${gcs_prefix}/${GCS_ARTIFACT}"
        echo "  [$channel] Fetching metadata from ${GCS_URL} ..."

        SIZE=$(curl -skI "$GCS_URL" |
            grep -i '^content-length:' | awk '{print $2}' | tr -d '\r' || true)
        [[ -n $SIZE ]] ||
            {
                echo "ERROR: Could not determine size of '${GCS_ARTIFACT}' from ${GCS_URL}" >&2
                ERRORS=$((ERRORS + 1))
                continue
            }

        SHA256=$(curl -skf "${GCS_URL}.sha256" | awk '{print $1}' || true)
        [[ -n $SHA256 ]] ||
            {
                echo "ERROR: Could not fetch sha256 for '${GCS_ARTIFACT}' from ${GCS_URL}.sha256" >&2
                ERRORS=$((ERRORS + 1))
                continue
            }

        if [[ $OS_FAMILY == "linux" ]]; then
            ARTIFACT_SIG=$(curl -skf "${GCS_URL}.asc" | base64 | tr -d '\n' || true)
            [[ -n $ARTIFACT_SIG ]] ||
                {
                    echo "ERROR: Could not fetch signature for '${GCS_ARTIFACT}' from ${GCS_URL}.asc" >&2
                    ERRORS=$((ERRORS + 1))
                    continue
                }
        else
            ARTIFACT_SIG=""
        fi

        if [[ $channel == "stable" ]]; then
            RELEASE_NOTES=$(gh release view "$ref" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
        else
            RELEASE_NOTES=""
        fi

        CHANNEL_ENTRY=$(jq -n \
            --arg version "$version" \
            --arg published_at "$published_at" \
            --arg download_url "${GCS_URL}" \
            --argjson size_bytes "$SIZE" \
            --arg sha256 "$SHA256" \
            --arg artifact_signature "$ARTIFACT_SIG" \
            --arg release_notes "$RELEASE_NOTES" \
            --arg min_os_version "$MIN_OS" \
            --arg min_app_version "$MIN_APP_VERSION" \
            '{
        version: $version,
        published_at: $published_at,
        download_url: $download_url,
        size_bytes: $size_bytes,
        sha256: $sha256,
        artifact_signature: $artifact_signature,
        release_notes: $release_notes,
        min_os_version: $min_os_version,
        min_app_version: $min_app_version
      }')

        CHANNELS_JSON=$(echo "$CHANNELS_JSON" |
            jq --arg ch "$channel" --argjson entry "$CHANNEL_ENTRY" \
                '. + {($ch): $entry}')
    done

    BODY=$(jq -n \
        --argjson schema_version 1 \
        --arg generated_at "$GENERATED_AT" \
        --argjson channels "$CHANNELS_JSON" \
        '{schema_version: $schema_version, generated_at: $generated_at, channels: $channels}')

    OUT_PATH="$OUTPUT_DIR/$MANIFEST_NAME.json"
    echo "$BODY" >"$OUT_PATH"
    echo "  Written: $OUT_PATH"
done

[[ $ERRORS -eq 0 ]] || die "$ERRORS error(s) during manifest generation."

echo "Manifest generation complete."
