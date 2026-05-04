# Security Policy

## Package Verification

All GnosisVPN packages include SHA256 checksums for integrity verification. Additionally:

- **Linux packages** (`.deb`) are signed with GPG
- **macOS packages** (`.pkg`) use Apple's code signing mechanism and are signed with an Apple Developer certificate

We strongly recommend verifying packages before installation.

### GPG Public Key

**Key ID:** `84F73FEA46D10972`

**Fingerprint:** `9A30 8031 FD3B FE8E DBF5  076D 84F7 3FEA 46D1 0972`

**Email:** tech@hoprnet.org

### Importing the Public Key

You can import the GnosisVPN public key using any of these methods:

**From keyserver:**

```bash
gpg --keyserver keyserver.ubuntu.com --recv-keys 9A308031FD3BFE8EDBF5076D84F73FEA46D10972
echo "9A308031FD3BFE8EDBF5076D84F73FEA46D10972:6:" | gpg --import-ownertrust
```

**From this repository:**

```bash
curl -s -O https://raw.githubusercontent.com/gnosis/gnosis_vpn/main/gnosisvpn-public-key.asc
gpg --import gnosisvpn-public-key.asc
```

**From release assets:**

Download `gnosisvpn-public-key.asc` from any release and import:

```bash
gpg --import gnosisvpn-public-key.asc
```

### Verifying Package Signatures

Each Linux release includes three files per package:

1. **Package file** (e.g., `gnosisvpn-amd64.deb`)
2. **SHA256 checksum** (e.g., `gnosisvpn-amd64.deb.sha256`)
3. **GPG signature** (e.g., `gnosisvpn-amd64.deb.asc`)

#### Verify SHA256 Checksum

```bash
sha256sum -c gnosisvpn-amd64.deb.sha256
```

Expected output:

```
gnosisvpn-amd64.deb: OK
```

#### Verify GPG Signature

```bash
gpg --verify gnosisvpn-amd64.deb.asc gnosisvpn-amd64.deb
```

Expected output:

```
gpg: Signature made Mon May  4 12:25:22 2026 CEST
gpg:                using EDDSA key 9A308031FD3BFE8EDBF5076D84F73FEA46D10972
gpg: checking the trustdb
gpg: marginals needed: 3  completes needed: 1  trust model: pgp
gpg: depth: 0  valid:   1  signed:   0  trust: 0-, 0q, 0n, 0m, 0f, 1u
gpg: next trustdb check due at 2075-11-23
gpg: Good signature from "GnosisVPN (Gnosis VPN) <tech@hoprnet.org>" [ultimate]
```

#### Verify Embedded Package Signatures

**Debian/Ubuntu packages:**

```bash
dpkg-sig --verify gnosisvpn-amd64.deb
```

## macOS Package Verification

macOS packages are signed with an Apple Developer certificate and notarized by Apple. The system verifies signatures
automatically during installation.

### Verify SHA256 Checksum (macOS)

Each macOS release includes a SHA256 checksum file for manual verification:

Download the package and checksum from the release page https://github.com/gnosis/gnosis_vpn/releases


```bash
# Verify checksum
shasum -a 256 -c gnosisvpn-arm64.pkg.sha256
```

Expected output:

```
gnosisvpn-arm64.pkg: OK
```

### Verify Code Signature (macOS)

```bash
# Verify installer package signature
pkgutil --check-signature gnosisvpn-arm64.pkg

# After installation, verify app signature
codesign --verify --deep --strict /Applications/Gnosis\ VPN.app
```

## Reporting Security Vulnerabilities

If you discover a security vulnerability in GnosisVPN, please report it privately to:

**Email:** tech@hoprnet.org

Please include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)
