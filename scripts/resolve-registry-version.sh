#!/bin/bash
#
# Resolve the newest registry version of a package that is complete across all
# target architectures.
#
# Queries the GCP Artifact Registry for every version of the given package,
# newest-first by upload time, and prints the first version whose files include
# every required file. Exits non-zero if no version is complete.
#
# The optional --min-version / --below-version window restricts candidates to a
# range of numeric version cores (the MAJOR.MINOR.PATCH before any "+metadata").
# It is how the two installer lines pick their components: the standard line
# takes --below-version 0.100.0, the experimental line --min-version 0.100.0.
# Versions whose core is not plain x.y.z are skipped while a window is active.
#
# All diagnostics go to stderr; ONLY the resolved version is printed to stdout,
# so callers can safely capture it with:  ver="$(resolve-registry-version.sh ...)"
#
# Usage: resolve-registry-version.sh [--min-version <x.y.z>] [--below-version <x.y.z>] <package> <required-file>...
#
# Exit codes:
#   0  a complete version was found (printed to stdout)
#   1  a real failure: bad usage, gcloud error, or no complete version at all
#   2  no version has a core inside the requested window (callers may treat this
#      as "nothing published for this line yet" and skip a build)
#

set -euo pipefail

# Source common functions (log_* helpers, GCP_* registry coordinates, version_core_*)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

MIN_VERSION=""
BELOW_VERSION=""

usage() {
    log_error "Usage: $0 [--min-version <x.y.z>] [--below-version <x.y.z>] <package> <required-file>..."
    exit 1
}

parse_options() {
    while [[ ${1:-} == --* ]]; do
        case "$1" in
        --min-version)
            if [[ -z ${2:-} ]]; then
                log_error "--min-version requires a value"
                usage
            fi
            MIN_VERSION="$2"
            shift 2
            ;;
        --below-version)
            if [[ -z ${2:-} ]]; then
                log_error "--below-version requires a value"
                usage
            fi
            BELOW_VERSION="$2"
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
        esac
    done
    if [[ -n $MIN_VERSION ]] && ! version_core_is_numeric "$MIN_VERSION"; then
        log_error "--min-version must be a numeric x.y.z version (got: '${MIN_VERSION}')"
        usage
    fi
    if [[ -n $BELOW_VERSION ]] && ! version_core_is_numeric "$BELOW_VERSION"; then
        log_error "--below-version must be a numeric x.y.z version (got: '${BELOW_VERSION}')"
        usage
    fi
    REMAINING_ARGS=("$@")
}

main() {
    REMAINING_ARGS=()
    parse_options "$@"
    set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

    local package="${1:-}"
    if [[ -z $package ]]; then
        usage
    fi
    shift
    local required_files=("$@")
    if [[ ${#required_files[@]} -eq 0 ]]; then
        usage
    fi

    local window="any"
    if [[ -n $MIN_VERSION || -n $BELOW_VERSION ]]; then
        window="[min=${MIN_VERSION:--}, below=${BELOW_VERSION:--})"
    fi
    log_info "Resolving newest complete version for '${package}' (${#required_files[@]} required files, window ${window})" >&2

    # Versions, newest-first by upload time. `name` is a full resource path;
    # its basename is the version tag.
    local versions
    versions="$(gcloud artifacts versions list \
        --package="${package}" --sort-by="~createTime" --format="value(name)" |
        sed 's#.*/##')"

    if [[ -z $versions ]]; then
        log_error "No versions found for package '${package}' in ${CLOUDSDK_ARTIFACTS_REPOSITORY}."
        exit 1
    fi

    local newest="" version files_raw files_rc missing file line found in_window=0
    while IFS= read -r version; do
        [[ -z $version ]] && continue

        # Apply the version window BEFORE listing files: skipping here saves one
        # registry API call per rejected version.
        if [[ -n $MIN_VERSION || -n $BELOW_VERSION ]]; then
            if ! version_core_is_numeric "$version"; then
                log_info "Skipping ${package} ${version}: version core is not plain x.y.z" >&2
                continue
            fi
            if [[ -n $MIN_VERSION ]] && version_core_lt "$version" "$MIN_VERSION"; then
                log_info "Skipping ${package} ${version}: core below --min-version ${MIN_VERSION}" >&2
                continue
            fi
            if [[ -n $BELOW_VERSION ]] && version_core_ge "$version" "$BELOW_VERSION"; then
                log_info "Skipping ${package} ${version}: core not below --below-version ${BELOW_VERSION}" >&2
                continue
            fi
        fi
        in_window=$((in_window + 1))
        [[ -z $newest ]] && newest="$version"

        # List this version's files. `value(name)` returns full resource names
        # whose file segment is the ".../files/<package>:<version>:<filename>"
        # coordinate (same form download-binaries.sh uses). Capture stderr and
        # the exit code so a real gcloud failure is surfaced rather than being
        # silently treated as "version incomplete".
        set +e
        files_raw="$(gcloud artifacts files list \
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

    # No candidate at all inside the window is a different situation from "some
    # candidates existed but none was complete": the caller may legitimately skip
    # a build for a line whose components have not been published yet.
    if [[ $in_window -eq 0 ]]; then
        log_error "No version of '${package}' has a core inside the window ${window}."
        exit 2
    fi

    log_error "No version of '${package}' has all required files across every architecture."
    log_error "Newest candidate '${newest}' was incomplete. Required files: ${required_files[*]}"
    exit 1
}

main "$@"
