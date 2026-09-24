#!/usr/bin/env bash
# Per-channel and per-installer-line constants, sourced by the build, packaging and prune scripts (keep bash 3.2 safe).

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
RETAIN_EXPERIMENTAL="${RETAIN_EXPERIMENTAL:-7}"

# Client/app boundary between the installer lines: standard < boundary <= experimental (the toolkit is not split).
COMPONENT_VERSION_BOUNDARY="0.100.0"

# Networks per installer line (space-separated, first = default); packages bake the list for their postinstall.
NETWORKS_STANDARD="${NETWORKS_STANDARD:-jura-prod jura-staging jura-dev}"
NETWORKS_EXPERIMENTAL="${NETWORKS_EXPERIMENTAL:-piz-palu-dev}"
