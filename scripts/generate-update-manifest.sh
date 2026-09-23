#!/usr/bin/env bash
# Generate signed update manifests using GCS (download.gnosisvpn.io) as the source.
# File metadata (size, sha256, signature) is fetched directly from GCS.
# Version and published_at are resolved from GitHub.
#
# For each platform/arch the script:
#   1. Resolves version and published_at from GitHub per channel.
#   2. Fetches size via HTTP HEAD, sha256 and signature directly from GCS.
#   3. Builds a manifest containing all channels, each with its end_of_life (null when nothing is announced).
#   4. Writes the manifest JSON to OUTPUT_DIR.
#
# Inputs from config/ (pinned, not env-overridable):
#   manifest.json  min_app_version and per-channel end_of_life {max_version, ends_at, reason}: installs of that
#                  channel with version <= max_version stop working at ends_at (RFC 3339 UTC)
#   min-os.json    OS floors written as min_os_version
#
# Channel → GCS path mapping:
#   Linux  stable        → download.gnosisvpn.io/linux/apt/pool/main/g/gnosisvpn/
#   Linux  snapshot      → download.gnosisvpn.io/linux/apt/pool/snapshot/g/gnosisvpn/
#   Linux  experimental  → download.gnosisvpn.io/linux/apt/pool/experimental/g/gnosisvpn/
#   macOS  stable        → download.gnosisvpn.io/macos/stable/
#   macOS  snapshot      → download.gnosisvpn.io/macos/latest/
#   macOS  experimental  → download.gnosisvpn.io/macos/experimental/
#
# stable and snapshot are mandatory; experimental is omitted with a warning until it has published once, and never reaches IPFS.
#
# Required environment variables:
#   GH_TOKEN  GitHub token with read access to releases
#
# Optional environment variables:
#   OUTPUT_DIR  Where to write manifest JSON files (default: ./build/manifests)

set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
CONFIG_DIR="${SCRIPT_DIR}/../config"

GCS_BASE_URL="https://download.gnosisvpn.io"
IPFS_BASE_URL="download.vpn.gnosis.eth"

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
    # Mirrors check_version_syntax in scripts/common.sh; covers stable, snapshot, experimental and PR/commit versions.
    local semver_regex='^[0-9]+\.[0-9]+\.[0-9]+(\+(pr|commit|build)(\.[0-9A-Za-z-]+)*)?$'
    [[ $version =~ $semver_regex ]] ||
        die "Version '$version' does not match expected format: x.y.z or x.y.z+(pr|commit|build).<meta>"
}

# RFC 3339 UTC to the second, same form as published_at; GNU date is fine since this runs on Linux CI only.
validate_ends_at() {
    local ends_at="$1"
    [[ $ends_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
        die "ends_at '$ends_at' must be RFC 3339 UTC, e.g. 2026-12-01T00:00:00Z"
    date -u -d "$ends_at" +%s >/dev/null 2>&1 ||
        die "ends_at '$ends_at' is not a valid date/time"
}

# Sets MIN_APP_VERSION and END_OF_LIFE[channel]; call bare, a command substitution would swallow die().
load_manifest_config() {
    local file="$1" channel max_version ends_at shape
    [[ -f $file ]] || die "Manifest config '$file' not found."
    jq -e '
        type == "object"
        and (keys == ["end_of_life", "min_app_version"])
        and (.min_app_version | type == "string")
        and (.end_of_life | type == "object")
        and (.end_of_life | to_entries | all(
            (.key | IN("stable", "snapshot", "experimental"))
            and (.value | type == "object")
            and (.value | keys == ["ends_at", "max_version", "reason"])
            and (.value | [.[] | type == "string"] | all)
        ))
    ' "$file" >/dev/null ||
        die "'$file' must be {min_app_version, end_of_life: {<stable|snapshot|experimental>: {max_version, ends_at, reason}}} with string values."

    MIN_APP_VERSION=$(jq -r '.min_app_version' "$file")
    [[ $MIN_APP_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "min_app_version '$MIN_APP_VERSION' must be x.y.z"

    declare -gA END_OF_LIFE=()
    while IFS=$'\t' read -r channel max_version ends_at; do
        validate_version "$max_version"
        case "$channel" in
        stable) shape='^[0-9]+\.[0-9]+\.[0-9]+$' ;;
        snapshot) shape='\+build\.[0-9]+$' ;;
        experimental) shape='\.experimental$' ;;
        esac
        [[ $max_version =~ $shape ]] ||
            die "end_of_life.${channel}.max_version '$max_version' is not a ${channel} version."
        validate_ends_at "$ends_at"
        if [[ $(date -u -d "$ends_at" +%s) -le $(date -u +%s) ]]; then
            echo "WARN: end_of_life.${channel}.ends_at ${ends_at} is in the past." >&2
        fi
        END_OF_LIFE[$channel]=$(jq -c --arg ch "$channel" '.end_of_life[$ch]' "$file")
        echo "  [$channel] end of life: <= ${max_version} stops working at ${ends_at}"
    done < <(jq -r '.end_of_life | to_entries[] | [.key, .value.max_version, .value.ends_at] | @tsv' "$file")
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

# Returns "version published_at" for the latest snapshot, read from repository
# variables that snapshot-build.yaml writes only when it actually produces
# artifacts — so they always reflect a real snapshot, never a no-op skipped run.
get_snapshot_run_info() {
    local version published_at
    version=$(gh variable get GNOSISVPN_SNAPSHOT_VERSION --repo "$REPO")
    published_at=$(gh variable get GNOSISVPN_SNAPSHOT_DATE --repo "$REPO")

    [[ -n $version ]] ||
        die "Repository variable GNOSISVPN_SNAPSHOT_VERSION is empty — has snapshot-build.yaml published a snapshot yet?"
    [[ -n $published_at ]] ||
        die "Repository variable GNOSISVPN_SNAPSHOT_DATE is empty — has snapshot-build.yaml published a snapshot yet?"
    validate_version "$version"

    echo "$version $published_at"
}

# Returns "version published_at" for the latest experimental build, or nothing while unset; returns rather than die()s, which a command substitution would swallow.
get_experimental_run_info() {
    local name out rc
    local values=()
    for name in GNOSISVPN_EXPERIMENTAL_VERSION GNOSISVPN_EXPERIMENTAL_DATE; do
        rc=0
        out=$(gh variable get "$name" --repo "$REPO" 2>&1) || rc=$?
        if [[ $rc -ne 0 ]]; then
            if grep -qi 'not found' <<<"$out"; then
                echo "WARN: repository variable ${name} is not set — skipping the experimental channel." >&2
                return 0
            fi
            echo "ERROR: gh variable get ${name} failed (exit ${rc}): ${out}" >&2
            return 1
        fi
        if [[ -z $out ]]; then
            echo "WARN: repository variable ${name} is empty — skipping the experimental channel." >&2
            return 0
        fi
        values+=("$out")
    done
    validate_version "${values[0]}"

    echo "${values[0]} ${values[1]}"
}

# ---------------------------------------------------------------------------
# Platform table: "manifest_name|os_family|default_min_os"
# Per-platform GCS URLs are built by build_gcs_url() below from manifest_name,
# channel, and version. Linux artifacts are GPG-signed; macOS relies on Apple
# notarization instead.
# ---------------------------------------------------------------------------
MIN_OS_MACOS=$(jq -er '.macos' "${CONFIG_DIR}/min-os.json")
MIN_OS_LINUX_UBUNTU=$(jq -er '.linux_ubuntu' "${CONFIG_DIR}/min-os.json")
PLATFORMS=(
    "linux-amd64|linux|${MIN_OS_LINUX_UBUNTU}"
    "linux-arm64|linux|${MIN_OS_LINUX_UBUNTU}"
    "macos-arm64|macos|${MIN_OS_MACOS}"
)

# Build the GCS download URL per platform / channel / version; macOS .pkg slugs substitute '-' for '+' (see build-binary.yaml::prepare_files).
build_gcs_url() {
    local manifest_name="$1"
    local channel="$2"
    local version="$3"
    local arch pool_dir chan_dir fs_version

    case "$manifest_name" in
    linux-*)
        arch="${manifest_name#linux-}"
        case "$channel" in
        stable) pool_dir="pool/main" ;;
        snapshot) pool_dir="pool/snapshot" ;;
        experimental) pool_dir="pool/experimental" ;;
        *) die "Unknown channel: ${channel}" ;;
        esac
        echo "${GCS_BASE_URL}/linux/apt/${pool_dir}/g/gnosisvpn/gnosisvpn_${version}_${arch}.deb"
        ;;
    macos-*)
        arch="${manifest_name#macos-}"
        case "$channel" in
        stable) chan_dir="stable" ;;
        snapshot) chan_dir="latest" ;;
        experimental) chan_dir="experimental" ;;
        *) die "Unknown channel: ${channel}" ;;
        esac
        fs_version="${version//+/-}"
        echo "${GCS_BASE_URL}/macos/${chan_dir}/gnosisvpn_${fs_version}_${arch}.pkg"
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

# Mandatory channels; "experimental" is appended below when it resolves.
CHANNELS="stable snapshot"
OUTPUT_DIR="${OUTPUT_DIR:-./build/manifests}"

GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$OUTPUT_DIR"

# Config only; fails before any network call.
echo "Loading ${CONFIG_DIR}/manifest.json ..."
load_manifest_config "${CONFIG_DIR}/manifest.json"

# ---------------------------------------------------------------------------
# Step 1: resolve each channel.
#   CHANNEL_DATA stores "ref version published_at"; ref is a git tag (stable) or "-" (snapshot, experimental).
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

echo "Resolving experimental channel ..."
if ! experimental_info="$(get_experimental_run_info)"; then
    die "Failed to resolve the experimental channel."
fi
if [[ -n $experimental_info ]]; then
    read -r version published_at <<<"$experimental_info"
    CHANNEL_DATA["experimental"]="- $version $published_at"
    CHANNELS="$CHANNELS experimental"
    echo "  -> ($version) published $published_at"
else
    echo "  -> not published yet; manifests will carry stable + snapshot only"
fi

# ---------------------------------------------------------------------------
# Step 2: for each platform, build a manifest with all channels.
# ---------------------------------------------------------------------------
ERRORS=0

for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r MANIFEST_NAME OS_FAMILY MIN_OS <<<"$entry"

    echo "Processing platform $MANIFEST_NAME ..."

    CHANNELS_JSON='{}'
    CHANNELS_JSON_IPFS='{}'

    for channel in $CHANNELS; do
        read -r ref version published_at <<<"${CHANNEL_DATA[$channel]}"

        [[ -n $version ]] ||
            die "[$channel] version is empty — cannot build manifest."
        [[ -n $published_at ]] ||
            die "[$channel] published_at is empty — cannot build manifest."

        GCS_URL=$(build_gcs_url "$MANIFEST_NAME" "$channel" "$version")
        # The IPFS manifest mirrors the same path layout for the stable channel.
        # File metadata below is still fetched from GCS (same binary, authoritative source).
        IPFS_URL="${GCS_URL/#$GCS_BASE_URL/$IPFS_BASE_URL}"
        echo "  [$channel] Fetching metadata from ${GCS_URL} ..."

        SIZE=$(curl -sfL -o /dev/null -w "%{size_download}" "$GCS_URL" || true)
        [[ -n $SIZE ]] ||
            {
                echo "ERROR: Could not determine size of '${MANIFEST_NAME}' from ${GCS_URL}" >&2
                ERRORS=$((ERRORS + 1))
                continue
            }

        SHA256=$(curl -sf "${GCS_URL}.sha256" | awk '{print $1}' || true)
        [[ -n $SHA256 ]] ||
            {
                echo "ERROR: Could not fetch sha256 for '${MANIFEST_NAME}' from ${GCS_URL}.sha256" >&2
                ERRORS=$((ERRORS + 1))
                continue
            }

        if [[ $OS_FAMILY == "linux" ]]; then
            ARTIFACT_SIG=$(curl -sf "${GCS_URL}.asc" | base64 | tr -d '\n' || true)
            [[ -n $ARTIFACT_SIG ]] ||
                {
                    echo "ERROR: Could not fetch signature for '${MANIFEST_NAME}' from ${GCS_URL}.asc" >&2
                    ERRORS=$((ERRORS + 1))
                    continue
                }
        else
            ARTIFACT_SIG=""
        fi

        # Only stable has a GitHub release to take notes from.
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
            --argjson end_of_life "${END_OF_LIFE[$channel]:-null}" \
            '{
        version: $version,
        published_at: $published_at,
        download_url: $download_url,
        size_bytes: $size_bytes,
        sha256: $sha256,
        artifact_signature: $artifact_signature,
        release_notes: $release_notes,
        min_os_version: $min_os_version,
        min_app_version: $min_app_version,
        end_of_life: $end_of_life
      }')

        CHANNELS_JSON=$(echo "$CHANNELS_JSON" |
            jq --arg ch "$channel" --argjson entry "$CHANNEL_ENTRY" \
                '. + {($ch): $entry}')

        # IPFS hosts stable binaries only, so its manifest carries that channel exclusively.
        if [[ $channel == "stable" ]]; then
            # Same entry, only download_url repointed at the IPFS host.
            CHANNEL_ENTRY_IPFS=$(echo "$CHANNEL_ENTRY" |
                jq --arg download_url "$IPFS_URL" '.download_url = $download_url')
            CHANNELS_JSON_IPFS=$(echo "$CHANNELS_JSON_IPFS" |
                jq --arg ch "$channel" --argjson entry "$CHANNEL_ENTRY_IPFS" \
                    '. + {($ch): $entry}')
        fi
    done

    BODY=$(jq -n \
        --argjson schema_version 2 \
        --arg generated_at "$GENERATED_AT" \
        --argjson channels "$CHANNELS_JSON" \
        '{schema_version: $schema_version, generated_at: $generated_at, channels: $channels}')

    OUT_PATH="$OUTPUT_DIR/$MANIFEST_NAME.json"
    echo "$BODY" >"$OUT_PATH"
    echo "  Written: $OUT_PATH"

    BODY_IPFS=$(jq -n \
        --argjson schema_version 2 \
        --arg generated_at "$GENERATED_AT" \
        --argjson channels "$CHANNELS_JSON_IPFS" \
        '{schema_version: $schema_version, generated_at: $generated_at, channels: $channels}')

    OUT_PATH_IPFS="$OUTPUT_DIR/$MANIFEST_NAME.ipfs.json"
    echo "$BODY_IPFS" >"$OUT_PATH_IPFS"
    echo "  Written: $OUT_PATH_IPFS"
done

[[ $ERRORS -eq 0 ]] || die "$ERRORS error(s) during manifest generation."

echo "Manifest generation complete."
