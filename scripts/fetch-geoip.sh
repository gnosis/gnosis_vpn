#!/bin/bash
#
# Stage the country GeoIP database the packages ship at build/geoip/geoip.mmdb.
# A prebuilt file (GNOSISVPN_GEOIP_DB) wins, then a fresh IPinfo Lite trim (IPINFO_TOKEN), then the bucket's last good copy.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

GEOIP_DIR="${BUILD_DIR}/geoip"
GEOIP_DB="${GEOIP_DIR}/geoip.mmdb"
# Written beside the database so CI only republishes a fresh trim, never the bucket's own copy.
GEOIP_SOURCE="${GEOIP_DIR}/source"
IPINFO_URL="https://ipinfo.io/data/ipinfo_lite.mmdb"
BUCKET_LATEST_URL="https://download.gnosisvpn.io/geoip/latest.mmdb"
# The jura-prod exits inside one BYOIP /24 plus the Vienna exit: the lookups this database exists for.
FLEET_PROBES=(185.9.1.9 185.9.1.25 185.9.1.41 185.9.1.57 185.9.1.73 185.9.1.89 185.9.1.105 89.58.60.202)

copy_prebuilt() {
    cp "${GNOSISVPN_GEOIP_DB}" "${GEOIP_DB}"
    echo "prebuilt" >"${GEOIP_SOURCE}"
    log_success "GeoIP database taken from ${GNOSISVPN_GEOIP_DB}"
}

# The token travels in a header only: a URL lands in logs and process lists.
ipinfo_get() {
    curl -fsSL --retry 3 -H "Authorization: Bearer ${IPINFO_TOKEN}" "$@"
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

fetch_last_good() {
    log_info "Downloading the last published GeoIP database from ${BUCKET_LATEST_URL}..."
    curl -fsSL --retry 3 -o "${GEOIP_DB}" "${BUCKET_LATEST_URL}" || return 1
    echo "bucket-latest" >"${GEOIP_SOURCE}"
    log_success "GeoIP database taken from the bucket"
}

main() {
    rm -rf "${GEOIP_DIR}"
    mkdir -p "${GEOIP_DIR}"
    if [[ -n ${GNOSISVPN_GEOIP_DB:-} ]]; then
        copy_prebuilt
    elif [[ -n ${IPINFO_TOKEN:-} ]] && build_from_ipinfo; then
        :
    else
        log_warn "No fresh IPinfo Lite trim (token unset or the download, checksum or trim failed); falling back to the bucket"
        fetch_last_good || {
            log_error "No GeoIP database available: IPinfo and ${BUCKET_LATEST_URL} both failed"
            exit 1
        }
    fi
    echo "GeoIP database: ${GEOIP_DB} ($(du -h "${GEOIP_DB}" | cut -f1), source: $(cat "${GEOIP_SOURCE}"))"
}

main
