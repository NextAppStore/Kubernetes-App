#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Kubernetes-App: Packer-Provisioning
#
# Das Image enthaelt:
#   - k3s (Version aus K3S_VERSION), installiert aber noch nicht gestartet
#   - das Student-Image als Tar in /var/lib/rancher/k3s/agent/images/
#     (k3s importiert es beim Start, eine Registry ist nicht noetig)
#   - labctl und das Erststart-Skript unter /usr/local/bin
#
# Erwartet von Packer:
#   K3S_VERSION   z.B. v1.31.4+k3s1
#   STUDENT_IMAGE z.B. kubernetes-app/student:1
#   FILES_DIR     Verzeichnis mit den hochgeladenen Dateien
# -----------------------------------------------------------------------------

: "${K3S_VERSION:?}"
: "${STUDENT_IMAGE:?}"
: "${FILES_DIR:?}"

echo "Waiting for cloud-init (if present)..."
cloud-init status --wait || true

echo "Installing packages..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates iproute2 docker.io

echo "Building student image ${STUDENT_IMAGE}..."
sudo docker build -t "${STUDENT_IMAGE}" "${FILES_DIR}/student-image"

echo "Exporting image for k3s auto-import..."
sudo mkdir -p /var/lib/rancher/k3s/agent/images
sudo docker save -o /var/lib/rancher/k3s/agent/images/student.tar "${STUDENT_IMAGE}"

echo "Removing docker (not needed at runtime)..."
sudo systemctl stop docker docker.socket || true
sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y docker.io containerd runc || true
sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
sudo rm -rf /var/lib/docker /var/lib/containerd

echo "Installing k3s ${K3S_VERSION}..."
curl -sfL https://get.k3s.io \
    | sudo INSTALL_K3S_VERSION="${K3S_VERSION}" \
        INSTALL_K3S_SKIP_START=true \
        INSTALL_K3S_SKIP_ENABLE=true \
        sh -s - server

echo "Installing labctl and first-boot script..."
sudo install -m 0755 "${FILES_DIR}/labctl" /usr/local/bin/labctl
sudo install -m 0755 "${FILES_DIR}/kubernetes-app-provision.sh" /usr/local/bin/kubernetes-app-provision.sh

echo "Cleanup..."
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/* "${FILES_DIR}"

echo "Provisioning finished."
