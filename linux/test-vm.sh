#!/bin/bash
set -Eeuo pipefail
#set -x

PROJECT_ID="${GCP_PROJECT:-gnosisvpn-staging}"
ZONE="europe-west4-a"
MACHINE_TYPE_x86="e2-medium"      # GCP's x86_64 instances
MACHINE_TYPE_ARM="t2a-standard-2" # GCP's ARM instances
NETWORK="default"
SUBNET="default"

get_vm_image() {
  case "${GNOSISVPN_DISTRIBUTION}" in
  deb)
    if [ "${GNOSISVPN_ARCHITECTURE}" == "aarch64-linux" ]; then
      echo "projects/debian-cloud/global/images/family/debian-12-arm64"
      return
    else
      echo "projects/debian-cloud/global/images/family/debian-12"
      return
    fi
    ;;
  rpm)
    if [ "${GNOSISVPN_ARCHITECTURE}" == "aarch64-linux" ]; then
      echo "projects/centos-cloud/global/images/family/centos-stream-9-arm64"
      return
    else
      echo "projects/centos-cloud/global/images/family/centos-stream-9"
      return
    fi
    ;;
  archlinux)
    # https://github.com/GoogleCloudPlatform/compute-archlinux-image-builder
    echo "projects/arch-linux-gce/global/images/family/arch"
    ;;
  *)
    echo "Unsupported GNOSISVPN_DISTRIBUTION: ${GNOSISVPN_DISTRIBUTION}. Supported GNOSISVPN_DISTRIBUTIONs are: deb, rpm, archlinux."
    exit 1
    ;;
  esac
}

create_action() {
  # Check if VM already exists
  if gcloud compute instances describe "${INSTANCE_NAME}" --project=${PROJECT_ID} --zone=${ZONE} --quiet >/dev/null 2>&1; then
    echo "VM ${INSTANCE_NAME} already exists. Skipping creation."
    echo "You can SSH into the VM using the following command:"
    echo "gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} ${INSTANCE_NAME}"
    return 0
  fi

  local image
  image=$(get_vm_image "${GNOSISVPN_DISTRIBUTION}")

  echo "Creating VM for GNOSISVPN_DISTRIBUTION: $GNOSISVPN_DISTRIBUTION, GNOSISVPN_ARCHITECTURE: $GNOSISVPN_ARCHITECTURE"
  if [ "${GNOSISVPN_ARCHITECTURE}" == "aarch64-linux" ]; then
    machine_type="$MACHINE_TYPE_ARM"
  else
    machine_type="$MACHINE_TYPE_x86"
  fi
  image_project=$(echo "$image" | cut -d'/' -f2)
  gcloud compute instances create "${INSTANCE_NAME}" \
    --project=${PROJECT_ID} \
    --zone=${ZONE} \
    --machine-type=${machine_type} \
    --network=${NETWORK} \
    --subnet=${SUBNET} \
    --image-project="${image_project}" \
    --image-family="${image##*/}" \
    --boot-disk-size=200GB \
    --tags="iap,rdp" \
    --scopes=storage-ro \
    --create-disk=auto-delete=yes \
    --quiet
  sleep 15
  waiting_iterations=0

  while ! gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${INSTANCE_NAME}" --command="echo SSH is accessible" --quiet 2>/dev/null; do
    echo "Waiting for SSH to become accessible..."
    waiting_iterations=$((waiting_iterations + 1))
    if [ $waiting_iterations -ge 33 ]; then
      echo "SSH is still not accessible after 3 minutes. Exiting."
      echo "You can try to SSH into the VM using the following command:"
      echo "gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} ${INSTANCE_NAME}"
      exit 1
    fi
    sleep 5
  done
  echo "SSH is now accessible on ${INSTANCE_NAME}."
  echo "VM ${INSTANCE_NAME} created successfully. You can SSH into the VM using the following command:"
  echo "gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} ${INSTANCE_NAME}"
}

copy_action() {
  echo "Copying artifacts on ${INSTANCE_NAME}"
  script_dir=$(cd "$(dirname "$0")" && pwd)
  gcloud compute scp --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${script_dir}/install-package.sh" "${INSTANCE_NAME}":/tmp/install-package.sh
  gcloud compute scp --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${script_dir}/build/packages/gnosis_vpn-${GNOSISVPN_ARCHITECTURE}.${GNOSISVPN_DISTRIBUTION}" "${INSTANCE_NAME}":/tmp/gnosis_vpn."${GNOSISVPN_DISTRIBUTION}"
  echo "Artifacts successfully copied on ${INSTANCE_NAME}"
}

install_action() {
  echo "Installing gnosis_vpn package on ${INSTANCE_NAME}"
  gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${INSTANCE_NAME}" --command="sudo bash /tmp/install-package.sh ${GNOSISVPN_DISTRIBUTION}"
  echo "Package installed successfully on ${GNOSISVPN_DISTRIBUTION}-${GNOSISVPN_ARCHITECTURE}."
}

install_desktop_action() {
  echo "Setting up desktop environment on ${INSTANCE_NAME}"
  
  # Generate password from username (part before the dot)
  GCP_USERNAME=$(gcloud config get-value account | cut -d'@' -f1)
  RDP_PASSWORD=$(echo "${GCP_USERNAME}" | cut -d'.' -f1)
  
  # Copy setup script to VM
  script_dir=$(cd "$(dirname "$0")" && pwd)
  gcloud compute scp --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${script_dir}/setup-desktop.sh" "${INSTANCE_NAME}":/tmp/setup-desktop.sh
  
  # Execute setup script on VM with password as argument
  gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${INSTANCE_NAME}" --command="bash /tmp/setup-desktop.sh ${GNOSISVPN_DISTRIBUTION} ${RDP_PASSWORD}"
  
  # Get the actual VM username
  VM_USERNAME=$(gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${INSTANCE_NAME}" --command="whoami" 2>/dev/null | tr -d '\r')
  
  echo ""
  echo "========================================"
  echo "Desktop setup completed on ${INSTANCE_NAME}"
  echo "========================================"
  echo "RDP Connection Details:"
  echo "  Username: ${VM_USERNAME}"
  echo "  Password: ${RDP_PASSWORD}"
  echo "========================================"
  echo ""
  echo "To connect via RDP, run:"
  echo "  $0 rdp ${GNOSISVPN_DISTRIBUTION} ${GNOSISVPN_ARCHITECTURE}"
  echo ""
  echo "IMPORTANT: Save the password above!"
  echo ""
}

rdp_action() {
  echo "Opening RDP tunnel to ${INSTANCE_NAME}..."
  echo ""
  echo "Starting IAP tunnel for RDP (port 3389)..."
  echo "Keep this terminal open while using RDP connection"
  echo ""
  
  # Get the actual VM username and password
  VM_USERNAME=$(gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} "${INSTANCE_NAME}" --command="whoami" 2>/dev/null | tr -d '\r')
  GCP_USERNAME=$(gcloud config get-value account | cut -d'@' -f1)
  RDP_PASSWORD=$(echo "${GCP_USERNAME}" | cut -d'.' -f1)
  
  echo ""
  echo "========================================"
  echo "Connection Details:"
  echo "========================================"
  echo "  Instance: ${INSTANCE_NAME}"
  echo "  Server:   localhost:3389"
  echo "  Username: ${VM_USERNAME}"
  echo "  Password: ${RDP_PASSWORD}"
  echo "========================================"
  echo ""
  echo "Press Ctrl+C to close the tunnel when done"

  echo ""

  gcloud compute start-iap-tunnel "${INSTANCE_NAME}" 3389 \
    --local-host-port=localhost:3389 \
    --project=${PROJECT_ID} \
    --zone=${ZONE}
}

delete_action() {
  echo "Deleting VM for GNOSISVPN_DISTRIBUTION: $GNOSISVPN_DISTRIBUTION, GNOSISVPN_ARCHITECTURE: $GNOSISVPN_ARCHITECTURE"
  if ! gcloud compute instances delete "${INSTANCE_NAME}" --project=${PROJECT_ID} --zone=${ZONE} --quiet; then
    echo "Failed to delete VM ${INSTANCE_NAME}. It may not exist or there was an error."
    exit 1
  fi
  echo "VM gnosisvpn-client-${GNOSISVPN_DISTRIBUTION}-${GNOSISVPN_ARCHITECTURE} deleted successfully."
}

check_parameters() {
  if [ $# -ne 3 ]; then
    echo "Usage: $0 <action> <GNOSISVPN_DISTRIBUTION> <GNOSISVPN_ARCHITECTURE>"
    echo ""
    echo "Actions:"
    echo "  create         - Create VM instance"
    echo "  copy           - Copy package to VM"
    echo "  install        - Install package on VM"
    echo "  install-desktop  - Install XFCE desktop and xrdp"
    echo "  rdp            - Open RDP tunnel to VM"
    echo "  delete         - Delete VM instance"
    echo ""
    echo "Example: $0 create deb x86_64-linux"
    exit 1
  fi

  if [ "$GNOSISVPN_ARCHITECTURE" != "x86_64-linux" ] && [ "$GNOSISVPN_ARCHITECTURE" != "aarch64-linux" ]; then
    echo "Unsupported GNOSISVPN_ARCHITECTURE: $GNOSISVPN_ARCHITECTURE. Supported GNOSISVPN_ARCHITECTUREs are x86_64-linux and aarch64-linux"
    exit 1
  fi

  if [ "$GNOSISVPN_DISTRIBUTION" != "deb" ] && [ "$GNOSISVPN_DISTRIBUTION" != "rpm" ] && [ "$GNOSISVPN_DISTRIBUTION" != "archlinux" ]; then
    echo "Unsupported GNOSISVPN_DISTRIBUTION: $GNOSISVPN_DISTRIBUTION. Supported GNOSISVPN_DISTRIBUTIONs are deb, rpm, and archlinux."
    exit 1
  fi
}

main() {
  case "$ACTION" in
  create)
    create_action
    ;;
  copy)
    copy_action
    ;;
  install)
    install_action
    ;;
  install-desktop)
    install_desktop_action
    ;;
  rdp)
    rdp_action
    ;;
  delete)
    delete_action
    ;;
  *)
    echo "Invalid action specified. Valid actions: create, copy, install, setup-desktop, rdp, delete"
    exit 1
    ;;
  esac
}

ACTION="$1"       # e.g., "create", "copy", "install", "delete"
GNOSISVPN_DISTRIBUTION="$2" # e.g., "deb", "rpm", "archlinux"
GNOSISVPN_ARCHITECTURE="$3" # e.g., "x86_64-linux", "aarch64-linux"
INSTANCE_NAME="gnosisvpn-client-${GNOSISVPN_DISTRIBUTION}-${GNOSISVPN_ARCHITECTURE/_/-}"
INSTANCE_NAME="${INSTANCE_NAME/-linux/}" # Remove -linux suffix for VM name
check_parameters "$@"
main "$@"
