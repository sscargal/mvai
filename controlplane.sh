#!/bin/bash
# set -xe

echo "[INIT] Control Plane Node Initialization"

# Validate required tools
command -v curl >/dev/null || { echo "[ERROR] curl not found"; exit 1; }
command -v jq >/dev/null || apt-get install -y jq
command -v aws >/dev/null || apt-get install -y unzip && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip awscliv2.zip && ./aws/install

echo "[INSTALL] Updating System & Installing Docker"
apt-get update -y
apt-get install -y ca-certificates curl unzip jq

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"${UBUNTU_CODENAME:-$VERSION_CODENAME}\") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker && systemctl start docker

echo "[INSTALL] Installing K3s server"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init" sh -s - || { echo "[ERROR] K3s install failed"; exit 1; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes || { echo "[ERROR] kubectl failed"; exit 1; }

echo "[K3S] Storing Join Token in SSM"
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
if [ -z "$K3S_TOKEN" ]; then
  echo "[ERROR] Failed to get the K3s Control Plan Token from '/var/lib/rancher/k3s/server/node-token')
fi
aws ssm put-parameter --name "/k3s/join-token" --value "$K3S_TOKEN" --type "String" --overwrite || { echo "[ERROR] Failed to write token to SSM"; exit 1; }

# Get the IP Addresses of the Control Plane nodes, and select the first one if there is more than one
CONTROL_PLANE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=MemVerge-ControlPlane" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].PublicIpAddress" \
  --output text | head -n1)
echo "[K3S] Server URL: https://${ControlPlaneElasticIP}:6443"

echo "[WAIT] Waiting for worker nodes to become Ready"

# 169.254.169.254 is always available to all EC2 instances and never changes across accounts or regions
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
if [ -z "$INSTANCE_ID" ]; then
  echo "[ERROR] Failed to retrieve EC2 instance ID"
  exit 1
fi

STACK_NAME=$(aws cloudformation describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" \
  | jq -r '.Tags[] | select(.Key=="aws:cloudformation:stack-name") | .Value')

if [ -z "$STACK_NAME" ]; then
  echo "[ERROR] Could not determine CloudFormation Stack Name from EC2 tags"
  exit 1
fi

EXPECTED_WORKERS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Parameters[?ParameterKey=='WorkerNodeCount'].ParameterValue" --output text)

EXPECTED_NODES=$((EXPECTED_WORKERS + 1))

for i in {1..30}; do
  READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready')
  echo "[WAIT] Ready Nodes: $READY_NODES / $EXPECTED_NODES"
  if [ "$READY_NODES" -eq "$EXPECTED_NODES" ]; then
    echo "[SUCCESS] All $EXPECTED_NODES nodes are Ready"
    break
  fi
  sleep 10
done

if [ "$READY_NODES" -ne "$EXPECTED_NODES" ]; then
  echo "[ERROR] Timeout: Only $READY_NODES of $EXPECTED_NODES nodes Ready after 5m"
  exit 1
fi
