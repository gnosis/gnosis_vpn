# Gnosis VPN macOS PKG Installer

This directory contains the macOS PKG installer implementation for Gnosis VPN
Client. The installer provides a user-friendly graphical interface for
installing and configuring the Gnosis VPN client on macOS systems.

## Features

- **Custom UI**: Professional welcome, readme, and completion screens with branding
- **System Requirements Check**: Validates macOS version, architecture, and disk space
- **Incremental Updates**: Detects previous installations and only updates changed binaries
- **Configuration Preservation**: Maintains user settings during updates when possible
- **Version Tracking**: Tracks installation versions for better update management
- **Automatic Backups**: Creates backups of binaries and configurations before updates
- **WireGuard Integration**: Automatically detects and installs WireGuard tools if needed
- **Network Selection**: Choose between Production (Gnosis Chain) or Rotsee testnet
- **Configuration Generation**: Creates `config.toml` with selected network destinations
- **macOS Integration**: Removes quarantine attributes and sets proper permissions
- **Management Tools**: Includes utility for managing installations and backups

### Management Tools

The installer includes a management utility accessible via:

```bash
gnosis-vpn-manager [command]
```

**Available commands:**

- `status` - Show complete installation status
- `version` - Display current installation version
- `backups` - List available backup files
- `restore` - Restore configuration from backup (requires sudo)
- `cleanup` - Clean up old backup files (requires sudo)


## Configuration

### Environment Variables

The installer scripts support these environment variables:

- `INSTALLER_CHOICE_NETWORK`: Network selection ("rotsee" or "dufour", default:
  "rotsee")

### Installation Locations

After installation, files are located at:

- Binaries: `/usr/local/bin/`
  - `gnosis_vpn` - Main VPN daemon
  - `gnosis_vpn-ctl` - Control utility
- Application: `/Applications/Gnosis VPN.app`
- Configuration: `/etc/gnosisvpn/config.toml`
- Logs Pre-install: `/Library/Logs/GnosisVPNInstaller/preinstall.log`
- Logs Post-install: `/Library/Logs/GnosisVPNInstaller/postinstall.log`

## Uninstallation

To completely remove Gnosis VPN from your system:

### Option 1: Using the Uninstall Script (Recommended)

```bash
cd mac
sudo ./uninstall.sh
```

The uninstall script will:

- Back up your configuration to `~/gnosis-vpn-config-backup-*`
- Remove binaries from `/usr/local/bin/`
- Remove configuration from `/etc/gnosisvpn/`
- Remove installation logs from `/Library/Logs/GnosisVPNInstaller/`
- Forget the package receipt

### Option 2: Manual Uninstallation

If you prefer to uninstall manually:

1. **Remove the binaries:**
   ```bash
   sudo rm -f /usr/local/bin/gnosis_vpn*
   ```

2. **Remove the configuration (backup first if needed):**
   ```bash
   sudo cp -R /etc/gnosisvpn ~/gnosis-vpn-config-backup
   sudo rm -rf /etc/gnosisvpn
   ```

3. **Remove installation logs:**
   ```bash
   sudo rm -rf /Library/Logs/GnosisVPNInstaller
   ```

4. **Forget the package receipt:**
   ```bash
   sudo pkgutil --forget org.gnosis.vpn.client
   ```

## Security

- Scripts run with root privileges during installation
- Binaries are downloaded over HTTPS from GitHub at build time
- SHA-256 checksums are verified for all downloaded binaries (build fails if
  verification fails)
- Universal binaries are packaged directly into the PKG
- No personal information is collected or transmitted

### System User and Group Management

The installer creates dedicated system credentials for enhanced security:

- **System User**: `gnosisvpn` (UID: 200-499 range)
  - Hidden from login window and Users & Groups preferences
  - Home directory: `/var/lib/gnosisvpn`
  - Shell: `/bin/bash` (no interactive login)
  - Used to run some VPN binaries with minimal privileges. The `gnosis_vpn-root` binary will be running as `root`.

- **System Group**: `gnosisvpn` (GID: 200-499 range)
  - Contains the current user and system user
  - Provides group-based access to VPN configuration and logs
  - Enables non-root users to manage the service

- **Permission Structure**:
  - Configuration files: `root:gnosisvpn` with group read access
  - Binaries: `root:gnosisvpn` with group execute access
  - Log directories: `gnosisvpn:gnosisvpn` for service logging
  - Runtime directories: `/var/run/gnosisvpn`, `/var/lib/gnosisvpn`
