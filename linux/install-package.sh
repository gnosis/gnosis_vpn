#!/usr/bin/env bash
set -Eeo pipefail
set -o errtrace

trap 'echo "Error occurred during package installation. Pausing for manual inspection..."; sleep 60' ERR

#set -x
GNOSISVPN_DISTRIBUTION="${1:?Error: GNOSISVPN_DISTRIBUTION parameter is required}"

# Install the package based on the GNOSISVPN_DISTRIBUTION
case "$GNOSISVPN_DISTRIBUTION" in
deb)
  sudo apt-get update
  sudo -E apt install -y "/tmp/gnosisvpn.${GNOSISVPN_DISTRIBUTION}"
  ;;
rpm)
  sudo -E dnf install -y "/tmp/gnosisvpn.${GNOSISVPN_DISTRIBUTION}"
  ;;
archlinux)
  # Archlinux mirrors conf in the GCP image is outdated by default
  sudo tee /etc/pacman.conf <<EOF
[options]
Architecture = auto
CheckSpace
SigLevel = Never

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
  sudo pacman -Syy
  sudo -E pacman --noconfirm -U "/tmp/gnosisvpn.${GNOSISVPN_DISTRIBUTION}" # --verbose --debug
  ;;
*)
  echo "Unsupported distribution: $GNOSISVPN_DISTRIBUTION"
  exit 1
  ;;
esac

# Check the health status of the gnosisvpn service
if systemctl is-active --quiet gnosisvpn; then
  echo "gnosisvpn service is running."
else
  echo "gnosisvpn service is not running."
  exit 1
fi
