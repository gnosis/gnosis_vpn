#!/usr/bin/env bash
#
# Per-scenario definitions. Each scenario id "<a>-<b>" maps to a function
# scenario_<a>_<b>_install (required) and, optionally,
# scenario_<a>_<b>_postupgrade (extra absolute re-checks after the shared
# upgrade phase; the shared phase already verifies preservation generically).
#
# Sourced by run-scenario.sh, which provides $GVPN_DEB (path to the .deb),
# $DEB_VERSION (its control Version), and $INSTALL_SH (patched install.sh), plus
# the log()/assert_*/die helpers.

CONF=/etc/gnosisvpn
JURA="$CONF/config-jura.toml"
ROTSEE="$CONF/config-rotsee.toml"

# --- helpers ---------------------------------------------------------------

# Install the local .deb, forwarding any VAR=VALUE arguments to the maintainer
# scripts (mirrors the documented `sudo env VAR=... apt install ./deb`).
# seed_identity() lives in common.sh (shared with run-transition.sh).
apt_install_deb() {
    env "$@" DEBIAN_FRONTEND=noninteractive apt-get install -y "$GVPN_DEB"
}

# ===========================================================================
# Group A/B — direct .deb install
# ===========================================================================

scenario_deb_default_install() {
    apt_install_deb
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_dynamic_env_blokli "https://blokli.jura.hoprnet.link"
    assert_version_txt "$DEB_VERSION"
    assert_service_enabled
    assert_service_active
    # The build carries a '+' version, so postinstall self-registers the
    # snapshot channel at the production mirror (documented behavior).
    assert_sources snapshot download.gnosisvpn.io
    # …and must NOT list the IPFS mirror, which has no snapshot suite.
    assert_sources_excludes eth.limo
}

scenario_deb_network_rotsee_install() {
    apt_install_deb GNOSISVPN_NETWORK=rotsee
    assert_symlink_target "$CONF/config.toml" "$ROTSEE"
    assert_dynamic_env_blokli "https://blokli.rotsee.hoprnet.link"
    assert_version_txt "$DEB_VERSION"
    assert_service_enabled
    assert_service_active
}
scenario_deb_network_rotsee_postupgrade() {
    assert_symlink_target "$CONF/config.toml" "$ROTSEE"
    assert_dynamic_env_blokli "https://blokli.rotsee.hoprnet.link"
}

scenario_deb_blokli_custom_install() {
    apt_install_deb GNOSISVPN_HOPR_BLOKLI_URL=https://blokli.example.com
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_dynamic_env_blokli "https://blokli.example.com"
    assert_service_enabled
    assert_service_active
}
scenario_deb_blokli_custom_postupgrade() {
    assert_dynamic_env_blokli "https://blokli.example.com"
}

scenario_deb_reset_identity_install() {
    seed_identity
    apt_install_deb GNOSISVPN_RESET_IDENTITY=true
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_identity_replaced "$SEED_ID_SHA" "$SEED_PASS_SHA"
    assert_service_enabled
    assert_service_active
}

# ===========================================================================
# Group C — install.sh (patched to the local repo)
# ===========================================================================

scenario_sh_default_install() {
    bash "$INSTALL_SH"
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_dynamic_env_blokli "https://blokli.jura.hoprnet.link"
    # Default channel = stable → installs the stable-versioned deb from the
    # stable suite; version.txt has no '+' → a true stable install (in production
    # this means the stable channel with both mirrors, incl. the IPFS one).
    assert_version_txt "$STABLE_VERSION"
    assert_service_enabled
    assert_service_active
    # install.sh wrote the stable source (both patched local mirrors); postinstall
    # sees a stable version + agreeing suites and leaves it as-is.
    assert_sources stable 127.0.0.1:8000/backup
}

scenario_sh_channel_stable_install() {
    bash "$INSTALL_SH" --channel=stable
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_version_txt "$STABLE_VERSION"
    assert_service_enabled
    assert_service_active
    # install.sh wrote the stable source (both patched local mirrors); postinstall
    # sees a stable version + agreeing suites and leaves it as-is.
    assert_sources stable 127.0.0.1:8000/backup
}

scenario_sh_channel_snapshot_install() {
    bash "$INSTALL_SH" --channel=snapshot
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_dynamic_env_blokli "https://blokli.jura.hoprnet.link"
    assert_version_txt "$SNAPSHOT_VERSION"
    assert_service_enabled
    assert_service_active
    # Suites already agree with the package channel → postinstall leaves the
    # installer-written local source untouched (backup root, snapshot suite).
    assert_sources snapshot 127.0.0.1:8000/backup
    # …and must NOT list the stable-only primary root (no snapshot suite there).
    assert_sources_excludes localhost:8000/primary
}

scenario_sh_network_jura_install() {
    bash "$INSTALL_SH" --network=jura
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_dynamic_env_blokli "https://blokli.jura.hoprnet.link"
    assert_service_enabled
    assert_service_active
}

scenario_sh_network_rotsee_install() {
    bash "$INSTALL_SH" --network=rotsee
    assert_symlink_target "$CONF/config.toml" "$ROTSEE"
    assert_dynamic_env_blokli "https://blokli.rotsee.hoprnet.link"
    assert_service_enabled
    assert_service_active
}
scenario_sh_network_rotsee_postupgrade() {
    assert_symlink_target "$CONF/config.toml" "$ROTSEE"
}

scenario_sh_reset_identity_install() {
    seed_identity
    bash "$INSTALL_SH" --reset-identity
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_identity_replaced "$SEED_ID_SHA" "$SEED_PASS_SHA"
    assert_service_enabled
    assert_service_active
}

scenario_sh_blokli_env_install() {
    GNOSISVPN_HOPR_BLOKLI_URL=https://blokli.example.com bash "$INSTALL_SH"
    assert_symlink_target "$CONF/config.toml" "$JURA"
    assert_dynamic_env_blokli "https://blokli.example.com"
    assert_service_enabled
    assert_service_active
}
scenario_sh_blokli_env_postupgrade() {
    assert_dynamic_env_blokli "https://blokli.example.com"
}
