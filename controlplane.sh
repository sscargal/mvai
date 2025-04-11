#!/bin/bash

echo "[INIT] Control Plane Node Initialization"

# Validate required tools
command -v curl >/dev/null || { echo "[ERROR] curl not found"; exit 1; }
command -v jq >/dev/null || apt-get update -y && apt-get install -y jq -y
command -v aws >/dev/null || apt-get update -y && apt-get install -y unzip -y && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip -q awscliv2.zip && ./aws/install

echo "[INSTALL] Updating System & Installing Required Tools"
apt-get update -y
apt-get install -y ca-certificates curl unzip jq -y

echo "[INSTALL] Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || { echo "[ERROR] Failed to download Docker GPG key"; exit 1; }
chmod a+r /etc/apt/keyrings/docker.asc || { echo "[ERROR] Failed to set permissions for Docker GPG key"; exit 1; }

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"${UBUNTU_CODENAME:-$VERSION_CODENAME}\") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y || { echo "[ERROR] Failed to update the packages using 'apt-get update -y'" }
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
systemctl enable docker || { echo "[ERROR] Failed to enable the Docker systemd service" }
systemctl start docker || { echo "[ERROR] Failed to start the Docker systemd service" }

echo "[INSTALL] Installing K3s Server Control Plane"
curl -sfL https://get.k3s.io | sh - || { echo "[ERROR] K3s install failed"; exit 1; }

# Verify we can communicate with the K3s Cluster
kubectl get nodes || { echo "[ERROR] kubectl get nodes failed"; exit 1; }

echo "[K3S] Storing Join Token in SSM"
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
if [ -z "$K3S_TOKEN" ]; then
    echo "[ERROR] Failed to get the K3s Control Plan Token from '/var/lib/rancher/k3s/server/node-token'. Exiting."
    exit 1
fi
# Store the K3S Server Token in AWS SSM so the Worker can read it and join the cluster.
aws ssm put-parameter --name "/k3s/join-token" --value "$K3S_TOKEN" --type "String" --overwrite || { echo "[ERROR] Failed to write K3s Join Token to SSM"; exit 1; }

# Get the IP Address of the Control Plane (this node)
CONTROL_PLANE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "[ERROR] Failed to get the Control Plane IP Address"
    exit 1
fi
K3S_URL="https://${CONTROL_PLANE_IP}:6443"
echo "[K3S] Server URL: $K3S_URL"
aws ssm put-parameter --name "/k3s/url" --value "$K3S_URL" --type "String" --overwrite || { echo "[ERROR] Failed to write K3s URL to SSM"; exit 1; }

echo "[WAIT] Waiting for $WORKER_NODE_COUNT worker nodes to become Ready"

# Include the Control Plan in the node count
EXPECTED_NODES=$((WORKER_NODE_COUNT + 1))

timeout=300
interval=30
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

kubectl create namespace cattle-system || true
kubectl create secret generic memverge-dockerconfig --namespace cattle-system \
    --from-file=.dockerconfigjson=$HOME/.config/helm/registry/config.json \
    --type=kubernetes.io/dockerconfigjson

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
