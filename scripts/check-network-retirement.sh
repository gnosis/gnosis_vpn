#!/usr/bin/env bash
# Renders the Linux maintainer scripts for today's lines, for the stable line on piz-palu and for a later replacement, so the retired-conffile set is checked on the PR.

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

# While a line still ships jura, a channel switch back to it must find its conffiles.
expect_retired "today" "config-jura.toml config-rotsee.toml"

NETWORKS_STANDARD="piz-palu-prod piz-palu-staging piz-palu-dev" \
    expect_retired "stable-on-piz-palu" \
    "config-jura.toml config-rotsee.toml config-jura-prod.toml config-jura-staging.toml config-jura-dev.toml"

NETWORKS_STANDARD="next-prod next-staging next-dev" NETWORKS_EXPERIMENTAL="next-dev next-staging next-prod" \
    NETWORK_SUCCESSORS="${NETWORK_SUCCESSORS} piz-palu-prod:next-prod piz-palu-staging:next-staging piz-palu-dev:next-dev" \
    expect_retired "after-a-second-replacement" \
    "config-jura.toml config-rotsee.toml config-jura-prod.toml config-jura-staging.toml config-jura-dev.toml config-piz-palu-prod.toml config-piz-palu-staging.toml config-piz-palu-dev.toml"

# Every replaced network must lead, through later replacements, to one some line ships, or the move has nowhere to go.
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
        case " ${NETWORKS_STANDARD} ${NETWORKS_EXPERIMENTAL} " in
        *" ${network} "*) continue 2 ;;
        esac
        [[ -n ${network} ]] || break
    done
    log_error "NETWORK_SUCCESSORS: ${pair%%:*} does not lead to a network any installer line ships within four replacements"
    exit 1
done
log_success "Every replaced network leads to one some installer line ships"
