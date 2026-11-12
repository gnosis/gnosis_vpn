#!/usr/bin/env bash
# Renders the Linux maintainer scripts for today's networks and for a later replacement, so the retired-conffile set is checked on the PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/../config/channels.sh"
ROOT="${SCRIPT_DIR}/.."

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

expect_retired() {
    local label="$1" expected="$2" script line
    local dst="${work}/${label}"
    render_maintainer_scripts "${ROOT}/linux/scripts" "${dst}"
    for script in preinstall.sh postinstall.sh postuninstall.sh; do
        line="$(grep '^RETIRED_CONFFILES=' "${dst}/${script}")"
        if [[ ${line} != "RETIRED_CONFFILES=\"${expected}\"" ]]; then
            log_error "${label}: ${script} has ${line}, expected RETIRED_CONFFILES=\"${expected}\""
            exit 1
        fi
    done
    log_success "${label}: retired conffiles are '${expected}'"
}

expect_retired "today" \
    "config-jura.toml config-rotsee.toml config-jura-prod.toml config-jura-staging.toml config-jura-dev.toml"

NETWORKS="next-prod next-staging next-dev" \
    NETWORK_SUCCESSORS="${NETWORK_SUCCESSORS} piz-palu-prod:next-prod piz-palu-staging:next-staging piz-palu-dev:next-dev" \
    expect_retired "after-a-second-replacement" \
    "config-jura.toml config-rotsee.toml config-jura-prod.toml config-jura-staging.toml config-jura-dev.toml config-piz-palu-prod.toml config-piz-palu-staging.toml config-piz-palu-dev.toml"

# Every replaced network must lead, through later replacements, to one the installer ships, or the move has nowhere to go.
successor_of() {
    local pair
    for pair in ${NETWORK_SUCCESSORS}; do
        if [[ ${pair%%:*} == "$1" ]]; then
            echo "${pair#*:}"
            return 0
        fi
    done
}

for pair in ${NETWORK_SUCCESSORS}; do
    network="${pair%%:*}"
    for _ in 1 2 3 4; do
        network="$(successor_of "${network}")"
        case " ${NETWORKS} " in
        *" ${network} "*) continue 2 ;;
        esac
        [[ -n ${network} ]] || break
    done
    log_error "NETWORK_SUCCESSORS: ${pair%%:*} does not lead to a shipped network within four replacements"
    exit 1
done
log_success "Every replaced network leads to a shipped one"

mirror_mismatch() {
    log_error "$1 does not match config/channels.sh: $2"
    exit 1
}

# install/linux.sh is published on its own, so it keeps copies of the channel lists and network maps; a drift misroutes --network.
(
    # shellcheck source=../install/linux.sh
    source <(sed '$d' "${ROOT}/install/linux.sh")
    # Stable keeps the published 0.97.x list until v1.0.0, so only snapshot mirrors what this repo builds.
    [[ "$(channel_networks snapshot)" == "${NETWORKS}" ]] ||
        mirror_mismatch install/linux.sh "channel_networks snapshot is '$(channel_networks snapshot)'"
    for pair in ${NETWORK_SUCCESSORS}; do
        [[ "$(network_successor "${pair%%:*}")" == "${pair#*:}" ]] ||
            mirror_mismatch install/linux.sh "network_successor ${pair%%:*} is '$(network_successor "${pair%%:*}")'"
    done
    for pair in ${NETWORK_RENAMES}; do
        [[ "$(canonical_network "${pair%%:*}")" == "${pair#*:}" ]] ||
            mirror_mismatch install/linux.sh "canonical_network ${pair%%:*} is '$(canonical_network "${pair%%:*}")'"
    done
    arms="$(sed -n '/^network_successor() {/,/^}/p' "${ROOT}/install/linux.sh" | grep -cE '^ +[a-z0-9-]+\) echo ')"
    [[ ${arms} -eq $(wc -w <<<"${NETWORK_SUCCESSORS}") ]] ||
        mirror_mismatch install/linux.sh "network_successor has ${arms} entries"
)
log_success "install/linux.sh mirrors the network list and maps"

# The postinstalls keep the pre-rename map in code (it goes away with its TODO); the successors are baked.
(
    # shellcheck source=../linux/scripts/postinstall.sh
    source <(sed '$d' "${ROOT}/linux/scripts/postinstall.sh")
    for pair in ${NETWORK_RENAMES}; do
        [[ "$(renamed_network "${pair%%:*}")" == "${pair#*:}" ]] ||
            mirror_mismatch linux/scripts/postinstall.sh "renamed_network ${pair%%:*} is '$(renamed_network "${pair%%:*}")'"
    done
)
mac_renames="$(sed -n 's/^NETWORK_RENAMES=(\(.*\))$/\1/p' "${ROOT}/mac/resources/scripts/postinstall")"
[[ ${mac_renames} == "${NETWORK_RENAMES}" ]] ||
    mirror_mismatch mac/resources/scripts/postinstall "NETWORK_RENAMES is '${mac_renames}'"
log_success "The postinstalls mirror the rename map"
