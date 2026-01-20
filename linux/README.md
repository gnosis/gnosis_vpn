# Linux Packages

## Testing

### Prerequisites

- Google Cloud SDK (`gcloud`)
- just
- GCP project access

### Console Testing

Test in headless VMs (CI/CD recommended):

```bash
just test-package deb x86_64-linux
```

### Desktop Testing

Test with GUI (XFCE + xrdp):

```bash
just test-package-desktop deb x86_64-linux
# In new terminal:
just rdp-connect deb x86_64-linux
```

**⚠️ Desktop VMs are not auto-deleted:**
```bash
just delete-test-vm deb x86_64-linux

```bash
# Build Debian package
just package deb x86_64-linux
```

**Build with signing:**

```
