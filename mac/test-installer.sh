#!/bin/bash
#
# Test script for Gnosis VPN macOS installer
#
# This script validates the installer build artifacts and structure.
# It assumes "just all dmg aarch64-darwin" (or equivalent) has been executed.
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

    if [[ ! -d "$BUILD_DIR" ]]; then
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
    local binaries=("gnosis_vpn-root" "gnosis_vpn-worker" "gnosis_vpn-ctl" "wg" "wg-quick" "wireguard-go")
    for bin in "${binaries[@]}"; do
        run_test "Binary '$bin' exists" "[[ -f '$rootfs/usr/local/bin/$bin' ]]"
        run_test "Binary '$bin' is executable" "[[ -x '$rootfs/usr/local/bin/$bin' ]]"
    done

    # Configuration templates
    local templates=("dufour.toml.template" "rotsee.toml.template")
    for tmpl in "${templates[@]}"; do
        run_test "Template '$tmpl' exists" "[[ -f '$rootfs/etc/gnosisvpn/templates/$tmpl' ]]"
    done

    # Scripts
    local scripts=("postinstall" "preinstall" "uninstall.sh" "logging.sh")
    for script in "${scripts[@]}"; do
        run_test "Script '$script' exists" "[[ -f '${BUILD_DIR}/scripts/$script' ]]"
    done

    # Packages
    # Note: Package name might have version, so check for .pkg extension
    run_test "Component package exists" "[[ -n \$(find '${BUILD_DIR}/packages' -name 'GnosisVPN.pkg' -print -quit) ]]"
    run_test "Distribution package exists" "[[ -n \$(find '${BUILD_DIR}/packages' -name 'GnosisVPN-Installer-*.pkg' -print -quit) ]]"
}

# 3. Signing Validation (Optional)
test_signing() {
    local signed_pkg
    signed_pkg=$(find "${BUILD_DIR}/packages" -name "GnosisVPN-Installer-*-signed.pkg" -print -quit)

    if [[ -n "$signed_pkg" ]]; then
        log_info "Signed package found: $(basename "$signed_pkg")"
        
        # Check package signature
        if command -v pkgutil >/dev/null; then
             run_test "Package signature verification" "pkgutil --check-signature '$signed_pkg' >/dev/null"
        else
            log_test "Skipping package signature check (pkgutil not found)"
        fi
        
        # Check binary signatures (if we can on this platform)
        if command -v codesign >/dev/null; then
             local rootfs="${BUILD_DIR}/app-contents/rootfs"
             local bins_to_check=("wg" "wireguard-go")
             
             for bin in "${bins_to_check[@]}"; do
                 local bin_path="$rootfs/usr/local/bin/$bin"
                 if [[ -f "$bin_path" ]]; then
                     run_test "Binary signature '$bin'" "codesign --verify --deep --strict '$bin_path' >/dev/null"
                 fi
             done
        else
             log_test "Skipping binary signature check (codesign not found)"
        fi
    else
        log_info "No signed package found. Skipping signing tests."
    fi
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

    # Distribution XML Validation (removed greps)
    local dist_xml="$SCRIPT_DIR/Distribution.xml"
    run_test "Distribution XML exists" "[[ -f '$dist_xml' ]]"
    
    if command -v xmllint >/dev/null; then
        run_test "Distribution XML syntax valid" "xmllint --noout '$dist_xml'"
    else
        log_test "Skipping xmllint check (not found)"
    fi

    # HTML Validation
    # Providing a tool to check syntax as requested
    local html_files=("welcome.html" "readme.html" "conclusion.html")
    local resource_dir="$SCRIPT_DIR/resources/distribution" # welcome.html might be here in source or just generated in build
    
    # Check source files if they exist (welcome.html might be a template in source)
    for html in "${html_files[@]}"; do
        local file_path="$resource_dir/$html"
        # Check if it's a template instead if the html file doesn't exist
        if [[ ! -f "$file_path" && -f "$SCRIPT_DIR/resources/${html}.template" ]]; then
             file_path="$SCRIPT_DIR/resources/${html}.template"
        fi
        
        # Also check just mac/resources/ if not in distribution/
        if [[ ! -f "$file_path" && -f "$SCRIPT_DIR/resources/$html" ]]; then
             file_path="$SCRIPT_DIR/resources/$html"
        fi

        if [[ -f "$file_path" ]]; then
            if command -v tidy >/dev/null; then
                 # tidy -e : show errors only, -q : quiet
                run_test "HTML syntax '$html' (tidy)" "tidy -e -q '$file_path' 2>/dev/null" 
            elif command -v xmllint >/dev/null; then
                run_test "HTML syntax '$html' (xmllint)" "xmllint --html --noout '$file_path' 2>/dev/null"
            else
                log_test "Skipping HTML syntax check for '$html' (no tool found)"
            fi
        fi
    done

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
