# OS Packages

Gnosis VPN has a ready to use package for the following variants:

- Supported processor architectures: `x86_64`
- Supported operating systems: `Linux`
- Supported package formats: `deb`, `rpm`, and `pkg.tar.zst`

## Install via package manager

- Visit the [release page](https://github.com/gnosis/gnosis_vpn/releases)
- Determine your processor architecture by running `uname -m`.  
  Note: `arm64` is equivalent to `aarch64`.
- Choose the appropriate package format for your system: `deb`, `rpm`, or `pkg.tar.zst`.
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

### Fedora, CentOS, RHEL, openSUSE

**Install:**

```bash
sudo -E dnf install -y ./gnosis_vpn-x86_64-linux.rpm
```

**Uninstall:**

```bash
sudo dnf remove -y gnosis_vpn
```

---

### Arch Linux, Manjaro

**Install:**

```bash
sudo pacman -Syy
sudo -E pacman --noconfirm -U ./gnosis_vpn-x86_64-linux.pkg.tar.zst
```

**Uninstall:**

```bash
sudo pacman -Rs gnosis_vpn
```

---

## Testing Packages

### Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud` CLI)
- [just](https://github.com/casey/just) command runner
- Access to GCP project with appropriate permissions

### Automated Testing (Server Environment)

Test packages in headless server VMs (recommended for CI/CD and quick validation):

```bash
# Test Debian package on x86_64
just test-package deb x86_64-linux

# Test RPM package on x86_64
just test-package rpm x86_64-linux

# Test Arch Linux package on x86_64
just test-package archlinux x86_64-linux

# Test on ARM64 architecture
just test-package deb aarch64-linux
just test-package rpm aarch64-linux
```

**What it tests:**
- ✅ Package installation
- ✅ Service lifecycle (start/stop/enable)
- ✅ File permissions and ownership
- ✅ User/group creation
- ✅ Configuration file handling
- ✅ WireGuard kernel module availability

**Note:** VMs are automatically deleted after testing completes.

### Desktop Testing (GUI Environment)

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

# Then use Microsoft Remote Desktop or compatible RDP client:
# - Server: localhost:3389
# - Username: Your GCP username (usually your email prefix before @)
# - Password: Check the script output
```

**Manual Testing:**

You can also run individual steps:

```bash
# Create VM
./test-vm.sh create deb x86_64-linux

# Copy package to VM
./test-vm.sh copy deb x86_64-linux

# Install package
./test-vm.sh install deb x86_64-linux

# Setup desktop environment (optional, for GUI testing)
./test-vm.sh install-desktop deb x86_64-linux

# Open RDP tunnel (requires desktop setup)
./test-vm.sh rdp deb x86_64-linux

# Delete VM when done
./test-vm.sh delete deb x86_64-linux
```

Or use the just commands:

```bash
# Build package for specific distribution
just package deb x86_64-linux

# Delete test VM
just delete-test-vm deb x86_64-linux
```

**Supported Test Configurations:**

| Distribution | x86_64-linux | aarch64-linux |
|--------------|--------------|---------------|
| deb          | ✅           | ✅            |
| rpm          | ✅           | ✅            |
| archlinux    | ✅           | ⚠️ Limited*   |

*Arch Linux ARM64 images have limited availability in GCP.

**Important:** Desktop testing VMs are NOT auto-deleted. Remember to clean up:

```bash
just delete-test-vm deb x86_64-linux
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

# Build RPM package
just package rpm x86_64-linux

# Build Arch Linux package
just package archlinux x86_64-linux
```

**Build with signing:**

```bash
# Set GPG key path
export GNOSISVPN_GPG_PRIVATE_KEY_PATH=/path/to/private-key.asc
export GNOSISVPN_GPG_PRIVATE_KEY_PASSWORD=<Bitwarden 'GnosisVPN GPG Binary Sign'>

# Build and sign
./build-package.sh --distribution deb --architecture x86_64-linux --sign --gpg-private-key-path "$GNOSISVPN_GPG_PRIVATE_KEY_PATH"
```

