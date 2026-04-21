#!/usr/bin/env bash
# Generate signed update manifests by querying GitHub releases fresh on every run.
# No local state — all channel data is fetched directly from GitHub.
#
# For each platform/arch the script:
#   1. Queries GitHub for the latest release per channel.
#   2. Downloads the pre-computed .sha256 and (where available) .asc files.
#   3. Reads size_bytes from the GitHub release asset metadata.
#   4. Builds a manifest containing all channels.
#   5. Signs the canonical manifest JSON with the GPG key (manifest_signature).
#   6. Writes the result to OUTPUT_DIR.
#
# The .sha256 and .asc files are produced at build time and are the authoritative
# values — this script never re-downloads or re-hashes the full artifact.
# Verification uses the public key committed to the repo: gnosisvpn-public-key.asc
#
# Required environment variables:
#   GNOSISVPN_GPG_PRIVATE_KEY_PATH      Path to the ASCII-armored GPG private key file
#   GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD  Passphrase for the GPG private key
#   GITHUB_REPOSITORY                   Owner/repo slug (e.g. "gnosis/gnosis_vpn")
#   GH_TOKEN                            GitHub token with read access to releases
#
# Optional environment variables:
#   OUTPUT_DIR            Where to write manifest JSON files (default: ./build/manifests)
#   MIN_APP_VERSION       Minimum installed app version eligible for this update (default from config.sh)
#   MIN_OS_VERSION_LINUX  Override minimum Linux version (default from config.sh)
#   MIN_OS_VERSION_MACOS  Override minimum macOS version (default from config.sh)
#
# Channel → data source mapping:
#   stable    = latest non-prerelease GitHub release
#   nightly   = latest successful nightly-build workflow run (GitHub Actions artifact)
#   snapshot  = same as nightly (same workflow, same artifact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

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
    # date-based snapshots (YYYY.MM.DD+build.HHMMSS), and PR/commit builds.
    local semver_regex='^[0-9]+\.[0-9]+\.[0-9]+(\+(pr|commit|build)(\.[0-9A-Za-z-]+)*)?$'
    [[ $version =~ $semver_regex ]] ||
        die "Version '$version' does not match expected format: x.y.z or x.y.z+(pr|commit|build).<meta>"
}

# Sign the canonical (sorted-keys, compact) JSON of a manifest body.
sign_json_body() {
    local json="$1"
    local tmp signature
    tmp=$(mktemp)
    printf '%s' "$(echo "$json" | jq -cS .)" >"$tmp"
    signature=$(
        printf '%s\n' "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
            gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
                --detach-sign --output - "$tmp" |
            base64 | tr -d '\n'
    )
    rm -f "$tmp"
    printf '%s' "$signature"
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

# Returns "run_id version published_at" for the latest successful nightly build run.
# Nightly and snapshot builds are GitHub Actions artifacts, not releases.
# Version is extracted from the Linux amd64 artifact name, which embeds the build timestamp.
get_snapshot_run_info() {
    local run_id published_at version

    run_id=$(gh run list \
        --repo "$REPO" \
        --workflow "nightly-build.yaml" \
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

    echo "$run_id $version $published_at"
}

# ---------------------------------------------------------------------------
# Platform table: "manifest_name|artifact_template|os_family|default_min_os|has_gpg_sig"
# Use __VERSION__ as a placeholder for the version string.
# has_gpg_sig: true for Linux (GPG-signed at build time); false for macOS
#              (Apple notarization covers integrity there, no .asc produced).
# ---------------------------------------------------------------------------
PLATFORMS=(
    "linux-amd64|gnosisvpn___VERSION___amd64.deb|linux|${MIN_OS_LINUX}|true"
    "linux-arm64|gnosisvpn___VERSION___arm64.deb|linux|${MIN_OS_LINUX}|true"
    "macos-arm64|GnosisVPN-Installer-v__VERSION__.pkg|macos|${MIN_OS_MACOS}|false"
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

GPG_KEY_PATH=$(require_env GNOSISVPN_GPG_PRIVATE_KEY_PATH)
GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD=$(require_env GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD)
REPO=$(require_env GITHUB_REPOSITORY)
require_env GH_TOKEN >/dev/null

CHANNELS="stable nightly snapshot"
OUTPUT_DIR="${OUTPUT_DIR:-./build/manifests}"

GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$OUTPUT_DIR"

# Import the GPG key into a temporary keyring; cleaned up on exit.
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
DOWNLOAD_DIRS=()
trap 'rm -rf "$GNUPGHOME" "${DOWNLOAD_DIRS[@]}"' EXIT

printf '%s\n' "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
    gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
        --import "$GPG_KEY_PATH"

# ---------------------------------------------------------------------------
# Step 1: resolve each channel.
#   CHANNEL_DATA stores "source_type ref version published_at" where source_type
#   is "release" (ref = git tag) or "actions" (ref = workflow run ID).
# ---------------------------------------------------------------------------
declare -A CHANNEL_DATA

echo "Resolving stable channel ..."
read -r tag version published_at <<<"$(get_stable_release_info)"
CHANNEL_DATA["stable"]="release $tag $version $published_at"
echo "  -> release $tag ($version) published $published_at"

echo "Resolving nightly/snapshot channels ..."
read -r run_id version published_at <<<"$(get_snapshot_run_info)"
snap_entry="actions $run_id $version $published_at"
CHANNEL_DATA["nightly"]="$snap_entry"
CHANNEL_DATA["snapshot"]="$snap_entry"
echo "  -> actions run $run_id ($version) published $published_at"

# ---------------------------------------------------------------------------
# Step 2: for each platform, build a manifest with all channels.
# ---------------------------------------------------------------------------
ERRORS=0

for entry in "${PLATFORMS[@]}"; do
    IFS='|' read -r MANIFEST_NAME ARTIFACT_TEMPLATE OS_FAMILY DEFAULT_MIN_OS HAS_GPG_SIG <<<"$entry"

    case "$OS_FAMILY" in
    linux) MIN_OS="${MIN_OS_VERSION_LINUX:-$DEFAULT_MIN_OS}" ;;
    macos) MIN_OS="${MIN_OS_VERSION_MACOS:-$DEFAULT_MIN_OS}" ;;
    *) MIN_OS="$DEFAULT_MIN_OS" ;;
    esac

    echo "Processing platform $MANIFEST_NAME ..."

    CHANNELS_JSON='{}'

    for channel in $CHANNELS; do
        read -r source_type ref version published_at <<<"${CHANNEL_DATA[$channel]}"

        ARTIFACT_NAME="${ARTIFACT_TEMPLATE//__VERSION__/$version}"
        DOWNLOAD_DIR=$(mktemp -d)
        DOWNLOAD_DIRS+=("$DOWNLOAD_DIR")

        echo "  [$channel] Fetching metadata for $ARTIFACT_NAME (source: $source_type) ..."

        if [[ $source_type == "release" ]]; then
            # ref = git tag; artifacts live in the GitHub release.
            tag="$ref"

            gh release download "$tag" \
                --repo "$REPO" \
                --pattern "$ARTIFACT_NAME.sha256" \
                --dir "$DOWNLOAD_DIR" ||
                {
                    echo "ERROR: Failed to download $ARTIFACT_NAME.sha256 for channel '$channel'" >&2
                    ERRORS=$((ERRORS + 1))
                    continue
                }
            SHA256=$(awk '{print $1}' "$DOWNLOAD_DIR/$ARTIFACT_NAME.sha256")

            if [[ $HAS_GPG_SIG == "true" ]]; then
                gh release download "$tag" \
                    --repo "$REPO" \
                    --pattern "$ARTIFACT_NAME.asc" \
                    --dir "$DOWNLOAD_DIR" ||
                    {
                        echo "ERROR: Failed to download $ARTIFACT_NAME.asc for channel '$channel'" >&2
                        ERRORS=$((ERRORS + 1))
                        continue
                    }
                ARTIFACT_SIG=$(base64 <"$DOWNLOAD_DIR/$ARTIFACT_NAME.asc" | tr -d '\n')
            else
                ARTIFACT_SIG=""
            fi

            if ! SIZE=$(gh release view "$tag" \
                --repo "$REPO" \
                --json assets \
                --jq ".assets[] | select(.name == \"$ARTIFACT_NAME\") | .size"); then
                echo "ERROR: Failed to fetch asset metadata for '$ARTIFACT_NAME' in release $tag for channel '$channel'" >&2
                ERRORS=$((ERRORS + 1))
                continue
            fi

            [[ -n $SIZE && $SIZE != "null" ]] ||
                {
                    echo "ERROR: Could not find asset '$ARTIFACT_NAME' in release $tag" >&2
                    ERRORS=$((ERRORS + 1))
                    continue
                }

            DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${tag}/${ARTIFACT_NAME}"
            RELEASE_NOTES=$(gh release view "$tag" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")

        else
            # ref = workflow run ID; artifacts live in GitHub Actions.
            # macOS artifact name is fixed (no version); Linux includes the version.
            run_id="$ref"
            case "$OS_FAMILY" in
            linux)
                pkg_artifact_name="$ARTIFACT_NAME"
                sha256_artifact_name="$ARTIFACT_NAME.sha256"
                asc_artifact_name="$ARTIFACT_NAME.asc"
                ;;
            macos)
                pkg_artifact_name="GnosisVPN-Installer.pkg"
                sha256_artifact_name="GnosisVPN-Installer.pkg.sha256"
                ;;
            esac

            # Fetch artifact metadata (id + size) for the package artifact.
            ARTIFACT_META=$(gh api "repos/$REPO/actions/runs/$run_id/artifacts" \
                --jq ".artifacts[] | select(.name == \"$pkg_artifact_name\")")
            ARTIFACT_ID=$(echo "$ARTIFACT_META" | jq -r '.id')
            SIZE=$(echo "$ARTIFACT_META" | jq -r '.size_in_bytes')

            [[ -n $ARTIFACT_ID && $ARTIFACT_ID != "null" ]] ||
                {
                    echo "ERROR: Artifact '$pkg_artifact_name' not found in run $run_id for channel '$channel'" >&2
                    ERRORS=$((ERRORS + 1))
                    continue
                }

            gh run download "$run_id" \
                --repo "$REPO" \
                --name "$sha256_artifact_name" \
                --dir "$DOWNLOAD_DIR" ||
                {
                    echo "ERROR: Failed to download $sha256_artifact_name for channel '$channel'" >&2
                    ERRORS=$((ERRORS + 1))
                    continue
                }
            SHA256=$(awk '{print $1}' "$DOWNLOAD_DIR/"*.sha256)

            if [[ $HAS_GPG_SIG == "true" ]]; then
                gh run download "$run_id" \
                    --repo "$REPO" \
                    --name "$asc_artifact_name" \
                    --dir "$DOWNLOAD_DIR" ||
                    {
                        echo "ERROR: Failed to download $asc_artifact_name for channel '$channel'" >&2
                        ERRORS=$((ERRORS + 1))
                        continue
                    }
                ARTIFACT_SIG=$(base64 <"$DOWNLOAD_DIR/$ARTIFACT_NAME.asc" | tr -d '\n')
            else
                ARTIFACT_SIG=""
            fi

            DOWNLOAD_URL="https://api.github.com/repos/${REPO}/actions/artifacts/${ARTIFACT_ID}/zip"
            RELEASE_NOTES=""
        fi

        CHANNEL_ENTRY=$(jq -n \
            --arg version "$version" \
            --arg published_at "$published_at" \
            --arg download_url "$DOWNLOAD_URL" \
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

    MANIFEST_SIG=$(sign_json_body "$BODY")

    OUT_PATH="$OUTPUT_DIR/$MANIFEST_NAME.json"
    echo "$BODY" |
        jq --arg manifest_signature "$MANIFEST_SIG" \
            '. + {manifest_signature: $manifest_signature}' \
            >"$OUT_PATH"

    echo "  Written: $OUT_PATH"
done

[[ $ERRORS -eq 0 ]] || die "$ERRORS error(s) during manifest generation."

echo "Manifest generation complete."
