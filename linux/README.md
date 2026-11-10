# Linux Packages

## DNS

The package declares no resolver dependency. While connected, the client scopes the tunnel DNS servers to its interface
through systemd-resolved (`resolvectl`) or resolvconf. systemd-resolved only reaches applications when
`/etc/resolv.conf` points at its local stub (`nameserver 127.0.0.53`, the `stub-resolv.conf` symlink); pointed at
`/run/systemd/resolve/resolv.conf` instead, applications query the uplink servers directly and skip the per-interface
tunnel DNS. On hosts where neither manages the resolver, queries stay on the host resolver and `postinstall.sh` prints a
warning. Never pull a resolver manager in as a package dependency: apt installs it while the network stack is running,
and the resolver configuration is lost until NetworkManager restarts (GNO-898).

## Testing

### Prerequisites

- Google Cloud SDK (`gcloud`)
- just
- GCP project access

### Console Testing

Test in headless VMs (CI/CD recommended):

```bash
just test-package deb x86_64-linux
just test-package rpm x86_64-linux   # CentOS Stream 10; EPEL is enabled through install/linux.sh
```

Other RPM distributions: pick the GCP image with `GNOSISVPN_VM_IMAGE=<project>/<family>`, e.g.
`GNOSISVPN_VM_IMAGE=rocky-linux-cloud/rocky-linux-10 just test-package rpm x86_64-linux` (also `rhel-cloud/rhel-10`,
`almalinux-cloud/almalinux-10`, `oracle-linux-cloud/oracle-linux-10`; add `-arm64` to the family for `aarch64-linux`).

### Container Testing (RPM)

`test-rpm-container.sh` installs, upgrades, reinstalls with a network override and removes the `.rpm` through the
installer's dnf path, inside a container of the target distribution, against a signed local repository. It needs two
builds of the container's architecture signed with a throwaway key:

```bash
# from the repository root
GNOSISVPN_TEST_KEY_PASSWORD=<pass> just test-rpm-container fedora:44 <packages-dir> <public.asc> <private.asc>
```

Build the packages with `GNOSISVPN_PUBLIC_KEY_PATH=<public.asc>`, `GNOSISVPN_GPG_PRIVATE_KEY_PATH=<private.asc>` and two
snapshot versions (`YYYY.MM.DD+build.HHMMSS`). Images of the supported distributions: `fedora:43`, `fedora:44`,
`quay.io/centos/centos:stream10`, `almalinux:10`, `rockylinux/rockylinux:10`, `oraclelinux:10`.

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
