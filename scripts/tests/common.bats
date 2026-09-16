#!/usr/bin/env bats

setup() {
    SCRIPT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=../common.sh
    source "${SCRIPT_DIR}/common.sh"
}

@test "validate_distribution accepts deb, rpm and dmg" {
    run validate_distribution deb
    [ "$status" -eq 0 ]
    run validate_distribution rpm
    [ "$status" -eq 0 ]
    run validate_distribution dmg
    [ "$status" -eq 0 ]
}

@test "validate_distribution rejects unknown types" {
    run validate_distribution archlinux
    [ "$status" -eq 1 ]
    [[ $output == *"Valid options: deb, rpm, dmg"* ]]
}

@test "generate_package_name keeps the deb naming" {
    GNOSISVPN_DISTRIBUTION=deb GNOSISVPN_PACKAGE_VERSION=0.94.2 GNOSISVPN_ARCHITECTURE=x86_64-linux \
        run generate_package_name
    [ "$output" = "gnosisvpn_0.94.2_amd64.deb" ]
}

@test "generate_package_name uses NVRA naming for rpm on x86_64" {
    GNOSISVPN_DISTRIBUTION=rpm GNOSISVPN_PACKAGE_VERSION=0.94.2 GNOSISVPN_ARCHITECTURE=x86_64-linux \
        run generate_package_name
    [ "$output" = "gnosisvpn-0.94.2-1.x86_64.rpm" ]
}

@test "generate_package_name uses NVRA naming for rpm on aarch64 with a snapshot version" {
    GNOSISVPN_DISTRIBUTION=rpm GNOSISVPN_PACKAGE_VERSION=2026.09.14+build.010203.experimental \
        GNOSISVPN_ARCHITECTURE=aarch64-linux run generate_package_name
    [ "$output" = "gnosisvpn-2026.09.14+build.010203.experimental-1.aarch64.rpm" ]
}

@test "check_rpm_version_syntax accepts versions rpm allows" {
    run check_rpm_version_syntax 0.94.2
    [ "$status" -eq 0 ]
    run check_rpm_version_syntax 2026.09.14+build.010203.experimental
    [ "$status" -eq 0 ]
}

@test "check_rpm_version_syntax rejects a hyphen" {
    run check_rpm_version_syntax 0.94.2+pr.12-abc
    [ "$status" -eq 1 ]
    [[ $output == *"must not contain '-'"* ]]
}
