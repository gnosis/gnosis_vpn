#!/usr/bin/env bash
#
# Print the snapshot installer version for a package.json version P (default: this repo's package.json),
# with T the current UTC time as YYYYMMDDHHMMSS:
#   P plain       -> P-0.T   (1.0.1-0.20261117010203)
#   P prerelease  -> P.T     (1.1.0-rc.1.20261120010203)
# Both sort below P and above every earlier snapshot of P under SemVer 2.0.0.
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
