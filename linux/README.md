# Linux Packages

## DNS

The package declares no resolver dependency. While connected, the client scopes the tunnel DNS servers to its interface
through systemd-resolved (`resolvectl`) or resolvconf, whichever owns `/etc/resolv.conf`. On hosts with neither, queries
stay on the host resolver and `postinstall.sh` prints a warning. Never pull a resolver manager in as a package
dependency: apt installs it while the network stack is running, and the resolver configuration is lost until
NetworkManager restarts (GNO-898).

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
```

```bash
# Build Debian package
just package deb x86_64-linux
```

**Build with signing:**
