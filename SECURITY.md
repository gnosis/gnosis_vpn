# Security Policy

## Linux Package Verification

All GnosisVPN Linux packages (`.deb`) are signed with GPG to ensure authenticity and integrity. We strongly recommend verifying packages before installation.

**Note:** macOS packages use Apple's code signing mechanism and are signed with an Apple Developer certificate. This guide covers Linux package verification only.

### GPG Public Key

**Key ID:** `84F73FEA46D10972`

**Fingerprint:** `9A30 8031 FD3B FE8E DBF5  076D 84F7 3FEA 46D1 0972`

**Email:** tech@hoprnet.org

### Importing the Public Key

You can import the GnosisVPN public key using any of these methods:

**From keyserver:**

```bash
gpg --keyserver keyserver.ubuntu.com --recv-keys 84F73FEA46D10972
```

**From this repository:**

```bash
curl -O https://raw.githubusercontent.com/gnosis/gnosis_vpn/main/gnosis-vpn-public-key.asc
gpg --import gnosis-vpn-public-key.asc
```

**From release assets:**

Download `gnosis-vpn-public-key.asc` from any release and import:

```bash
gpg --import gnosis-vpn-public-key.asc
```

### Verifying Package Signatures

Each Linux release includes three files per package:

1. **Package file** (e.g., `gnosis_vpn-x86_64-linux.deb`)
2. **SHA256 checksum** (e.g., `gnosis_vpn-x86_64-linux.deb.sha256`)
3. **GPG signature** (e.g., `gnosis_vpn-x86_64-linux.deb.asc`)

#### Verify SHA256 Checksum

```bash
sha256sum -c gnosis_vpn-x86_64-linux.deb.sha256
```

Expected output:
```
gnosis_vpn-x86_64-linux.deb: OK
```

#### Verify GPG Signature

```bash
gpg --verify gnosis_vpn-x86_64-linux.deb.asc gnosis_vpn-x86_64-linux.deb
```

Expected output:
```
gpg: Signature made [date]
gpg:                using EDDSA key 9A308031FD3BFE8EDBF5076D84F73FEA46D10972
gpg: Good signature from "GnosisVPN <tech@hoprnet.org>"
```

#### Verify Embedded Package Signatures

**Debian/Ubuntu packages:**

```bash
dpkg-sig --verify gnosis_vpn-x86_64-linux.deb
```

### Complete Verification Example (Linux)

```bash
# Download all files (example for Debian package)
PACKAGE="gnosis_vpn-x86_64-linux.deb"
wget https://github.com/gnosis/gnosis_vpn/releases/latest/download/${PACKAGE}
wget https://github.com/gnosis/gnosis_vpn/releases/latest/download/${PACKAGE}.sha256
wget https://github.com/gnosis/gnosis_vpn/releases/latest/download/${PACKAGE}.asc

# Import public key (first time only)
gpg --keyserver keyserver.ubuntu.com --recv-keys 84F73FEA46D10972

# Verify checksum
sha256sum -c ${PACKAGE}.sha256

# Verify signature
gpg --verify ${PACKAGE}.asc ${PACKAGE}

# If both checks pass, install
sudo apt install ./${PACKAGE}
```

## Reporting Security Vulnerabilities

If you discover a security vulnerability in GnosisVPN, please report it privately to:

**Email:** tech@hoprnet.org

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Security Best Practices

When using GnosisVPN:

1. ✅ Always verify package signatures before installation
2. ✅ Download packages only from official sources (GitHub releases)
3. ✅ Keep your system and GnosisVPN updated
4. ✅ Review configuration files before making changes
5. ✅ Use strong authentication for VPN connections
6. ✅ Monitor system logs for unusual activity
