#!/bin/bash
#
# Resolve the newest registry version of a package that is complete across all
# target architectures.
#
# Queries the GCP Artifact Registry for every version of the given package,
# newest-first by upload time, and prints the first version whose files include
# every required file. Exits non-zero if no version is complete.
#
# All diagnostics go to stderr; ONLY the resolved version is printed to stdout,
# so callers can safely capture it with:  ver="$(resolve-registry-version.sh ...)"
#
# Usage: resolve-registry-version.sh <package> <required-file>...
#

set -euo pipefail

# Source common functions (log_* helpers)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Registry coordinates (must match download-binaries.sh)
GCP_PROJECT="gnosisvpn-production"
GCP_LOCATION="europe-west3"
GCP_REPOSITORY="rust-binaries"

usage() {
    log_error "Usage: $0 <package> <required-file>..."
    exit 1
}

main() {
    local package="${1:-}"
    if [[ -z $package ]]; then
        usage
    fi
    shift
    local required_files=("$@")
    if [[ ${#required_files[@]} -eq 0 ]]; then
        usage
    fi

    log_info "Resolving newest complete version for '${package}' (${#required_files[@]} required files)" >&2

    # Versions, newest-first by upload time. `name` is a full resource path;
    # its basename is the version tag.
    local versions
    versions="$(gcloud artifacts versions list \
        --project="${GCP_PROJECT}" --location="${GCP_LOCATION}" --repository="${GCP_REPOSITORY}" \
        --package="${package}" --sort-by="~createTime" --format="value(name)" |
        sed 's#.*/##')"

    if [[ -z $versions ]]; then
        log_error "No versions found for package '${package}' in ${GCP_REPOSITORY}."
        exit 1
    fi

    local newest="" version files_raw files_rc missing file line found
    while IFS= read -r version; do
        [[ -z $version ]] && continue
        [[ -z $newest ]] && newest="$version"

        # List this version's files. `value(name)` returns full resource names
        # whose file segment is the ".../files/<package>:<version>:<filename>"
        # coordinate (same form download-binaries.sh uses). Capture stderr and
        # the exit code so a real gcloud failure is surfaced rather than being
        # silently treated as "version incomplete".
        set +e
        files_raw="$(gcloud artifacts files list \
            --project="${GCP_PROJECT}" --location="${GCP_LOCATION}" --repository="${GCP_REPOSITORY}" \
            --package="${package}" --version="${version}" --format="value(name)" 2>&1)"
        files_rc=$?
        set -e
        if [[ $files_rc -ne 0 ]]; then
            log_error "gcloud artifacts files list failed for ${package} ${version} (exit ${files_rc}):"
            log_error "${files_raw}"
            exit 1
        fi
        if [[ -n ${RESOLVE_DEBUG:-} ]]; then
            log_info "[debug] files listed for ${package} ${version}:" >&2
            printf '%s\n' "${files_raw}" | sed 's/^/[debug]   /' >&2
        fi

        # A required file is present when some listed name ENDS WITH that
        # filename — separator-agnostic, so it works whether the file segment is
        # ":"-, "/"- or "%2F"-separated. Filenames are distinct and none is a
        # suffix of another, so ends-with matching is unambiguous here.
        missing=()
        for file in "${required_files[@]}"; do
            found=0
            while IFS= read -r line; do
                [[ -z $line ]] && continue
                if [[ $line == *"$file" ]]; then
                    found=1
                    break
                fi
            done <<<"${files_raw}"
            [[ $found -eq 1 ]] || missing+=("$file")
        done

        if [[ ${#missing[@]} -eq 0 ]]; then
            log_success "Selected '${package}' version: ${version}" >&2
            echo "$version"
            return 0
        fi
        log_info "Skipping ${package} ${version}: missing ${#missing[@]} file(s): ${missing[*]}" >&2
    done <<<"$versions"

    log_error "No version of '${package}' has all required files across every architecture."
    log_error "Newest candidate '${newest}' was incomplete. Required files: ${required_files[*]}"
    exit 1
}

main "$@"
