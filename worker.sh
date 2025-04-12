#!/bin/bash
# set -xe

echo "[INIT] Worker Node Initialization"

apt update -y
apt install -y unzip curl jq apt-transport-https ca-certificates curl software-properties-common

# Validate required tools
command -v curl >/dev/null || apt-get install -y curl
command -v jq >/dev/null || apt-get install -y jq
command -v unzip >/dev/null || apt-get install -y unzip
command -v aws >/dev/null || curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip -q awscliv2.zip && ./aws/install

echo "[INSTALL] Docker"
# Use the Docker Convenience script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh

systemctl enable docker && systemctl start docker

# Wait for the control plane to become ready
echo "[WAIT] Waiting for Control Plane to become available"

timeout=600 # 10 minutes
interval=30 # 30 seconds
elapsed=0

while [ "$elapsed" -lt "$timeout" ]; do
    K3S_URL=$(aws ssm get-parameter --name "/k3s/url" --with-decryption --query "Parameter.Value" --output text)
    if [ ! -z "$K3S_URL" ]; then
        if curl -s -o /dev/null -w "%{http_code}" "$K3S_URL/healthz" | grep -q '200'; then
            echo "[SUCCESS] Control Plane is available"
            break
        else
            echo "[WAIT] Control Plane not yet ready, retrying..."
        fi
    else
        echo "[WAIT] Control plane URL not yet available in SSM, retrying..."
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "[WAIT] Elapsed Time: $((elapsed / 60))m $((elapsed % 60))s"
done

if [ "$elapsed" -ge "$timeout" ]; then
    echo "[ERROR] Timeout: Control Plane not available after $((timeout / 60))m"
    echo "[K3S] Trying to get the Control Plane IP Address"
    CONTROL_PLANE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=MemVerge-ControlPlane" --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)
    if [ -z "$CONTROL_PLANE_IP" ]; then
        echo "[ERROR] Failed to get the Control Plane IP Address from AWS SSM. Exiting."
        exit 1
    fi
    K3S_URL="https://${CONTROL_PLANE_IP}:6443"
fi

echo "[K3S] Joining cluster"
K3S_TOKEN=$(aws ssm get-parameter --name "/k3s/join-token" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$K3S_TOKEN" ]; then
   echo "[ERROR] Failed to get the K3s Control Plane Token from AWS SSM. Exiting."
   exit 1
fi

# Install K3s as a worker node and join it to the cluster (Control Plane)
curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh - || { echo "[ERROR] K3s worker node agent failed"; exit 1; }

echo "[SUCCESS] Worker joined cluster"
