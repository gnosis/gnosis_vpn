#!/usr/bin/env bash
set -Eeo pipefail
set -o errtrace

trap 'echo "Error occurred during desktop setup. Check logs for details."; exit 1' ERR

GNOSISVPN_DISTRIBUTION="${1:?Error: GNOSISVPN_DISTRIBUTION parameter is required}"
RDP_PASSWORD="${2:?Error: RDP_PASSWORD parameter is required}"

# Setup desktop environment based on distribution
case "$GNOSISVPN_DISTRIBUTION" in
deb)
  echo 'Installing XFCE desktop and xrdp...'
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y task-xfce-desktop xrdp dbus-x11
  
  echo 'Configuring xrdp for XFCE...'
  echo 'xfce4-session' | sudo tee /home/$(whoami)/.xsession
  sudo chmod +x /home/$(whoami)/.xsession
  
  echo 'Configuring PolicyKit to avoid authentication dialogs...'
  sudo mkdir -p /etc/polkit-1/localauthority/50-local.d
  sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla > /dev/null <<EOF
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
  
  echo 'Configuring xrdp...'
  sudo systemctl enable xrdp
  sudo systemctl start xrdp
  
  echo 'Adding default user to ssl-cert group...'
  sudo usermod -a -G ssl-cert $(whoami)
  
  echo 'Setting up password for RDP access...'
  echo "$(whoami):${RDP_PASSWORD}" | sudo chpasswd
  
  echo 'Desktop environment setup complete!'
  echo 'You can now connect via RDP to this VM'
  ;;
rpm)
  echo 'Installing XFCE desktop and xrdp...'
  sudo dnf groupinstall -y 'Xfce' 'base-x'
  sudo dnf install -y xrdp tigervnc-server dbus-x11
  
  echo 'Configuring xrdp for XFCE...'
  echo 'xfce4-session' | sudo tee /home/$(whoami)/.Xclients
  sudo chmod +x /home/$(whoami)/.Xclients
  
  echo 'Configuring PolicyKit to avoid authentication dialogs...'
  sudo mkdir -p /etc/polkit-1/localauthority/50-local.d
  sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla > /dev/null <<EOF
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
  
  echo 'Configuring xrdp...'
  sudo systemctl enable xrdp
  sudo systemctl start xrdp
  
  echo 'Setting up password for RDP access...'
  echo "$(whoami):${RDP_PASSWORD}" | sudo chpasswd
  
  echo 'Desktop environment setup complete!'
  echo 'You can now connect via RDP to this VM'
  ;;
archlinux)
  echo 'Installing XFCE desktop and xrdp...'
  sudo pacman -Syy
  sudo pacman -S --noconfirm xfce4 xfce4-goodies xrdp tigervnc dbus
  
  echo 'Configuring xrdp for XFCE...'
  echo 'xfce4-session' | sudo tee /home/$(whoami)/.xinitrc
  sudo chmod +x /home/$(whoami)/.xinitrc
  
  echo 'Configuring PolicyKit to avoid authentication dialogs...'
  sudo mkdir -p /etc/polkit-1/rules.d
  sudo tee /etc/polkit-1/rules.d/02-allow-colord.rules > /dev/null <<EOF
polkit.addRule(function(action, subject) {
 if ((action.id == "org.freedesktop.color-manager.create-device" ||
      action.id == "org.freedesktop.color-manager.create-profile" ||
      action.id == "org.freedesktop.color-manager.delete-device" ||
      action.id == "org.freedesktop.color-manager.delete-profile" ||
      action.id == "org.freedesktop.color-manager.modify-device" ||
      action.id == "org.freedesktop.color-manager.modify-profile") &&
     subject.isInGroup("users")) {
    return polkit.Result.YES;
 }
});
EOF
  
  echo 'Configuring xrdp...'
  sudo systemctl enable xrdp
  sudo systemctl start xrdp
  
  echo 'Setting up password for RDP access...'
  echo "$(whoami):${RDP_PASSWORD}" | sudo chpasswd
  
  echo 'Desktop environment setup complete!'
  echo 'You can now connect via RDP to this VM'
  ;;
*)
  echo "Unsupported distribution: $GNOSISVPN_DISTRIBUTION"
  exit 1
  ;;
esac

# Verify xrdp is running
if systemctl is-active --quiet xrdp; then
  echo "xrdp service is running successfully."
else
  echo "WARNING: xrdp service failed to start. Check logs with: journalctl -u xrdp"
  exit 1
fi
