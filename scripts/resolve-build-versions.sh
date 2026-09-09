#!/bin/bash
#
# Resolve the package / client / app / toolkit versions for a build and write
# them as GitHub Actions step outputs.
#
# Used by the setup job of .github/workflows/build-binary.yaml. Behaviour
# depends on VERSION_TYPE:
#   snapshot     - date-based package version; newest complete registry versions
#                  for client/app/toolkit; sets SKIP_BUILDING=true when nothing
#                  changed since the previous snapshot
#   experimental - date-based package version carrying the ".experimental"
#                  marker; same skip behaviour as snapshot
#   commit       - latest merged-PR package version pinned to the PR head commit
#   pr           - package version of the latest merged gnosis_vpn PR
#   release      - package version from package.json on GITHUB_REF; latest
#                  eligible GitHub releases for client/app/toolkit
#
# Two installer lines are served from the same repo and differ in which
# client/app versions they may use (COMPONENT_VERSION_BOUNDARY in config.sh):
#   experimental                        -> component core >= boundary
#   snapshot / commit / pr / release    -> component core <  boundary
# The toolkit is NOT split: both lines take its newest complete version.
#
# Environment:
#   VERSION_TYPE                       (required) snapshot | experimental | commit | pr | release
#   GH_TOKEN                           (required) token for gh api calls
#   GITHUB_OUTPUT                      step output file; defaults to /dev/null
#                                      so the script can be run locally
#   INPUT_CLIENT_VERSION               explicit client version override
#   INPUT_APP_VERSION                  explicit app version override
#   INPUT_TOOLKIT_VERSION              explicit toolkit version override
#   GNOSISVPN_PACKAGE_PREVIOUS_VERSION previously built versions, used for the
#   GNOSISVPN_CLIENT_PREVIOUS_VERSION  snapshot/experimental skip check and, via
#   GNOSISVPN_APP_PREVIOUS_VERSION     the outputs below, for the changelog range
#   GNOSISVPN_TOOLKIT_PREVIOUS_VERSION
#   GNOSISVPN_<C>_PREVIOUS_VERSION_PR           per-line candidates; when the one
#   GNOSISVPN_<C>_PREVIOUS_VERSION_RELEASE      matching VERSION_TYPE is SET it
#   GNOSISVPN_<C>_PREVIOUS_VERSION_EXPERIMENTAL wins, even when empty. The
#                                      workflow passes all three because GitHub
#                                      Actions expressions cannot yield an empty
#                                      string from a ternary (see
#                                      select_previous_version below)
#   PR_HEAD_SHA                        PR head commit sha (VERSION_TYPE=commit)
#   GITHUB_REPOSITORY, GITHUB_REF      set by GitHub Actions (VERSION_TYPE=release)
#
# Outputs written to GITHUB_OUTPUT:
#   LATEST_GNOSISVPN_PACKAGE_PR_VERSION, GNOSISVPN_PACKAGE_VERSION,
#   GNOSISVPN_CLIENT_VERSION, GNOSISVPN_APP_VERSION,
#   GNOSISVPN_TOOLKIT_VERSION, GNOSISVPN_NETWORKS, GNOSISVPN_CHANNEL,
#   SKIP_BUILDING, and the four resolved GNOSISVPN_*_PREVIOUS_VERSION values
#

set -euo pipefail

# Source common functions (log_* helpers, version_core_* comparators)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

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

# Newest published (non-draft, non-prerelease) GitHub release of gnosis/<repo>
# whose numeric version core is below <boundary>. Same newest-first ordering as
# releases/latest (created_at descending), just filtered to one installer line.
get_latest_release_version_below() {
    local repo=$1 boundary=$2 line tag
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        tag="${line#* }"
        version_core_is_numeric "$tag" || continue
        if version_core_lt "$tag" "$boundary"; then
            echo "${tag#v}"
            return 0
        fi
    done < <(gh api --paginate "repos/gnosis/${repo}/releases?per_page=100" \
        --jq '.[] | select(.draft == false and .prerelease == false) | "\(.created_at) \(.tag_name)"' | sort -r)
    log_error "No GitHub release of gnosis/${repo} has a version core below ${boundary}."
    return 1
}

# Pick this line's "previously built" version for one component.
#
# Each installer line tracks its own previous versions, and the caller cannot do
# the picking: a GitHub Actions ternary cannot produce an empty string, because
# `cond && vars.EMPTY || other` sees the empty value as falsy and falls through
# to `other`. On the experimental line that silently substituted the standard
# line's versions, which would diff the changelog across the wrong range. So the
# workflow passes every candidate and the choice happens here, where an unset
# variable and an empty one can be told apart: a SET-but-empty candidate means
# "no previous build on this line" and is honoured as such.
select_previous_version() {
    local component="$1" suffix specific plain
    case "${version_type}" in
    release) suffix="RELEASE" ;;
    experimental) suffix="EXPERIMENTAL" ;;
    *) suffix="PR" ;;
    esac
    specific="GNOSISVPN_${component}_PREVIOUS_VERSION_${suffix}"
    plain="GNOSISVPN_${component}_PREVIOUS_VERSION"
    if [[ -n ${!specific+set} ]]; then
        printf '%s\n' "${!specific}"
    else
        printf '%s\n' "${!plain:-}"
    fi
}

main() {
    local version_type="${VERSION_TYPE:-}"
    if [[ -z ${version_type} ]]; then
        log_error "VERSION_TYPE is not set. Expected snapshot, experimental, commit, pr, or release."
        exit 1
    fi

    # Resolve this line's previous versions before anything reads them, and
    # publish them so the build jobs use the same values for the changelog.
    GNOSISVPN_PACKAGE_PREVIOUS_VERSION="$(select_previous_version PACKAGE)"
    GNOSISVPN_CLIENT_PREVIOUS_VERSION="$(select_previous_version CLIENT)"
    GNOSISVPN_APP_PREVIOUS_VERSION="$(select_previous_version APP)"
    GNOSISVPN_TOOLKIT_PREVIOUS_VERSION="$(select_previous_version TOOLKIT)"
    set_output "GNOSISVPN_PACKAGE_PREVIOUS_VERSION" "${GNOSISVPN_PACKAGE_PREVIOUS_VERSION}"
    set_output "GNOSISVPN_CLIENT_PREVIOUS_VERSION" "${GNOSISVPN_CLIENT_PREVIOUS_VERSION}"
    set_output "GNOSISVPN_APP_PREVIOUS_VERSION" "${GNOSISVPN_APP_PREVIOUS_VERSION}"
    set_output "GNOSISVPN_TOOLKIT_PREVIOUS_VERSION" "${GNOSISVPN_TOOLKIT_PREVIOUS_VERSION}"

    # Which side of COMPONENT_VERSION_BOUNDARY this line's client/app must sit on.
    local component_filter=()
    if [[ ${version_type} == "experimental" ]]; then
        component_filter=(--min-version "${COMPONENT_VERSION_BOUNDARY}")
    else
        component_filter=(--below-version "${COMPONENT_VERSION_BOUNDARY}")
    fi

    # An explicit operator override always wins, but warn when it belongs to the
    # other line — that combination builds a package the network configs of this
    # line were not validated against.
    warn_if_outside_boundary() {
        local package="$1" version="$2"
        version_core_is_numeric "$version" || return 0
        if [[ ${version_type} == "experimental" ]]; then
            version_core_ge "$version" "${COMPONENT_VERSION_BOUNDARY}" ||
                log_warn "Explicit ${package} override ${version} is below the experimental boundary ${COMPONENT_VERSION_BOUNDARY}; using it anyway."
        else
            version_core_lt "$version" "${COMPONENT_VERSION_BOUNDARY}" ||
                log_warn "Explicit ${package} override ${version} is not below the boundary ${COMPONENT_VERSION_BOUNDARY} that this line expects; using it anyway."
        fi
    }

    # Exit 2 from the resolver means "no version inside this line's window". For
    # the nightly lines that is a legitimate skip (e.g. no client/app at or above
    # the boundary has been published yet); everywhere else it is a hard failure.
    local components_out_of_window=false
    handle_resolve_rc() {
        local package="$1" rc="$2"
        case "$rc" in
        0) return 0 ;;
        2)
            if [[ ${version_type} == "snapshot" || ${version_type} == "experimental" ]]; then
                log_warn "No ${package} version inside the ${version_type} line's version window."
                components_out_of_window=true
                return 0
            fi
            log_error "No ${package} version inside the version window required for a ${version_type} build."
            exit 1
            ;;
        *)
            log_error "Failed to resolve ${package} (exit ${rc})."
            exit 1
            ;;
        esac
    }

    local latest_package_pr_version
    latest_package_pr_version=$(get_latest_pr_version "gnosis_vpn" "package.json")

    # Auto-detect the newest *complete* client/app/toolkit versions.
    # CONTRACT: the resolved value must be the exact registry version tag,
    # e.g. "0.91.1+pr.638". It is used verbatim as the GCP artifact tag in
    # download-binaries.sh, in the snapshot skip comparison below, and in the
    # "+pr." branch of generate-changelog.ts, so a different encoding would
    # break those. Registry tags never carry a leading "v", but explicit
    # INPUT_* overrides and GitHub release tags may, so strip it.
    local latest_client_pr_version="" latest_app_pr_version="" latest_toolkit_pr_version=""
    local rc=0
    if [[ ${version_type} != "release" ]]; then
        if [[ -n ${INPUT_CLIENT_VERSION:-} ]]; then
            latest_client_pr_version="${INPUT_CLIENT_VERSION#v}"
            warn_if_outside_boundary "gnosis_vpn-client" "${latest_client_pr_version}"
        else
            set +e
            latest_client_pr_version="$(
                "${SCRIPT_DIR}/resolve-registry-version.sh" "${component_filter[@]}" gnosis_vpn-client \
                    gnosis_vpn-root-x86_64-linux gnosis_vpn-worker-x86_64-linux gnosis_vpn-ctl-x86_64-linux \
                    gnosis_vpn-root-aarch64-linux gnosis_vpn-worker-aarch64-linux gnosis_vpn-ctl-aarch64-linux \
                    gnosis_vpn-root-aarch64-darwin gnosis_vpn-worker-aarch64-darwin gnosis_vpn-ctl-aarch64-darwin
            )"
            rc=$?
            set -e
            handle_resolve_rc "gnosis_vpn-client" "$rc"
        fi
        if [[ -n ${INPUT_APP_VERSION:-} ]]; then
            latest_app_pr_version="${INPUT_APP_VERSION#v}"
            warn_if_outside_boundary "gnosis_vpn-app" "${latest_app_pr_version}"
        else
            set +e
            latest_app_pr_version="$(
                "${SCRIPT_DIR}/resolve-registry-version.sh" "${component_filter[@]}" gnosis_vpn-app \
                    gnosis_vpn-app-x86_64-linux.deb gnosis_vpn-app-aarch64-linux.deb gnosis_vpn-app-aarch64-darwin.dmg
            )"
            rc=$?
            set -e
            handle_resolve_rc "gnosis_vpn-app" "$rc"
        fi
        # The toolkit is shared by both lines: no version window.
        if [[ -n ${INPUT_TOOLKIT_VERSION:-} ]]; then
            latest_toolkit_pr_version="${INPUT_TOOLKIT_VERSION#v}"
        else
            set +e
            latest_toolkit_pr_version="$(
                "${SCRIPT_DIR}/resolve-registry-version.sh" gnosis_vpn-toolkit gnosis_vpn-update-aarch64-darwin
            )"
            rc=$?
            set -e
            handle_resolve_rc "gnosis_vpn-toolkit" "$rc"
        fi
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
    experimental)
        # Snapshot-shaped date version with a trailing ".experimental" marker.
        # Everything that infers a channel from a version string must test this
        # suffix BEFORE the generic "+" (snapshot) case — the metadata type is
        # deliberately still "build" so the version grammar is unchanged.
        set_output "GNOSISVPN_PACKAGE_VERSION" "$(date +%Y.%m.%d+build.%H%M%S.experimental)"
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
        # Stable releases belong to the standard line, so the newest release
        # below the boundary is used rather than releases/latest. errexit does
        # not propagate out of a command substitution, hence the emptiness check.
        client_version="${INPUT_CLIENT_VERSION:-$(get_latest_release_version_below "gnosis_vpn-client" "${COMPONENT_VERSION_BOUNDARY}")}"
        [[ -n ${client_version} ]] || exit 1
        app_version="${INPUT_APP_VERSION:-$(get_latest_release_version_below "gnosis_vpn-app" "${COMPONENT_VERSION_BOUNDARY}")}"
        [[ -n ${app_version} ]] || exit 1
        toolkit_version="${INPUT_TOOLKIT_VERSION:-$(get_latest_release_version "gnosis_vpn-toolkit")}"
        [[ -n ${toolkit_version} ]] || exit 1
        # GitHub tags and operator inputs may carry a "v" prefix while the
        # registry tag never does; the download coordinates need a verbatim match.
        client_version="${client_version#v}"
        app_version="${app_version#v}"
        toolkit_version="${toolkit_version#v}"
        [[ -z ${INPUT_CLIENT_VERSION:-} ]] || warn_if_outside_boundary "gnosis_vpn-client" "${client_version}"
        [[ -z ${INPUT_APP_VERSION:-} ]] || warn_if_outside_boundary "gnosis_vpn-app" "${app_version}"
        set_output "GNOSISVPN_PACKAGE_VERSION" "${package_version}"
        set_output "GNOSISVPN_CLIENT_VERSION" "${client_version}"
        set_output "GNOSISVPN_APP_VERSION" "${app_version}"
        set_output "GNOSISVPN_TOOLKIT_VERSION" "${toolkit_version}"
        ;;
    *)
        log_error "Invalid version_type: ${version_type}. Expected snapshot, experimental, commit, pr, or release."
        exit 1
        ;;
    esac

    # Line-specific packaging inputs: which networks the package ships and which
    # channel it is published to. Consumed by generate-package.sh (network configs,
    # baked network list) and generate-changelog.ts (download links).
    local networks channel
    case "${version_type}" in
    experimental)
        networks="${NETWORKS_EXPERIMENTAL}"
        channel="experimental"
        ;;
    snapshot)
        networks="${NETWORKS_STANDARD}"
        channel="snapshot"
        ;;
    release)
        networks="${NETWORKS_STANDARD}"
        channel="stable"
        ;;
    *)
        # pr / commit builds are never published, so they carry no channel.
        networks="${NETWORKS_STANDARD}"
        channel=""
        ;;
    esac
    set_output "GNOSISVPN_NETWORKS" "${networks}"
    set_output "GNOSISVPN_CHANNEL" "${channel}"

    local skip_building=false
    if [[ ${version_type} == "snapshot" || ${version_type} == "experimental" ]]; then
        if [[ ${components_out_of_window} == true ]]; then
            skip_building=true
            log_info "No client/app version is available for the ${version_type} line yet. Skipping the build."
        elif [[ ${latest_package_pr_number} == "${previous_package_pr_number}" ]] &&
            [[ ${latest_client_pr_version} == "${GNOSISVPN_CLIENT_PREVIOUS_VERSION:-}" ]] &&
            [[ ${latest_app_pr_version} == "${GNOSISVPN_APP_PREVIOUS_VERSION:-}" ]] &&
            [[ ${latest_toolkit_pr_version} == "${GNOSISVPN_TOOLKIT_PREVIOUS_VERSION:-}" ]]; then
            skip_building=true
            log_info "No new gnosis_vpn PR, nor newly published gnosis_vpn-client / gnosis_vpn-app / gnosis_vpn-toolkit versions found. Skipping ${version_type} build."
        fi
    fi

    if [[ ${skip_building} == true ]]; then
        set_output "SKIP_BUILDING" "true"
    else
        set_output "SKIP_BUILDING" "false"
        log_info "Proceeding with the build."
    fi
}

main "$@"
