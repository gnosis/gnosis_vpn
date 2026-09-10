#!/usr/bin/env bash
#
# Stand up a throwaway, GPG-signed APT repository from a locally built .deb and
# serve it over http://localhost:8000, reproducing the production two-mirror
# split so the installer scenarios never touch the real repos:
#
#   /primary  → stable only          (mimics downloads.vpn.gnosis.eth.limo)
#   /backup   → stable + snapshot     (mimics download.gnosisvpn.io)
#
# The stable suite is populated with a *repacked* stable-versioned copy of the
# built deb (the built deb has a "+"-suffixed snapshot version); this gives real
# version asymmetry (stable < snapshot) so channel switches and downgrades are
# genuinely exercised. Also produces a copy of install/linux.sh whose hardcoded
# mirror URLs are patched to the two local roots.
#
# Usage: sudo -E local-repo.sh <path-to-gnosisvpn_*_amd64.deb>
# Must run as root.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

SNAPSHOT_DEB="${1:?usage: local-repo.sh <deb-file>}"
[[ -f $SNAPSHOT_DEB ]] || die "deb file not found: $SNAPSHOT_DEB"

REPO_DIR=/srv/gvpn-apt
PRIMARY_DIR="$REPO_DIR/primary"
BACKUP_DIR="$REPO_DIR/backup"
HTTP_PORT=8000
GNUPGHOME_DIR=/root/.gnupg-gvpn-test
TEST_KEYRING=/etc/apt/keyrings/gnosisvpn-test-keyring.gpg
PATCHED_INSTALL_SH=/tmp/install-linux-test.sh
DISTRIBUTIONS_SRC="$REPO_ROOT/linux/apt/conf/distributions"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "local-repo.sh must run as root"

log "Installing repo tooling (reprepro, gnupg, dpkg-dev)"
retry 3 5 apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y reprepro gnupg gpg-agent dpkg-dev

log "Generating throwaway signing key"
rm -rf "$GNUPGHOME_DIR"
install -d -m 700 "$GNUPGHOME_DIR"
export GNUPGHOME="$GNUPGHOME_DIR"
gpg --batch --gen-key <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: GnosisVPN Test
Name-Email: test@invalid
Expire-Date: 0
%commit
EOF
KEYID="$(gpg --list-keys --with-colons | awk -F: '/^pub/{print $5; exit}')"
[[ -n $KEYID ]] || die "failed to determine test key id"
log "Test key id: $KEYID"

# --- Repack a stable-versioned deb from the built snapshot deb ---------------
SNAPSHOT_VERSION="$(dpkg-deb -f "$SNAPSHOT_DEB" Version)"
PKG_ARCH="$(dpkg-deb -f "$SNAPSHOT_DEB" Architecture)" # amd64 on CI; arm64 etc. locally
# Strip the "+…" build suffix to get a lower, stable-flavored version. Snapshot
# builds (pr/commit/date) always carry a "+"; guard just in case.
STABLE_VERSION="${SNAPSHOT_VERSION%%+*}"
if [[ $STABLE_VERSION == "$SNAPSHOT_VERSION" ]]; then
    # No "+" to strip — make a deterministically lower version so downgrades work.
    STABLE_VERSION="${SNAPSHOT_VERSION}~stable"
fi
log "Versions: stable=${STABLE_VERSION}  snapshot=${SNAPSHOT_VERSION}"

WORK="$(mktemp -d)"
dpkg-deb -R "$SNAPSHOT_DEB" "$WORK/pkg"
sed -i "s/^Version: .*/Version: ${STABLE_VERSION}/" "$WORK/pkg/DEBIAN/control"
printf '%s\n' "$STABLE_VERSION" >"$WORK/pkg/etc/gnosisvpn/version.txt"
STABLE_DEB="$WORK/gnosisvpn_${STABLE_VERSION}_${PKG_ARCH}.deb"
dpkg-deb -b "$WORK/pkg" "$STABLE_DEB" >/dev/null
log "Repacked stable deb: $(basename "$STABLE_DEB")"

# --- Build the two reprepro roots --------------------------------------------
build_root() {
    # build_root <dir> <distributions-content-file>
    local dir="$1" dist="$2"
    rm -rf "$dir"
    install -d -m 755 "$dir/conf"
    cp "$dist" "$dir/conf/distributions"
    gpg --export "$KEYID" >"$dir/gnosisvpn-archive-keyring.gpg"
}

log "Building backup root (stable + snapshot) at $BACKUP_DIR"
BACKUP_DIST="$WORK/distributions.backup"
sed "s/^SignWith:.*/SignWith: ${KEYID}/" "$DISTRIBUTIONS_SRC" >"$BACKUP_DIST"
build_root "$BACKUP_DIR" "$BACKUP_DIST"
reprepro -b "$BACKUP_DIR" includedeb stable "$STABLE_DEB"
reprepro -b "$BACKUP_DIR" includedeb snapshot "$SNAPSHOT_DEB"

log "Building primary root (stable only) at $PRIMARY_DIR"
PRIMARY_DIST="$WORK/distributions.primary"
# First stanza of the distributions file is the stable suite.
awk 'BEGIN{RS="";ORS="\n\n"} NR==1{print}' "$DISTRIBUTIONS_SRC" |
    sed "s/^SignWith:.*/SignWith: ${KEYID}/" >"$PRIMARY_DIST"
build_root "$PRIMARY_DIR" "$PRIMARY_DIST"
reprepro -b "$PRIMARY_DIR" includedeb stable "$STABLE_DEB"

# --- Keyrings ----------------------------------------------------------------
# A dedicated path for the upgrade phase: postinstall clobbers the production
# keyring at /etc/apt/keyrings/gnosisvpn-archive-keyring.gpg on every run, so
# the local repo's Signed-By must reference a keyring it cannot overwrite.
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$BACKUP_DIR/gnosisvpn-archive-keyring.gpg" "$TEST_KEYRING"

# --- Record versions for the scenario runners --------------------------------
cat >"$REPO_DIR/versions.env" <<EOF
STABLE_VERSION=${STABLE_VERSION}
SNAPSHOT_VERSION=${SNAPSHOT_VERSION}
EOF
chmod 0644 "$REPO_DIR/versions.env"

# --- Serve -------------------------------------------------------------------
log "Serving the repo on http://localhost:${HTTP_PORT} (/primary, /backup)"
setsid nohup python3 -m http.server "$HTTP_PORT" --directory "$REPO_DIR" \
    >/var/log/gvpn-repo-http.log 2>&1 &
disown || true

log "Waiting for the repo to answer"
retry 15 2 curl -fsS "http://localhost:${HTTP_PORT}/backup/dists/snapshot/InRelease" -o /dev/null ||
    die "local backup repo did not come up on port ${HTTP_PORT}"
retry 15 2 curl -fsS "http://localhost:${HTTP_PORT}/primary/dists/stable/InRelease" -o /dev/null ||
    die "local primary repo did not come up on port ${HTTP_PORT}"

# --- Patch install.sh --------------------------------------------------------
log "Patching install.sh mirror URLs → ${PATCHED_INSTALL_SH}"
# PRIMARY = stable-only root (eth.limo analog); BACKUP = both-suites root
# (gnosisvpn.io analog). Distinct host+path so the stable source lists two
# working apt sources without "configured multiple times" warnings.
sed -e 's|^REPO_URL_PRIMARY=.*|REPO_URL_PRIMARY="http://localhost:8000/primary"|' \
    -e 's|^REPO_URL_BACKUP=.*|REPO_URL_BACKUP="http://127.0.0.1:8000/backup"|' \
    "$REPO_ROOT/install/linux.sh" >"$PATCHED_INSTALL_SH"
chmod 0755 "$PATCHED_INSTALL_SH"

log "Local APT repo ready (stable=${STABLE_VERSION}, snapshot=${SNAPSHOT_VERSION})"
