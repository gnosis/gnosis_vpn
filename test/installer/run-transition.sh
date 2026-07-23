#!/usr/bin/env bash
#
# One cell of the channel×network transition matrix.
#
#   sudo -E run-transition.sh switch-<from>-to-<to>
#
# where <from>/<to> ∈ { sj, sr, nj, nr }  (s=stable, n=snapshot; j=jura, r=rotsee).
#
# Installs state A (fresh), seeds a known identity, then installs state B while
# switching channel + network AND resetting identity — the compound flow — and
# asserts the final state equals B. Driven by the patched install.sh (the
# documented switch tool; the only path that correctly downgrades snapshot→stable).
#
# Expects lib/local-repo.sh to have run already. Must run as root.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SCENARIO="${1:?usage: run-transition.sh switch-<from>-to-<to>}"
export GVPN_RESULT_FILE="${GVPN_RESULT_FILE:-${GITHUB_WORKSPACE:-$PWD}/results/${SCENARIO}.json}"

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/asserts.sh
source "$HERE/lib/asserts.sh"

# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_SCENARIO="$SCENARIO"
# shellcheck disable=SC2034
RESULT_TYPE="switch"
install_result_trap

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run-transition.sh must run as root"

INSTALL_SH="${INSTALL_SH:-/tmp/install-linux-test.sh}"
[[ -f $INSTALL_SH ]] || die "patched install.sh not found at $INSTALL_SH (run lib/local-repo.sh first)"

STABLE_VERSION=""
SNAPSHOT_VERSION=""
if [[ -f /srv/gvpn-apt/versions.env ]]; then
    # shellcheck disable=SC1091
    source /srv/gvpn-apt/versions.env
fi
[[ -n $STABLE_VERSION && -n $SNAPSHOT_VERSION ]] ||
    die "versions.env missing STABLE_VERSION/SNAPSHOT_VERSION (run lib/local-repo.sh first)"

CONF=/etc/gnosisvpn

# --- decode the cell id ("switch-<from>-to-<to>") ----------------------------
# Parameter expansion (portable across bash 3.2/5.x); the 2-char state codes
# never contain "-to-", so the splits are unambiguous.
case "$SCENARIO" in
switch-*-to-*) ;;
*) die "bad cell id: $SCENARIO (expected switch-<from>-to-<to>)" ;;
esac
rest="${SCENARIO#switch-}"
FROM="${rest%%-to-*}"
TO="${rest##*-to-}"
for code in "$FROM" "$TO"; do
    case "$code" in
    sj | sr | nj | nr) ;;
    *) die "bad state code '$code' in $SCENARIO (expected sj|sr|nj|nr)" ;;
    esac
done

decode_channel() { case "${1:0:1}" in s) echo stable ;; n) echo snapshot ;; esac }
decode_network() { case "${1:1:1}" in j) echo jura ;; r) echo rotsee ;; esac }

from_ch="$(decode_channel "$FROM")"
from_net="$(decode_network "$FROM")"
to_ch="$(decode_channel "$TO")"
to_net="$(decode_network "$TO")"

log "cell=$SCENARIO  A=${from_ch}/${from_net} → B=${to_ch}/${to_net}"

# --- state A: fresh install --------------------------------------------------
log "=== install A: ${from_ch}/${from_net} ==="
# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_INSTALL="fail"
bash "$INSTALL_SH" --channel="$from_ch" --network="$from_net"
assert_symlink_target "$CONF/config.toml" "$CONF/config-${from_net}.toml"
# shellcheck disable=SC2034
RESULT_INSTALL="pass"
print_outcome_report "after install A (${from_ch}/${from_net})"

seed_identity

# --- state B: switch channel + network + reset identity ----------------------
log "=== install B: ${to_ch}/${to_net} + reset-identity ==="
# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_UPGRADE="fail"
bash "$INSTALL_SH" --channel="$to_ch" --network="$to_net" --reset-identity

# The final state must equal B (B set channel, network and reset explicitly).
assert_symlink_target "$CONF/config.toml" "$CONF/config-${to_net}.toml"
assert_dynamic_env_blokli "https://blokli.${to_net}.hoprnet.link"
assert_identity_replaced "$SEED_ID_SHA" "$SEED_PASS_SHA"
if [[ $to_ch == stable ]]; then
    assert_version_txt "$STABLE_VERSION" # snapshot→stable also exercises the downgrade pin
    assert_sources stable 127.0.0.1:8000/backup
else
    assert_version_txt "$SNAPSHOT_VERSION"
    assert_sources snapshot 127.0.0.1:8000/backup
    assert_sources_excludes localhost:8000/primary # snapshot must not list the stable-only mirror
fi
assert_service_enabled
assert_service_active
# shellcheck disable=SC2034
RESULT_UPGRADE="pass"
print_outcome_report "after switch to B (${to_ch}/${to_net})"

log "=== $SCENARIO: PASSED ==="
