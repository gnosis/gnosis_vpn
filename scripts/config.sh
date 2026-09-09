#!/usr/bin/env bash
# Shared build/release constants — referenced by the manifest generator, the macOS
# installer, resolve-build-versions.sh, the packaging scripts and the prune workflow.
MIN_OS_MACOS="15.0"
MIN_OS_LINUX_UBUNTU="22.04"
MIN_APP_VERSION="${MIN_APP_VERSION:-0.77.0}"

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
RETAIN_EXPERIMENTAL="${RETAIN_EXPERIMENTAL:-7}"

# Component version boundary between the two installer lines. Applies to
# gnosis_vpn-client and gnosis_vpn-app; the toolkit is not split.
#   standard line     (stable, snapshot, pr, commit) -> version core <  boundary
#   experimental line (experimental)                 -> version core >= boundary
COMPONENT_VERSION_BOUNDARY="${COMPONENT_VERSION_BOUNDARY:-0.100.0}"

# Networks shipped per installer line (space-separated; the FIRST entry is the
# default the postinstalls select). The packages bake the applicable list so the
# postinstalls can validate a selection and re-point /etc/gnosisvpn/config.toml
# after a channel switch without hardcoding network names.
NETWORKS_STANDARD="${NETWORKS_STANDARD:-jura-prod jura-dev}"
NETWORKS_EXPERIMENTAL="${NETWORKS_EXPERIMENTAL:-piz-palu-dev}"
