#!/usr/bin/env bash
#
# Aggregate the per-scenario result JSONs into (1) a linear table for the
# single-install scenarios and (2) a 4×4 grid for the transition matrix.
#
#   report.sh <results-dir>
#
# Emits to stdout and, when set, to $GITHUB_STEP_SUMMARY. Exits non-zero if any
# scenario/cell failed or is missing — one overall pass/fail signal. Needs jq.

set -Eeuo pipefail

DIR="${1:?usage: report.sh <results-dir>}"

# Keep in sync with the matrices in .github/workflows/installer-tests.yaml.
SINGLE=(
    deb-default
    deb-network-rotsee
    deb-blokli-custom
    deb-reset-identity
    sh-default
    sh-channel-stable
    sh-channel-snapshot
    sh-network-jura
    sh-network-rotsee
    sh-reset-identity
    sh-blokli-env
)
STATES=(sj sr nj nr) # s=stable n=snapshot, j=jura r=rotsee

state_label() {
    case "$1" in
    sj) echo "stable/jura" ;;
    sr) echo "stable/rotsee" ;;
    nj) echo "snapshot/jura" ;;
    nr) echo "snapshot/rotsee" ;;
    esac
}

command -v jq >/dev/null 2>&1 || {
    echo "report.sh requires jq" >&2
    exit 2
}

icon() {
    case "$1" in
    pass) printf '✅' ;;
    fail) printf '❌' ;;
    skip) printf '➖' ;;
    *) printf '❔' ;;
    esac
}

field() { # field <id> <jq-path>
    local f="$DIR/$1.json"
    [[ -f $f ]] || {
        echo ""
        return
    }
    jq -r "$2 // \"\"" "$f" 2>/dev/null || echo ""
}

# Overall status of a result id: pass | fail | missing.
status_of() {
    local f="$DIR/$1.json"
    [[ -f $f ]] || {
        echo missing
        return
    }
    local ov
    ov="$(jq -r '.overall // "fail"' "$f" 2>/dev/null || echo fail)"
    [[ $ov == pass ]] && echo pass || echo fail
}

# --- counting pass (main shell, so the exit code below sees the totals) ------
pass=0
fail=0
missing=0
version=""
tally() {
    case "$1" in
    pass) pass=$((pass + 1)) ;;
    fail) fail=$((fail + 1)) ;;
    missing) missing=$((missing + 1)) ;;
    esac
}
for s in "${SINGLE[@]}"; do
    tally "$(status_of "$s")"
    v="$(field "$s" .version)"
    [[ -n $v && -z $version ]] && version="$v"
done
for from in "${STATES[@]}"; do
    for to in "${STATES[@]}"; do
        tally "$(status_of "switch-${from}-to-${to}")"
        v="$(field "switch-${from}-to-${to}" .version)"
        [[ -n $v && -z $version ]] && version="$v"
    done
done

# --- render (into $GITHUB_STEP_SUMMARY and stdout) ---------------------------
{
    printf '## Installer test results'
    [[ -n $version ]] && printf ' — `%s`' "$version"
    printf '\n\n### Single-install scenarios\n\n'
    printf '| Test case | Type | Install | Upgrade | Network | Blokli | Service (active/enabled) | Result |\n'
    printf '|---|---|:-:|:-:|---|---|---|:-:|\n'
    for s in "${SINGLE[@]}"; do
        st="$(status_of "$s")"
        if [[ $st == missing ]]; then
            printf '| `%s` |  |  |  |  |  |  | ⚠️ no result |\n' "$s"
            continue
        fi
        res="✅ PASS"
        [[ $st == fail ]] && res="❌ FAIL"
        printf '| `%s` | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$s" "$(field "$s" .type)" \
            "$(icon "$(field "$s" .install)")" "$(icon "$(field "$s" .upgrade)")" \
            "$(field "$s" .network)" "$(field "$s" .blokli)" "$(field "$s" .service)" "$res"
    done

    printf '\n### Transition matrix — install A → install B (switch channel+network, reset identity)\n\n'
    printf '| from ↓ / to → |'
    for to in "${STATES[@]}"; do printf ' %s |' "$(state_label "$to")"; done
    printf '\n|---|'
    for _ in "${STATES[@]}"; do printf ':-:|'; done
    printf '\n'
    for from in "${STATES[@]}"; do
        printf '| **%s** |' "$(state_label "$from")"
        for to in "${STATES[@]}"; do
            st="$(status_of "switch-${from}-to-${to}")"
            case "$st" in
            pass) printf ' ✅ |' ;;
            fail) printf ' ❌ |' ;;
            *) printf ' ⚠️ |' ;;
            esac
        done
        printf '\n'
    done

    total=$((${#SINGLE[@]} + ${#STATES[@]} * ${#STATES[@]}))
    printf '\n**%d passed, %d failed' "$pass" "$fail"
    ((missing > 0)) && printf ', %d missing' "$missing"
    printf '** out of %d checks.\n' "$total"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if ((fail > 0 || missing > 0)); then
    exit 1
fi
