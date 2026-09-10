#!/usr/bin/env bash
# Shared build/release constants — used by the packaging scripts, manifest generator and workflows.
MIN_OS_MACOS="15.0"
MIN_OS_LINUX_UBUNTU="22.04"
MIN_APP_VERSION="${MIN_APP_VERSION:-0.77.0}"

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
RETAIN_EXPERIMENTAL="${RETAIN_EXPERIMENTAL:-7}"

# Client/app boundary between the installer lines: standard < boundary <= experimental (the toolkit is not split).
COMPONENT_VERSION_BOUNDARY="${COMPONENT_VERSION_BOUNDARY:-0.100.0}"

# Networks per installer line (space-separated, first = default); packages bake the list for their postinstall.
NETWORKS_STANDARD="${NETWORKS_STANDARD:-jura-prod jura-dev}"
NETWORKS_EXPERIMENTAL="${NETWORKS_EXPERIMENTAL:-piz-palu-dev}"
