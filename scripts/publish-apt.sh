#!/usr/bin/env bash
#
# Build and publish a signed APT repository to gs://download.gnosisvpn.io/linux/apt
# using reprepro.
#
# Two channels are supported:
#   stable    - append-only pool, all historical releases kept under
#               pool/main/g/gnosisvpn/ (Components: main).
#   snapshot  - append-only pool, all historical snapshots kept under
#               pool/snapshot/g/gnosisvpn/ (Components: snapshot). Filenames are
#               version-pinned so old .debs stay reachable for in-flight installs.
#               A separate retention pass is expected to prune old snapshots
#               periodically.
#
# Repository metadata (Packages, Release, InRelease, Release.gpg) is produced
# by reprepro from linux/apt/conf/distributions. Reprepro drives gpg via
# SignWith: with the passphrase presetted into gpg-agent, so it never appears
# on a command line. Same key signs each .deb's .asc sidecar (out-of-band,
# in generate-package-linux.sh).

set -Eeuo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

GNOSISVPN_APT_BUCKET="${GNOSISVPN_APT_BUCKET:-gs://download.gnosisvpn.io/linux/apt}"
GNOSISVPN_APT_PUBLIC_KEY="${GNOSISVPN_APT_PUBLIC_KEY:-${REPO_ROOT}/gnosisvpn-public-key.asc}"
GNOSISVPN_APT_CONF_DIR="${GNOSISVPN_APT_CONF_DIR:-${REPO_ROOT}/linux/apt/conf}"
# Long key ID of the signing key. Must match SignWith: in conf/distributions.
GNOSISVPN_APT_SIGNING_KEY="${GNOSISVPN_APT_SIGNING_KEY:-84F73FEA46D10972}"

CHANNEL=""
DEBS_DIR=""
WORK_DIR=""
WORK_DIR_AUTO=0
GNUPGHOME_AUTO=0

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
  GNOSISVPN_APT_CONF_DIR              Directory with reprepro's distributions file
                                      (default: ${GNOSISVPN_APT_CONF_DIR})
  GNOSISVPN_APT_SIGNING_KEY           Long key ID matching SignWith: in
                                      conf/distributions (default: ${GNOSISVPN_APT_SIGNING_KEY})
EOF
    exit "${1:-1}"
}

parse_args() {
    # Without this guard `shift 2` would trip `set -e` before the helpful
    # error below, exiting silently.
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
    # Enforce filename shape, require both arches, reject mixed-version inputs
    # (else Packages would index both and clients on different arches get different versions).
    local has_amd64=0 has_arm64=0 version_seen="" this_version name
    for deb in "$DEBS_DIR"/*.deb; do
        [[ -e $deb ]] || continue
        name="$(basename "$deb")"
        if [[ ! $name =~ ^gnosisvpn_(.+)_(amd64|arm64)\.deb$ ]]; then
            log_error "Unexpected .deb filename: ${name} (expected gnosisvpn_<version>_<arch>.deb)"
            exit 1
        fi
        this_version="${BASH_REMATCH[1]}"
        if [[ -z $version_seen ]]; then
            version_seen="$this_version"
        elif [[ $this_version != "$version_seen" ]]; then
            log_error "All .deb files must share the same version (got '${version_seen}' and '${this_version}')"
            exit 1
        fi
        case "${BASH_REMATCH[2]}" in
        amd64) has_amd64=1 ;;
        arm64) has_arm64=1 ;;
        esac
    done
    if [[ $has_amd64 -eq 0 || $has_arm64 -eq 0 ]]; then
        log_error "--debs must contain both an amd64 and an arm64 .deb (found amd64=${has_amd64} arm64=${has_arm64})"
        exit 1
    fi
    # Sidecars (.asc + .sha256) are consumed by generate-update-manifest.sh
    # from the bucket — required release contract.
    local missing=() f
    for deb in "$DEBS_DIR"/*.deb; do
        [[ -e $deb ]] || continue
        for ext in asc sha256; do
            [[ -f "${deb}.${ext}" ]] || missing+=("${deb}.${ext}")
        done
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing sidecar files (each .deb needs .asc + .sha256):"
        for f in "${missing[@]}"; do log_error "  - ${f}"; done
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
    if ! command -v reprepro >/dev/null 2>&1; then
        log_error "reprepro not installed (install with: sudo apt-get install -y reprepro)"
        exit 1
    fi
    if [[ ! -f "${GNOSISVPN_APT_CONF_DIR}/distributions" ]]; then
        log_error "reprepro distributions file not found: ${GNOSISVPN_APT_CONF_DIR}/distributions"
        exit 1
    fi
    if [[ -z $WORK_DIR ]]; then
        WORK_DIR="$(mktemp -d -t gnosisvpn-apt-XXXXXX)"
        WORK_DIR_AUTO=1
    fi
}

# Bucket and work-dir paths for each channel. Reprepro derives the pool path
# from the Components: field in conf/distributions, so these must match:
#   stable    Components: main      → pool/main/g/gnosisvpn/
#   snapshot  Components: snapshot  → pool/snapshot/g/gnosisvpn/
pool_subpath_for_channel() {
    case "$1" in
    stable) echo "pool/main/g/gnosisvpn" ;;
    snapshot) echo "pool/snapshot/g/gnosisvpn" ;;
    esac
}

component_for_channel() {
    case "$1" in
    stable) echo "main" ;;
    snapshot) echo "snapshot" ;;
    esac
}

reprepro_setup() {
    log_info "Configuring GNUPGHOME and presetting signing passphrase ..."
    GNUPGHOME="$(mktemp -d -t gnosisvpn-gnupg-XXXXXX)"
    GNUPGHOME_AUTO=1
    export GNUPGHOME
    chmod 700 "$GNUPGHOME"
    # SHA512 + agent-cached passphrase: matches the previous --digest-algo
    # SHA512 + --passphrase-fd 0 behavior without putting the passphrase on a
    # gpg command line.
    printf 'digest-algo SHA512\nuse-agent\n' >"$GNUPGHOME/gpg.conf"
    printf 'allow-preset-passphrase\nmax-cache-ttl 7200\n' >"$GNUPGHOME/gpg-agent.conf"

    echo "$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
            --import "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"
    gpg-connect-agent /bye >/dev/null
    # Preset passphrase for every keygrip on the key (primary + subkeys) so any
    # signing subkey reprepro picks is unlocked.
    local preset_bin
    preset_bin="$(gpgconf --list-dirs libexecdir)/gpg-preset-passphrase"
    gpg --batch --with-keygrip --list-secret-keys "$GNOSISVPN_APT_SIGNING_KEY" |
        awk '/Keygrip/ {print $3}' |
        while read -r grip; do
            "$preset_bin" --preset "$grip" <<<"$GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD"
        done

    # Reprepro re-derives db/ from the local pool every run. Wipe leftover
    # state a reused --work-dir may have inherited.
    rm -rf "$WORK_DIR/db" "$WORK_DIR/pool" "$WORK_DIR/dists" "$WORK_DIR/incoming"
    log_success "GNUPGHOME ready"
}

stage_pool() {
    local pool_subpath
    pool_subpath="$(pool_subpath_for_channel "$CHANNEL")"
    # All .debs (rsynced existing + newly built) land in incoming/ first;
    # reprepro_publish consumes that directory and re-places the .debs into
    # the pool path derived from Components: in conf/distributions.
    local incoming_dir="${WORK_DIR}/incoming"
    mkdir -p "$incoming_dir"

    log_info "Pulling existing ${CHANNEL} pool from ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/ ..."
    # gsutil ls returns non-zero for ALL failures (empty prefix, auth/network/
    # permission errors), so we must distinguish "matched no objects" from real
    # errors — publishing without pulling an existing pool truncates the
    # Packages index to only the newly built .debs and breaks `apt install
    # gnosisvpn=<older>` until the next successful publish.
    local ls_output ls_status=0
    ls_output=$(gsutil ls "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/" 2>&1) || ls_status=$?
    if [[ $ls_status -eq 0 ]]; then
        # `-d` makes incoming/ a strict mirror of the bucket pool before we
        # drop the new .debs in. Without it, a reusable --work-dir can keep
        # stale files from a previous failed run, which reprepro would then
        # ingest and InRelease would advertise as available.
        # Bucket-side deletion is unaffected — this is bucket → local only.
        gsutil -m rsync -d -r "${GNOSISVPN_APT_BUCKET}/${pool_subpath}/" "${incoming_dir}/"
    elif echo "$ls_output" | grep -qi 'matched no objects'; then
        log_warn "Remote pool does not exist yet — starting from empty"
        # Clear any leftovers a reusable --work-dir may have inherited so
        # incoming/ matches the (empty) bucket state before staging new files.
        find "${incoming_dir}" -mindepth 1 -delete
    else
        log_error "Failed to read existing ${CHANNEL} pool at ${GNOSISVPN_APT_BUCKET}/${pool_subpath}/"
        log_error "gsutil ls (exit ${ls_status}):"
        echo "$ls_output" >&2
        exit 1
    fi

    # Both channels are append-only: a rerun that produces different bytes for
    # an already-published filename must fail loudly. Without this guard the
    # local pool gets the new bytes (cp overwrites the rsynced copy) and the
    # regenerated Packages/InRelease describe them, but `gsutil cp -n` in
    # upload() skips the existing bucket object — leaving the bucket .deb on
    # the old bytes and every `apt-get install` failing with Hash Sum mismatch.
    for deb in "${DEBS_DIR}"/*.deb; do
        [[ -e $deb ]] || continue
        local name existing
        name="$(basename "$deb")"
        existing="${incoming_dir}/${name}"
        if [[ -f $existing ]] && ! cmp -s "$deb" "$existing"; then
            log_error "${CHANNEL} pool already contains ${name} with different content."
            if [[ $CHANNEL == "stable" ]]; then
                log_error "Re-releasing the same version is not supported — bump package.json or delete the old .deb manually."
            else
                log_error "Snapshot filenames embed a timestamp and must not be reused — rebuild with a fresh version or delete the old .deb manually."
            fi
            exit 1
        fi
    done

    log_info "Copying new .deb files into ${incoming_dir} ..."
    local copied=0
    for deb in "${DEBS_DIR}"/*.deb; do
        [[ -e $deb ]] || continue
        cp -v "$deb" "${incoming_dir}/"
        # Sidecars are guaranteed by parse_args — copy unconditionally.
        cp -v "${deb}.asc" "${incoming_dir}/"
        cp -v "${deb}.sha256" "${incoming_dir}/"
        copied=$((copied + 1))
    done
    if [[ $copied -eq 0 ]]; then
        log_error "No .deb files found in ${DEBS_DIR}"
        exit 1
    fi
    log_success "Staged ${copied} new .deb file(s) into ${incoming_dir}"
}

reprepro_publish() {
    local incoming_dir="${WORK_DIR}/incoming"
    local pool_dir="${WORK_DIR}/$(pool_subpath_for_channel "$CHANNEL")"

    log_info "Ingesting ${CHANNEL} .debs into reprepro ..."
    # --export=never batches the work; one final `reprepro export` regenerates
    # Packages / Release / InRelease / Release.gpg once at the end.
    local count=0 deb
    for deb in "${incoming_dir}"/*.deb; do
        [[ -e $deb ]] || continue
        reprepro -b "$WORK_DIR" --confdir "$GNOSISVPN_APT_CONF_DIR" \
            --export=never includedeb "$CHANNEL" "$deb"
        count=$((count + 1))
    done
    [[ $count -gt 0 ]] || { log_error "No .deb files in ${incoming_dir}"; exit 1; }
    reprepro -b "$WORK_DIR" --confdir "$GNOSISVPN_APT_CONF_DIR" export "$CHANNEL"

    # Reprepro ignores .asc / .sha256 sidecars — copy them alongside the .debs
    # it just placed in the pool.
    mkdir -p "$pool_dir"
    shopt -s nullglob
    cp -t "$pool_dir" "${incoming_dir}"/*.deb.asc "${incoming_dir}"/*.deb.sha256
    shopt -u nullglob
    log_success "Reprepro published ${count} .deb file(s)"
}

verify_deb_signatures() {
    # Each .deb ships with a `.asc` — a detached GPG signature used by the
    # client app's auto-updater to confirm the .deb really came from us
    # (beyond just trusting the manifest's hash).
    log_info "Verifying .deb GPG signatures against the public key being published ..."
    VERIFY_GNUPGHOME="${WORK_DIR}/verify-gnupg"
    mkdir -p "$VERIFY_GNUPGHOME"
    chmod 700 "$VERIFY_GNUPGHOME"
    GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --quiet --import "$GNOSISVPN_APT_PUBLIC_KEY"
    local deb
    for deb in "$DEBS_DIR"/*.deb; do
        [[ -e $deb ]] || continue
        GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --verify "${deb}.asc" "$deb" 2>/dev/null || {
            log_error "GPG signature verification failed for $(basename "$deb"): ${deb}.asc does not verify against ${GNOSISVPN_APT_PUBLIC_KEY}"
            exit 1
        }
    done
    log_success ".deb signatures verify against the keyring that will be published"
}

verify_signatures_against_published_key() {
    # Catches drift between the committed gnosisvpn-public-key.asc and the
    # private key in secrets — without it, publish would dearmor the OLD pub
    # key into the bucket keyring while signing InRelease with the NEW key,
    # BADSIG-ing every fresh install.sh run. Does NOT make rotation safe:
    # existing clients still have the old keyring on disk. Reuses VERIFY_GNUPGHOME.
    log_info "Verifying InRelease / Release.gpg against the public key being published ..."
    local dists_dir="${WORK_DIR}/dists/${CHANNEL}"
    GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --verify "${dists_dir}/InRelease" || {
        log_error "InRelease does not verify against ${GNOSISVPN_APT_PUBLIC_KEY} — the committed public key is stale or the signing private key was rotated"
        exit 1
    }
    GNUPGHOME="$VERIFY_GNUPGHOME" gpg --batch --verify "${dists_dir}/Release.gpg" "${dists_dir}/Release" || {
        log_error "Release.gpg does not verify against ${GNOSISVPN_APT_PUBLIC_KEY}"
        exit 1
    }
    log_success "Signatures verify against the keyring that will be published"
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

    # Cache headers set at upload time (gsutil -h), not via post-upload
    # `setmeta` wildcards — the wildcard form re-tags every historical
    # .deb / .asc / .sha256 in the pool on each publish, scaling linearly
    # with snapshot retention.
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

    # reprepro 5.4.x has no Acquire-By-Hash, so no by-hash dirs to upload.
    # Atomic InRelease swap (uploaded last) keeps clients from seeing partial state.
    local arch component
    component="$(component_for_channel "$CHANNEL")"

    log_info "Uploading dists/${CHANNEL} Packages indexes ..."
    # Canonical Packages files are overwritten every publish — clients must
    # revalidate so `apt update` sees fresh contents promptly.
    for arch in amd64 arm64; do
        gsutil -m -h "${revalidate_header}" \
            cp "${WORK_DIR}/dists/${CHANNEL}/${component}/binary-${arch}/Packages" \
            "${WORK_DIR}/dists/${CHANNEL}/${component}/binary-${arch}/Packages.gz" \
            "${GNOSISVPN_APT_BUCKET}/dists/${CHANNEL}/${component}/binary-${arch}/"
    done

    # Keyring uploaded BEFORE Release/InRelease so it's in place when the
    # atomic InRelease swap reveals new metadata — a crash between uploads
    # would otherwise leave clients with no fetchable keyring. Revalidate
    # header matches Release/InRelease so during a key rotation no CDN edge
    # serves the stale keyring alongside metadata signed by the new key.
    log_info "Uploading public keyring ..."
    gsutil -h "${revalidate_header}" \
        cp "${WORK_DIR}/gnosisvpn-archive-keyring.gpg" \
        "${GNOSISVPN_APT_BUCKET}/gnosisvpn-archive-keyring.gpg"

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

    log_success "Upload complete"
}

cleanup() {
    if [[ -n ${GNUPGHOME:-} && -d ${GNUPGHOME} ]]; then
        gpgconf --kill gpg-agent 2>/dev/null || true
    fi
    if [[ ${GNUPGHOME_AUTO:-0} -eq 1 && -n ${GNUPGHOME:-} && -d ${GNUPGHOME} && ${GNUPGHOME} == /tmp/* ]]; then
        rm -rf "$GNUPGHOME"
    fi
    if [[ ${WORK_DIR_AUTO:-0} -eq 1 && -n ${WORK_DIR:-} && -d ${WORK_DIR} && ${WORK_DIR} == /tmp/* ]]; then
        rm -rf "$WORK_DIR"
    fi
}

main() {
    trap cleanup EXIT
    parse_args "$@"
    verify_deb_signatures
    reprepro_setup
    stage_pool
    reprepro_publish
    verify_signatures_against_published_key
    dearmor_public_key
    upload

    log_success "APT repository published: channel=${CHANNEL} bucket=${GNOSISVPN_APT_BUCKET}"
}

main "$@"
