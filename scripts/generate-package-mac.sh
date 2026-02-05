#!/bin/bash
#
# Build script for Gnosis VPN macOS PKG installer
#
# This script creates a distributable .pkg installer with custom UI for macOS.
# It uses pkgbuild and productbuild to create a standard macOS installer package.
#

set -euo pipefail

# Safe default values
: "${GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH:=}"
: "${GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH:=}"
: "${GNOSISVPN_APPLE_ID:=}"
: "${GNOSISVPN_APPLE_PASSWORD:=}"
: "${GNOSISVPN_APPLE_TEAM_ID:=}"

RESOURCES_DIR="${SCRIPT_DIR}/../mac/resources"
DISTRIBUTION_XML="${SCRIPT_DIR}/../mac/Distribution.xml"
PKG_NAME_INSTALLER="GnosisVPN-Installer-v${GNOSISVPN_PACKAGE_VERSION}-signed.pkg"
COMPONENT_PKG="GnosisVPN.pkg"
CHOICE_PACKAGES_DIR="${SCRIPT_DIR}/../mac/choice-packages"
CHOICE_PACKAGE_PREFIX="choice"
CHOICE_PACKAGE_NAMES=(
    network-rotsee
    network-jura
    network-dufour
    loglevel-info
    loglevel-debug
)
CHOICE_PACKAGE_IDENTIFIERS=(
    com.gnosisvpn.choice.network.rotsee
    com.gnosisvpn.choice.network.jura
    com.gnosisvpn.choice.network.dufour
    com.gnosisvpn.choice.loglevel.info
    com.gnosisvpn.choice.loglevel.debug
)

# Keychain
KEYCHAIN_NAME="gnosisvpn.keychain"
KEYCHAIN_PASSWORD=$(openssl rand -base64 24)

usage_platform(){
    echo "  --binary-certificate-path <path>  Set the path to the certificate for signing binaries (if signing is enabled)"
    echo "  --installer-certificate-path <path>  Set the path to the certificate for signing the installer (if signing is enabled)"
    echo "  --apple-id <apple_id>     Set the Apple ID for notarization (if signing is enabled)"
    echo "  --apple-team-id <team_id> Set the Apple Team ID for notarization (if signing is enabled)"
    echo
    echo "Note: Assumes binaries, changelog, and manual pages already exist in build directory."
    echo "      Run 'just download', 'just changelog', and 'just manual' first if needed."
    exit 1
}

# Parse command-line arguments
parse_platform_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --binary-certificate-path)
            GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH="${2:-}"
            if [[ -z $GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH ]]; then
                log_error "'--binary-certificate-path <path>' requires a value"
                usage
            else
                if [[ ! -f $GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH ]]; then
                    log_error "Certificate file not found: $GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH"
                    exit 1
                fi
            fi
            shift 2
            ;;
        --installer-certificate-path)
            GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH="${2:-}"
            if [[ -z $GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH ]]; then
                log_error "'--installer-certificate-path <path>' requires a value "
                usage
            else
                if [[ ! -f $GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH ]]; then
                    log_error "Certificate file not found: $GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH"
                    exit 1
                fi
            fi
            shift 2
            ;;
        --apple-id)
            GNOSISVPN_APPLE_ID="${2:-}"
            if [[ -z $GNOSISVPN_APPLE_ID ]]; then
                log_error "'--apple-id <apple_id>' requires a value"
                usage
            fi
            shift 2
            ;;
        --apple-team-id)
            GNOSISVPN_APPLE_TEAM_ID="${2:-}"
            if [[ -z $GNOSISVPN_APPLE_TEAM_ID ]]; then
                log_error "'--apple-team-id <team_id>' requires a value"
                usage
            fi
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
        esac
    done

    # Validate required arguments
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        if [[ -z $GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH ]]; then
            log_error "'--binary-certificate-path <path>' is required or environment variable GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH must be set"
            usage
        fi

        if [[ -z ${GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PASSWORD:-} ]]; then
            log_error "Apple Developer certificate password not set in GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PASSWORD environment variable"
            exit 1
        else
            if ! command -v openssl pkcs12 -info -in "$GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH" -passin pass:"$GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PASSWORD" -nokeys -nomacver -nodes 2>/dev/null >/dev/null; then
                log_error "Password for $GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH certificate is incorrect or certificate file is invalid"
                exit 1
            fi
        fi

        if [[ -z $GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH ]]; then
            log_error "'--installer-certificate-path <path>' is required or environment variable GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH must be set"
            usage
        fi

        if [[ -z ${GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PASSWORD:-} ]]; then
            log_error "Apple Installer certificate password not set in GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PASSWORD environment variable"
            exit 1
        else
            if ! command -v openssl pkcs12 -info -in "$GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH" -passin pass:"$GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PASSWORD" -nokeys -nomacver -nodes 2>/dev/null >/dev/null; then
                log_error "Password for $GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH certificate is incorrect or certificate file is invalid"
                exit 1
            fi
        fi

        if [[ -z $GNOSISVPN_APPLE_ID ]]; then
            log_error "'--apple-id <apple_id>' is required or environment variable GNOSISVPN_APPLE_ID must be set"
            usage
        fi

        if [[ -z $GNOSISVPN_APPLE_TEAM_ID ]]; then
            log_error "'--apple-team-id <team_id>' is required or environment variable GNOSISVPN_APPLE_TEAM_ID must be set"
            usage
        fi

        if [[ -z ${GNOSISVPN_APPLE_PASSWORD:-} ]]; then
            log_error "Apple ID app-specific password not set in GNOSISVPN_APPLE_PASSWORD environment variable"
            exit 1
        fi
    fi

    log_success "Command-line arguments parsed successfully"
}


# Print banner
print_platform_banner() {
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        echo "Developer certificate path: $GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH"
        echo "Installer certificate path: $GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH"
        echo "Apple ID:                   $GNOSISVPN_APPLE_ID"
        echo "Apple Team ID:              $GNOSISVPN_APPLE_TEAM_ID"
    fi
}

# Verify prerequisites
check_platform_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=0

    # Check for required tools
    for cmd in pkgbuild productbuild; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required tool not found: $cmd"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_error "Prerequisites check failed. Please install missing tools and verify file structure."
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Clean and prepare build directory
prepare_build_dir() {
    log_info "Preparing build directory..."

    # Create fresh build directory structure
    mkdir -p "${BUILD_DIR}/app-contents/rootfs/usr/local/bin"
    mkdir -p "${BUILD_DIR}/app-contents/rootfs/etc/gnosisvpn/templates"
    # UI app archive will be added during binary embedding
    mkdir -p "${BUILD_DIR}/scripts"

    # Copy config templates to package payload
    if [[ -d "$RESOURCES_DIR/config/templates" ]]; then
        cp "$RESOURCES_DIR/config/templates"/*.template "${BUILD_DIR}/app-contents/rootfs/etc/gnosisvpn/templates/" || true
        log_success "Config templates copied"
    fi

    # Copy system configuration files to scripts directory (for postinstall access)
    if [[ -d "$RESOURCES_DIR/config/system" ]]; then
        mkdir -p "${BUILD_DIR}/scripts/config/system"
        cp "$RESOURCES_DIR/config/system"/* "${BUILD_DIR}/scripts/config/system/" || true
        log_success "System config files copied"
    fi

    # Copy binaries
    for binary in gnosis_vpn-root gnosis_vpn-worker gnosis_vpn-ctl; do
        if [[ -f "${BUILD_DIR}/download/${binary}" ]]; then
            cp "${BUILD_DIR}/download/${binary}" "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/${binary}"
            log_success "Copied binary: ${binary}"
        else
            log_error "Missing binary files for '${binary}'"
            exit 1
        fi
    done

    # Copy artifacts needed by the application
    if [[ -d "$RESOURCES_DIR/artifacts/" ]]; then
        mkdir -p "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/"

        log_info "Creating universal binary for the 'wg'..."
        lipo -create -output "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wg" \
            "$RESOURCES_DIR/artifacts/wg-x86_64-darwin" "$RESOURCES_DIR/artifacts/wg-aarch64-darwin"
        chmod 755 "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wg"

        log_info "Creating universal binary for the 'wireguard-go'..."
        lipo -create -output "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wireguard-go" \
            "$RESOURCES_DIR/artifacts/wireguard-go-x86_64-darwin" "$RESOURCES_DIR/artifacts/wireguard-go-aarch64-darwin"
        chmod 755 "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wireguard-go"

        # Signing of the binaries by the `Developer ID Application` certificate
        if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
            security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_NAME}"
            security default-keychain -s "${KEYCHAIN_NAME}"
            security set-keychain-settings -lut 21600 "${KEYCHAIN_NAME}"
            security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_NAME}"
            security list-keychains -d user -s "${KEYCHAIN_NAME}" login.keychain
            security import "${GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PATH}" -k "${KEYCHAIN_NAME}" -P "${GNOSISVPN_APPLE_CERTIFICATE_DEVELOPER_PASSWORD}" -T /usr/bin/codesign
            security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_NAME}" 2>/dev/null >/dev/null
            CERT_ID=$(security find-identity -v -p codesigning "${KEYCHAIN_NAME}" | awk -F'"' '{print $2}' | tr -d '\n')

            # sign the wg binary
            codesign --sign "${CERT_ID}" --options runtime --timestamp "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wg"
            codesign --verify --deep --strict --verbose=4 "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wg"
            log_success "'wg' binary signed successfully"

            # sign the wireguard-go binary
            codesign --sign "${CERT_ID}" --options runtime --timestamp "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wireguard-go"
            codesign --verify --deep --strict --verbose=4 "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/wireguard-go"
            log_success "'wireguard-go' binary signed successfully"
        fi

        cp "$RESOURCES_DIR/artifacts/wg-quick" "${BUILD_DIR}/app-contents/rootfs/usr/local/bin/" || true
        log_success "Artifacts copied"
    fi

    log_success "Build directory prepared"
}

# Package UI application asset into a tar.gz archive for staging
unpack() {
    local dmg_filepath="${BUILD_DIR}/download/gnosis_vpn-app-universal-darwin.dmg"
    local output_archive="${BUILD_DIR}/app-contents/rootfs/usr/local/share/gnosisvpn/gnosis_vpn-app.tar.gz"

    if [[ ! -f $dmg_filepath ]]; then
        log_warn "UI asset not found at $dmg_filepath"
        return 1
    fi

    local file_info
    file_info=$(file "$dmg_filepath")
    local work_dir
    work_dir=$(mktemp -d -t gnosis-ui-app.XXXXXX)
    chmod 700 "$work_dir"

    local staging_app_dir="$work_dir/Gnosis VPN.app"
    local success=false

    log_info "Packaging UI asset (type: $file_info)"

    if echo "$file_info" | grep -qi "zlib compressed data"; then
        log_info "Detected DMG file, mounting for extraction"
        local mount_point
        mount_point=$(mktemp -d -t gnosis-dmg-mount.XXXXXX)

        if hdiutil attach "$dmg_filepath" -mountpoint "$mount_point" -quiet; then
            log_info "DMG mounted at $mount_point"
            local app_bundle
            app_bundle=$(find "$mount_point" -maxdepth 1 -type d -name "*.app" | head -1)

            if [[ -n $app_bundle ]]; then
                log_info "Found app bundle in DMG: $(basename "$app_bundle")"
                if ditto "$app_bundle" "$staging_app_dir"; then
                    success=true
                else
                    log_warn "Failed to copy app bundle from DMG"
                fi
            else
                log_warn "No app bundle found inside DMG"
            fi

            hdiutil detach "$mount_point" -quiet || log_warn "Failed to detach DMG mount"
        else
            log_warn "Failed to mount DMG asset"
        fi
        rmdir "$mount_point" 2>/dev/null || true
    else
        log_warn "Unsupported UI asset type: $file_info"
    fi

    local result=1
    if [[ $success == true ]] && [[ -d $staging_app_dir ]]; then
        mkdir -p "$(dirname "$output_archive")"
        rm -f "$output_archive"
        if tar -czf "$output_archive" -C "$work_dir" "$(basename "$staging_app_dir")"; then
            log_success "Packaged UI app archive: $output_archive"
            result=0
        else
            log_warn "Failed to create UI app archive at $output_archive"
        fi
    else
        log_warn "UI app staging failed, archive will not be created"
    fi

    if [[ -f "${BUILD_DIR}/app-contents/rootfs/Applications/GnosisVPN" ]]; then
        lipo -info "${BUILD_DIR}/app-contents/rootfs/Applications/GnosisVPN" || true
    fi

    rm -rf "$work_dir" 2>/dev/null || true
    return $result
}


# Copy installation scripts
copy_scripts() {
    log_info "Copying installation scripts..."

    # Copy logging library (required by all scripts)
    if [[ -f "$RESOURCES_DIR/scripts/logging.sh" ]]; then
        cp "$RESOURCES_DIR/scripts/logging.sh" "${BUILD_DIR}/scripts/"
        log_success "Copied logging library"
    fi

    # Preinstall is now a minimal no-op (optional WireGuard check only)
    if [[ -f "$RESOURCES_DIR/scripts/preinstall" ]]; then
        cp "$RESOURCES_DIR/scripts/preinstall" "${BUILD_DIR}/scripts/"
        chmod +x "${BUILD_DIR}/scripts/preinstall"
        log_success "Copied preinstall script"
    fi

    if [[ -f "$RESOURCES_DIR/scripts/postinstall" ]]; then
        cp "$RESOURCES_DIR/scripts/postinstall" "${BUILD_DIR}/scripts/"
        chmod +x "${BUILD_DIR}/scripts/postinstall"
        log_success "Copied postinstall script"
    fi

    if [[ -f "$RESOURCES_DIR/scripts/uninstall.sh" ]]; then
        cp "$RESOURCES_DIR/scripts/uninstall.sh" "${BUILD_DIR}/scripts/"
        chmod +x "${BUILD_DIR}/scripts/uninstall.sh"
        log_success "Copied uninstall.sh script"
    fi
}

# Build component package
build_component_package() {
    log_info "Building component package..."
    mkdir -p "${BUILD_DIR}/packages"
    pkgbuild \
        --root "${BUILD_DIR}/app-contents/rootfs" \
        --scripts "${BUILD_DIR}/scripts" \
        --identifier "com.gnosisvpn.gnosisvpnclient" \
        --version "$GNOSISVPN_PACKAGE_VERSION" \
        --install-location "/" \
        --ownership recommended \
        "${BUILD_DIR}/packages/$COMPONENT_PKG"

    if [[ -f "${BUILD_DIR}/packages/$COMPONENT_PKG" ]]; then
        local size
        size=$(du -h "${BUILD_DIR}/packages/$COMPONENT_PKG" | cut -f1)
        log_success "Component package created: $COMPONENT_PKG ($size)"
    else
        log_error "Failed to create component package"
        exit 1
    fi
}

build_choice_packages() {
    log_info "Building choice marker packages..."

    local total=${#CHOICE_PACKAGE_NAMES[@]}
    if [[ $total -eq 0 ]]; then
        log_info "No choice packages configured; skipping"
        return 0
    fi

    mkdir -p "${BUILD_DIR}/packages"

    local i
    for ((i = 0; i < total; i++)); do
        local package_name="${CHOICE_PACKAGE_NAMES[$i]}"
        local identifier="${CHOICE_PACKAGE_IDENTIFIERS[$i]}"
        local scripts_dir="${CHOICE_PACKAGES_DIR}/${package_name}/Scripts"
        local output_pkg="${BUILD_DIR}/packages/${CHOICE_PACKAGE_PREFIX}-${package_name}.pkg"

        if [[ ! -d "$scripts_dir" ]]; then
            log_error "Choice package scripts directory not found: $scripts_dir"
            exit 1
        fi

        pkgbuild \
            --nopayload \
            --scripts "$scripts_dir" \
            --identifier "$identifier" \
            --version "$GNOSISVPN_PACKAGE_VERSION" \
            "$output_pkg"

        if [[ -f "$output_pkg" ]]; then
            log_success "Choice package created: $(basename "$output_pkg")"
        else
            log_error "Failed to create choice package: $package_name"
            exit 1
        fi
    done
}

# Build distribution package
build_distribution_package() {
    log_info "Building distribution package with custom UI..."

    # Prepare distribution resources in build directory to avoid modifying source files
    local distribution_dir="${BUILD_DIR}/distribution"
    mkdir -p "$distribution_dir"

    if [[ -d "${RESOURCES_DIR}/distribution" ]]; then
        cp -R "${RESOURCES_DIR}/distribution" "$BUILD_DIR"
    else
        log_error "Distribution resources directory not found."
        exit 1
    fi

    # Generate welcome.html from template
    if [[ -f "${distribution_dir}/welcome.html" ]]; then
        sed -i "s/__GNOSISVPN_APP_VERSION__/v${GNOSISVPN_APP_VERSION}/g" "$distribution_dir/welcome.html"
        sed -i "s/__GNOSISVPN_CLI_VERSION__/v${GNOSISVPN_CLI_VERSION}/g" "$distribution_dir/welcome.html"
    else
        log_warn "welcome.html not found, using default if available"
    fi

    productbuild \
        --distribution "$DISTRIBUTION_XML" \
        --resources "$distribution_dir" \
        --package-path "${BUILD_DIR}/packages" \
        --version "$GNOSISVPN_PACKAGE_VERSION" \
        "${BUILD_DIR}/packages/${PKG_NAME}"

    if [[ -f "${BUILD_DIR}/packages/$PKG_NAME" ]]; then
        local size
        size=$(du -h "${BUILD_DIR}/packages/$PKG_NAME" | cut -f1)
        log_success "Distribution package created: $PKG_NAME ($size)"
    else
        log_error "Failed to create distribution package"
        exit 1
    fi

}

# Sign package
sign_platform_package() {
    if [[ $GNOSISVPN_ENABLE_SIGNATURE == true ]]; then
        log_info "Signing package for distribution..."
        security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_NAME}"
        security import "${GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PATH}" -k "${KEYCHAIN_NAME}" -P "${GNOSISVPN_APPLE_CERTIFICATE_INSTALLER_PASSWORD}" -T /usr/bin/productsign -T /usr/bin/xcrun
        security set-key-partition-list -S apple-tool:,apple:,productsign:,xcrun: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_NAME}" 2>/dev/null >/dev/null
        local signing_identity
        signing_identity=$(security find-identity -v -p basic "${KEYCHAIN_NAME}" | grep "Developer ID Installer" | awk -F'"' '{print $2}')

        if [[ -n $signing_identity ]]; then
            log_info "Found signing certificate: $signing_identity"

            # Sign the package
            if productsign --sign "$signing_identity" --keychain "${KEYCHAIN_NAME}" "${BUILD_DIR}/packages/$PKG_NAME" "${BUILD_DIR}/packages/${PKG_NAME_INSTALLER}"; then
                log_success "Package signed successfully: ${PKG_NAME_INSTALLER}"
                log_info "Verifying package signature..."
                if pkgutil --check-signature "${BUILD_DIR}/packages/${PKG_NAME_INSTALLER}"; then
                    log_success "Signature verification passed"
                    echo ""
                else
                    log_error "Signature verification failed"
                    exit 1
                fi
            else
                log_error "Failed to sign package"
                log_info "Make sure the signing identity is correct"
                exit 1
            fi
            notarize_package
            staple_ticket
        else
            log_info "Package signing is disabled; skipping signing step"
        fi
    fi
}

# Submit for notarization
notarize_package() {
    log_info "Submitting package for notarization to Apple (this may take a while)..."
    notary_json="$(
    xcrun notarytool submit "${BUILD_DIR}/packages/${PKG_NAME_INSTALLER}" \
        --apple-id "$GNOSISVPN_APPLE_ID" \
        --team-id "$GNOSISVPN_APPLE_TEAM_ID" \
        --password "$GNOSISVPN_APPLE_PASSWORD" \
        --wait \
        --output-format json 2>${BUILD_DIR}/notarytool-submit.log
    )"
    submit_rc=$?
    if [[ $submit_rc -ne 0 ]]; then
        log_error "Notarytool command failed (exit code $submit_rc)"
        log_error "$notary_json"
        cat "${BUILD_DIR}/notarytool-submit.log" >&2
        exit 1
    else
        log_success "Notarization submission completed"
    fi
    status="$(printf '%s' "$notary_json" | jq -r '.status // empty')"
    id="$(printf '%s' "$notary_json" | jq -r '.id // empty')"

    if [[ "$status" != "Accepted" ]]; then
        log_error "Notarization finished but status is '$status' (id: $id)"
        #Optional: fetch the detailed log from Apple for debugging:
        xcrun notarytool log "$id" \
            --apple-id "$GNOSISVPN_APPLE_ID" \
            --team-id "$GNOSISVPN_APPLE_TEAM_ID" \
            --password "$GNOSISVPN_APPLE_PASSWORD" || true
        exit 1
    fi
    log_success "Notarization accepted (id: $id)"
    echo ""

}

# Staple notarization ticket
staple_ticket() {
    log_info "Stapling notarization ticket to package..."

    if xcrun stapler staple -v "${BUILD_DIR}/packages/${PKG_NAME_INSTALLER}"; then
        log_success "Notarization ticket stapled successfully"
        echo ""
    else
        local exit_code=$?
        log_warn "Failed to staple ticket (exit code: $exit_code)"
        log_warn "Package is still valid, but requires internet for verification"
        log_info "To check stapler status manually, run:"
        log_info "  xcrun stapler validate '${BUILD_DIR}/packages/${PKG_NAME_INSTALLER}'"
        echo ""
    fi
}

# Print build summary
print_platform_summary() {
    package_path="${BUILD_DIR}/packages/${PKG_NAME_INSTALLER}"
    local sha256
    # Generate checksum with filename relative to the dir, for standard verification
    (cd "$(dirname "$package_path")" && shasum -a 256 "$(basename "$package_path")") > "$package_path".sha256
    # Extract just the hash for the summary display
    sha256=$(cut -d' ' -f1 "$package_path".sha256)
    pkg_size=$(du -h "$package_path" | cut -f1)
    echo "Package:           ${package_path}"
    echo "Package size:      ${pkg_size}"
    echo "SHA256:            ${sha256}"
}


# Build Mac package
build_platform_package() {
    prepare_build_dir
    unpack
    copy_scripts
    build_component_package
    build_choice_packages
    build_distribution_package
}
