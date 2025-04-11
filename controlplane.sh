#!/bin/bash
# set -xe

echo "[INIT] Control Plane Node Initialization"

# Validate required tools
command -v curl >/dev/null || { echo "[ERROR] curl not found"; exit 1; }
command -v jq >/dev/null || apt-get install -y jq
command -v aws >/dev/null || apt-get install -y unzip && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip awscliv2.zip && ./aws/install

echo "[INSTALL] Updating System & Installing Required Tools"
apt-get update -y
apt-get install -y ca-certificates curl unzip jq

echo "[INSTALL] Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || { echo "[ERROR] Failed to download Docker GPG key"; exit 1; }
chmod a+r /etc/apt/keyrings/docker.asc || { echo "[ERROR] Failed to set permissions for Docker GPG key"; exit 1; }

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"${UBUNTU_CODENAME:-$VERSION_CODENAME}\") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker && systemctl start docker

echo "[INSTALL] Installing K3s Server Control Plane"
curl -sfL https://get.k3s.io | sh - || { echo "[ERROR] K3s install failed"; exit 1; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes || { echo "[ERROR] kubectl get nodes failed"; exit 1; }

echo "[K3S] Storing Join Token in SSM"
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
if [ -z "$K3S_TOKEN" ]; then
  echo "[ERROR] Failed to get the K3s Control Plan Token from '/var/lib/rancher/k3s/server/node-token'. Exiting."
  exit 1
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

timeout=300
interval=10
elapsed=0

while [ "$elapsed" -lt "$timeout" ]; do
  READY_NODES=$(kubectl get nodes --no-headers | grep -c ' Ready')
  echo "[WAIT] Ready Nodes: $READY_NODES / $EXPECTED_NODES"
  if [ "$READY_NODES" -eq "$EXPECTED_NODES" ]; then
    echo "[SUCCESS] All $EXPECTED_NODES nodes are Ready"
    break
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
  echo "[WAIT] Elapsed Time: $((elapsed / 60))m $((elapsed % 60))s"
done

if [ "$READY_NODES" -ne "$EXPECTED_NODES" ]; then
  echo "[ERROR] Timeout: Only $READY_NODES of $EXPECTED_NODES nodes Ready after $((timeout / 60))m"
  exit 1
fi

##########
# Install MemVerge.ai
##########

# Validate environment variables
if [ -z "$MEMVERGE_VERSION" ] || [ -z "$MEMVERGE_SUBDOMAIN" ] || [ -z "$MEMVERGE_GITHUB_TOKEN" ]; then
    echo "[ERROR] Missing required environment variables."
    echo "[DEBUG] MEMVERGE_VERSION='$MEMVERGE_VERSION'"
    echo "[DEBUG] MEMVERGE_SUBDOMAIN='$MEMVERGE_SUBDOMAIN'"
    echo "[DEBUG] MEMVERGE_GITHUB_TOKEN='$MEMVERGE_GITHUB_TOKEN'"
    echo "Ensure MEMVERGE_VERSION, MEMVERGE_SUBDOMAIN, and MEMVERGE_GITHUB_TOKEN are set."
    exit 1
fi

echo "[INIT] MemVerge.ai installation starting..."

echo "[HELM] Installing Helm"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh && ./get_helm.sh

echo "[HELM] Adding Repos"
helm repo add stable https://charts.helm.sh/stable
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

echo "[CERT-MANAGER] Installing cert-manager"
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm install cert-manager jetstack/cert-manager --namespace cert-manager --set crds.enabled=true
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=300s || echo "[WARN] cert-manager may not be ready"

echo "[HELM] Logging into GHCR"
helm registry logout ghcr.io/memverge || echo "[INFO] helm registry logout failed"
helm registry login ghcr.io/memverge -u mv-customer-support -p $MEMVERGE_GITHUB_TOKEN
if [ $? -ne 0 ]; then
    echo "[ERROR] Helm login failed. Exiting."
    exit 1
fi

kubectl create namespace cattle-system
kubectl create secret generic memverge-dockerconfig --namespace cattle-system \
    --from-file=.dockerconfigjson=$HOME/.config/helm/registry/config.json \
    --type=kubernetes.io/dockerconfigjson

CONTROL_PLANE_IP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)
LOADBALANCER_HOSTNAME="${MEMVERGE_SUBDOMAIN}.memvergelab.com"

echo "[MVAI] Installing MemVerge.ai using the Helm Chart"
helm install --namespace cattle-system mvai oci://ghcr.io/memverge/charts/mvai \
    --wait --timeout 20m \
    --version ${MemVergeVersion} \
    --set hostname=$LOADBALANCER_HOSTNAME \
    --set bootstrapPassword=admin \
    --set ingress.tls.source=letsEncrypt \
    --set letsEncrypt.email=support@memverge.ai \
    --set letsEncrypt.ingress.class=traefik
if [ $? -ne 0 ]; then
    echo "[ERROR] Helm install failed. Exiting."
    exit 1
fi

echo "[SUCCESS] MemVerge.ai Installed"
