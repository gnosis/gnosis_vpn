#!/usr/bin/env bash
# Fails when a client and an app version speak different gnosis_vpn-ipc protocols; the app refuses such a service.
# Usage: check-ipc-compat.sh <client_version> <app_version>  (registry tags like 1.0.1+pr.1053 or 1.0.1+commit.abcdef0, or release versions; needs GH_TOKEN)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Registry tags name the merged PR or the commit; release versions name their v-prefixed tag.
commit_for_version() {
    local repo="$1" version="${2#v}"
    if [[ ${version} =~ \+pr\.([0-9]+)$ ]]; then
        gh api "repos/gnosis/${repo}/pulls/${BASH_REMATCH[1]}" --jq '.merge_commit_sha'
        return
    fi
    if [[ ${version} =~ \+commit\.([0-9a-f]+)$ ]]; then
        gh api "repos/gnosis/${repo}/commits/${BASH_REMATCH[1]}" --jq '.sha'
        return
    fi
    if [[ ${version} != *+* ]]; then
        gh api "repos/gnosis/${repo}/commits/v${version}" --jq '.sha'
        return
    fi
    log_error "Cannot map ${repo} version ${version} to a commit; expected <x.y.z>+pr.<n>, <x.y.z>+commit.<sha> or a release version."
    return 1
}

# Raw media type, so the contents API's 1 MB limit never applies to Cargo.lock.
read_file_at() {
    local repo="$1" path="$2" ref="$3"
    gh api -H "Accept: application/vnd.github.raw" "repos/gnosis/${repo}/contents/${path}?ref=${ref}"
}

protocol_version_at() {
    local path="$1" rev="$2" version
    version="$(read_file_at gnosis_vpn-client "gnosis_vpn-ipc/src/${path}" "${rev}" |
        sed -n 's/^pub const PROTOCOL_VERSION: [a-z0-9]* = \([0-9]*\);$/\1/p')"
    if [[ -z ${version} ]]; then
        log_error "No PROTOCOL_VERSION in gnosis_vpn-ipc/src/${path} at client rev ${rev}."
        return 1
    fi
    echo "${version}"
}

ipc_rev_pinned_by_app() {
    local app_commit="$1" rev
    rev="$(read_file_at gnosis_vpn-app src-tauri/Cargo.lock "${app_commit}" |
        sed -n '/^name = "gnosis_vpn-ipc"$/,/^$/s/^source = "git+.*#\([0-9a-f]*\)"$/\1/p')"
    if [[ -z ${rev} ]]; then
        log_error "The app's Cargo.lock at ${app_commit} pins no gnosis_vpn-ipc git revision."
        return 1
    fi
    echo "${rev}"
}

main() {
    if [[ $# -ne 2 ]]; then
        log_error "Usage: $0 <client_version> <app_version>"
        exit 1
    fi
    local client_version="$1" app_version="$2"
    local client_rev app_commit app_rev
    client_rev="$(commit_for_version gnosis_vpn-client "${client_version}")"
    app_commit="$(commit_for_version gnosis_vpn-app "${app_version}")"
    app_rev="$(ipc_rev_pinned_by_app "${app_commit}")"

    local mismatch=false path client_protocol app_protocol
    for path in protocol.rs traffic.rs; do
        client_protocol="$(protocol_version_at "${path}" "${client_rev}")"
        app_protocol="$(protocol_version_at "${path}" "${app_rev}")"
        if [[ ${client_protocol} != "${app_protocol}" ]]; then
            log_error "${path}: client ${client_version} speaks protocol ${client_protocol}, app ${app_version} speaks ${app_protocol}."
            mismatch=true
        fi
    done

    if [[ ${mismatch} == true ]]; then
        log_error "Bump the app's gnosis_vpn-client ref (client rev ${client_rev}) before packaging this pair."
        exit 1
    fi
    log_success "Client ${client_version} and app ${app_version} speak the same IPC protocols."
}

main "$@"
