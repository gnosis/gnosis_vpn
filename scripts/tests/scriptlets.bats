#!/usr/bin/env bats
#
# Pure-function tests for the Linux maintainer scripts; safe to run unprivileged on any host.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=../../linux/scripts/scriptlet-lib.sh
    source "${REPO_ROOT}/linux/scripts/scriptlet-lib.sh"
}

@test "scriptlet_mode: rpm %pre/%post argument 1 is a fresh install" {
    run scriptlet_mode install 1
    [ "$output" = "rpm-install" ]
}

@test "scriptlet_mode: rpm %pre/%post argument 2 or more is an upgrade" {
    run scriptlet_mode install 2
    [ "$output" = "rpm-upgrade" ]
    run scriptlet_mode install 3
    [ "$output" = "rpm-upgrade" ]
}

@test "scriptlet_mode: rpm %preun/%postun argument 0 is an erase" {
    run scriptlet_mode remove 0
    [ "$output" = "rpm-erase" ]
}

@test "scriptlet_mode: rpm %preun/%postun argument 1 or more is an upgrade" {
    run scriptlet_mode remove 1
    [ "$output" = "rpm-upgrade" ]
    run scriptlet_mode remove 2
    [ "$output" = "rpm-upgrade" ]
}

@test "scriptlet_mode: dpkg action words and no argument are dpkg" {
    local action
    for action in configure install upgrade remove purge abort-upgrade ""; do
        run scriptlet_mode install "$action"
        [ "$output" = "dpkg" ]
        run scriptlet_mode remove "$action"
        [ "$output" = "dpkg" ]
    done
}

@test "is_rpm_mode is true only for rpm modes" {
    run is_rpm_mode rpm-install
    [ "$status" -eq 0 ]
    run is_rpm_mode rpm-upgrade
    [ "$status" -eq 0 ]
    run is_rpm_mode rpm-erase
    [ "$status" -eq 0 ]
    run is_rpm_mode dpkg
    [ "$status" -eq 1 ]
}

@test "render_maintainer_scripts inlines the library into every script" {
    source "${REPO_ROOT}/scripts/common.sh" 2>/dev/null || true
    local out="${BATS_TEST_TMPDIR}/scripts" script
    render_maintainer_scripts "${REPO_ROOT}/linux/scripts" "$out"
    for script in preinstall postinstall preuninstall postuninstall; do
        [ -f "${out}/${script}.sh" ]
        # The rendered scripts must still parse after the inlining.
        bash -n "${out}/${script}.sh"
        grep -q '^scriptlet_mode()' "${out}/${script}.sh"
        if grep -q '__GNOSIS_VPN_SCRIPTLET_LIB__' "${out}/${script}.sh"; then
            echo "unrendered library marker left in ${script}.sh" >&2
            return 1
        fi
    done
}

@test "render_maintainer_scripts fails when the shared library is missing" {
    source "${REPO_ROOT}/scripts/common.sh" 2>/dev/null || true
    local src="${BATS_TEST_TMPDIR}/linux/scripts"
    mkdir -p "$src"
    cp "${REPO_ROOT}"/linux/scripts/{preinstall,postinstall,preuninstall,postuninstall}.sh "$src/"
    run render_maintainer_scripts "$src" "${BATS_TEST_TMPDIR}/out"
    [ "$status" -ne 0 ]
    [[ $output == *"scriptlet-lib.sh"* ]]
}

@test "preuninstall: an rpm upgrade leaves the service to the new package" {
    [[ $EUID -ne 0 ]] || skip "must not run as root"
    source "${REPO_ROOT}/linux/scripts/preuninstall.sh"
    run main 1
    [ "$status" -eq 0 ]
    [[ $output == *"Upgrade in progress"* ]]
    [[ $output != *"Stopping"* ]]
    [[ $output != *"Disabling"* ]]
}

@test "postuninstall: an rpm upgrade only reloads systemd" {
    [[ $EUID -ne 0 ]] || skip "must not run as root"
    source "${REPO_ROOT}/linux/scripts/postuninstall.sh"
    # A stub keeps the test off the host's service manager.
    systemctl() { echo "systemctl $*"; }
    deb-systemd-helper() { echo "deb-systemd-helper $*"; }
    run main 1
    [ "$status" -eq 0 ]
    [[ $output == *"Upgrade in progress"* ]]
    [[ $output == *"daemon-reload"* ]]
    [[ $output != *"Removing"* ]]
}

@test "channel_for_version maps the version shape to a channel" {
    source "${REPO_ROOT}/linux/scripts/postinstall.sh"
    run channel_for_version 0.94.2
    [ "$output" = "stable" ]
    run channel_for_version 2026.09.14+build.010203
    [ "$output" = "snapshot" ]
    run channel_for_version 2026.09.14+build.010203.experimental
    [ "$output" = "experimental" ]
}

@test "render_rpm_repo lists GCS first and the IPFS mirror second on stable" {
    source "${REPO_ROOT}/linux/scripts/postinstall.sh"
    run render_rpm_repo stable
    [ "$status" -eq 0 ]
    [[ $output == *"[gnosisvpn]"* ]]
    [[ $output == *"name=GnosisVPN (stable)"* ]]
    [[ $output == *"baseurl=https://download.gnosisvpn.io/linux/rpm/stable https://download.vpn.gnosis.eth.limo/linux/rpm/stable"* ]]
    [[ $output == *"gpgcheck=1"* ]]
    [[ $output == *"repo_gpgcheck=1"* ]]
    [[ $output == *"gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-gnosisvpn"* ]]
}

@test "render_rpm_repo lists only GCS on snapshot and experimental" {
    source "${REPO_ROOT}/linux/scripts/postinstall.sh"
    run render_rpm_repo snapshot
    [[ $output == *"baseurl=https://download.gnosisvpn.io/linux/rpm/snapshot"$'\n'* ]]
    [[ $output != *"eth.limo"* ]]
    run render_rpm_repo experimental
    [[ $output == *"baseurl=https://download.gnosisvpn.io/linux/rpm/experimental"$'\n'* ]]
    [[ $output != *"eth.limo"* ]]
}

@test "sourcing a maintainer script does not run main or change shell options" {
    local script
    for script in preinstall postinstall preuninstall postuninstall; do
        run bash -c "source '${REPO_ROOT}/linux/scripts/scriptlet-lib.sh'; source '${REPO_ROOT}/linux/scripts/${script}.sh'; [[ \$- != *e* ]] && echo clean"
        [ "$status" -eq 0 ]
        [ "$output" = "clean" ]
    done
}
