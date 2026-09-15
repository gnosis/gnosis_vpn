# Configuration Files Directory

This directory contains all configuration files and templates used by the Gnosis VPN installer.

## Directory Structure

```
config/
├── README.md              # This file - documentation
├── system/               # System configuration files
│   └── com.gnosisvpn.gnosisvpnclient.plist  # LaunchD service configuration
└── templates/           # Configuration templates
    ├── jura-prod.toml.template          # Jura Prod network (standard line)
    ├── jura-dev.toml.template           # Jura Dev network (standard line)
    ├── piz-palu-dev.toml.template       # Piz Palu Dev network (experimental line)
```

Each build ships only the templates of its installer line, selected by `GNOSISVPN_NETWORKS` (see `NETWORKS_STANDARD` /
`NETWORKS_EXPERIMENTAL` in `scripts/config.sh`): the stable and snapshot channels ship the jura networks, the
experimental channel ships `piz-palu-dev`.

## System Configuration Files

### `system/com.gnosisvpn.gnosisvpnclient.plist`

LaunchD service configuration for automatic startup and management of the Gnosis VPN service.

**Features:**

- Automatic startup on system boot (`RunAtLoad=true`)
- Automatic restart on crashes (`KeepAlive`)
- Resource limits and security configuration
- Logging to `/Library/Log/GnosisVPN/`
- Runs as root with wheel group permissions

## Configuration Templates

### `templates/*.toml.template`

TOML configuration templates for different network environments.

**Available Networks:**

- **jura-prod**: Default production network (stable, snapshot)
- **jura-dev**: Development network (stable, snapshot)
- **piz-palu-dev**: Piz Palu development network (experimental)

**Template Structure** (Jura networks):

```toml
version = 6

[destinations.Country]
address = "0xExitNodeAddress"
meta = { location = "City", flag = "XX" }
```

The `[destinations.*]` tables are present in the Jura templates only. `piz-palu-dev` declares `version = 7`, ships no
destination list and relies on the client finding exit nodes at runtime.

The table key is a free-form destination id (the country name, by convention). `path` is optional and may only be
`path = { hops = N }` with `N` in 0-3; when omitted it defaults to 1 hop, which is what the Jura configs rely on.

The `meta` table accepts any string key-value pairs. Two keys are used by the UI:

| Key        | Required | Description                                                                                             |
| ---------- | -------- | ------------------------------------------------------------------------------------------------------- |
| `location` | yes      | Human-readable city name shown in the exit node list                                                    |
| `flag`     | no       | ISO 3166-1 alpha-2 country code (e.g. `"SE"`, `"BR"`, `"GB"`) used to render the country flag in the UI |

## Usage

These configuration files are automatically processed during installation:

1. **Templates** are copied to `/etc/gnosisvpn/templates/` during package installation
2. **System configs** are processed by postinstall scripts to set up services
3. The installer selects appropriate templates based on the `INSTALLER_CHOICE_NETWORK` environment variable

The networks a build ships are baked next to the installer's `version.txt` (read by the postinstall as
`${SCRIPT_DIR}/networks`, first entry = default). The postinstall validates `INSTALLER_CHOICE_NETWORK` against that list
— a choice left over from an install of the other line falls back to the default — and deletes templates from
`/etc/gnosisvpn/templates/` that this build does not ship, since the package payload only ever adds files.

## Customization

To customize the installer configuration:

1. **Add new network templates**: create a new `.toml.template` file in `templates/`, then add the network to
   `NETWORKS_STANDARD` or `NETWORKS_EXPERIMENTAL` in `scripts/config.sh` and give it a title and description in
   `network_title` / `network_description` in `scripts/generate-package-mac.sh`. Linux additionally needs a matching
   `linux/resources/config-<network>.toml`.
2. **Modify service behavior**: Edit `system/com.gnosisvpn.gnosisvpnclient.plist`
3. **Update build process**: Modify references in `../build-pkg.sh` and `../scripts/postinstall`

## File Ownership

- **Templates**: Copied to target system during installation
- **System configs**: Used by installer scripts, not copied to target system
- **Documentation**: Local reference only
