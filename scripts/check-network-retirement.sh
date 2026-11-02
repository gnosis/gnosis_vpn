#!/usr/bin/env bash
# Renders the Linux maintainer scripts for today's lines and for the stable line on piz-palu, so the retired-conffile set is checked on the PR.

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

# Every replaced network must name a successor some line ships, or the move has nowhere to go.
for pair in ${NETWORK_SUCCESSORS}; do
    successor="${pair#*:}"
    case " ${NETWORKS_STANDARD} ${NETWORKS_EXPERIMENTAL} " in
    *" ${successor} "*) ;;
    *)
        log_error "NETWORK_SUCCESSORS maps ${pair%%:*} to ${successor}, which no installer line ships"
        exit 1
        ;;
    esac
done
log_success "Every network successor ships on some installer line"
