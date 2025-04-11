#!/bin/bash
# set -xe

echo "[INIT] Worker Node Initialization"

apt update -y
apt install -y unzip curl jq apt-transport-https ca-certificates curl software-properties-common

echo "[INSTALL] Docker"
# Use the Docker Convenience script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh

systemctl enable docker && systemctl start docker

echo "[K3S] Joining cluster"
K3S_TOKEN=$(aws ssm get-parameter --name "/k3s/join-token" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$K3S_TOKEN" ]; then
    echo "[ERROR] Failed to get the K3s Control Plane Token from AWS SSM. Exiting."
    exit 1
fi

# Get the K3S URL from AWS SSM and fall back to using the IP
K3S_URL=$(aws ssm get-parameter --name "/k3s/url" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$K3S_URL" ]; then
    echo "[ERROR] Failed to get the K3s URL from AWS SSM." 
    CONTROL_PLANE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=MemVerge-ControlPlane" --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)
    if [ -z "$CONTROL_PLANE_IP" ]; then
        echo "[ERROR] Failed to get the Control Plane IP Address from AWS SSM. Exiting."
        exit 1
    fi
    K3S_URL="https://${CONTROL_PLANE_IP}:6443"
fi

# Install K3s as a worker node and join it to the cluster (Control Plane)
curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh - || { echo "[ERROR] K3s worker node agent failed"; exit 1; }

echo "[SUCCESS] Worker joined cluster"
