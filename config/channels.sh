#!/usr/bin/env bash
# Per-channel and per-installer-line constants, sourced by the build, packaging and prune scripts (keep bash 3.2 safe).

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
RETAIN_EXPERIMENTAL="${RETAIN_EXPERIMENTAL:-7}"

# Client/app boundary between the installer lines: standard < boundary <= experimental (the toolkit is not split); pinned so a stray env var cannot move it.
COMPONENT_VERSION_BOUNDARY="0.100.0"

# Networks per installer line (space-separated, first = default); packages bake the list for their postinstall.
NETWORKS_STANDARD="${NETWORKS_STANDARD:-jura-prod jura-staging jura-dev}"
NETWORKS_EXPERIMENTAL="${NETWORKS_EXPERIMENTAL:-piz-palu-dev piz-palu-staging piz-palu-prod}"

# Networks replaced by a new one (`old:new`): an install on `old` moves to `new` once its package stops shipping `old`.
# Packages bake it for their postinstall; install/linux.sh keeps a copy. Its keys' conffiles go once no line ships them.
NETWORK_SUCCESSORS="jura-prod:piz-palu-prod jura-staging:piz-palu-staging jura-dev:piz-palu-dev"
# TODO: remove by December 2027. Pre-rename names of the same networks; mirrors the rename maps in the postinstalls and install/linux.sh.
NETWORK_RENAMES="jura:jura-prod rotsee:jura-dev"
