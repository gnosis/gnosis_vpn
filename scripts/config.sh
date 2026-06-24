#!/usr/bin/env bash
# Shared version constraints — referenced by the manifest generator and macOS installer
MIN_OS_MACOS="15.0"
MIN_OS_LINUX_UBUNTU="22.04"
MIN_APP_VERSION="${MIN_APP_VERSION:-0.77.0}"

# Bucket retention: how many of the newest versions to keep per channel. Single
# source of truth, read by scripts/publish-apt.sh (index pruning) and
# .github/workflows/prune-bucket.yaml (bucket object pruning) so the two never
# disagree on the retention window.
RETAIN_STABLE="${RETAIN_STABLE:-3}"
RETAIN_SNAPSHOT="${RETAIN_SNAPSHOT:-7}"
