#!/usr/bin/env bash
#
# Shared upgrade phase, run after every scenario's install phase.
#
# We do not build a second .deb. Instead we make the already-installed package
# look older than the local repo's copy ("downgrade installed state"): rewrite
# the recorded Version in dpkg's status DB to 0.0.1 and blank version.txt, point
# apt at the local repo, then `apt-get install` — apt sees the real version as
# an upgrade and runs the genuine unpack → conffile-handling → postinstall path.
# We also edit the active config (a conffile) beforehand to prove a user's edits
# survive the upgrade.
#
# Relies on log()/die() + the assert_* helpers being sourced already.

run_upgrade_phase() {
    local real_ver net_link blokli_line
    real_ver="$(dpkg-query -W -f='${Version}' gnosisvpn)"
    [[ -n $real_ver ]] || die "gnosisvpn is not installed; cannot run upgrade phase"

    # State that must survive the upgrade.
    net_link="$(readlink -f /etc/gnosisvpn/config.toml)"
    blokli_line="$(grep '^GNOSISVPN_HOPR_BLOKLI_URL=' /etc/gnosisvpn/gnosisvpn-dynamic.env || true)"
    log "Pre-upgrade: version=${real_ver}, config→${net_link}, ${blokli_line:-<no blokli line>}"

    # Simulate a config that the user edited between versions. net_link is the
    # active config-<network>.toml, which is a dpkg conffile. The "new" .deb
    # ships this file byte-identical, so dpkg keeps our edit silently — the true
    # confold-under-a-changed-conffile path needs a second build (out of scope).
    log "Appending a user edit to ${net_link}"
    echo '# gvpn-test user edit' >>"$net_link"

    # Downgrade the recorded installed version. The sed range is bounded to the
    # gnosisvpn stanza (Package: line → next blank line), so only its Version:
    # field changes; the Conffiles: md5sums stay intact and dpkg still sees the
    # local edit above.
    log "Rewriting recorded dpkg version to 0.0.1"
    cp /var/lib/dpkg/status /var/lib/dpkg/status.gvpn-test-backup
    sed -i '/^Package: gnosisvpn$/,/^$/ s/^Version: .*/Version: 0.0.1/' /var/lib/dpkg/status
    [[ "$(dpkg-query -W -f='${Version}' gnosisvpn)" == "0.0.1" ]] ||
        die "failed to rewrite dpkg status version"
    echo "0.0.1" >/etc/gnosisvpn/version.txt

    # Point apt at the local repo's BACKUP root (serves both suites). Match the
    # suite to the installed channel so the candidate is the same version we
    # started from and postinstall (which re-detects the channel from the
    # restored version.txt) sees agreeing suites and leaves this file untouched.
    local suite component arch
    if [[ $real_ver == *"+"* ]]; then
        suite=snapshot
        component=snapshot
    else
        suite=stable
        component=main
    fi
    arch="$(dpkg --print-architecture)"
    log "Repointing apt at the local backup repo (${suite} suite, ${arch})"
    cat >/etc/apt/sources.list.d/gnosisvpn.sources <<EOF
Types: deb
URIs: http://127.0.0.1:8000/backup
Suites: ${suite}
Components: ${component}
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/gnosisvpn-test-keyring.gpg
EOF

    log "apt-get update + upgrade from the local repo"
    retry 3 5 apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gnosisvpn

    log "Post-upgrade assertions"
    assert_dpkg_version "$real_ver"
    # version.txt is a plain packaged file (not a conffile) → restored on upgrade.
    assert_version_txt "$real_ver"
    # Network choice preserved: postinstall does not relink without GNOSISVPN_NETWORK.
    assert_symlink_target /etc/gnosisvpn/config.toml "$net_link"
    if [[ -n $blokli_line ]]; then
        assert_contains "blokli preserved" \
            "$(cat /etc/gnosisvpn/gnosisvpn-dynamic.env)" "${blokli_line#*=}"
    fi
    assert_contains "user config edit kept" "$(cat "$net_link")" 'gvpn-test user edit'
    assert_service_enabled
    assert_service_active
    # postinstall leaves the sources file as-is (suites already agree).
    assert_sources "$suite" 127.0.0.1:8000/backup
    compgen -G '/etc/gnosisvpn/config.toml.backup.*' >/dev/null ||
        die "preinstall did not create a config.toml backup during the upgrade"
    log "Upgrade phase assertions passed"
}
