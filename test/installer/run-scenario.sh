#!/usr/bin/env bash
#
# Entry point for a single installer test scenario.
#
#   sudo -E run-scenario.sh <scenario-id>
#
# Runs the scenario's install phase (+ asserts), then the shared upgrade phase
# (+ asserts), then any scenario-specific post-upgrade asserts. A per-scenario
# JSON result record is written to $GVPN_RESULT_FILE on exit (pass or fail).
#
# Expects the local APT repo to be up already (lib/local-repo.sh) and the .deb
# in ./debs (or $GVPN_DEB). Must run as root.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SCENARIO="${1:?usage: run-scenario.sh <scenario-id>}"

# Where the result record is written. The workflow sets this; the CWD-based
# fallback keeps it working for local runs and if the env var is not carried
# through sudo (CWD is preserved, so this resolves to the same file).
export GVPN_RESULT_FILE="${GVPN_RESULT_FILE:-${GITHUB_WORKSPACE:-$PWD}/results/${SCENARIO}.json}"

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/asserts.sh
source "$HERE/lib/asserts.sh"
# shellcheck source=lib/upgrade.sh
source "$HERE/lib/upgrade.sh"
# shellcheck source=scenarios.sh
source "$HERE/scenarios.sh"

# The RESULT_* globals form the result record consumed by write_result() in
# common.sh; shellcheck can't see that cross-file use.
# shellcheck disable=SC2034
RESULT_SCENARIO="$SCENARIO"
# shellcheck disable=SC2034
RESULT_TYPE="${SCENARIO%%-*}" # "deb" or "sh"
install_result_trap

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run-scenario.sh must run as root"

# Locate the .deb (workflow downloads it into ./debs). Match the host arch so
# this works on both the amd64 CI runners and a local arm64 box.
_arch="$(dpkg --print-architecture)"
GVPN_DEB="${GVPN_DEB:-$(compgen -G "debs/gnosisvpn_*_${_arch}.deb" 2>/dev/null | head -n1 || true)}"
[[ -n $GVPN_DEB && -f $GVPN_DEB ]] || die "deb not found (set GVPN_DEB or place a gnosisvpn_*_${_arch}.deb in ./debs)"
# Absolute path: `apt-get install <path>` treats a bare relative "dir/x.deb" as
# the pkg/release syntax, not a local file.
GVPN_DEB="$(readlink -f "$GVPN_DEB")"
export GVPN_DEB
DEB_VERSION="$(dpkg-deb -f "$GVPN_DEB" Version)"
export DEB_VERSION
export INSTALL_SH="${INSTALL_SH:-/tmp/install-linux-test.sh}"

# The stable/snapshot versions the local repo published (local-repo.sh writes
# this). Stable-channel scenarios assert against STABLE_VERSION; the direct-deb
# and snapshot scenarios use the built (snapshot) version.
STABLE_VERSION=""
SNAPSHOT_VERSION="$DEB_VERSION"
if [[ -f /srv/gvpn-apt/versions.env ]]; then
    # shellcheck disable=SC1091
    source /srv/gvpn-apt/versions.env
fi
export STABLE_VERSION SNAPSHOT_VERSION

log "scenario=$SCENARIO deb=$GVPN_DEB version=$DEB_VERSION"

fn="scenario_${SCENARIO//-/_}"
declare -F "${fn}_install" >/dev/null || die "unknown scenario: $SCENARIO"

log "=== $SCENARIO: install phase ==="
# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_INSTALL="fail"
"${fn}_install"
# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_INSTALL="pass"
print_outcome_report "after install"

log "=== $SCENARIO: upgrade phase ==="
# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_UPGRADE="fail"
run_upgrade_phase
if declare -F "${fn}_postupgrade" >/dev/null; then
    log "=== $SCENARIO: scenario-specific post-upgrade asserts ==="
    "${fn}_postupgrade"
fi
# shellcheck disable=SC2034  # RESULT_* consumed by write_result() in common.sh
RESULT_UPGRADE="pass"
print_outcome_report "after upgrade"

log "=== $SCENARIO: PASSED ==="
