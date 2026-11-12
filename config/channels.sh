#!/usr/bin/env bash
# Per-channel constants, sourced by the build, packaging and prune scripts (keep bash 3.2 safe).

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
RETAIN_EXPERIMENTAL="${RETAIN_EXPERIMENTAL:-7}"

# Lowest client/app version any channel packages, so a merge on the frozen v4 branch (release/hoprdv4) never wins; pinned against stray env vars.
COMPONENT_VERSION_BOUNDARY="0.100.0"

# Networks every channel ships (space-separated, first = default); packages bake the list for their postinstall.
NETWORKS="${NETWORKS:-piz-palu-prod piz-palu-staging piz-palu-dev}"

# Replaced networks (`old:new`), baked into packages and mirrored in install/linux.sh; entries chain and stay for installs that skipped a step.
NETWORK_SUCCESSORS="jura-prod:piz-palu-prod jura-staging:piz-palu-staging jura-dev:piz-palu-dev"
# TODO: remove by December 2027. Pre-rename names of the same networks; mirrors the rename maps in the postinstalls and install/linux.sh.
NETWORK_RENAMES="jura:jura-prod rotsee:jura-dev"
