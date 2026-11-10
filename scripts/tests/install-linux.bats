#!/usr/bin/env bats
#
# Unit tests for install/linux.sh; no root, network or package manager needed.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    INSTALLER="${REPO_ROOT}/install/linux.sh"
    # shellcheck source=../../install/linux.sh
    source "$INSTALLER"
    OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
}

write_os_release() {
    printf '%s\n' "$@" >"$OS_RELEASE_FILE"
}

@test "piped execution runs main (curl | bash)" {
    run bash -s -- --help <"$INSTALLER"
    [ "$status" -eq 0 ]
    [[ $output == *"Usage: linux.sh"* ]]
}

@test "detect_family: Debian and Ubuntu use apt" {
    write_os_release 'ID=debian' 'VERSION_ID="12"'
    run detect_family
    [ "$output" = "apt" ]
    write_os_release 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"'
    run detect_family
    [ "$output" = "apt" ]
}

@test "detect_family: Debian derivatives are recognised through ID_LIKE" {
    write_os_release 'ID=linuxmint' 'ID_LIKE="ubuntu debian"'
    run detect_family
    [ "$output" = "apt" ]
}

@test "detect_family: Fedora and EL10 distributions use dnf" {
    local line
    for line in 'ID=fedora' 'ID="rhel"' 'ID="almalinux"' 'ID="rocky"' 'ID="centos"' 'ID="ol"'; do
        write_os_release "$line" 'VERSION_ID="10.0"'
        run detect_family
        [ "$output" = "dnf" ]
    done
}

@test "detect_family: unknown distributions fail" {
    write_os_release 'ID=arch'
    run detect_family
    [ "$status" -eq 1 ]
    [[ $output == *"Unsupported distribution"* ]]
}

@test "detect_family: falls back to apt when os-release is missing but dpkg and apt-get exist" {
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$bin"
    printf '#!/bin/sh\nexit 0\n' >"${bin}/dpkg"
    printf '#!/bin/sh\nexit 0\n' >"${bin}/apt-get"
    chmod 0755 "${bin}/dpkg" "${bin}/apt-get"
    OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/missing-os-release"
    PATH="${bin}:${PATH}"
    run detect_family
    [ "$status" -eq 0 ]
    [ "$output" = "apt" ]
}

@test "detect_family: a missing os-release without apt tools fails with a clear message" {
    local bin="${BATS_TEST_TMPDIR}/empty-bin" bash_bin
    mkdir -p "$bin"
    bash_bin="$(command -v bash)"
    # An empty PATH hides every host tool, so only the shell builtins the probe uses are available.
    run env PATH="$bin" "$bash_bin" -c 'source "$1"; OS_RELEASE_FILE="$2"; detect_family' _ \
        "$INSTALLER" "${BATS_TEST_TMPDIR}/missing-os-release"
    [ "$status" -eq 1 ]
    [[ $output == *"/etc/os-release not found"* ]]
}

@test "check_dnf_distro: Fedora 43 and 44 are supported" {
    local version
    for version in 43 44; do
        write_os_release 'ID=fedora' "VERSION_ID=${version}"
        run check_dnf_distro
        [ "$status" -eq 0 ]
        [[ $output == *"(supported)"* ]]
    done
}

@test "check_dnf_distro: every EL10 distribution is supported" {
    local id
    for id in rhel almalinux rocky centos ol; do
        write_os_release "ID=\"${id}\"" 'VERSION_ID="10.2"'
        run check_dnf_distro
        [ "$status" -eq 0 ]
        [[ $output == *"(supported)"* ]]
    done
}

@test "check_dnf_distro: EL9 is refused with the reason" {
    local id
    for id in rhel almalinux rocky centos ol; do
        write_os_release "ID=\"${id}\"" 'VERSION_ID="9.8"'
        run check_dnf_distro
        [ "$status" -eq 1 ]
        [[ $output == *"webkit2gtk4.1"* ]]
    done
}

@test "check_dnf_distro: other Fedora releases warn and continue" {
    write_os_release 'ID=fedora' 'VERSION_ID=45'
    run check_dnf_distro
    [ "$status" -eq 0 ]
    [[ $output == *"not in the officially supported list"* ]]
}

@test "is_enterprise_linux distinguishes EL from Fedora" {
    write_os_release 'ID="rocky"' 'VERSION_ID="10.0"'
    run is_enterprise_linux
    [ "$status" -eq 0 ]
    write_os_release 'ID=fedora' 'VERSION_ID=44'
    run is_enterprise_linux
    [ "$status" -eq 1 ]
}

@test "parse_args: --enable-epel and --enable-resolved accept y and n" {
    parse_args --enable-epel=y --enable-resolved=n
    [ "$ENABLE_EPEL" = "y" ]
    [ "$ENABLE_RESOLVED" = "n" ]
    parse_args --enable-epel yes --enable-resolved no
    [ "$ENABLE_EPEL" = "y" ]
    [ "$ENABLE_RESOLVED" = "n" ]
}

@test "parse_args: invalid --enable-epel values fail" {
    run parse_args --enable-epel=maybe
    [ "$status" -eq 1 ]
    [[ $output == *"--enable-epel must be"* ]]
}

@test "parse_args: GNOSISVPN_ENABLE_EPEL presets the answer" {
    run bash -c "GNOSISVPN_ENABLE_EPEL=y; source '$INSTALLER'; parse_args; echo \"\$ENABLE_EPEL\""
    [ "$output" = "y" ]
}

@test "ask_yes_no returns a preset answer without a terminal" {
    run ask_yes_no y "Enable?" </dev/null
    [ "$output" = "y" ]
    run ask_yes_no n "Enable?" </dev/null
    [ "$output" = "n" ]
}

@test "ask_yes_no returns nothing without a preset or a terminal" {
    run setsid bash -c "source '$INSTALLER'; ask_yes_no '' 'Enable?'" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "installer and postinstall render the same dnf repository file" {
    local channel installer_repo postinstall_repo
    for channel in stable snapshot experimental; do
        installer_repo="$(render_rpm_repo "$channel")"
        postinstall_repo="$(bash -c "source '${REPO_ROOT}/linux/scripts/scriptlet-lib.sh'; source '${REPO_ROOT}/linux/scripts/postinstall.sh'; render_rpm_repo '$channel'")"
        [ "$installer_repo" = "$postinstall_repo" ]
    done
}

@test "first_nonempty_line skips the blank lines dnf4 repoquery emits" {
    run first_nonempty_line <<<$'\n\n2026.09.14+build.010203\n\n'
    [ "$output" = "2026.09.14+build.010203" ]
}
