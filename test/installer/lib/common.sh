#!/usr/bin/env bash
#
# Shared helpers for the installer integration tests.
# Sourced by run-scenario.sh and the other lib/*.sh scripts — no side effects
# on source beyond defining functions and the RESULT_* globals below.

# --- logging ---------------------------------------------------------------
log() { printf '\033[0;34m[itest]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[itest]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[itest]\033[0m %s\n' "$*" >&2; }

die() {
    err "$*"
    exit 1
}

# --- fixtures --------------------------------------------------------------
# Seed a known HOPR identity so a --reset-identity / GNOSISVPN_RESET_IDENTITY
# can be verified afterwards. Sets SEED_ID_SHA / SEED_PASS_SHA, consumed by
# assert_identity_replaced (asserts.sh).
# shellcheck disable=SC2034  # read by callers after seed_identity runs
SEED_ID_SHA=""
# shellcheck disable=SC2034
SEED_PASS_SHA=""
seed_identity() {
    install -d -m 0755 /var/lib/gnosisvpn /var/lib/gnosisvpn/.config
    printf 'SEEDED-IDENTITY-DO-NOT-USE\n' >/var/lib/gnosisvpn/.config/gnosisvpn-hopr.id
    printf 'SEEDED-PASSWORD-DO-NOT-USE\n' >/var/lib/gnosisvpn/.config/gnosisvpn-hopr.pass
    SEED_ID_SHA="$(sha256sum /var/lib/gnosisvpn/.config/gnosisvpn-hopr.id | awk '{print $1}')"
    SEED_PASS_SHA="$(sha256sum /var/lib/gnosisvpn/.config/gnosisvpn-hopr.pass | awk '{print $1}')"
    log "Seeded identity (id sha ${SEED_ID_SHA:0:12}…, pass sha ${SEED_PASS_SHA:0:12}…)"
}

# retry <attempts> <sleep-seconds> <command...>
retry() {
    local attempts=$1 delay=$2
    shift 2
    local i=1
    until "$@"; do
        if ((i >= attempts)); then
            return 1
        fi
        warn "attempt ${i}/${attempts} failed: $*; retrying in ${delay}s"
        sleep "$delay"
        i=$((i + 1))
    done
}

# --- result record ---------------------------------------------------------
# Populated as the scenario progresses; flushed to $GVPN_RESULT_FILE by the
# EXIT trap so a record is written even when an assertion aborts mid-phase.
RESULT_SCENARIO="${SCENARIO:-unknown}"
RESULT_TYPE="unknown"
RESULT_INSTALL="skip"
RESULT_UPGRADE="skip"
RESULT_NETWORK=""
RESULT_BLOKLI=""
RESULT_SERVICE=""
RESULT_VERSION=""
RESULT_NOTE=""

_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# Best-effort snapshot of the observable installer state.
_gather_facts() {
    RESULT_VERSION="$(dpkg-query -W -f='${Version}' gnosisvpn 2>/dev/null || true)"
    if [[ -e /etc/gnosisvpn/config.toml ]]; then
        RESULT_NETWORK="$(basename "$(readlink -f /etc/gnosisvpn/config.toml 2>/dev/null || true)" 2>/dev/null || true)"
    else
        RESULT_NETWORK=""
    fi
    if [[ -f /etc/gnosisvpn/gnosisvpn-dynamic.env ]]; then
        RESULT_BLOKLI="$(sed -n 's/^GNOSISVPN_HOPR_BLOKLI_URL=//p' /etc/gnosisvpn/gnosisvpn-dynamic.env 2>/dev/null | head -n1 || true)"
    fi
    local active enabled
    active="$(systemctl is-active gnosisvpn.service 2>/dev/null || true)"
    enabled="$(systemctl is-enabled gnosisvpn.service 2>/dev/null || true)"
    RESULT_SERVICE="${active:-unknown}/${enabled:-unknown}"
}

write_result() {
    local file="${GVPN_RESULT_FILE:-}"
    [[ -z $file ]] && return 0
    _gather_facts
    local overall="fail"
    if [[ $RESULT_INSTALL == pass && $RESULT_UPGRADE == pass ]]; then
        overall="pass"
    fi
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg scenario "$RESULT_SCENARIO" \
            --arg type "$RESULT_TYPE" \
            --arg install "$RESULT_INSTALL" \
            --arg upgrade "$RESULT_UPGRADE" \
            --arg overall "$overall" \
            --arg network "$RESULT_NETWORK" \
            --arg blokli "$RESULT_BLOKLI" \
            --arg service "$RESULT_SERVICE" \
            --arg version "$RESULT_VERSION" \
            --arg note "$RESULT_NOTE" \
            '{scenario:$scenario,type:$type,install:$install,upgrade:$upgrade,overall:$overall,network:$network,blokli:$blokli,service:$service,version:$version,note:$note}' \
            >"$file"
    else
        {
            printf '{'
            printf '"scenario":"%s",' "$(_json_escape "$RESULT_SCENARIO")"
            printf '"type":"%s",' "$(_json_escape "$RESULT_TYPE")"
            printf '"install":"%s",' "$(_json_escape "$RESULT_INSTALL")"
            printf '"upgrade":"%s",' "$(_json_escape "$RESULT_UPGRADE")"
            printf '"overall":"%s",' "$(_json_escape "$overall")"
            printf '"network":"%s",' "$(_json_escape "$RESULT_NETWORK")"
            printf '"blokli":"%s",' "$(_json_escape "$RESULT_BLOKLI")"
            printf '"service":"%s",' "$(_json_escape "$RESULT_SERVICE")"
            printf '"version":"%s",' "$(_json_escape "$RESULT_VERSION")"
            printf '"note":"%s"' "$(_json_escape "$RESULT_NOTE")"
            printf '}\n'
        } >"$file"
    fi
    # World-readable so the (non-root) runner user can upload it as an artifact.
    chmod 0644 "$file" 2>/dev/null || true
}

_on_exit() {
    local ec=$?
    write_result || true
    exit "$ec"
}

install_result_trap() {
    trap _on_exit EXIT
}

# --- per-scenario detailed outcome report ----------------------------------
# Rendered to stdout and, when set, appended to $GITHUB_STEP_SUMMARY.
print_outcome_report() {
    local phase="$1"
    local sources dynenv idfiles backups
    sources="$(cat /etc/apt/sources.list.d/gnosisvpn.sources 2>/dev/null || echo '(absent)')"
    dynenv="$(cat /etc/gnosisvpn/gnosisvpn-dynamic.env 2>/dev/null || echo '(absent)')"
    idfiles="$(ls -la /var/lib/gnosisvpn/.config 2>/dev/null || echo '(absent)')"
    backups="$(find /etc/gnosisvpn -maxdepth 1 -name 'config.toml.backup.*' 2>/dev/null | wc -l | tr -d ' ')"
    _gather_facts

    {
        printf '### %s — %s\n\n' "$RESULT_SCENARIO" "$phase"
        printf '| item | value |\n|---|---|\n'
        printf '| dpkg version | `%s` |\n' "${RESULT_VERSION:-?}"
        printf '| version.txt | `%s` |\n' "$(cat /etc/gnosisvpn/version.txt 2>/dev/null || echo '?')"
        printf '| config.toml → | `%s` |\n' "$(readlink -f /etc/gnosisvpn/config.toml 2>/dev/null || echo '?')"
        printf '| service (active/enabled) | `%s` |\n' "${RESULT_SERVICE:-?}"
        printf '| config backups | %s |\n' "$backups"
        printf '\n<details><summary>gnosisvpn.sources</summary>\n\n```\n%s\n```\n</details>\n' "$sources"
        printf '\n<details><summary>gnosisvpn-dynamic.env</summary>\n\n```\n%s\n```\n</details>\n' "$dynenv"
        printf '\n<details><summary>/var/lib/gnosisvpn/.config</summary>\n\n```\n%s\n```\n</details>\n\n' "$idfiles"
    } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
