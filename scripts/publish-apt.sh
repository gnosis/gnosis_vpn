#!/usr/bin/env bash
#
# Build and publish a signed APT repository to gs://download.gnosisvpn.io/apt
#
# Two channels are supported:
#   stable    - append-only pool, all historical releases kept under
#               pool/main/g/gnosisvpn/
#   snapshot  - pool is replaced on every run with only the freshly built
#               .debs, under pool/snapshot/g/gnosisvpn/
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

GNOSISVPN_APT_BUCKET="${GNOSISVPN_APT_BUCKET:-gs://download.gnosisvpn.io/apt}"
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
  --debs <dir>                    Directory containing freshly built .deb files
                                  (must include one amd64 and one arm64 .deb)

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
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --channel)
            CHANNEL="${2:-}"
            shift 2
            ;;
        --debs)
            DEBS_DIR="${2:-}"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="${2:-}"
            shift 2
            ;;
        --bucket)
            GNOSISVPN_APT_BUCKET="${2:-}"
            shift 2
            ;;
        --public-key)
            GNOSISVPN_APT_PUBLIC_KEY="${2:-}"
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

    if [[ $CHANNEL == "stable" ]]; then
        log_info "Pulling existing stable pool from ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/ ..."
        # Tolerate a first-run empty pool: rsync with no source falls through.
        if gsutil -q ls "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/" >/dev/null 2>&1; then
            gsutil -m rsync -r "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/" "${pool_dir}/"
        else
            log_warn "Remote pool does not exist yet — starting from empty"
        fi
    else
        log_info "Snapshot channel — pool is replaced, not appended"
    fi

    log_info "Copying new .deb files into ${pool_dir} ..."
    local copied=0
    for deb in "${DEBS_DIR}"/*.deb; do
        [[ -e $deb ]] || continue
        cp -v "$deb" "${pool_dir}/"
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
        "${dists_dir}/main/binary-amd64" \
        "${dists_dir}/main/binary-arm64"

    pushd "$WORK_DIR" >/dev/null
    apt-ftparchive --arch amd64 packages "$pool_scan_root" \
        >"${dists_dir}/main/binary-amd64/Packages"
    apt-ftparchive --arch arm64 packages "$pool_scan_root" \
        >"${dists_dir}/main/binary-arm64/Packages"
    popd >/dev/null

    gzip -kf9 "${dists_dir}/main/binary-amd64/Packages"
    gzip -kf9 "${dists_dir}/main/binary-arm64/Packages"
    log_success "Wrote Packages and Packages.gz for amd64 and arm64"
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

    log_info "Uploading pool to ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/ ..."
    if [[ $CHANNEL == "snapshot" ]]; then
        # Snapshot pool is fully replaced — rsync with -d removes old .debs.
        gsutil -m rsync -d -r "${WORK_DIR}/${pool_subpath}/" \
            "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/"
    else
        # Stable pool is additive — never delete historical versions.
        gsutil -m cp -n -r "${WORK_DIR}/${pool_subpath}/." \
            "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/"
    fi

    log_info "Uploading dists/${CHANNEL} metadata ..."
    gsutil -m rsync -d -r "${WORK_DIR}/dists/${CHANNEL}/" \
        "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/"

    log_info "Uploading public keyring ..."
    gsutil cp "${WORK_DIR}/gnosisvpn-archive-keyring.gpg" \
        "${GNOSISVPN_APT_BUCKET}/gnosisvpn-archive-keyring.gpg"

    log_info "Setting cache headers ..."
    # .deb files are version-pinned — safe to cache for a year.
    gsutil -m setmeta \
        -h "Cache-Control:public, max-age=31536000, immutable" \
        "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/*.deb" || true
    # Metadata must revalidate so apt update sees fresh indexes promptly.
    gsutil -m setmeta \
        -h "Cache-Control:no-cache, max-age=60, must-revalidate" \
        "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/**" || true
    gsutil setmeta \
        -h "Cache-Control:public, max-age=3600" \
        "${GNOSISVPN_APT_BUCKET}/gnosisvpn-archive-keyring.gpg" || true
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
