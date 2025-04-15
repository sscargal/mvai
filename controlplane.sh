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
echo "[CERT-MANAGER] Checking if namespace 'cert-manager' exists..."

# Attempt to get the namespace. Exit code will be 0 if it exists, non-zero otherwise.
# Redirect stdout and stderr (> /dev/null 2>&1) to suppress command output.
kubectl get namespace cert-manager > /dev/null 2>&1
NAMESPACE_EXISTS_EXIT_CODE=$?

# Check the exit code from the 'get namespace' command
if [ $NAMESPACE_EXISTS_EXIT_CODE -ne 0 ]; then
  # Namespace does NOT exist (kubectl get failed), so create it
  echo "[INFO] Namespace 'cert-manager' not found. Creating..."
  kubectl create namespace cert-manager
  # Check if the create command succeeded
  if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to create namespace 'cert-manager'."
    exit 1 # Exit script if creation fails
  else
    echo "[INFO] Namespace 'cert-manager' created successfully."
  fi
else
  # Namespace already exists (kubectl get succeeded)
  echo "[INFO] Namespace 'cert-manager' already exists. Skipping creation."
fi

# --- Cert-Manager Installation Section ---

# Flag to track if we need to run the installation steps
SKIP_CERT_MANAGER_INSTALL=false
CERT_MANAGER_NAMESPACE="cert-manager"
CERT_MANAGER_RELEASE_NAME="cert-manager"
LATEST_CM_VERSION="" # Variable to store latest version

echo "[CERT-MANAGER] Checking existing cert-manager Helm release status in namespace ${CERT_MANAGER_NAMESPACE}..."
# Check if a deployed Helm release exists and is healthy in the target namespace
if helm status ${CERT_MANAGER_RELEASE_NAME} -n ${CERT_MANAGER_NAMESPACE} > /dev/null 2>&1; then
    echo "[CERT-MANAGER] Helm release '${CERT_MANAGER_RELEASE_NAME}' found. Verifying deployment status..."
    # Quick check if key deployments are Available
    CM_AVAILABLE=true
    for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
        # Check if deployment exists and is available
        STATUS=$(kubectl get deployment ${deployment} -n ${CERT_MANAGER_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
        if [ "$STATUS" != "True" ]; then
            echo "[WARN] Deployment ${deployment} found but is not 'Available' (Status: $STATUS). Will attempt install/upgrade."
            CM_AVAILABLE=false
            break
        fi
    done

    if [ "$CM_AVAILABLE" = true ]; then
        echo "[CERT-MANAGER] Existing cert-manager deployments look Available. Skipping installation and verification."
        # Update repo index even if skipping install, so subsequent operations have latest info
        echo "[HELM] Updating jetstack repo index..."
        helm repo update jetstack || echo "[WARN] Failed to update jetstack repo, subsequent installs might use cached versions."
        SKIP_CERT_MANAGER_INSTALL=true
    else
         echo "[CERT-MANAGER] Existing Helm release found, but deployments not fully available. Will attempt install/upgrade."
         # Ensure repo is updated before install/upgrade attempt
         echo "[HELM] Updating jetstack repo index..."
         helm repo update jetstack || { echo "[ERROR] Failed to update jetstack repo. Cannot ensure latest version."; exit 1; }
    fi
else
    echo "[CERT-MANAGER] Helm release '${CERT_MANAGER_RELEASE_NAME}' not found. Proceeding with installation..."
    # Ensure repo is updated before install attempt
    echo "[HELM] Updating jetstack repo index..."
    helm repo update jetstack || { echo "[ERROR] Failed to update jetstack repo. Cannot ensure latest version."; exit 1; }
fi


# --- Installation Block ---
if [ "$SKIP_CERT_MANAGER_INSTALL" = false ]; then

    # --- Determine Latest Certificate manager Version ---
    echo "[CERT-MANAGER] Determining latest stable cert-manager version from jetstack repo..."
    # Get the latest non-development version using helm search and parsing
    # Ensure repo was updated just before this section if install is needed
    LATEST_CM_VERSION=$(helm search repo jetstack/cert-manager --versions --devel=false | awk '$1 == "jetstack/cert-manager" {print $2; exit}')

    if [ -z "$LATEST_CM_VERSION" ]; then
        echo "[ERROR] Could not determine the latest stable version for jetstack/cert-manager via helm search."
        exit 1
    fi
    echo "[CERT-MANAGER] Latest stable version found: ${LATEST_CM_VERSION}"
    # --- End Determine Latest Version ---

    echo "[CERT-MANAGER] Ensuring ${CERT_MANAGER_NAMESPACE} namespace exists..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${CERT_MANAGER_NAMESPACE}
EOF
    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to apply ${CERT_MANAGER_NAMESPACE} namespace definition."
        kubectl get namespace ${CERT_MANAGER_NAMESPACE} || exit 1 # Exit if apply failed AND it doesn't exist
    fi
    echo "[SETUP] Namespace ${CERT_MANAGER_NAMESPACE} ensured."
  
    # --- Install CRDs Manually using LATEST determined version ---
    # Note: GitHub release tags usually have a 'v' prefix
    CRD_URL="https://github.com/cert-manager/cert-manager/releases/download/${LATEST_CM_VERSION}/cert-manager.crds.yaml"
    echo "[CERT-MANAGER] Applying cert-manager CRDs from ${CRD_URL}..."

    # Download CRDs to a temporary file first
    TMP_CRD_FILE=$(mktemp)
    if [ -z "$TMP_CRD_FILE" ]; then
      echo "[ERROR] Failed to create temporary file for CRDs."
      exit 1
    fi

    if curl -sSL "${CRD_URL}" -o "${TMP_CRD_FILE}"; then
        # Apply the downloaded CRDs
        if ! kubectl apply -f "${TMP_CRD_FILE}"; then
            echo "[ERROR] Failed to apply downloaded cert-manager CRDs from ${TMP_CRD_FILE}. Exiting."
            rm -f "${TMP_CRD_FILE}" # Clean up temp file on error
            exit 1
        fi
        rm -f "${TMP_CRD_FILE}" # Clean up temp file on success
        echo "[CERT-MANAGER] CRDs applied successfully."
    else
         echo "[ERROR] Failed to download cert-manager CRDs from ${CRD_URL}. Please check version/URL. Exiting."
         rm -f "${TMP_CRD_FILE}" # Clean up temp file on error
         exit 1
    fi

    echo "[CERT-MANAGER] Waiting for CRD registration..."
    sleep 45 # Keep the wait after CRD apply
    echo "[CERT-MANAGER] Finished waiting for CRD registration."
    # --- End CRD Install ---


    echo "[CERT-MANAGER] Installing cert-manager Helm chart version ${LATEST_CM_VERSION}..."
    # Use the determined LATEST version and explicitly disable Helm's CRD installation
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --version ${LATEST_CM_VERSION} \
      --create-namespace \
      --set installCRDs=false \
      --set startupapicheck.enabled=false \
      --wait \
      --timeout 10m # Wait up to 10 minutes for all resources (including hooks/jobs)

    # Check the exit status of the helm install command
    if [ $? -ne 0 ]; then
        echo "[ERROR] 'helm install ${CERT_MANAGER_RELEASE_NAME}' failed. Exiting."
        echo "[DEBUG] Gathering diagnostic info from ${CERT_MANAGER_NAMESPACE} namespace..."
        # (Debugging commands remain the same, using variables)
        echo "------- Pod Status -------"
        kubectl get pods -n ${CERT_MANAGER_NAMESPACE} -o wide
        echo "------- Deployments Status -------"
        kubectl get deployments -n ${CERT_MANAGER_NAMESPACE}
        echo "------- Recent Events -------"
        kubectl get events -n ${CERT_MANAGER_NAMESPACE} --sort-by='.metadata.creationTimestamp' | tail -n 20
        echo "------- Describing Pending/Error Pods (if any) -------"
        kubectl get pods -n ${CERT_MANAGER_NAMESPACE} --no-headers | awk '$3 != "Running" && $3 != "Completed" {print $1}' | xargs -r -n 1 kubectl describe pod -n ${CERT_MANAGER_NAMESPACE}
        echo "[DEBUG] Getting logs for current startupapicheck job pods..."
        kubectl logs -n cert-manager -l app=startupapicheck --tail=100
        echo "[DEBUG] Getting logs for PREVIOUS startupapicheck job pods (if any)..."
        kubectl logs -n cert-manager -l app=startupapicheck --tail=100 --previous
        exit 1
    fi
    echo "[CERT-MANAGER] Helm install command succeeded. Proceeding with readiness checks..."

    # --- Robust Readiness Checks (only run if install was attempted) ---
    echo "[CERT-MANAGER] Waiting for cert-manager deployments to become available..."
    if ! kubectl wait --for=condition=Available deployment --all -n ${CERT_MANAGER_NAMESPACE} --timeout=300s; then
        echo "[ERROR] Timed out waiting for cert-manager deployments to become available. Check status:"
        kubectl get pods -n ${CERT_MANAGER_NAMESPACE} -o wide
        exit 1
    fi
    echo "[CERT-MANAGER] Deployments available."

    echo "[CERT-MANAGER] Waiting for cert-manager webhook pod(s) to be Ready..."
    WEBHOOK_SELECTOR="app.kubernetes.io/instance=${CERT_MANAGER_RELEASE_NAME},app.kubernetes.io/component=webhook"
    if ! kubectl wait --for=condition=Ready pod -l ${WEBHOOK_SELECTOR} -n ${CERT_MANAGER_NAMESPACE} --timeout=180s; then
        echo "[ERROR] Timed out waiting for cert-manager webhook pod(s) to be Ready. Check status:"
        kubectl get pods -n ${CERT_MANAGER_NAMESPACE} -l ${WEBHOOK_SELECTOR} -o wide
        kubectl describe pod -n ${CERT_MANAGER_NAMESPACE} -l ${WEBHOOK_SELECTOR}
        kubectl logs -n ${CERT_MANAGER_NAMESPACE} -l ${WEBHOOK_SELECTOR} --tail=50
        exit 1
    fi
    echo "[CERT-MANAGER] Webhook pod(s) Ready."

    echo "[CERT-MANAGER] Waiting for cert-manager webhook service endpoints to be available..."
    ENDPOINTS_READY=false
    # Loop until endpoints have at least one address
    for i in {1..30}; do # Check for 30 * 5s = 150 seconds max
        ENDPOINT_IPS=$(kubectl get endpoints cert-manager-webhook -n ${CERT_MANAGER_NAMESPACE} -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        if [ -n "$ENDPOINT_IPS" ]; then
            echo "[CERT-MANAGER] Webhook endpoints found: ${ENDPOINT_IPS}"
            ENDPOINTS_READY=true
            break
        fi
        echo "[CERT-MANAGER] Waiting for webhook endpoints... (${i}/30)"
        sleep 5
    done

    if [ "$ENDPOINTS_READY" = false ]; then
        echo "[ERROR] Timed out waiting for cert-manager webhook service endpoints."
        kubectl get endpoints cert-manager-webhook -n ${CERT_MANAGER_NAMESPACE}
        kubectl describe svc cert-manager-webhook -n ${CERT_MANAGER_NAMESPACE}
        exit 1
    fi
    echo "[CERT-MANAGER] Cert-manager webhook service endpoints available."
    echo "[CERT-MANAGER] Installation and verification complete."

fi
# --- End Installation Block ---

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
