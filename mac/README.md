# Gnosis VPN macOS PKG Installer

This directory contains the macOS PKG installer implementation for Gnosis VPN Client. The installer provides a
user-friendly graphical interface for installing and configuring the Gnosis VPN client on macOS systems.

## Features

- **Custom UI**: Professional welcome, readme, and completion screens with branding
- **System Requirements Check**: Validates macOS version (floor from `config/min-os.json`) and Apple Silicon
  architecture
- **Incremental Updates**: Detects previous installations and only updates changed binaries
- **Configuration Preservation**: Maintains user settings during updates when possible
- **Version Tracking**: Tracks installation versions for better update management
- **Automatic Backups**: Creates backups of binaries and configurations before updates
- **WireGuard Integration**: Automatically detects and installs WireGuard tools if needed
- **Network Selection**: Jura Prod, Jura Staging or Jura Dev on stable/snapshot builds; Piz Palu Dev, Piz Palu Staging
  or Piz Palu Prod on experimental builds (each installer only offers the networks of its own line)
- **Configuration Generation**: Creates `config.toml` for the selected network; the Jura networks ship a configured
  destination list, the Piz Palu networks ship none and rely on the client finding exit nodes at runtime
- **macOS Integration**: Removes quarantine attributes and sets proper permissions
- **Management Tools**: Includes utility for managing installations and backups

### Management Tools

The installer includes a management utility accessible via:

```bash
gnosis_vpn-manager [command]
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

- `INSTALLER_CHOICE_NETWORK`: Network selection; one of the networks the installer ships (listed in the pkg's baked
  `networks` file), defaulting to the first of them — "jura-prod" on stable/snapshot builds, "piz-palu-dev" on
  experimental builds. A value the installer does not ship falls back to that default.
- `INSTALLER_CHOICE_LOGLEVEL`: Log level service mode ( "debug" or "info", default: "info")

### Installation Locations

After installation, files are located at:

- Binaries: `/usr/local/bin/`
  - `gnosis_vpn-root` - Root VPN daemon
  - `gnosis_vpn-worker` - VPN worker binary
  - `gnosis_vpn-ctl` - Control utility
  - `gnosis_vpn-update` - Self-updater utility
  - `gnosis_vpn-migrate` - Legacy identity migration (run by the installer, and by hand after a failed migration)
- Application: `/Applications/Gnosis VPN.app`
- Configuration: `/etc/gnosisvpn/config.toml`
- Per-user identity: `~/Library/Application Support/GnosisVPN/networks/<network>/` (each user's own data)
- Updater state, legacy identity backups: `/Library/Application Support/GnosisVPN/`
- Logs Pre-install: `/Library/Logs/GnosisVPN/installer/preinstall.log`
- Logs Post-install: `/Library/Logs/GnosisVPN/installer/postinstall.log`
- Logs Identity migration: `/Library/Logs/GnosisVPN/installer/migrate.log`

### Identity Migration on Upgrade

Releases before the per-user layout ran the worker as a `gnosisvpn` system user with one shared identity in
`/Library/Application Support/GnosisVPN/.config/`. On upgrade, `postinstall` runs
`gnosis_vpn-migrate identity --user <console user>` after the old service was stopped and before the new one is loaded,
moving that identity into the console user's layout and renaming the legacy directory to `.config.migrated-<timestamp>`.
The `gnosisvpn` user is removed once the migration succeeds; the group stays. Without a console session the migration is
skipped with a warning, the service starts, and the legacy identity stays intact for a manual
`sudo gnosis_vpn-migrate identity --user <name> --replace` (`--replace` because a connection made in the meantime may
already have created a per-user identity).

If the migration fails, Installer.app still reports success, but the launchd service is installed **disabled** and not
bootstrapped, so neither the install nor the next boot can create a fresh identity that shadows the legacy one.
`postinstall.log` ends with three ways forward, then the start command:

```bash
sudo gnosis_vpn-migrate identity --user <name>      # retry after fixing the cause
sudo gnosis_vpn-migrate upload-log                  # send the migrate + installer logs to support
sudo gnosis_vpn-migrate start-clean --user <name>   # give up on the legacy identity, start fresh
sudo launchctl enable system/com.gnosisvpn.gnosisvpnclient && sudo launchctl bootstrap system /Library/LaunchDaemons/com.gnosisvpn.gnosisvpnclient.plist
```

When the failure is a conflict (the user already has an identity for that network, exit code 75), the block offers
`identity --user <name> --replace` (keep the legacy identity) and a bare `start-clean` (keep the current one) instead.

`gnosis_vpn-migrate identity` is idempotent, so re-running the pkg after a failure is safe.

## Uninstallation

To completely remove Gnosis VPN from your system:

### Option 1: Using the Uninstall Script (Recommended)

```bash
cd mac
sudo ./uninstall.sh
```

Per-user identities under `~/Library/Application Support/GnosisVPN/` and the updater state in
`/Library/Application Support/GnosisVPN/` are left in place.

## Security

- Scripts run with root privileges during installation
- Binaries are downloaded over HTTPS from GitHub at build time
- SHA-256 checksums are verified for all downloaded binaries (build fails if verification fails)
- App binary is packaged directly into the PKG
- No personal information is collected or transmitted

### Accounts and Permission Group

No service account exists. `gnosis_vpn-root` runs as `root` under launchd and spawns `gnosis_vpn-worker` as whichever
user asks for a connection; that worker keeps its identity under the user's own home.

- **Permission Group**: `gnosisvpn` (GID: 200-499 range)
  - The sudoers principal: `/etc/sudoers.d/gnosis-vpn` lets members run the `launchctl` service commands and the
    self-updater without a password
  - The installer adds the console user; other users join with `sudo dseditgroup -o edit -a <name> -t user gnosisvpn`

- **Permission Structure**:
  - Configuration files: `root:wheel`, world-readable (`644`)
  - Binaries: `root:wheel`; `gnosis_vpn-root` is `750`, everything else `755`
  - `/Library/Logs/GnosisVPN`, `/Library/Application Support/GnosisVPN`: `root:wheel 755`
  - Per-user identity: `~/Library/Application Support/GnosisVPN/networks/<network>/`, owned by that user
