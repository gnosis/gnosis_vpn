#!/usr/bin/env bash
#
# Build and publish a signed dnf repository to gs://download.gnosisvpn.io/linux/rpm/<channel> using createrepo_c.
#
# Channels: stable, snapshot and experimental, one repository each; every repository indexes both architectures
# (dnf filters by arch). Pools are append-only and version-pinned, pruned separately (prune-bucket.yaml).
#
# Package signatures are embedded by nfpm at build time (generate-package-linux.sh) and checked here before
# publishing. The repository metadata is signed as repodata/repomd.xml.asc with the primary key: dnf5 rejects a
# repomd signature made by a subkey.
#
# The previous repomd.xml pair is saved to --previous-dir before publishing, so a failed stable release can put it
# back with --rollback.

set -Eeuo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

GNOSISVPN_RPM_BUCKET="${GNOSISVPN_RPM_BUCKET:-gs://download.gnosisvpn.io/linux/rpm}"
GNOSISVPN_RPM_PUBLIC_KEY="${GNOSISVPN_RPM_PUBLIC_KEY:-${REPO_ROOT}/gnosisvpn-public-key.asc}"
# Long key ID of the signing key; the trailing '!' passed to gpg pins the primary key.
GNOSISVPN_RPM_SIGNING_KEY="${GNOSISVPN_RPM_SIGNING_KEY:-84F73FEA46D10972}"

CHANNEL=""
RPMS_DIR=""
WORK_DIR=""
WORK_DIR_AUTO=0
PREVIOUS_DIR=""
ROLLBACK=0
VERSION=""
SIGNING_GNUPGHOME=""
VERIFY_GNUPGHOME=""

IMMUTABLE_HEADER="Cache-Control:public, max-age=31536000, immutable"
REVALIDATE_HEADER="Cache-Control:no-cache, max-age=60, must-revalidate"

usage() {
    cat <<EOF
Usage: $(basename "$0") --channel <stable|snapshot|experimental> --rpms <dir> --previous-dir <dir> [options]
       $(basename "$0") --channel <stable|snapshot|experimental> --rollback --previous-dir <dir> --version <version>

Publish:
  --channel <stable|snapshot|experimental>
                                  dnf repository to publish into
  --rpms <dir>                    Directory containing freshly built .rpm files.
                                  Must include:
                                    - gnosisvpn-<version>-1.x86_64.rpm
                                    - gnosisvpn-<version>-1.aarch64.rpm
                                  and, for each .rpm, matching sidecars:
                                    - <rpm>.asc      (GPG detached signature)
                                    - <rpm>.sha256   (sha256sum output)
  --previous-dir <dir>            Where the repomd.xml pair being replaced is saved

Rollback (restores the saved repomd.xml pair and deletes the version's packages):
  --rollback
  --previous-dir <dir>            Directory saved by the publish run
  --version <version>             Version the failed publish added

Options:
  --work-dir <dir>                Staging directory (default: \$(mktemp -d))
  --bucket <gs://...>             Override target bucket prefix
                                  (default: ${GNOSISVPN_RPM_BUCKET})
  --public-key <path>             Armored public key to verify against and publish
                                  (default: ${GNOSISVPN_RPM_PUBLIC_KEY})
  -h, --help                      Show this help

Environment:
  GNOSISVPN_GPG_PRIVATE_KEY_PATH      Armored private key file (required to publish)
  GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD  Passphrase for the private key (required to publish)
  GNOSISVPN_RPM_SIGNING_KEY           Long key ID of the primary signing key
                                      (default: ${GNOSISVPN_RPM_SIGNING_KEY})
EOF
    exit "${1:-1}"
}

# Prints "<version> <arch>" for a well-formed package filename; fails otherwise.
parse_rpm_filename() {
    if [[ $1 =~ ^gnosisvpn-(.+)-1\.(x86_64|aarch64)\.rpm$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# Metadata files (basenames) a repomd.xml references; prints nothing when the file does not exist.
repodata_hrefs() {
    [[ -f $1 ]] || return 0
    grep -o 'href="repodata/[^"]*"' "$1" | sed -e 's|^href="repodata/||' -e 's|"$||'
}

# Bucket repodata objects referenced by neither metadata generation; the repomd pair itself always stays.
stale_repodata_objects() {
    local listing="$1" referenced="$2" object name
    while IFS= read -r object; do
        [[ -n $object ]] || continue
        name="${object##*/}"
        case "$name" in
        repomd.xml | repomd.xml.asc) continue ;;
        esac
        if ! grep -qxF "$name" <<<"$referenced"; then
            echo "$object"
        fi
    done <<<"$listing"
}

parse_args() {
    # Without this guard `shift 2` would trip `set -e` before the helpful error below, exiting silently.
    require_value() {
        if [[ -z ${2:-} ]]; then
            log_error "$1 requires a value"
            usage
        fi
    }
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --channel)
            require_value "$1" "${2:-}"
            CHANNEL="$2"
            shift 2
            ;;
        --rpms)
            require_value "$1" "${2:-}"
            RPMS_DIR="$2"
            shift 2
            ;;
        --work-dir)
            require_value "$1" "${2:-}"
            WORK_DIR="$2"
            shift 2
            ;;
        --bucket)
            require_value "$1" "${2:-}"
            GNOSISVPN_RPM_BUCKET="$2"
            shift 2
            ;;
        --public-key)
            require_value "$1" "${2:-}"
            GNOSISVPN_RPM_PUBLIC_KEY="$2"
            shift 2
            ;;
        --previous-dir)
            require_value "$1" "${2:-}"
            PREVIOUS_DIR="$2"
            shift 2
            ;;
        --version)
            require_value "$1" "${2:-}"
            VERSION="$2"
            shift 2
            ;;
        --rollback)
            ROLLBACK=1
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

    case "$CHANNEL" in
    stable | snapshot | experimental) ;;
    *)
        log_error "--channel must be 'stable', 'snapshot' or 'experimental' (got: '${CHANNEL}')"
        usage
        ;;
    esac
    if [[ -z $PREVIOUS_DIR ]]; then
        log_error "--previous-dir is required"
        usage
    fi
    if ! command -v gsutil >/dev/null 2>&1; then
        log_error "gsutil not installed"
        exit 1
    fi

    if [[ $ROLLBACK -eq 1 ]]; then
        if [[ ! -f "${PREVIOUS_DIR}/channel" ]]; then
            log_error "--previous-dir must point to the directory saved by the publish run (got: '${PREVIOUS_DIR}')"
            exit 1
        fi
        if [[ "$(cat "${PREVIOUS_DIR}/channel")" != "$CHANNEL" ]]; then
            log_error "${PREVIOUS_DIR} was saved for the '$(cat "${PREVIOUS_DIR}/channel")' channel, not '${CHANNEL}'"
            exit 1
        fi
        if [[ -z $VERSION ]]; then
            log_error "--rollback requires --version"
            usage
        fi
        return 0
    fi

    if [[ -z $RPMS_DIR || ! -d $RPMS_DIR ]]; then
        log_error "--rpms must point to an existing directory (got: '${RPMS_DIR}')"
        usage
    fi
    # Enforce filename shape, require both arches, reject mixed-version inputs.
    local has_x86_64=0 has_aarch64=0 version_seen="" parsed rpm name
    for rpm in "$RPMS_DIR"/*.rpm; do
        [[ -e $rpm ]] || continue
        name="$(basename "$rpm")"
        if ! parsed="$(parse_rpm_filename "$name")"; then
            log_error "Unexpected .rpm filename: ${name} (expected gnosisvpn-<version>-1.<x86_64|aarch64>.rpm)"
            exit 1
        fi
        if [[ -z $version_seen ]]; then
            version_seen="${parsed% *}"
        elif [[ ${parsed% *} != "$version_seen" ]]; then
            log_error "All .rpm files must share the same version (got '${version_seen}' and '${parsed% *}')"
            exit 1
        fi
        case "${parsed#* }" in
        x86_64) has_x86_64=1 ;;
        aarch64) has_aarch64=1 ;;
        esac
    done
    if [[ $has_x86_64 -eq 0 || $has_aarch64 -eq 0 ]]; then
        log_error "--rpms must contain both an x86_64 and an aarch64 .rpm (found x86_64=${has_x86_64} aarch64=${has_aarch64})"
        exit 1
    fi
    VERSION="$version_seen"
    local missing=() f ext
    for rpm in "$RPMS_DIR"/*.rpm; do
        for ext in asc sha256; do
            [[ -f "${rpm}.${ext}" ]] || missing+=("${rpm}.${ext}")
        done
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing sidecar files (each .rpm needs .asc + .sha256):"
        for f in "${missing[@]}"; do log_error "  - ${f}"; done
        exit 1
    fi
    local sha
    for sha in "$RPMS_DIR"/*.rpm.sha256; do
        (cd "$(dirname "$sha")" && sha256sum -c "$(basename "$sha")" >/dev/null) || {
            log_error "sha256 mismatch: ${sha}"
            exit 1
        }
    done
    if [[ -z ${GNOSISVPN_GPG_PRIVATE_KEY_PATH:-} || ! -f ${GNOSISVPN_GPG_PRIVATE_KEY_PATH} ]]; then
        log_error "GNOSISVPN_GPG_PRIVATE_KEY_PATH must point to an armored private key"
        exit 1
    fi
    if [[ -z ${GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD:-} ]]; then
        log_error "GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD must be set"
        exit 1
    fi
    if [[ ! -f $GNOSISVPN_RPM_PUBLIC_KEY ]]; then
        log_error "Public key not found: ${GNOSISVPN_RPM_PUBLIC_KEY}"
        exit 1
    fi
    local tool
    for tool in createrepo_c rpmkeys gpg; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "${tool} not installed (provided by the nix devShell on Linux)"
            exit 1
        fi
    done
    if [[ -z $WORK_DIR ]]; then
        WORK_DIR="$(mktemp -d -t gnosisvpn-rpm-XXXXXX)"
        WORK_DIR_AUTO=1
    fi
    mkdir -p "$PREVIOUS_DIR"
}

verify_package_signatures() {
    log_info "Verifying .rpm signatures against the public key being published ..."
    VERIFY_GNUPGHOME="$(mktemp -d -t gnosisvpn-rpm-verify-XXXXXX)"
    chmod 700 "$VERIFY_GNUPGHOME"
    GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --quiet --import "$GNOSISVPN_RPM_PUBLIC_KEY"
    # A throwaway root keeps the import out of the host's rpm keyring.
    local rpm_root="${WORK_DIR}/rpm-root" rpm
    mkdir -p "$rpm_root"
    rpmkeys --root "$rpm_root" --import "$GNOSISVPN_RPM_PUBLIC_KEY"
    for rpm in "$RPMS_DIR"/*.rpm; do
        GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --verify "${rpm}.asc" "$rpm" 2>/dev/null || {
            log_error "GPG signature verification failed for $(basename "$rpm"): ${rpm}.asc does not verify against ${GNOSISVPN_RPM_PUBLIC_KEY}"
            exit 1
        }
        if ! rpmkeys --root "$rpm_root" --checksig "$rpm" | grep -q 'signatures OK'; then
            log_error "Embedded rpm signature of $(basename "$rpm") does not verify against ${GNOSISVPN_RPM_PUBLIC_KEY}"
            rpmkeys --root "$rpm_root" --checksig -v "$rpm" >&2 || true
            exit 1
        fi
    done
    log_success ".rpm signatures verify against the key that will be published"
}

# Fetches gs://.../<channel>/<subpath>/ into <dir>; an absent prefix yields an empty dir, any other gsutil error aborts.
pull_prefix() {
    local subpath="$1" dir="$2" ls_output ls_status=0
    mkdir -p "$dir"
    ls_output=$(gsutil ls "${GNOSISVPN_RPM_BUCKET}/${CHANNEL}/${subpath}/" 2>&1) || ls_status=$?
    if [[ $ls_status -eq 0 ]]; then
        gsutil -m rsync -d -r "${GNOSISVPN_RPM_BUCKET}/${CHANNEL}/${subpath}/" "${dir}/"
    elif echo "$ls_output" | grep -qi 'matched no objects'; then
        log_warn "${GNOSISVPN_RPM_BUCKET}/${CHANNEL}/${subpath}/ does not exist yet — starting from empty"
        find "$dir" -mindepth 1 -delete
    else
        log_error "Failed to read ${GNOSISVPN_RPM_BUCKET}/${CHANNEL}/${subpath}/"
        log_error "gsutil ls (exit ${ls_status}):"
        echo "$ls_output" >&2
        exit 1
    fi
}

save_previous_metadata() {
    log_info "Saving the current ${CHANNEL} repomd.xml pair to ${PREVIOUS_DIR} ..."
    local previous_repodata="${WORK_DIR}/previous-repodata"
    pull_prefix repodata "$previous_repodata"
    rm -f "${PREVIOUS_DIR}/repomd.xml" "${PREVIOUS_DIR}/repomd.xml.asc"
    # Marks the save as done even without previous metadata, so a rollback can tell "none" from "never saved".
    echo "$CHANNEL" >"${PREVIOUS_DIR}/channel"
    if [[ -f "${previous_repodata}/repomd.xml" ]]; then
        cp "${previous_repodata}/repomd.xml" "${PREVIOUS_DIR}/repomd.xml"
        [[ -f "${previous_repodata}/repomd.xml.asc" ]] && cp "${previous_repodata}/repomd.xml.asc" "${PREVIOUS_DIR}/repomd.xml.asc"
        log_success "Saved previous metadata"
    else
        log_warn "No previous ${CHANNEL} metadata — a rollback will remove the repository metadata"
    fi
}

stage_packages() {
    local packages_dir="${WORK_DIR}/${CHANNEL}/packages"
    log_info "Pulling existing ${CHANNEL} packages ..."
    pull_prefix packages "$packages_dir"

    # Append-only: a rerun with different bytes for a published filename must fail, because `cp -n` in upload
    # would keep the old bucket object while the new metadata describes the new bytes (checksum mismatch).
    local rpm name existing
    for rpm in "$RPMS_DIR"/*.rpm; do
        name="$(basename "$rpm")"
        existing="${packages_dir}/${name}"
        if [[ -f $existing ]] && ! cmp -s "$rpm" "$existing"; then
            log_error "${CHANNEL} repository already contains ${name} with different content."
            if [[ $CHANNEL == "stable" ]]; then
                log_error "Re-releasing the same version is not supported — bump package.json or delete the old .rpm manually."
            else
                log_error "${CHANNEL} filenames embed a timestamp and must not be reused — rebuild with a fresh version or delete the old .rpm manually."
            fi
            exit 1
        fi
    done

    log_info "Copying new .rpm files into ${packages_dir} ..."
    for rpm in "$RPMS_DIR"/*.rpm; do
        cp -v "$rpm" "${rpm}.asc" "${rpm}.sha256" "${packages_dir}/"
    done
    log_success "Staged ${CHANNEL} packages"
}

build_and_sign_metadata() {
    local repo_dir="${WORK_DIR}/${CHANNEL}"
    log_info "Generating ${CHANNEL} repository metadata ..."
    rm -rf "${repo_dir}/repodata"
    createrepo_c "$repo_dir"

    log_info "Signing repodata/repomd.xml with ${GNOSISVPN_RPM_SIGNING_KEY} ..."
    SIGNING_GNUPGHOME="$(mktemp -d -t gnosisvpn-rpm-gnupg-XXXXXX)"
    chmod 700 "$SIGNING_GNUPGHOME"
    printf '%s' "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
        GNUPGHOME="$SIGNING_GNUPGHOME" gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
            --import "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"
    printf '%s' "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
        GNUPGHOME="$SIGNING_GNUPGHOME" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
            --local-user "${GNOSISVPN_RPM_SIGNING_KEY}!" --armor \
            --output "${repo_dir}/repodata/repomd.xml.asc" --detach-sign "${repo_dir}/repodata/repomd.xml"

    # Catches drift between the committed public key and the private key in secrets before anything is uploaded.
    GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --verify "${repo_dir}/repodata/repomd.xml.asc" "${repo_dir}/repodata/repomd.xml" || {
        log_error "repomd.xml.asc does not verify against ${GNOSISVPN_RPM_PUBLIC_KEY} — the committed public key is stale or the signing private key was rotated"
        exit 1
    }
    log_success "Metadata generated and signed"
}

upload() {
    local repo_dir="${WORK_DIR}/${CHANNEL}" target="${GNOSISVPN_RPM_BUCKET}/${CHANNEL}"

    log_info "Uploading packages to ${target}/packages/ ..."
    # `cp -n` skips existing objects: old packages keep the headers of their original upload.
    gsutil -m -h "${IMMUTABLE_HEADER}" cp -n -r "${repo_dir}/packages/." "${target}/packages/"

    log_info "Uploading content-addressed metadata ..."
    local metadata=() file
    for file in "${repo_dir}"/repodata/*; do
        case "$(basename "$file")" in
        repomd.xml | repomd.xml.asc) ;;
        *) metadata+=("$file") ;;
        esac
    done
    gsutil -m -h "${IMMUTABLE_HEADER}" cp -n "${metadata[@]}" "${target}/repodata/"

    # Before the repomd swap, so the key is fetchable as soon as the new metadata is visible.
    log_info "Uploading public key ..."
    gsutil -h "Content-Type:application/pgp-keys" -h "${REVALIDATE_HEADER}" \
        cp "$GNOSISVPN_RPM_PUBLIC_KEY" "${GNOSISVPN_RPM_BUCKET}/RPM-GPG-KEY-gnosisvpn"

    # The pair cannot be swapped atomically; uploading the two small objects back to back keeps the window short.
    log_info "Uploading repomd.xml pair ..."
    gsutil -h "${REVALIDATE_HEADER}" cp "${repo_dir}/repodata/repomd.xml.asc" "${target}/repodata/repomd.xml.asc"
    gsutil -h "${REVALIDATE_HEADER}" cp "${repo_dir}/repodata/repomd.xml" "${target}/repodata/repomd.xml"
    log_success "Upload complete"
}

# Keeps the previous generation so clients holding the old repomd.xml can still fetch what it references.
prune_stale_metadata() {
    local target="${GNOSISVPN_RPM_BUCKET}/${CHANNEL}/repodata" listing referenced stale
    listing="$(gsutil ls "${target}/" 2>/dev/null || true)"
    referenced="$(
        repodata_hrefs "${WORK_DIR}/${CHANNEL}/repodata/repomd.xml"
        repodata_hrefs "${PREVIOUS_DIR}/repomd.xml"
    )"
    stale="$(stale_repodata_objects "$listing" "$referenced")"
    if [[ -z $stale ]]; then
        log_info "No stale metadata to remove"
        return 0
    fi
    log_info "Removing metadata referenced by neither the new nor the previous repomd.xml:"
    printf '%s\n' "$stale" | sed 's/^/    /'
    # Best-effort: leftovers are harmless and retried on the next publish.
    printf '%s\n' "$stale" | gsutil -m rm -I || log_warn "Failed to remove some stale metadata"
}

rollback() {
    local target="${GNOSISVPN_RPM_BUCKET}/${CHANNEL}"
    log_info "Rolling back ${CHANNEL} to the metadata saved in ${PREVIOUS_DIR} ..."
    if [[ -f "${PREVIOUS_DIR}/repomd.xml" ]]; then
        if [[ -f "${PREVIOUS_DIR}/repomd.xml.asc" ]]; then
            gsutil -h "${REVALIDATE_HEADER}" cp "${PREVIOUS_DIR}/repomd.xml.asc" "${target}/repodata/repomd.xml.asc"
        fi
        gsutil -h "${REVALIDATE_HEADER}" cp "${PREVIOUS_DIR}/repomd.xml" "${target}/repodata/repomd.xml"
        log_success "Restored previous repomd.xml pair"
    else
        log_warn "No previous metadata saved — removing the ${CHANNEL} repomd.xml pair"
        gsutil rm -f "${target}/repodata/repomd.xml" "${target}/repodata/repomd.xml.asc" || true
    fi
    # The trailing "-1." anchors the version so 0.9.1 never matches 0.9.10.
    log_info "Deleting ${target}/packages/gnosisvpn-${VERSION}-1.* ..."
    gsutil -m rm "${target}/packages/gnosisvpn-${VERSION}-1.*" || log_warn "No packages of ${VERSION} to delete"
    log_success "Rollback complete: channel=${CHANNEL} version=${VERSION}"
}

cleanup() {
    local dir
    for dir in "$SIGNING_GNUPGHOME" "$VERIFY_GNUPGHOME"; do
        if [[ -n $dir && -d $dir ]]; then
            gpgconf --homedir "$dir" --kill gpg-agent 2>/dev/null || true
            rm -rf "$dir"
        fi
    done
    if [[ ${WORK_DIR_AUTO:-0} -eq 1 && -n ${WORK_DIR:-} && -d ${WORK_DIR} && ${WORK_DIR} == /tmp/* ]]; then
        rm -rf "$WORK_DIR"
    fi
}

main() {
    trap cleanup EXIT
    parse_args "$@"
    if [[ $ROLLBACK -eq 1 ]]; then
        rollback
        return 0
    fi
    verify_package_signatures
    save_previous_metadata
    stage_packages
    build_and_sign_metadata
    upload
    prune_stale_metadata

    log_success "dnf repository published: channel=${CHANNEL} version=${VERSION} bucket=${GNOSISVPN_RPM_BUCKET}"
}

# Sourced by the unit tests.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
