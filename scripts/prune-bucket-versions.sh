#!/usr/bin/env bash
#
# Prune old gnosisvpn artifacts under a GCS prefix, keeping only the newest
# --keep versions (by `sort -V`). Each pruned version loses all its objects:
# the .deb / .pkg plus its .asc / .sha256 sidecars.
#
# Caller: .github/workflows/prune-bucket.yaml runs this twice per channel (APT
# pool + macOS dir) after a successful publish — build-binary.yaml for snapshot,
# release.yaml for stable. Retention counts come from scripts/config.sh.
#
# Best-effort: a failed deletion warns but exits 0, so cleanup never turns a
# successful publish red. Only call AFTER publishing — the retained set sorts
# newest, so the just-published version is never deleted.
#
# SAFETY: only call this AFTER the new version is fully published and every
# index/manifest references the retained set. The retained set always includes
# the just-published version because it sorts newest, so it is never deleted.

set -Eeuo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PREFIX=""
KEEP=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") --prefix <gs://...> --keep <N> [--dry-run]

Required:
  --prefix <gs://bucket/path/>   GCS prefix to prune (trailing slash optional)
  --keep <N>                     Number of most-recent versions to retain (>= 1)

Options:
  --dry-run                      List what would be deleted without deleting
  -h, --help                     Show this help
EOF
    exit "${1:-1}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --prefix)
            [[ -n ${2:-} ]] || {
                log_error "--prefix requires a value"
                usage
            }
            PREFIX="$2"
            shift 2
            ;;
        --keep)
            [[ -n ${2:-} ]] || {
                log_error "--keep requires a value"
                usage
            }
            KEEP="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
        esac
    done

    [[ -n $PREFIX ]] || {
        log_error "--prefix is required"
        usage
    }
    [[ $PREFIX == gs://* ]] || {
        log_error "--prefix must be a gs:// URL (got: '${PREFIX}')"
        usage
    }
    [[ $KEEP =~ ^[0-9]+$ && $KEEP -ge 1 ]] || {
        log_error "--keep must be a positive integer (got: '${KEEP}')"
        usage
    }
    # Normalize to a single trailing slash so wildcard joins are predictable.
    PREFIX="${PREFIX%/}/"

    if ! command -v gsutil >/dev/null 2>&1; then
        log_error "gsutil not installed"
        exit 1
    fi
}

main() {
    parse_args "$@"

    log_info "Listing artifacts under ${PREFIX} ..."
    # `gsutil ls` returns non-zero for ALL failures (empty prefix, auth, network),
    # so distinguish "matched no objects" from real errors — pruning on a failed
    # listing could otherwise delete nothing (or, worse, mislead) silently.
    local ls_output ls_status=0
    ls_output=$(gsutil ls "${PREFIX}" 2>&1) || ls_status=$?
    if [[ $ls_status -ne 0 ]]; then
        if echo "$ls_output" | grep -qi 'matched no objects'; then
            log_info "Nothing under ${PREFIX} — nothing to prune."
            exit 0
        fi
        log_error "Failed to list ${PREFIX} (gsutil exit ${ls_status}):"
        echo "$ls_output" >&2
        exit 1
    fi

    # Collect unique versions from primary artifacts only. Sidecars end in
    # .deb.asc / .pkg.sha256 etc. and do not match the `\.(deb|pkg)$` anchor, so
    # they are not counted as versions (but are still removed via the wildcard
    # below). Version slugs never contain '_', so the greedy `.*` stops at the
    # final `_<arch>`.
    local versions
    versions=$(printf '%s\n' "$ls_output" |
        sed -n 's#.*/gnosisvpn_\(.*\)_\(amd64\|arm64\)\.\(deb\|pkg\)$#\1#p' |
        sort -Vu)

    local total=0
    [[ -n $versions ]] && total=$(printf '%s\n' "$versions" | wc -l)
    if [[ $total -le $KEEP ]]; then
        log_info "Found ${total} version(s); retention is ${KEEP} — nothing to prune."
        exit 0
    fi

    # `head -n -KEEP` yields every version except the newest KEEP.
    local to_delete
    to_delete=$(printf '%s\n' "$versions" | head -n -"${KEEP}")

    log_info "Found ${total} version(s); keeping newest ${KEEP}, pruning $((total - KEEP)):"
    printf '%s\n' "$to_delete" | sed 's/^/    /'

    local failures=0 v
    while read -r v; do
        [[ -n $v ]] || continue
        # The trailing `_` after the version anchors the match so e.g. pruning
        # 0.9.1 never touches 0.9.10. The wildcard sweeps the artifact and all
        # sidecars for this version.
        local glob="${PREFIX}gnosisvpn_${v}_*"
        if [[ $DRY_RUN -eq 1 ]]; then
            log_info "[dry-run] would delete: ${glob}"
            gsutil ls "${glob}" 2>/dev/null | sed 's/^/    /' || true
            continue
        fi
        log_info "Pruning version ${v} ..."
        if ! gsutil -m rm "${glob}"; then
            log_warn "Failed to prune version ${v} — leaving in place (will retry next publish)"
            failures=$((failures + 1))
        fi
    done <<<"$to_delete"

    if [[ $failures -gt 0 ]]; then
        log_warn "Pruning completed with ${failures} version(s) left behind."
    else
        log_success "Pruning complete."
    fi
    # Best-effort: never fail the caller's publish over cleanup.
    exit 0
}

main "$@"
