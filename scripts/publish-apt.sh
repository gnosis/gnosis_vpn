#!/usr/bin/env bash
#
# Build and publish a signed APT repository to gs://download.gnosisvpn.io/linux/apt
#
# Two channels are supported:
#   stable    - append-only pool, all historical releases kept under
#               pool/main/g/gnosisvpn/
#   snapshot  - append-only pool, all historical snapshots kept under
#               pool/snapshot/g/gnosisvpn/. Filenames are version-pinned so
#               old .debs stay reachable for in-flight installs. A separate
#               retention pass is expected to prune old snapshots periodically.
#
# The Release file is GPG-signed (both clearsigned InRelease and detached
# Release.gpg) using the same signing key already used for the loose .deb
# distribution.

set -Eeuo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

GNOSISVPN_APT_BUCKET="${GNOSISVPN_APT_BUCKET:-gs://download.gnosisvpn.io/linux/apt}"
GNOSISVPN_APT_PUBLIC_KEY="${GNOSISVPN_APT_PUBLIC_KEY:-${REPO_ROOT}/gnosisvpn-public-key.asc}"

CHANNEL=""
DEBS_DIR=""
WORK_DIR=""
WORK_DIR_AUTO=0

usage() {
    cat <<EOF
Usage: $(basename "$0") --channel <stable|snapshot> --debs <dir> [options]

Required:
  --channel <stable|snapshot>     APT suite to publish into
  --debs <dir>                    Directory containing freshly built .deb files.
                                  Must include:
                                    - gnosisvpn_<version>_amd64.deb
                                    - gnosisvpn_<version>_arm64.deb
                                  and, for each .deb, matching sidecars:
                                    - <deb>.asc      (GPG detached signature)
                                    - <deb>.sha256   (sha256sum output)

Options:
  --work-dir <dir>                Staging directory (default: \$(mktemp -d))
  --bucket <gs://...>             Override target bucket prefix
                                  (default: ${GNOSISVPN_APT_BUCKET})
  --public-key <path>             Armored public key to dearmor and publish
                                  (default: ${GNOSISVPN_APT_PUBLIC_KEY})
  -h, --help                      Show this help

Environment:
  GNOSISVPN_GPG_PRIVATE_KEY_PATH      Armored private key file (required)
  GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD  Passphrase for the private key (required)
EOF
    exit "${1:-1}"
}

parse_args() {
    # Guard against `<flag>` with no value: without this, `shift 2` would abort
    # under `set -e` before the validation block below runs, leaving the user
    # with a silent exit 1 instead of a useful error.
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
        --debs)
            require_value "$1" "${2:-}"
            DEBS_DIR="$2"
            shift 2
            ;;
        --work-dir)
            require_value "$1" "${2:-}"
            WORK_DIR="$2"
            shift 2
            ;;
        --bucket)
            require_value "$1" "${2:-}"
            GNOSISVPN_APT_BUCKET="$2"
            shift 2
            ;;
        --public-key)
            require_value "$1" "${2:-}"
            GNOSISVPN_APT_PUBLIC_KEY="$2"
            shift 2
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

    if [[ $CHANNEL != "stable" && $CHANNEL != "snapshot" ]]; then
        log_error "--channel must be 'stable' or 'snapshot' (got: '${CHANNEL}')"
        usage
    fi
    if [[ -z $DEBS_DIR || ! -d $DEBS_DIR ]]; then
        log_error "--debs must point to an existing directory (got: '${DEBS_DIR}')"
        usage
    fi
    local has_amd64=0 has_arm64=0
    for deb in "$DEBS_DIR"/*.deb; do
        [[ -e $deb ]] || continue
        case "$deb" in
        *_amd64.deb) has_amd64=1 ;;
        *_arm64.deb) has_arm64=1 ;;
        esac
    done
    if [[ $has_amd64 -eq 0 || $has_arm64 -eq 0 ]]; then
        log_error "--debs must contain both an amd64 and an arm64 .deb (found amd64=${has_amd64} arm64=${has_arm64})"
        exit 1
    fi
    # Sidecars (.asc + .sha256) are part of the release contract — they are
    # consumed by scripts/generate-update-manifest.sh from the bucket and a
    # publish without them leaves the manifest workflow broken.
    local missing=() f
    for deb in "$DEBS_DIR"/*.deb; do
        [[ -e $deb ]] || continue
        for ext in asc sha256; do
            [[ -f "${deb}.${ext}" ]] || missing+=("${deb}.${ext}")
        done
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required sidecar files (every .deb needs both .asc and .sha256):"
        for f in "${missing[@]}"; do log_error "  - ${f}"; done
        log_error "Generate them alongside each .deb before re-running, e.g.:"
        log_error "  gpg --armor --detach-sign --output <deb>.asc <deb>"
        log_error '  (cd "$(dirname <deb>)" && sha256sum "$(basename <deb>)" > <deb>.sha256)'
        exit 1
    fi
    # Sanity-check each .sha256 against the .deb it claims to hash.
    local sha
    for sha in "$DEBS_DIR"/*.deb.sha256; do
        [[ -e $sha ]] || continue
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
    if [[ ! -f $GNOSISVPN_APT_PUBLIC_KEY ]]; then
        log_error "Public key not found: ${GNOSISVPN_APT_PUBLIC_KEY}"
        exit 1
    fi
    if [[ -z $WORK_DIR ]]; then
        WORK_DIR="$(mktemp -d -t gnosisvpn-apt-XXXXXX)"
        WORK_DIR_AUTO=1
    fi
}

# Path inside the bucket and inside the work dir where the suite's .debs live.
# Stable uses the standard pool/main/, snapshot uses pool/snapshot/ so the two
# suites cannot accidentally cross-contaminate.
pool_subpath_for_channel() {
    case "$1" in
    stable) echo "pool/main/g/gnosisvpn" ;;
    snapshot) echo "pool/snapshot/g/gnosisvpn" ;;
    esac
}

# Pool prefix that apt-ftparchive will scan when generating Packages.
pool_scan_root_for_channel() {
    case "$1" in
    stable) echo "pool/main" ;;
    snapshot) echo "pool/snapshot" ;;
    esac
}

setup_gnupg() {
    log_info "Importing signing key into temporary GNUPGHOME..."
    GNUPGHOME="$(mktemp -d -t gnosisvpn-gnupg-XXXXXX)"
    export GNUPGHOME
    chmod 700 "$GNUPGHOME"
    echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
            --import "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"
    log_success "Signing key imported"
}

stage_pool() {
    local pool_subpath
    pool_subpath="$(pool_subpath_for_channel "$CHANNEL")"
    local pool_dir="${WORK_DIR}/${pool_subpath}"
    mkdir -p "$pool_dir"

    log_info "Pulling existing ${CHANNEL} pool from ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/ ..."
    # gsutil ls returns non-zero for ALL failures (empty prefix, auth/network/
    # permission errors), so we must distinguish "matched no objects" from real
    # errors — publishing without pulling an existing pool truncates the
    # Packages index to only the newly built .debs and breaks `apt install
    # gnosisvpn=<older>` until the next successful publish.
    local ls_output ls_status=0
    ls_output=$(gsutil ls "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/" 2>&1) || ls_status=$?
    if [[ $ls_status -eq 0 ]]; then
        gsutil -m rsync -r "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/" "${pool_dir}/"
    elif echo "$ls_output" | grep -qi 'matched no objects'; then
        log_warn "Remote pool does not exist yet — starting from empty"
    else
        log_error "Failed to read existing ${CHANNEL} pool at ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/"
        log_error "gsutil ls (exit ${ls_status}):"
        echo "$ls_output" >&2
        exit 1
    fi

    if [[ $CHANNEL == "stable" ]]; then
        for deb in "${DEBS_DIR}"/*.deb; do
            [[ -e $deb ]] || continue
            local name existing
            name="$(basename "$deb")"
            existing="${pool_dir}/${name}"
            if [[ -f $existing ]] && ! cmp -s "$deb" "$existing"; then
                log_error "Stable pool already contains ${name} with different content."
                log_error "Re-releasing the same version is not supported — bump package.json or delete the old .deb manually."
                exit 1
            fi
        done
    fi

    log_info "Copying new .deb files into ${pool_dir} ..."
    local copied=0
    for deb in "${DEBS_DIR}"/*.deb; do
        [[ -e $deb ]] || continue
        cp -v "$deb" "${pool_dir}/"
        # Sidecars are guaranteed by parse_args — copy unconditionally.
        cp -v "${deb}.asc" "${pool_dir}/"
        cp -v "${deb}.sha256" "${pool_dir}/"
        copied=$((copied + 1))
    done
    if [[ $copied -eq 0 ]]; then
        log_error "No .deb files found in ${DEBS_DIR}"
        exit 1
    fi
    log_success "Staged ${copied} .deb file(s) into pool"
}

generate_indexes() {
    log_info "Generating Packages indexes ..."
    local pool_scan_root
    pool_scan_root="$(pool_scan_root_for_channel "$CHANNEL")"

    local dists_dir="${WORK_DIR}/dists/${CHANNEL}"
    mkdir -p \
        "${dists_dir}/main/binary-amd64/by-hash/SHA256" \
        "${dists_dir}/main/binary-arm64/by-hash/SHA256"

    pushd "$WORK_DIR" >/dev/null
    apt-ftparchive --arch amd64 packages "$pool_scan_root" \
        >"${dists_dir}/main/binary-amd64/Packages"
    apt-ftparchive --arch arm64 packages "$pool_scan_root" \
        >"${dists_dir}/main/binary-arm64/Packages"
    popd >/dev/null

    gzip -kf9 "${dists_dir}/main/binary-amd64/Packages"
    gzip -kf9 "${dists_dir}/main/binary-arm64/Packages"

    # Place a content-addressed copy of each Packages{,.gz} under by-hash/SHA256/
    # so apt's Acquire-By-Hash can fetch an immutable index matching whichever
    # InRelease the client last validated — eliminates Hash Sum mismatch races
    # during publish.
    local arch arch_dir f hash
    for arch in amd64 arm64; do
        arch_dir="${dists_dir}/main/binary-${arch}"
        for f in Packages Packages.gz; do
            hash="$(sha256sum "${arch_dir}/${f}" | awk '{print $1}')"
            cp "${arch_dir}/${f}" "${arch_dir}/by-hash/SHA256/${hash}"
        done
    done
    log_success "Wrote Packages and Packages.gz (with by-hash copies) for amd64 and arm64"
}

generate_release() {
    log_info "Generating Release file ..."
    local dists_dir="${WORK_DIR}/dists/${CHANNEL}"

    pushd "$WORK_DIR" >/dev/null
    apt-ftparchive \
        -o "APT::FTPArchive::Release::Origin=GnosisVPN" \
        -o "APT::FTPArchive::Release::Label=GnosisVPN" \
        -o "APT::FTPArchive::Release::Suite=${CHANNEL}" \
        -o "APT::FTPArchive::Release::Codename=${CHANNEL}" \
        -o "APT::FTPArchive::Release::Architectures=amd64 arm64" \
        -o "APT::FTPArchive::Release::Components=main" \
        -o "APT::FTPArchive::Release::Description=Gnosis VPN APT repository (${CHANNEL})" \
        -o "APT::FTPArchive::Release::Acquire-By-Hash=true" \
        release "dists/${CHANNEL}" >"${dists_dir}/Release"
    popd >/dev/null
    log_success "Release written to ${dists_dir}/Release"
}

sign_release() {
    log_info "Signing Release ..."
    local dists_dir="${WORK_DIR}/dists/${CHANNEL}"

    rm -f "${dists_dir}/InRelease" "${dists_dir}/Release.gpg"

    echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
            --digest-algo SHA512 \
            --clearsign --output "${dists_dir}/InRelease" \
            "${dists_dir}/Release"
    log_success "InRelease (clearsigned) written"

    echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
            --digest-algo SHA512 \
            --armor --detach-sign --output "${dists_dir}/Release.gpg" \
            "${dists_dir}/Release"
    log_success "Release.gpg (detached signature) written"
}

dearmor_public_key() {
    log_info "Dearmoring public key for apt keyring ..."
    gpg --dearmor <"$GNOSISVPN_APT_PUBLIC_KEY" \
        >"${WORK_DIR}/gnosisvpn-archive-keyring.gpg"
    log_success "Keyring written to ${WORK_DIR}/gnosisvpn-archive-keyring.gpg"
}

upload() {
    local pool_subpath
    pool_subpath="$(pool_subpath_for_channel "$CHANNEL")"

    # Cache headers are set at upload time (gsutil -h) rather than via a
    # post-upload `setmeta` wildcard. The wildcard form re-tags every historical
    # .deb / .asc / .sha256 / by-hash object in the pool on every publish, which
    # scales linearly with snapshot retention and makes nightlies progressively
    # slower and more expensive. Setting headers on the cp itself only touches
    # the newly uploaded objects.
    local immutable_header="Cache-Control:public, max-age=31536000, immutable"
    local revalidate_header="Cache-Control:no-cache, max-age=60, must-revalidate"

    log_info "Uploading pool to ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/ ..."
    # Both pools are additive: version-pinned filenames never collide, and old
    # .debs stay reachable for in-flight apt installs and historical reference.
    # `cp -n` skips existing objects, so old files retain the headers from their
    # original upload and we don't re-tag them.
    gsutil -m -h "${immutable_header}" \
        cp -n -r "${WORK_DIR}/${pool_subpath}/." \
        "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/"

    log_info "Uploading dists/${CHANNEL} by-hash indexes ..."
    # by-hash files are content-addressed and therefore immutable; we
    # intentionally do not pass rsync's -d flag, so historical by-hash files
    # persist long enough to satisfy clients that cached an older InRelease.
    local arch
    for arch in amd64 arm64; do
        gsutil -m -h "${immutable_header}" \
            cp -r "${WORK_DIR}/dists/${CHANNEL}/main/binary-${arch}/by-hash/." \
            "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/main/binary-${arch}/by-hash/"
    done

    log_info "Uploading dists/${CHANNEL} Packages indexes ..."
    # Canonical Packages files are overwritten every publish — clients must
    # revalidate so `apt update` sees fresh contents promptly.
    for arch in amd64 arm64; do
        gsutil -m -h "${revalidate_header}" \
            cp "${WORK_DIR}/dists/${CHANNEL}/main/binary-${arch}/Packages" \
            "${WORK_DIR}/dists/${CHANNEL}/main/binary-${arch}/Packages.gz" \
            "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/main/binary-${arch}/"
    done

    # Upload Release + its detached signature next. The OLD InRelease is still
    # in the bucket and apt prefers InRelease, so clients see a consistent view
    # at this point.
    log_info "Uploading dists/${CHANNEL} Release + Release.gpg ..."
    gsutil -h "${revalidate_header}" \
        cp "${WORK_DIR}/dists/${CHANNEL}/Release" \
        "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/Release"
    gsutil -h "${revalidate_header}" \
        cp "${WORK_DIR}/dists/${CHANNEL}/Release.gpg" \
        "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/Release.gpg"

    # Upload InRelease LAST — a single-object overwrite is atomic in GCS, so
    # this is the atomic pointer swap that makes new indexes visible to apt.
    log_info "Uploading dists/${CHANNEL} InRelease (atomic pointer swap) ..."
    gsutil -h "${revalidate_header}" \
        cp "${WORK_DIR}/dists/${CHANNEL}/InRelease" \
        "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/InRelease"

    log_info "Uploading public keyring ..."
    gsutil -h "Cache-Control:public, max-age=3600" \
        cp "${WORK_DIR}/gnosisvpn-archive-keyring.gpg" \
        "${GNOSISVPN_APT_BUCKET}/gnosisvpn-archive-keyring.gpg"

    log_success "Upload complete"
}

cleanup() {
    if [[ -n ${GNUPGHOME:-} && -d ${GNUPGHOME} && ${GNUPGHOME} == /tmp/* ]]; then
        rm -rf "$GNUPGHOME"
    fi
    if [[ ${WORK_DIR_AUTO:-0} -eq 1 && -n ${WORK_DIR:-} && -d ${WORK_DIR} && ${WORK_DIR} == /tmp/* ]]; then
        rm -rf "$WORK_DIR"
    fi
}

main() {
    trap cleanup EXIT
    parse_args "$@"
    setup_gnupg
    stage_pool
    generate_indexes
    generate_release
    sign_release
    dearmor_public_key
    upload

    log_success "APT repository published: channel=${CHANNEL} bucket=${GNOSISVPN_APT_BUCKET}"
}

main "$@"
