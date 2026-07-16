#!/bin/bash
#
# Resolve the package / client / app / toolkit versions for a build and write
# them as GitHub Actions step outputs.
#
# Used by the setup job of .github/workflows/build-binary.yaml. Behaviour
# depends on VERSION_TYPE:
#   snapshot - date-based package version; newest complete registry versions
#              for client/app/toolkit; sets SKIP_BUILDING=true when nothing
#              changed since the previous snapshot
#   commit   - latest merged-PR package version pinned to the PR head commit
#   pr       - package version of the latest merged gnosis_vpn PR
#   release  - package version from package.json on GITHUB_REF; latest GitHub
#              releases for client/app/toolkit
#
# Environment:
#   VERSION_TYPE                       (required) snapshot | commit | pr | release
#   GH_TOKEN                           (required) token for gh api calls
#   GITHUB_OUTPUT                      step output file; defaults to /dev/null
#                                      so the script can be run locally
#   INPUT_CLIENT_VERSION               explicit client version override
#   INPUT_APP_VERSION                  explicit app version override
#   INPUT_TOOLKIT_VERSION              explicit toolkit version override
#   GNOSISVPN_PACKAGE_PREVIOUS_VERSION previously built versions, used for
#   GNOSISVPN_CLIENT_PREVIOUS_VERSION  the snapshot skip check
#   GNOSISVPN_APP_PREVIOUS_VERSION
#   GNOSISVPN_TOOLKIT_PREVIOUS_VERSION
#   PR_HEAD_SHA                        PR head commit sha (VERSION_TYPE=commit)
#   GITHUB_REPOSITORY, GITHUB_REF      set by GitHub Actions (VERSION_TYPE=release)
#
# Outputs written to GITHUB_OUTPUT:
#   LATEST_GNOSISVPN_PACKAGE_PR_VERSION, GNOSISVPN_PACKAGE_VERSION,
#   GNOSISVPN_CLIENT_VERSION, GNOSISVPN_APP_VERSION,
#   GNOSISVPN_TOOLKIT_VERSION, SKIP_BUILDING
#

set -euo pipefail

# Source common functions (log_* helpers)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

set_output() {
    echo "$1=$2" | tee -a "${GITHUB_OUTPUT}"
}

get_latest_pr_version() {
    local repo=$1
    local file_path=$2
    local pr_number merge_sha file_content version
    pr_number=$(gh api "repos/gnosis/${repo}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100" \
        --jq '[.[] | select(.merged_at != null)] | sort_by(.merged_at) | last | .number | tostring')
    merge_sha=$(gh api "repos/gnosis/${repo}/pulls/${pr_number}" --jq '.merge_commit_sha')
    file_content=$(gh api "repos/gnosis/${repo}/contents/${file_path}?ref=${merge_sha}" --jq '.content' | base64 --decode)
    if [[ ${file_path} == "package.json" ]]; then
        version=$(echo "${file_content}" | jq -r '.version')
    else
        version=$(echo "${file_content}" | grep '^version\s*=' | head -n 1 | cut -d '"' -f 2)
    fi
    echo "${version}+pr.${pr_number}"
}

get_latest_release_version() {
    local repo=$1
    gh api "repos/gnosis/${repo}/releases/latest" --jq '.tag_name' | sed 's/^v//'
}

main() {
    local version_type="${VERSION_TYPE:-}"
    if [[ -z ${version_type} ]]; then
        log_error "VERSION_TYPE is not set. Expected snapshot, commit, pr, or release."
        exit 1
    fi

    local latest_package_pr_version
    latest_package_pr_version=$(get_latest_pr_version "gnosis_vpn" "package.json")

    # Auto-detect the newest *complete* client/app/toolkit versions.
    # CONTRACT: the resolved value must be the exact registry version tag,
    # e.g. "0.91.1+pr.638". It is used verbatim as the GCP artifact tag in
    # download-binaries.sh, in the snapshot skip comparison below, and in the
    # "+pr." branch of generate-changelog.ts, so a different encoding would
    # break those.
    local latest_client_pr_version="" latest_app_pr_version="" latest_toolkit_pr_version=""
    if [[ ${version_type} != "release" ]]; then
        latest_client_pr_version="${INPUT_CLIENT_VERSION:-$(
            "${SCRIPT_DIR}/resolve-registry-version.sh" gnosis_vpn-client \
                gnosis_vpn-root-x86_64-linux gnosis_vpn-worker-x86_64-linux gnosis_vpn-ctl-x86_64-linux \
                gnosis_vpn-root-aarch64-linux gnosis_vpn-worker-aarch64-linux gnosis_vpn-ctl-aarch64-linux \
                gnosis_vpn-root-aarch64-darwin gnosis_vpn-worker-aarch64-darwin gnosis_vpn-ctl-aarch64-darwin
        )}"
        latest_app_pr_version="${INPUT_APP_VERSION:-$(
            "${SCRIPT_DIR}/resolve-registry-version.sh" gnosis_vpn-app \
                gnosis_vpn-app-x86_64-linux.deb gnosis_vpn-app-aarch64-linux.deb gnosis_vpn-app-aarch64-darwin.dmg
        )}"
        latest_toolkit_pr_version="${INPUT_TOOLKIT_VERSION:-$(
            "${SCRIPT_DIR}/resolve-registry-version.sh" gnosis_vpn-toolkit gnosis_vpn-update-aarch64-darwin
        )}"
    fi

    local latest_package_version_number latest_package_pr_number previous_package_pr_number
    latest_package_version_number=$(echo "${latest_package_pr_version}" | cut -d '+' -f 1)
    latest_package_pr_number=$(echo "${latest_package_pr_version}" | cut -d '+' -f 2 | cut -d '.' -f 2)
    previous_package_pr_number=$(echo "${GNOSISVPN_PACKAGE_PREVIOUS_VERSION:-}" | cut -d '+' -f 2 | cut -d '.' -f 2)
    set_output "LATEST_GNOSISVPN_PACKAGE_PR_VERSION" "${latest_package_pr_version}"

    case "${version_type}" in
    snapshot)
        set_output "GNOSISVPN_PACKAGE_VERSION" "$(date +%Y.%m.%d+build.%H%M%S)"
        set_output "GNOSISVPN_CLIENT_VERSION" "${latest_client_pr_version}"
        set_output "GNOSISVPN_APP_VERSION" "${latest_app_pr_version}"
        set_output "GNOSISVPN_TOOLKIT_VERSION" "${latest_toolkit_pr_version}"
        ;;
    commit)
        local sha="${PR_HEAD_SHA:?PR_HEAD_SHA is required for VERSION_TYPE=commit}"
        set_output "GNOSISVPN_PACKAGE_VERSION" "${latest_package_version_number}+commit.${sha:0:7}"
        set_output "GNOSISVPN_CLIENT_VERSION" "${latest_client_pr_version}"
        set_output "GNOSISVPN_APP_VERSION" "${latest_app_pr_version}"
        set_output "GNOSISVPN_TOOLKIT_VERSION" "${latest_toolkit_pr_version}"
        ;;
    pr)
        set_output "GNOSISVPN_PACKAGE_VERSION" "${latest_package_pr_version}"
        set_output "GNOSISVPN_CLIENT_VERSION" "${latest_client_pr_version}"
        set_output "GNOSISVPN_APP_VERSION" "${latest_app_pr_version}"
        set_output "GNOSISVPN_TOOLKIT_VERSION" "${latest_toolkit_pr_version}"
        ;;
    release)
        # Read package.json from the ref the workflow was dispatched on
        # (typically main, but supports release branches). The hopr-workflows
        # release-version action also reads source_branch's package.json, so
        # sourcing it here keeps the build version and the release version
        # aligned regardless of which branch close-release runs on.
        local package_version client_version app_version toolkit_version
        package_version=$(gh api \
            "repos/${GITHUB_REPOSITORY}/contents/package.json?ref=${GITHUB_REF}" \
            --jq '.content' | base64 --decode | jq -r '.version')
        client_version="${INPUT_CLIENT_VERSION:-$(get_latest_release_version "gnosis_vpn-client")}"
        app_version="${INPUT_APP_VERSION:-$(get_latest_release_version "gnosis_vpn-app")}"
        toolkit_version="${INPUT_TOOLKIT_VERSION:-$(get_latest_release_version "gnosis_vpn-toolkit")}"
        set_output "GNOSISVPN_PACKAGE_VERSION" "${package_version}"
        set_output "GNOSISVPN_CLIENT_VERSION" "${client_version}"
        set_output "GNOSISVPN_APP_VERSION" "${app_version}"
        set_output "GNOSISVPN_TOOLKIT_VERSION" "${toolkit_version}"
        ;;
    *)
        log_error "Invalid version_type: ${version_type}. Expected snapshot, commit, pr, or release."
        exit 1
        ;;
    esac

    if [[ ${version_type} == "snapshot" ]] &&
        [[ ${latest_package_pr_number} == "${previous_package_pr_number}" ]] &&
        [[ ${latest_client_pr_version} == "${GNOSISVPN_CLIENT_PREVIOUS_VERSION:-}" ]] &&
        [[ ${latest_app_pr_version} == "${GNOSISVPN_APP_PREVIOUS_VERSION:-}" ]] &&
        [[ ${latest_toolkit_pr_version} == "${GNOSISVPN_TOOLKIT_PREVIOUS_VERSION:-}" ]]; then
        set_output "SKIP_BUILDING" "true"
        log_info "No new gnosis_vpn PR, nor newly published gnosis_vpn-client / gnosis_vpn-app / gnosis_vpn-toolkit versions found. Skipping snapshot build."
    else
        set_output "SKIP_BUILDING" "false"
        log_info "Proceeding with the build."
    fi
}

main "$@"
