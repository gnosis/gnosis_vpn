#!/usr/bin/env bash
#
# Stage the country GeoIP database experimental-line packages ship at build/geoip/geoip.mmdb.
# A prebuilt file (GNOSISVPN_GEOIP_DB) wins, then a fresh IPinfo Lite trim (IPINFO_TOKEN), else the bucket's daily trim.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

GEOIP_DIR="${BUILD_DIR}/geoip"
GEOIP_DB="${GEOIP_DIR}/geoip.mmdb"
# Written beside the database so update-geoip.yaml only republishes a fresh trim, never the bucket's own copy.
GEOIP_SOURCE="${GEOIP_DIR}/source"
IPINFO_URL="https://ipinfo.io/data/ipinfo_lite.mmdb"
# Refreshed daily by update-geoip.yaml; what every build that ships the database takes.
BUCKET_LATEST_URL="https://download.gnosisvpn.io/geoip/latest.mmdb"
# The jura-prod exits inside one BYOIP /24 plus the Vienna exit: the lookups this database exists for.
FLEET_PROBES=(185.9.1.9 185.9.1.25 185.9.1.41 185.9.1.57 185.9.1.73 185.9.1.89 185.9.1.105 89.58.60.202)

copy_prebuilt() {
    mkdir -p "${GEOIP_DIR}"
    # Reusing the already staged database must not copy it onto itself.
    if [[ ! ${GNOSISVPN_GEOIP_DB} -ef ${GEOIP_DB} ]]; then
        cp "${GNOSISVPN_GEOIP_DB}" "${GEOIP_DB}"
    fi
    echo "prebuilt" >"${GEOIP_SOURCE}"
    log_success "GeoIP database taken from ${GNOSISVPN_GEOIP_DB}"
}

# Header via stdin: argv, URL included, is visible in process lists.
ipinfo_get() {
    curl -fsSL --retry 3 -H @- "$@" <<<"Authorization: Bearer ${IPINFO_TOKEN}"
}

build_from_ipinfo() {
    local full="${GEOIP_DIR}/ipinfo_lite.mmdb"
    log_info "Downloading IPinfo Lite..."
    ipinfo_get -o "${full}" "${IPINFO_URL}" || return 1
    local expected actual
    expected=$(ipinfo_get "${IPINFO_URL}/checksums" | jq -r '.checksums.sha256') || return 1
    actual=$(shasum -a 256 "${full}" | cut -d' ' -f1)
    if [[ ${expected} != "${actual}" ]]; then
        log_error "IPinfo Lite checksum mismatch: expected ${expected}, got ${actual}"
        return 1
    fi
    log_info "Trimming to a country-only IPv4 database..."
    # Pure Go; CGO off so the dev shell needs no C compiler.
    (cd "${SCRIPT_DIR}/geoip" && CGO_ENABLED=0 go run . "${full}" "${GEOIP_DB}" "${FLEET_PROBES[@]}") || return 1
    rm -f "${full}"
    echo "ipinfo-lite" >"${GEOIP_SOURCE}"
    log_success "GeoIP database built from today's IPinfo Lite"
}

fetch_from_bucket() {
    log_info "Downloading the daily GeoIP database from ${BUCKET_LATEST_URL}..."
    curl -fsSL --retry 3 -o "${GEOIP_DB}" "${BUCKET_LATEST_URL}" || {
        log_error "No GeoIP database available: ${BUCKET_LATEST_URL} failed"
        exit 1
    }
    echo "bucket-latest" >"${GEOIP_SOURCE}"
    log_success "GeoIP database taken from the bucket"
}

main() {
    if [[ -n ${GNOSISVPN_GEOIP_DB:-} ]]; then
        copy_prebuilt
    else
        # A prebuilt input may live in here, so only downloads start from a clean directory.
        rm -rf "${GEOIP_DIR}"
        mkdir -p "${GEOIP_DIR}"
        if [[ -z ${IPINFO_TOKEN:-} ]]; then
            fetch_from_bucket
        elif ! build_from_ipinfo; then
            log_warn "IPinfo Lite download, checksum or trim failed; falling back to the bucket"
            fetch_from_bucket
        fi
    fi
    echo "GeoIP database: ${GEOIP_DB} ($(du -h "${GEOIP_DB}" | cut -f1), source: $(cat "${GEOIP_SOURCE}"))"
}

main
