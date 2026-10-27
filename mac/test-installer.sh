#!/usr/bin/env bash
#
# Test script for Gnosis VPN macOS installer
#
# This script validates the installer build artifacts and structure.
# It assumes "just all dmg aarch64-darwin" (or equivalent) has been executed.
#
# Set GNOSISVPN_NETWORKS to the set the build shipped (defaults to the standard line), e.g. GNOSISVPN_NETWORKS=piz-palu-dev.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Base directory for build artifacts
# Assuming the script is run from 'mac/' or project root, correct path to verify
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"

# Networks the build under test is expected to ship (first = default).
# shellcheck source=../config/channels.sh
source "${PROJECT_ROOT}/config/channels.sh"
: "${GNOSISVPN_NETWORKS:=${NETWORKS_STANDARD}}"
NETWORKS=()
read -r -a NETWORKS <<<"${GNOSISVPN_NETWORKS}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

# Test helper
run_test() {
    local test_name="$1"
    local test_command="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$test_name"

    if eval "$test_command"; then
        log_success "$test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

start_suite() {
    echo "=========================================="
    echo "  Gnosis VPN Installer Test Suite"
    echo "=========================================="
    echo "Checking build directory: $BUILD_DIR"
    echo ""

    if [[ ! -d $BUILD_DIR ]]; then
        log_error "Build directory not found at $BUILD_DIR"
        echo "Please run the build command (e.g., 'just all dmg aarch64-darwin true') before running this test."
        exit 1
    fi
}

# 1. Analyze Build Output Directory
test_build_structure() {
    log_info "Testing build directory structure..."

    local rootfs="${BUILD_DIR}/app-contents/rootfs"

    # Directory existence
    run_test "Rootfs directory exists" "[[ -d '$rootfs' ]]"
    run_test "Bin directory exists" "[[ -d '$rootfs/usr/local/bin' ]]"
    run_test "Templates directory exists" "[[ -d '$rootfs/etc/gnosisvpn/templates' ]]"
    run_test "Scripts directory exists" "[[ -d '${BUILD_DIR}/scripts' ]]"
    run_test "Packages directory exists" "[[ -d '${BUILD_DIR}/packages' ]]"

    # Binaries presence
    local binaries=("gnosis_vpn-root" "gnosis_vpn-worker" "gnosis_vpn-ctl" "gnosis_vpn-update" "gnosis_vpn-migrate")
    for bin in "${binaries[@]}"; do
        run_test "Binary '$bin' exists" "[[ -f '$rootfs/usr/local/bin/$bin' ]]"
        run_test "Binary '$bin' is executable" "[[ -x '$rootfs/usr/local/bin/$bin' ]]"
    done

    # Configuration templates and choice packages: exactly the shipped networks.
    local network
    for network in "${NETWORKS[@]}"; do
        run_test "Template '${network}.toml.template' exists" \
            "[[ -f '$rootfs/etc/gnosisvpn/templates/${network}.toml.template' ]]"
        run_test "Choice package for network '${network}' exists" \
            "[[ -f '${BUILD_DIR}/packages/choice-network-${network}.pkg' ]]"
    done

    # No template from the other installer line leaked into the payload.
    local tmpl tmpl_network unexpected=""
    for tmpl in "$rootfs"/etc/gnosisvpn/templates/*.template; do
        [[ -f $tmpl ]] || continue
        tmpl_network="$(basename "$tmpl" .toml.template)"
        if [[ " ${NETWORKS[*]} " != *" ${tmpl_network} "* ]]; then
            unexpected="${unexpected} ${tmpl_network}"
        fi
    done
    run_test "No templates outside '${GNOSISVPN_NETWORKS}' in payload" "[[ -z '${unexpected}' ]]"

    # Baked network list matches what the build was asked to ship.
    run_test "Baked networks file exists" "[[ -f '${BUILD_DIR}/scripts/networks' ]]"
    run_test "Baked networks file says '${GNOSISVPN_NETWORKS}'" \
        "[[ \"\$(cat '${BUILD_DIR}/scripts/networks' 2>/dev/null)\" == '${GNOSISVPN_NETWORKS}' ]]"

    # The payload must match the baked decision; a stale experimental stage would otherwise ship in a standard pkg.
    local share_dir="$rootfs/usr/local/share/gnosisvpn"
    SHIPS_GEOIP="$(cat "${BUILD_DIR}/scripts/geoip" 2>/dev/null || true)"
    run_test "Baked geoip file says true or false" "[[ '${SHIPS_GEOIP}' =~ ^(true|false)$ ]]"
    if [[ ${SHIPS_GEOIP} == true ]]; then
        run_test "GeoIP database and notice in payload" "[[ -f '${share_dir}/geoip.mmdb' && -f '${share_dir}/geoip.NOTICE' ]]"
    else
        run_test "No GeoIP files in payload" "[[ ! -e '${share_dir}/geoip.mmdb' && ! -e '${share_dir}/geoip.NOTICE' ]]"
    fi

    # Scripts
    local scripts=("postinstall" "preinstall" "uninstall.sh" "logging.sh")
    for script in "${scripts[@]}"; do
        run_test "Script '$script' exists" "[[ -f '${BUILD_DIR}/scripts/$script' ]]"
    done

    # Packages
    # Note: Package name might have version, so check for .pkg extension
    run_test "Component package exists" "[[ -n \$(find '${BUILD_DIR}/packages' -name 'GnosisVPN.pkg' -print -quit) ]]"
    run_test "Distribution package exists" "[[ -n \$(find '${BUILD_DIR}/packages' -name 'gnosisvpn_*_*.pkg' -print -quit) ]]"

    # SHA256 Checksum Validation
    local checksum_file
    checksum_file=$(find "${BUILD_DIR}/packages" -name "gnosisvpn_*_*.pkg.sha256" -print -quit)
    if [[ -n $checksum_file ]]; then
        run_test "Checksum file exists" "[[ -f '$checksum_file' ]]"
        # Check if the file contains two fields (hash and filename)
        run_test "Checksum format includes filename" "grep -qE '^[a-f0-9]{64}  .+' '$checksum_file'"
    else
        log_test "Skipping checksum format check (no .sha256 file found)"
    fi
}

# 3. Signing Validation (Optional)
# Signing is optional (e.g. local builds without certificates), so this section
# only asserts signatures when the package is actually signed. The distribution
# package is named gnosisvpn_<version>_<arch>.pkg whether or not it is signed,
# so signedness is detected via pkgutil rather than inferred from the filename.
test_signing() {
    local pkg
    pkg=$(find "${BUILD_DIR}/packages" -name "gnosisvpn_*_*.pkg" -print -quit)

    if [[ -z $pkg ]]; then
        log_info "No distribution package found. Skipping signing tests."
        return 0
    fi

    if ! command -v pkgutil >/dev/null; then
        log_test "Skipping signing tests (pkgutil not found)"
        return 0
    fi

    if ! pkgutil --check-signature "$pkg" 2>/dev/null | grep -q 'Status: signed'; then
        log_info "Package is unsigned: $(basename "$pkg"). Skipping signing tests."
        return 0
    fi

    log_info "Signed package found: $(basename "$pkg")"

    # Check package signature
    run_test "Package signature verification" "pkgutil --check-signature '$pkg' >/dev/null"
}

# 2. File Content & Syntax Validation (Cleaned up)
test_file_syntax() {
    log_info "Validating file syntax..."

    # Plist Validation (removed greps)
    local plist_src="$SCRIPT_DIR/resources/config/system/com.gnosisvpn.gnosisvpnclient.plist"
    run_test "Launchd Plist exists" "[[ -f '$plist_src' ]]"

    if command -v plutil >/dev/null; then
        run_test "Launchd Plist syntax valid" "plutil -lint '$plist_src' >/dev/null"
    else
        log_test "Skipping plutil check (not found)"
    fi

    local newsyslog_plist_src="$SCRIPT_DIR/resources/config/system/com.gnosisvpn.newsyslog.plist"
    run_test "Log rotation timer plist exists" "[[ -f '$newsyslog_plist_src' ]]"
    if command -v plutil >/dev/null; then
        run_test "Log rotation timer plist syntax valid" "plutil -lint '$newsyslog_plist_src' >/dev/null"
    fi

    # Distribution XML Validation (removed greps)
    local dist_xml="$SCRIPT_DIR/Distribution.xml"
    run_test "Distribution XML exists" "[[ -f '$dist_xml' ]]"

    if command -v xmllint >/dev/null; then
        run_test "Distribution XML syntax valid" "xmllint --noout '$dist_xml'"
    else
        log_test "Skipping xmllint check (not found)"
    fi

    # The rendered copy productbuild consumed: placeholders expanded, choices limited to the shipped set.
    local dist_xml_built="${BUILD_DIR}/Distribution.xml"
    if [[ -f $dist_xml_built ]]; then
        if command -v xmllint >/dev/null; then
            run_test "Rendered Distribution XML syntax valid" "xmllint --noout '$dist_xml_built'"
        fi
        run_test "Rendered Distribution XML has no unexpanded placeholders" \
            "! grep -q '__[A-Z][A-Z_]*__' '$dist_xml_built'"
        local network
        for network in "${NETWORKS[@]}"; do
            run_test "Rendered Distribution XML offers network '${network}'" \
                "grep -q 'choice-network-${network}.pkg' '$dist_xml_built'"
        done
        # One pre-selected network plus one pre-selected log level.
        run_test "Rendered Distribution XML pre-selects exactly two choices" \
            "[[ \"\$(grep -c 'start_selected=\"true\"' '$dist_xml_built')\" == '2' ]]"
    else
        log_test "Skipping rendered Distribution.xml checks (build/Distribution.xml not found)"
    fi

    # HTML syntax of the installer pages: the sources, plus the rendered copies productbuild actually ships.
    local html_paths=()
    local html
    for html in welcome.html readme.html conclusion.html; do
        [[ -f "$SCRIPT_DIR/resources/distribution/$html" ]] && html_paths+=("$SCRIPT_DIR/resources/distribution/$html")
        [[ -f "${BUILD_DIR}/distribution/$html" ]] && html_paths+=("${BUILD_DIR}/distribution/$html")
    done
    local file_path
    for file_path in "${html_paths[@]}"; do
        if command -v tidy >/dev/null; then
            # tidy -e : show errors only, -q : quiet
            run_test "HTML syntax '$file_path' (tidy)" "tidy -e -q '$file_path' 2>/dev/null"
        elif command -v xmllint >/dev/null; then
            run_test "HTML syntax '$file_path' (xmllint)" "xmllint --html --noout '$file_path' 2>/dev/null"
        else
            log_test "Skipping HTML syntax check for '$file_path' (no tool found)"
        fi
    done

    # The rendered readme must agree with the payload about the GeoIP database.
    local rendered_readme="${BUILD_DIR}/distribution/readme.html"
    if [[ -f $rendered_readme ]]; then
        run_test "Rendered readme has no unrendered placeholder" "! grep -q '__GNOSIS_VPN_' '$rendered_readme'"
        if [[ ${SHIPS_GEOIP:-} == true ]]; then
            run_test "Rendered readme lists the GeoIP database" "grep -q 'geoip.mmdb' '$rendered_readme'"
        else
            run_test "Rendered readme does not mention GeoIP" "! grep -qi 'geoip' '$rendered_readme'"
        fi
    fi

    echo ""
}

# Report
print_summary() {
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        exit 0
    else
        echo -e "${RED}SOME TESTS FAILED${NC}"
        exit 1
    fi
}

# Main
main() {
    start_suite
    test_build_structure
    test_signing
    test_file_syntax
    print_summary
}

main
