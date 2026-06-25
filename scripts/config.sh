#!/usr/bin/env bash
# Shared version constraints — referenced by the manifest generator and macOS installer
MIN_OS_MACOS="15.0"
MIN_OS_LINUX_UBUNTU="22.04"
MIN_APP_VERSION="${MIN_APP_VERSION:-0.77.0}"

# Retention counts for published versions — referenced by the prune script
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
