# OS Packages

Gnosis VPN has a ready to use package for the following variants:

- Supported processor architectures: `x86_64`
- Supported operating systems: `Linux`
- Supported package formats: `deb`

## Install via package manager

- Visit the [release page](https://github.com/gnosis/gnosis_vpn/releases)
- Choose the appropriate package format for your system: `deb`.
- Download the package files:
  - Main package (e.g., `gnosis_vpn-x86_64-linux.deb`)
  - SHA256 checksum (e.g., `gnosis_vpn-x86_64-linux.deb.sha256`)
  - GPG signature (e.g., `gnosis_vpn-x86_64-linux.deb.asc`)

**⚠️ Security Notice:** We strongly recommend verifying package integrity before installation. See [SECURITY.md](../SECURITY.md) for complete verification instructions.

### Debian, Ubuntu and derivatives

**Install:**

```bash
sudo apt-get update
sudo -E apt -y install ./gnosis_vpn-x86_64-linux.deb
```

**Uninstall:**

```bash
sudo apt remove -y gnosis_vpn
```


---

## Building Packages

### Build Requirements

- [nfpm](https://nfpm.goreleaser.com/) - Package builder
- [just](https://github.com/casey/just) - Command runner
- Google Cloud SDK for downloading binaries
- GPG (optional, for signing packages)

### Build Commands

**Build a package:**

```bash
# Build Debian package
just package deb x86_64-linux
```

**Build with signing:**

```bash
# Set GPG key path
export GNOSISVPN_GPG_PRIVATE_KEY_PATH=/path/to/private-key.asc
export GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD=<Bitwarden 'GnosisVPN GPG Binary Sign'>

# Build and sign
./build-package.sh --distribution deb --architecture x86_64-linux --sign --gpg-private-key-path "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"
```


---

## Testing Packages

### Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud` CLI)
- [just](https://github.com/casey/just) command runner
- Access to GCP project with appropriate permissions

### Testing - Console

Test packages in headless server VMs (recommended for CI/CD and quick validation):

```bash
# Test Debian package on x86_64
just test-package deb x86_64-linux
```

### Testing - Desktop GUI

Test packages with desktop environment for GUI application testing:

```bash
# Create VM with XFCE desktop and xrdp
just test-package-desktop deb x86_64-linux
```

This will:
1. Create a GCP VM instance
2. Install the Gnosis VPN package
3. Install XFCE desktop environment
4. Configure xrdp for remote desktop access
5. Check the script output for credentials

**Connect via RDP:**

```bash
# In a separate terminal, open RDP tunnel
just rdp-connect deb x86_64-linux
```

Note: Desktop testing VMs are NOT auto-deleted. Remember to clean up:

```bash
just delete-test-vm deb x86_64-linux
```
