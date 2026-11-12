#!/usr/bin/env bash
#
# Stage the Curvy pix-aggregation proving files packages ship at build/curvy-zk/.
# The client looks for them at its default curvy-zk directory and rejects any file whose SHA-256 differs from its curvy-witnesscalc build.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Must match the curvy-witnesscalc version in the packaged client's Cargo.lock; digests from its src/lib.rs.
RS_SDK_VERSION="v0.2.0"
RELEASE_URL="https://github.com/0xCurvy/rs-sdk/releases/download/${RS_SDK_VERSION}"

has_digest() {
    local path="$1" expected="$2"
    [[ -f ${path} ]] && [[ "$(shasum -a 256 "${path}" | cut -d' ' -f1)" == "${expected}" ]]
}

stage_file() {
    local file="$1" expected="$2"
    local path="${CURVY_ZK_DIR}/${file}"
    # Reruns keep a verified copy instead of downloading 40 MB again.
    if has_digest "${path}" "${expected}"; then
        log_info "${file} already staged"
        return
    fi
    log_info "Downloading ${file} from rs-sdk ${RS_SDK_VERSION}..."
    curl -fsSL --retry 3 -o "${path}" "${RELEASE_URL}/${file}"
    if ! has_digest "${path}" "${expected}"; then
        rm -f "${path}"
        log_error "${file}: SHA-256 mismatch, expected ${expected}"
        exit 1
    fi
}

main() {
    mkdir -p "${CURVY_ZK_DIR}"
    stage_file pix-aggregation-bound-2-9-30.signet.zst 334964e70daf187c66ee02af6c3061049458994de162ce6981c7a8eec7dc60f6
    stage_file verifyPixAggregationBound_2_9_30-final.zkey a7269ddecf820217aa103d9267e8884f3c7f37a8211f235c9f6c814f5786ed97
    cp "${SCRIPT_DIR}/curvy-zk/LICENSE" "${CURVY_ZK_DIR}/LICENSE"
    log_success "Curvy proving files staged at ${CURVY_ZK_DIR} (rs-sdk ${RS_SDK_VERSION}, $(du -sh "${CURVY_ZK_DIR}" | cut -f1))"
}

main
