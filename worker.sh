#!/bin/bash
# set -xe

echo "[INIT] Worker Node Initialization"

apt update -y
apt install -y unzip curl jq ca-certificates awscli

echo "[INSTALL] Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"${UBUNTU_CODENAME:-$VERSION_CODENAME}\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker && systemctl start docker

echo "[K3S] Joining cluster"
K3S_TOKEN=$(aws ssm get-parameter --name "/k3s/join-token" --with-decryption --query "Parameter.Value" --output text)
[ -z "$K3S_TOKEN" ] && { echo "[ERROR] No token found"; exit 1; }

CONTROL_PLANE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=MemVerge-ControlPlane" --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)
[ -z "$CONTROL_PLANE_IP" ] && { echo "[ERROR] Control Plane IP not found"; exit 1; }

K3S_URL="https://${CONTROL_PLANE_IP}:6443"

curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s agent || { echo "[ERROR] K3s agent failed"; exit 1; }

echo "[SUCCESS] Worker joined cluster"
