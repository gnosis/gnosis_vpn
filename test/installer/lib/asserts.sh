#!/usr/bin/env bash
#
# Assertion primitives for the installer integration tests. Every failing
# assertion calls die() (exit 1), which fires the EXIT trap in common.sh so a
# result record is still written. Sourced by run-scenario.sh; relies on
# log()/warn()/die() and the RESULT_* globals from common.sh.

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ $actual != "$expected" ]]; then
        die "ASSERT FAIL [$label]: expected '$expected', got '$actual'"
    fi
    log "ok [$label]: '$actual'"
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ $haystack != *"$needle"* ]]; then
        die "ASSERT FAIL [$label]: '$needle' not found in: $haystack"
    fi
    log "ok [$label]: contains '$needle'"
}

assert_file_exists() {
    [[ -e $1 ]] || die "ASSERT FAIL: expected file to exist: $1"
    log "ok: exists $1"
}

assert_file_absent() {
    [[ ! -e $1 ]] || die "ASSERT FAIL: expected file to be absent: $1"
    log "ok: absent $1"
}

# assert_symlink_target <link> <expected-target>
assert_symlink_target() {
    local link="$1" want="$2" got want_abs
    got="$(readlink -f "$link" 2>/dev/null || true)"
    # Resolve the expected path too, so a comparison works whether the caller
    # passes an already-resolved path or the config-*.toml target.
    want_abs="$(readlink -f "$want" 2>/dev/null || echo "$want")"
    assert_eq "symlink $link" "$got" "$want_abs"
}

# assert_dynamic_env_blokli <expected-url> — value plus root:root 0644 ownership
# (the file is loaded by the root systemd service, so it must not be worker-writable).
assert_dynamic_env_blokli() {
    local want="$1" f=/etc/gnosisvpn/gnosisvpn-dynamic.env got owner mode
    assert_file_exists "$f"
    got="$(sed -n 's/^GNOSISVPN_HOPR_BLOKLI_URL=//p' "$f" | head -n1)"
    assert_eq "blokli url" "$got" "$want"
    owner="$(stat -c '%U:%G' "$f")"
    assert_eq "dynamic.env owner" "$owner" "root:root"
    mode="$(stat -c '%a' "$f")"
    assert_eq "dynamic.env mode" "$mode" "644"
}

assert_version_txt() {
    assert_eq "version.txt" "$(cat /etc/gnosisvpn/version.txt 2>/dev/null || true)" "$1"
}

assert_dpkg_version() {
    assert_eq "dpkg version" "$(dpkg-query -W -f='${Version}' gnosisvpn 2>/dev/null || true)" "$1"
}

# Deterministic: postinstall enables the unit on every run.
assert_service_enabled() {
    local st
    st="$(systemctl is-enabled gnosisvpn.service 2>/dev/null || true)"
    assert_eq "service is-enabled" "$st" "enabled"
}

# Retries because the worker needs a moment to come up. Whether the VPN worker
# stays up in a headless CI VM is environment-dependent, so honor
# GVPN_TEST_TOLERATE_INACTIVE=1 to record (not fail on) an inactive service.
assert_service_active() {
    local st=""
    for _ in $(seq 1 10); do
        st="$(systemctl is-active gnosisvpn.service 2>/dev/null || true)"
        if [[ $st == active ]]; then
            log "ok: service is-active"
            return 0
        fi
        sleep 2
    done
    warn "service not active after retries (state: ${st:-unknown})"
    journalctl -u gnosisvpn.service -n 80 --no-pager 2>/dev/null || true
    if [[ ${GVPN_TEST_TOLERATE_INACTIVE:-0} == 1 ]]; then
        # shellcheck disable=SC2034  # consumed by write_result() in common.sh
        RESULT_NOTE="service not active (${st:-unknown}); tolerated"
        warn "GVPN_TEST_TOLERATE_INACTIVE=1 → recording, not failing"
        return 0
    fi
    die "ASSERT FAIL: service not active (state: ${st:-unknown})"
}

# assert_sources <suite-substring> <uri-substring> — parses the deb822 source.
assert_sources() {
    local want_suite="$1" want_uri="$2" f=/etc/apt/sources.list.d/gnosisvpn.sources suites uris
    assert_file_exists "$f"
    suites="$(awk 'tolower($1)=="suites:"{sub(/^[^:]*:[[:space:]]*/,"");print;exit}' "$f")"
    uris="$(awk 'tolower($1)=="uris:"{sub(/^[^:]*:[[:space:]]*/,"");print;exit}' "$f")"
    assert_contains "sources suites" "$suites" "$want_suite"
    assert_contains "sources uris" "$uris" "$want_uri"
}

# assert_sources_excludes <substring> — fails if the substring appears anywhere
# in gnosisvpn.sources. Guards against a snapshot source listing a mirror that
# has no snapshot suite (which would 404 every apt-get update).
assert_sources_excludes() {
    local needle="$1" f=/etc/apt/sources.list.d/gnosisvpn.sources content
    assert_file_exists "$f"
    content="$(cat "$f")"
    if [[ $content == *"$needle"* ]]; then
        die "ASSERT FAIL: gnosisvpn.sources must not contain '$needle' (would break apt-get update):"$'\n'"$content"
    fi
    log "ok: sources excludes '$needle'"
}

# assert_identity_replaced <seed-id-sha256> <seed-pass-sha256>
# A reset either removes the identity file or the restarted service regenerates
# it with different bytes; both count as "no longer the seeded identity".
assert_identity_replaced() {
    local seed_id="$1" seed_pass="$2" cur
    local idf=/var/lib/gnosisvpn/.config/gnosisvpn-hopr.id
    local pf=/var/lib/gnosisvpn/.config/gnosisvpn-hopr.pass
    if [[ -e $idf ]]; then
        cur="$(sha256sum "$idf" | awk '{print $1}')"
        [[ $cur != "$seed_id" ]] || die "ASSERT FAIL: identity .id still equals the seed (not reset)"
        log "ok: identity .id regenerated (differs from seed)"
    else
        log "ok: identity .id removed"
    fi
    if [[ -e $pf ]]; then
        cur="$(sha256sum "$pf" | awk '{print $1}')"
        [[ $cur != "$seed_pass" ]] || die "ASSERT FAIL: identity .pass still equals the seed (not reset)"
        log "ok: identity .pass regenerated (differs from seed)"
    else
        log "ok: identity .pass removed"
    fi
}
