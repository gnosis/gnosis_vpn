#!/usr/bin/env bash
# Renders the GeoIP placeholders for both installer lines without a build, so drift fails `nix flake check` on the PR, not the nightly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
ROOT="${SCRIPT_DIR}/.."

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for GNOSISVPN_SHIP_GEOIP in true false; do
    export GNOSISVPN_SHIP_GEOIP
    # One dir per line: copies out of the read-only nix store cannot be overwritten in the next round.
    line_dir="${work}/${GNOSISVPN_SHIP_GEOIP}"
    mkdir -p "${line_dir}"
    cp "${ROOT}/linux/nfpm-template.yaml" "${line_dir}/nfpm.yaml"
    cp "${ROOT}/linux/resources/copyright" "${line_dir}/copyright"
    cp "${ROOT}/mac/resources/distribution/readme.html" "${line_dir}/readme.html"
    render_geoip_placeholder "${line_dir}/nfpm.yaml" "${ROOT}/linux/resources/nfpm-geoip.yaml"
    render_geoip_placeholder "${line_dir}/copyright" "${ROOT}/linux/resources/copyright-geoip"
    render_geoip_placeholder "${line_dir}/readme.html" "${ROOT}/mac/resources/readme-geoip.html"
    log_success "GeoIP placeholders render with GNOSISVPN_SHIP_GEOIP=${GNOSISVPN_SHIP_GEOIP}"
done
