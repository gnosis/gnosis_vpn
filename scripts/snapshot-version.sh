#!/usr/bin/env bash
#
# Usage: snapshot-version.sh [package_version]; P = package_version or package.json, T = UTC YYYYMMDDHHMMSS.
# Prints P-0.T (1.0.1-0.20261117010203), or P.T for a prerelease P (1.1.0-rc.1.20261120010203).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

package_version="${1:-$(jq -r '.version' "${SCRIPT_DIR}/../package.json")}"
timestamp="$(date -u +%Y%m%d%H%M%S)"

if [[ $package_version == *-* ]]; then
    echo "${package_version}.${timestamp}"
else
    echo "${package_version}-0.${timestamp}"
fi
