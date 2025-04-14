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

# Ensure K3S_URL is not empty
if [ -z "$K3S_URL" ]; then
  echo "[ERROR] K3S_URL variable is empty before attempting to store in SSM."
  exit 1
fi

echo "[INFO] Storing K3S_URL (${K3S_URL}) in SSM using --cli-input-json"

# Create a temporary file to hold the literal URL string
TMP_FILE=$(mktemp)
if [ -z "$TMP_FILE" ]; then
  echo "[ERROR] Failed to create temporary file."
  exit 1
fi

# Write the literal URL string into the temporary file
# Using printf is slightly safer than echo for arbitrary strings
printf "%s" "$K3S_URL" > "$TMP_FILE"

echo "[INFO] Storing K3S URL from temporary file ${TMP_FILE} into SSM parameter /k3s/url"

# Call aws ssm put-parameter using the file:// prefix
# The CLI will read the content of TMP_FILE as the literal value
aws ssm put-parameter \
  --name "/k3s/url" \
  --value "file://${TMP_FILE}" \
  --type "String" \
  --overwrite \
  --region "$AWS_DEFAULT_REGION"

# Check the exit status of the aws command
if [ $? -ne 0 ]; then
  echo "[ERROR] Failed to write K3s URL to SSM using file://${TMP_FILE}"
  rm -f "$TMP_FILE" # Clean up temp file on error
  exit 1
fi

# Clean up the temporary file on success
rm -f "$TMP_FILE"

echo "[SUCCESS] Successfully stored K3s URL in SSM."

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

# Point to the K3s-generated kubeconfig file
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "[INFO] Using KUBECONFIG=${KUBECONFIG}"

# Verify kubectl can connect (optional but good debug step)
echo "[K8S] Checking cluster connectivity..."
kubectl cluster-info || echo "[WARN] Initial kubectl cluster-info failed."
kubectl get nodes || echo "[WARN] Initial kubectl get nodes failed."

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
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true \
  --create-namespace # Add --create-namespace just in case, although kubectl does it above

echo "[CERT-MANAGER] Waiting for cert-manager deployments to become available..."
if ! kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s; then
    echo "[ERROR] Timed out waiting for cert-manager deployments to become available. Checking pod status..."
    kubectl get pods -n cert-manager -o wide
    # Add describe/logs for failing pods if needed here
    exit 1
fi
echo "[CERT-MANAGER] All cert-manager deployments available."

# --- ADD SHORT DELAY ---
echo "[INFO] Adding short delay for webhook stabilization..."
sleep 15
# --- END DELAY ---

echo "[HELM] Logging into GHCR"
# Using || true allows the script to continue if logout fails (e.g., already logged out)
helm registry logout ghcr.io/memverge || true

# Log in using --password-stdin
echo "[INFO] Logging into ghcr.io/memverge using password/token via stdin..."
# Use printf to pipe the token without adding extra newlines or interpreting escapes
printf "%s" "$MEMVERGE_GITHUB_TOKEN" | helm registry login ghcr.io/memverge \
  -u mv-customer-support \
  --password-stdin

# Check the exit status of the login command
if [ $? -ne 0 ]; then
    echo "[ERROR] Helm login failed. Exiting."
    exit 1
else
    echo "[INFO] Helm login succeeded." # Optional success message
fi

# Ensure cattle-system namespace exists (use create --dry-run | apply for idempotency)
echo "[SETUP] Ensuring cattle-system namespace exists"
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

# Create or update secret (use apply for idempotency)
echo "[SETUP] Creating/Updating image pull secret in cattle-system namespace"
kubectl create secret docker-registry memverge-dockerconfig \
  --namespace cattle-system \
  --docker-server=ghcr.io/memverge \
  --docker-username=mv-customer-support \
  --docker-password=$MEMVERGE_GITHUB_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -

LOADBALANCER_HOSTNAME="${MEMVERGE_SUBDOMAIN}.memvergelab.com"

echo "[MVAI] Installing MemVerge.ai using the Helm Chart"
helm install --namespace cattle-system mvai oci://ghcr.io/memverge/charts/mvai \
  --wait --timeout 30m \
  --version $MEMVERGE_VERSION \
  --set hostname=$LOADBALANCER_HOSTNAME \
  --set bootstrapPassword="admin" \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email="noreply@memvergelab.com" \
  --set letsEncrypt.ingress.class=traefik

if [ $? -ne 0 ]; then
  echo "[ERROR] Helm install failed. Exiting."
  # Add debugging for mvai pods if install fails
  echo "[DEBUG] Checking pod status in cattle-system namespace after failed install:"
  kubectl get pods -n cattle-system -o wide --show-labels
  exit 1
fi

echo "[SUCCESS] MemVerge.ai installation script finished."
