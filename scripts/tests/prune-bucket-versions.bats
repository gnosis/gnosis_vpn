#!/usr/bin/env bats
#
# Unit tests for the listing parsers of scripts/prune-bucket-versions.sh (GNU sed/head, run on Linux).

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=../prune-bucket-versions.sh
    source "${REPO_ROOT}/scripts/prune-bucket-versions.sh"
}

@test "extract_versions reads deb pools and ignores sidecars" {
    local listing
    listing=$'gs://b/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.9.10_amd64.deb\ngs://b/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.9.10_amd64.deb.asc\ngs://b/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.9.2_arm64.deb\ngs://b/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.9.10_arm64.deb.sha256'
    run extract_versions <<<"$listing"
    [ "$output" = $'0.9.2\n0.9.10' ]
}

@test "extract_versions reads macOS directories" {
    run extract_versions <<<$'gs://b/macos/latest/gnosisvpn_2026.05.14-build.143052_arm64.pkg\ngs://b/macos/latest/gnosisvpn_2026.05.14-build.143052_arm64.pkg.sha256'
    [ "$output" = "2026.05.14-build.143052" ]
}

@test "extract_versions reads rpm repositories and ignores sidecars" {
    local listing
    listing=$'gs://b/linux/rpm/snapshot/packages/gnosisvpn-2026.09.14+build.000002-1.x86_64.rpm\ngs://b/linux/rpm/snapshot/packages/gnosisvpn-2026.09.14+build.000002-1.aarch64.rpm.asc\ngs://b/linux/rpm/snapshot/packages/gnosisvpn-2026.09.13+build.000001-1.aarch64.rpm\ngs://b/linux/rpm/snapshot/packages/gnosisvpn-2026.09.14+build.000002-1.aarch64.rpm'
    run extract_versions <<<"$listing"
    [ "$output" = $'2026.09.13+build.000001\n2026.09.14+build.000002' ]
}

@test "version_glob anchors deb and pkg versions with underscores" {
    run version_glob gs://b/linux/apt/pool/main/g/gnosisvpn/ 0.9.1 $'gs://b/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.9.1_amd64.deb'
    [ "$output" = "gs://b/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.9.1_*" ]
}

@test "version_glob anchors rpm versions with the release" {
    run version_glob gs://b/linux/rpm/stable/packages/ 0.9.1 $'gs://b/linux/rpm/stable/packages/gnosisvpn-0.9.1-1.x86_64.rpm'
    [ "$output" = "gs://b/linux/rpm/stable/packages/gnosisvpn-0.9.1-1.*" ]
}
