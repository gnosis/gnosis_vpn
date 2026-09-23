#!/usr/bin/env bash
# Shared build/release constants — used by the packaging scripts, manifest generator and workflows.
# Manifest inputs (min_app_version, end_of_life) and OS floors live in ../config/*.json.

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
RETAIN_EXPERIMENTAL="${RETAIN_EXPERIMENTAL:-7}"

# Client/app boundary between the installer lines: standard < boundary <= experimental (the toolkit is not split).
COMPONENT_VERSION_BOUNDARY="${COMPONENT_VERSION_BOUNDARY:-0.100.0}"

# Networks per installer line (space-separated, first = default); packages bake the list for their postinstall.
NETWORKS_STANDARD="${NETWORKS_STANDARD:-jura-prod jura-staging jura-dev}"
NETWORKS_EXPERIMENTAL="${NETWORKS_EXPERIMENTAL:-piz-palu-dev}"
