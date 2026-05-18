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
#   Linux  stable    → download.gnosisvpn.io/linux/apt/pool/main/g/gnosisvpn/
#   Linux  snapshot  → download.gnosisvpn.io/linux/apt/pool/snapshot/g/gnosisvpn/
#   macOS  stable    → download.gnosisvpn.io/macos/stable/
#   macOS  snapshot  → download.gnosisvpn.io/macos/latest/
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
    # date-based snapshot builds (YYYY.MM.DD+build.HHMMSS), and PR/commit builds.
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

# Returns "version published_at" for the latest successful snapshot build.
# Version is extracted from the Linux amd64 artifact name, which embeds the build timestamp.
get_snapshot_run_info() {
    local run_id published_at version

    run_id=$(gh run list \
        --repo "$REPO" \
        --workflow "snapshot-build.yaml" \
        --branch main \
        --status success \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId')

    [[ -n $run_id && $run_id != "null" ]] ||
        die "No successful snapshot-build workflow run found."

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
# Platform table: "manifest_name|os_family|default_min_os"
# Per-platform GCS URLs are built by build_gcs_url() below from manifest_name,
# channel, and version. Linux artifacts are GPG-signed; macOS relies on Apple
# notarization instead.
# ---------------------------------------------------------------------------
PLATFORMS=(
    "linux-amd64|linux|${MIN_OS_LINUX_UBUNTU}"
    "linux-arm64|linux|${MIN_OS_LINUX_UBUNTU}"
    "macos-arm64|macos|${MIN_OS_MACOS}"
)

# Build the GCS download URL for a given platform / channel / version.
# Both Linux .deb and macOS .pkg filenames are version-pinned
# (gnosisvpn_<version>_<arch>.{deb,pkg}). Linux files live in the APT pool
# (pool/main/g/gnosisvpn for stable, pool/snapshot/g/gnosisvpn for snapshot).
# macOS files live in /macos/<channel-dir>/ where channel-dir is "stable" or
# "latest".
build_gcs_url() {
    local manifest_name="$1"
    local channel="$2"
    local version="$3"
    local arch pool_dir chan_dir

    case "$manifest_name" in
    linux-*)
        arch="${manifest_name#linux-}"
        if [[ $channel == "stable" ]]; then
            pool_dir="pool/main"
        else
            pool_dir="pool/snapshot"
        fi
        echo "${GCS_BASE_URL}/linux/apt/${pool_dir}/g/gnosisvpn/gnosisvpn_${version}_${arch}.deb"
        ;;
    macos-*)
        arch="${manifest_name#macos-}"
        if [[ $channel == "stable" ]]; then
            chan_dir="stable"
        else
            chan_dir="latest"
        fi
        echo "${GCS_BASE_URL}/macos/${chan_dir}/gnosisvpn_${version}_${arch}.pkg"
        ;;
    *)
        die "Unknown manifest_name: ${manifest_name}"
        ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

REPO="gnosis/gnosis_vpn"
require_env GH_TOKEN >/dev/null

CHANNELS="stable snapshot"
OUTPUT_DIR="${OUTPUT_DIR:-./build/manifests}"

GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1: resolve each channel.
#   CHANNEL_DATA stores "ref version published_at" where:
#     ref = git tag (stable, used for release notes) or "-" (snapshot)
# ---------------------------------------------------------------------------
declare -A CHANNEL_DATA

echo "Resolving stable channel ..."
read -r tag version published_at <<<"$(get_stable_release_info)"
CHANNEL_DATA["stable"]="$tag $version $published_at"
echo "  -> $tag ($version) published $published_at"

echo "Resolving snapshot channel ..."
read -r version published_at <<<"$(get_snapshot_run_info)"
CHANNEL_DATA["snapshot"]="- $version $published_at"
echo "  -> ($version) published $published_at"

# ---------------------------------------------------------------------------
# Step 2: for each platform, build a manifest with all channels.
# ---------------------------------------------------------------------------
ERRORS=0

for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r MANIFEST_NAME OS_FAMILY DEFAULT_MIN_OS <<<"$entry"

    case "$OS_FAMILY" in
    linux) MIN_OS="${MIN_OS_VERSION_LINUX_UBUNTU:-$DEFAULT_MIN_OS}" ;;
    macos) MIN_OS="${MIN_OS_VERSION_MACOS:-$DEFAULT_MIN_OS}" ;;
    *) MIN_OS="$DEFAULT_MIN_OS" ;;
    esac

    echo "Processing platform $MANIFEST_NAME ..."

    CHANNELS_JSON='{}'

    for channel in $CHANNELS; do
        read -r ref version published_at <<<"${CHANNEL_DATA[$channel]}"

        [[ -n $version ]] ||
            die "[$channel] version is empty — cannot build manifest."
        [[ -n $published_at ]] ||
            die "[$channel] published_at is empty — cannot build manifest."

        GCS_URL=$(build_gcs_url "$MANIFEST_NAME" "$channel" "$version")
        echo "  [$channel] Fetching metadata from ${GCS_URL} ..."

        SIZE=$(curl -skfL -o /dev/null -w "%{size_download}" "$GCS_URL" || true)
        [[ -n $SIZE ]] ||
            {
                echo "ERROR: Could not determine size of '${MANIFEST_NAME}' from ${GCS_URL}" >&2
                ERRORS=$((ERRORS + 1))
                continue
            }

        SHA256=$(curl -skf "${GCS_URL}.sha256" | awk '{print $1}' || true)
        [[ -n $SHA256 ]] ||
            {
                echo "ERROR: Could not fetch sha256 for '${MANIFEST_NAME}' from ${GCS_URL}.sha256" >&2
                ERRORS=$((ERRORS + 1))
                continue
            }

        if [[ $OS_FAMILY == "linux" ]]; then
            ARTIFACT_SIG=$(curl -skf "${GCS_URL}.asc" | base64 | tr -d '\n' || true)
            [[ -n $ARTIFACT_SIG ]] ||
                {
                    echo "ERROR: Could not fetch signature for '${MANIFEST_NAME}' from ${GCS_URL}.asc" >&2
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
