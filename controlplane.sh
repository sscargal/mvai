#!/bin/bash

echo "[INIT] Control Plane Node Initialization"

echo "[AWS] Detecting the Default Region"

# Check if AWS_DEFAULT_REGION is already set. If not, try to detect it.
# This is required for the `aws` commands if not running within the CloudFormation environment
# Uses shell parameter expansion: ${VAR:-DEFAULT_VALUE} -> If VAR is unset or null, use DEFAULT_VALUE.
# Calls command substitution $(...) only if AWS_DEFAULT_REGION is unset/null.
# Requires jq to parse the region from the instance identity document.
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)}

# Verify that AWS_DEFAULT_REGION is now non-empty (detection worked)
if [ -z "$AWS_DEFAULT_REGION" ] || [ "$AWS_DEFAULT_REGION" == "null" ]; then
  echo "[ERROR] Failed to detect AWS Region automatically."
  echo "[ERROR] Please set the AWS_DEFAULT_REGION environment variable manually."
  exit 1
else
  # Optional: Set AWS_REGION too for tools that might look for it instead.
  export AWS_REGION=${AWS_REGION:-$AWS_DEFAULT_REGION}
  echo "[INFO] Using AWS Region: ${AWS_REGION}"
  echo "[INFO] Using AWS Default Region: ${AWS_DEFAULT_REGION}"
fi

echo "[INSTALL] Updating System & Installing Required Tools"
apt update -y
apt install -y ca-certificates curl unzip jq

# Validate required tools
command -v curl >/dev/null || apt install -y curl
command -v jq >/dev/null || apt install -y jq
command -v unzip >/dev/null || apt install -y unzip
command -v aws >/dev/null || curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip -q awscliv2.zip && ./aws/install

echo "[INSTALL] Docker Check & Setup"
# Check if Docker command exists
if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker is already installed. Verifying service status."
    DOCKER_VERSION=$(docker --version)
    echo "[INFO] Docker version: $DOCKER_VERSION"

    # Ensure Docker service is enabled and active
    if ! systemctl is-enabled --quiet docker; then
         echo "[INFO] Docker service is not enabled. Enabling..."
         systemctl enable docker || echo "[WARN] Failed to enable Docker service."
    else
         echo "[INFO] Docker service is already enabled."
    fi
    if ! systemctl is-active --quiet docker; then
        echo "[INFO] Docker service is not active. Starting..."
        systemctl start docker || echo "[WARN] Failed to start Docker service."
    else
         echo "[INFO] Docker service is already active."
    fi
else
    # Docker not found, proceed with installation
    echo "[INFO] Docker not found. Proceeding with installation using get-docker.sh script."
    curl -fsSL https://get.docker.com -o get-docker.sh
    # Run the installation script
    if sh ./get-docker.sh; then
        echo "[SUCCESS] Docker installed successfully via get-docker.sh."
        # Ensure Docker is enabled and started after fresh install
        echo "[INFO] Enabling and starting Docker service..."
        systemctl enable docker && systemctl start docker
        if [ $? -ne 0 ]; then
             echo "[WARN] Failed to enable or start Docker service after installation."
        else
             echo "[INFO] Docker service enabled and started."
        fi
    else
        echo "[ERROR] Docker installation using get-docker.sh failed."
        # Clean up the script even on failure
        rm -f get-docker.sh
        exit 1
    fi
    # Clean up the script on success
    rm -f get-docker.sh
fi

# Final verification that the Docker daemon is running and docker command works
if ! docker info > /dev/null 2>&1; then
   echo "[ERROR] Docker command is available, but Docker daemon does not seem to be running correctly. Exiting."
   exit 1
fi
echo "[SUCCESS] Docker check/setup complete. Docker is active."

systemctl enable docker || echo "[ERROR] Failed to enable the Docker systemd service"
systemctl start docker || echo "[ERROR] Failed to start the Docker systemd service"

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
aws ssm put-parameter --name "/k3s/join-token" --value "$K3S_TOKEN" --type "String" --overwrite --region $AWS_DEFAULT_REGION || { echo "[ERROR] Failed to write K3s Join Token to SSM"; exit 1; }

# Get the IP Address of the Control Plane (this node)
# CONTROL_PLANE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) # Public/Elastic IP
CONTROL_PLANE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4) # Private IP
if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "[ERROR] Failed to get the Control Plane IP Address"
    exit 1
fi

# Store the Control Plane IP Address in AWS SSM so the Worker can read it and join the cluster.
K3S_URL="https://${CONTROL_PLANE_IP}:6443"
echo "[K3S] Server URL: $K3S_URL"
aws ssm put-parameter --name "/k3s/url" --value "$K3S_URL" --type "String" --overwrite --region $AWS_DEFAULT_REGION || { echo "[ERROR] Failed to write K3s URL to SSM"; exit 1; }

# Ensure we get the correct number of worker nodes for this CloudFormation stack
if [ -z "$WORKER_NODE_COUNT" ]; then
    echo "[ERROR] WORKER_NODE_COUNT is not set. Exiting."
    exit 1
fi
echo "[WAIT] Waiting for $WORKER_NODE_COUNT worker nodes to become Ready"

# Include the Control Plan in the node count
EXPECTED_NODES=$((WORKER_NODE_COUNT + 1))

timeout=1800 # 30mins
interval=30
elapsed=0
# Wait for the nodes to be "Ready"
while [ "$elapsed" -lt "$timeout" ]; do
    READY_NODES=$(kubectl get nodes --no-headers | grep -c 'Ready')
    echo "[WAIT] Ready Nodes: $READY_NODES / $EXPECTED_NODES"
    if [ "$READY_NODES" -eq "$EXPECTED_NODES" ]; then
        echo "[SUCCESS] All $EXPECTED_NODES nodes are Ready"
        break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "[WAIT] Elapsed Time: $((elapsed / 60))m $((elapsed % 60))s"
done

# Check if we timed out waiting for the nodes to be Ready
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
    --version ${MEMVERGE_VERSION} \
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
