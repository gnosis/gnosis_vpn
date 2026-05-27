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

In every method below, `gpg --import` only prints the 64-bit key ID — not the full fingerprint — so an extra step is
needed to display the fingerprint and compare it against the expected value above.

**From keyserver:**

```bash
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 9A308031FD3BFE8EDBF5076D84F73FEA46D10972
gpg --fingerprint 9A308031FD3BFE8EDBF5076D84F73FEA46D10972
# Confirm the printed fingerprint matches 9A30 8031 FD3B FE8E DBF5  076D 84F7 3FEA 46D1 0972
# before running the next command — it grants the key ultimate trust.
echo "9A308031FD3BFE8EDBF5076D84F73FEA46D10972:6:" | gpg --import-ownertrust
```

**From this repository:**

```bash
curl -fsSLO https://raw.githubusercontent.com/gnosis/gnosis_vpn/main/gnosisvpn-public-key.asc
gpg --show-keys gnosisvpn-public-key.asc
# Confirm the printed fingerprint matches 9A30 8031 FD3B FE8E DBF5  076D 84F7 3FEA 46D1 0972
# before importing.
gpg --import gnosisvpn-public-key.asc
```

**From the APT repository:**

(This is the same key, already dearmored.) The keyring is served over HTTPS without an out-of-band signature, so
download it to a file and inspect the fingerprint before importing:

```bash
curl -fsSL https://download.gnosisvpn.io/linux/apt/gnosisvpn-archive-keyring.gpg \
    -o /tmp/gnosisvpn-archive-keyring.gpg
gpg --show-keys /tmp/gnosisvpn-archive-keyring.gpg
# Confirm the printed fingerprint matches 9A30 8031 FD3B FE8E DBF5  076D 84F7 3FEA 46D1 0972
# before importing.
gpg --import /tmp/gnosisvpn-archive-keyring.gpg
```

### Verifying Package Signatures

The examples below use `<version>` and `<arch>` placeholders — substitute the release version (e.g., `0.79.0`) and your
architecture (`amd64` or `arm64`).

Each Linux package consists of three files in the APT pool at
`https://download.gnosisvpn.io/linux/apt/pool/main/g/gnosisvpn/` (stable) or
`https://download.gnosisvpn.io/linux/apt/pool/snapshot/g/gnosisvpn/` (snapshot):

1. **Package file** — `gnosisvpn_<version>_<arch>.deb`
2. **SHA256 checksum** — `gnosisvpn_<version>_<arch>.deb.sha256`
3. **GPG signature** — `gnosisvpn_<version>_<arch>.deb.asc`

Download all three from the same prefix, then verify:

#### Verify SHA256 Checksum

```bash
sha256sum -c gnosisvpn_<version>_<arch>.deb.sha256
```

Expected output:

```
gnosisvpn_<version>_<arch>.deb: OK
```

#### Verify GPG Signature

```bash
gpg --verify gnosisvpn_<version>_<arch>.deb.asc gnosisvpn_<version>_<arch>.deb
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
dpkg-sig --verify gnosisvpn_<version>_<arch>.deb
```

## macOS Package Verification

macOS packages are signed with an Apple Developer certificate and notarized by Apple. The system verifies signatures
automatically during installation.

### Verify SHA256 Checksum (macOS)

Each macOS release includes a SHA256 checksum file for manual verification:

Download the package and checksum from the release page https://github.com/gnosis/gnosis_vpn/releases

```bash
# Verify checksum
shasum -a 256 -c gnosisvpn_<version>_arm64.pkg.sha256
```

Expected output:

```
gnosisvpn_<version>_arm64.pkg: OK
```

### Verify Code Signature (macOS)

```bash
# Verify installer package signature
pkgutil --check-signature gnosisvpn_<version>_arm64.pkg

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
