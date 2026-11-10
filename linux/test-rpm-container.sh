#!/usr/bin/env bash
#
# Integration test for the RPM package, its maintainer scripts and the installer's dnf path, run inside a
# disposable container of the target distribution.
#
# Usage:
#   GNOSISVPN_TEST_KEY_PASSWORD=<pass> linux/test-rpm-container.sh <image> <packages-dir> <public-key> <private-key>
#
# <packages-dir> holds two signed builds of the same architecture as the container (older first by version), e.g.
#   gnosisvpn-2026.09.14+build.000001-1.aarch64.rpm and gnosisvpn-2026.09.14+build.000002-1.aarch64.rpm
# built with GNOSISVPN_PUBLIC_KEY_PATH=<public-key> and signed with <private-key>. Snapshot-shaped versions are
# expected, because the installer runs with --channel=snapshot.
#
# The repository is served from file:///repo inside the container under the production repo id, so the installer
# runs unmodified apart from its base URL and key download. Service state is not asserted: containers run no systemd.

set -Eeuo pipefail

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() {
    printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2
    exit 1
}
step() { printf '\n\033[0;34m==> %s\033[0m\n' "$*"; }

run_host() {
    if [[ $# -ne 4 ]]; then
        sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
    fi
    local image="$1" packages_dir public_key private_key repo_root
    packages_dir="$(cd "$2" && pwd)"
    public_key="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
    private_key="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    : "${GNOSISVPN_TEST_KEY_PASSWORD:?GNOSISVPN_TEST_KEY_PASSWORD must be set}"

    docker run --rm \
        -e GNOSISVPN_TEST_KEY_PASSWORD \
        -v "${repo_root}:/src:ro" \
        -v "${packages_dir}:/packages:ro" \
        -v "${public_key}:/keys/public.asc:ro" \
        -v "${private_key}:/keys/private.asc:ro" \
        "$image" bash /src/linux/test-rpm-container.sh --inside
}

# --- inside the container ---------------------------------------------------------------------------------------

publish_local_repo() {
    rm -rf /repo/snapshot
    mkdir -p /repo/snapshot/packages
    cp "$@" /repo/snapshot/packages/
    createrepo_c -q /repo/snapshot
    printf '%s' "$GNOSISVPN_TEST_KEY_PASSWORD" |
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --local-user "${KEY_ID}!" \
            --armor --detach-sign /repo/snapshot/repodata/repomd.xml
}

# Runs the real installer against the local repository.
run_installer() {
    bash -c '
        source /src/install/linux.sh
        RPM_REPO_URL_PRIMARY="file:///repo"
        install_rpm_key() {
            install -D -m 0644 /keys/public.asc "$RPM_KEY_PATH"
            rpm --import "$RPM_KEY_PATH"
        }
        main "$@"
    ' installer --channel=snapshot --enable-epel=y --enable-resolved=n "$@"
}

installed_version() {
    rpm -q --qf '%{VERSION}' gnosisvpn
}

run_inside() {
    local packages v1_rpm v2_rpm v1 v2
    mapfile -t packages < <(find /packages -maxdepth 1 -name 'gnosisvpn-*.rpm' | sort -V)
    [[ ${#packages[@]} -eq 2 ]] || fail "expected two rpm files in /packages, found ${#packages[@]}"
    v1_rpm="${packages[0]}"
    v2_rpm="${packages[1]}"
    v1="$(rpm -qp --qf '%{VERSION}' "$v1_rpm" 2>/dev/null)"
    v2="$(rpm -qp --qf '%{VERSION}' "$v2_rpm" 2>/dev/null)"

    step "Preparing test tooling on $(. /etc/os-release && echo "$PRETTY_NAME")"
    dnf -y -q install createrepo_c gnupg2 findutils >/dev/null
    export GNUPGHOME
    GNUPGHOME="$(mktemp -d)"
    printf '%s' "$GNOSISVPN_TEST_KEY_PASSWORD" |
        gpg --batch --pinentry-mode loopback --passphrase-fd 0 --import /keys/private.asc 2>/dev/null
    KEY_ID="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^sec/ { print $5; exit }')"

    step "Fresh install of ${v1}"
    publish_local_repo "$v1_rpm"
    run_installer
    [[ "$(installed_version)" == "$v1" ]] || fail "installed version is $(installed_version), expected ${v1}"
    pass "installed ${v1} through the installer"
    rpmkeys -K "$v1_rpm" | grep -q 'digests signatures OK' || fail "package signature does not verify"
    pass "package signature verifies against the imported key"
    # The service runs as root and spawns the worker as the requesting user, so no service account is created.
    ! getent passwd gnosisvpn >/dev/null 2>&1 || fail "postinstall created a service user"
    pass "no service user created"
    grep -qx 'name=GnosisVPN (snapshot)' /etc/yum.repos.d/gnosisvpn.repo || fail "postinstall did not register the snapshot repo"
    grep -qx 'repo_gpgcheck=1' /etc/yum.repos.d/gnosisvpn.repo || fail "repo file lacks repo_gpgcheck=1"
    pass "postinstall registered the snapshot dnf repository"
    [[ "$(readlink /etc/gnosisvpn/config.toml)" == "/etc/gnosisvpn/config-jura-prod.toml" ]] || fail "config.toml does not point at jura-prod"
    pass "config.toml points at the default network"
    [[ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-gnosisvpn ]] || fail "rpm key not shipped"
    [[ -f /usr/share/zsh/site-functions/_gnosis_vpn-ctl ]] || fail "zsh completion not at the rpm path"
    [[ ! -e /usr/share/lintian/overrides/gnosisvpn ]] || fail "deb-only lintian override shipped in the rpm"
    pass "packager-specific files are in place"
    if ldd /usr/bin/gnosis_vpn-app | grep 'not found'; then
        fail "gnosis_vpn-app has unresolved libraries"
    fi
    # No grep -q: it would stop reading early and pipefail would report ldconfig's SIGPIPE as a failure.
    ldconfig -p | grep -E 'lib(ayatana-)?appindicator3\.so\.1' >/dev/null || fail "no appindicator library installed"
    pass "gnosis_vpn-app libraries resolve, tray library present"
    local wants=/etc/systemd/system/multi-user.target.wants/gnosisvpn.service enabled_before=no
    [[ -e $wants ]] && enabled_before=yes
    mkdir -p /var/lib/gnosisvpn/.config
    echo "identity" >/var/lib/gnosisvpn/.config/identity-marker

    step "Upgrade to ${v2}"
    publish_local_repo "$v1_rpm" "$v2_rpm"
    run_installer
    [[ "$(installed_version)" == "$v2" ]] || fail "installed version is $(installed_version), expected ${v2}"
    pass "upgraded to ${v2}"
    # No seat0 user is logged in, so the migration defers and only locks the legacy identity down.
    [[ "$(stat -c '%a %U' /var/lib/gnosisvpn/.config)" == "700 root" ]] || fail "legacy identity dir is not locked down to 0700 root"
    pass "legacy identity dir locked down for a later migration"
    [[ -d /var/log/gnosisvpn ]] || fail "old %postun removed /var/log/gnosisvpn"
    [[ -f /usr/share/doc/gnosisvpn/changelog.gz ]] || fail "old %postun removed the new package's docs"
    pass "logs and docs survived the old package's scriptlets"
    local enabled_after=no
    [[ -e $wants ]] && enabled_after=yes
    [[ $enabled_after == "$enabled_before" ]] || fail "service enablement changed during upgrade (${enabled_before} -> ${enabled_after})"
    pass "service enablement unchanged (${enabled_after})"
    [[ -f /var/lib/gnosisvpn/.config/identity-marker ]] || fail "identity lost during upgrade"
    pass "identity kept"

    step "Reinstall with --network=jura-dev"
    run_installer --network=jura-dev
    [[ "$(readlink /etc/gnosisvpn/config.toml)" == "/etc/gnosisvpn/config-jura-dev.toml" ]] || fail "network override did not reach postinstall"
    grep -qx 'GNOSISVPN_HOPR_BLOKLI_URL=https://blokli.jura.dev.gnosisvpn.io' /etc/gnosisvpn/gnosisvpn-dynamic.env || fail "Blokli endpoint did not follow the network"
    pass "environment reached the rpm scriptlets; network switched to jura-dev"

    step "Erase"
    dnf -y -q remove gnosisvpn
    ! rpm -q gnosisvpn >/dev/null 2>&1 || fail "package still installed"
    [[ ! -e /etc/yum.repos.d/gnosisvpn.repo ]] || fail "repo file left behind after erase"
    pass "repo file removed"
    [[ -f /var/lib/gnosisvpn/.config/identity-marker && -d /etc/gnosisvpn ]] || fail "erase deleted configuration or identity"
    pass "configuration and identity preserved"
    dnf -y -q makecache >/dev/null || fail "dnf makecache fails after erase"
    pass "dnf still works after erase"

    printf '\n\033[0;32mAll checks passed on %s\033[0m\n' "$(. /etc/os-release && echo "$PRETTY_NAME")"
}

if [[ ${1:-} == "--inside" ]]; then
    run_inside
else
    run_host "$@"
fi
