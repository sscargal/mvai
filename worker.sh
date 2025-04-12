#!/bin/bash
# set -xe

echo "[INIT] Worker Node Initialization"

# Get current date and time - using UTC for consistency
CURRENT_DATETIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "[INFO] Script started at: $CURRENT_DATETIME"
echo "[INFO] Location context: Mead, Colorado, United States" # Based on user context


apt update -y
apt install -y unzip curl jq apt-transport-https ca-certificates curl software-properties-common

# Validate required tools are installed or install them
echo "[SETUP] Ensuring required tools are available..."
command -v curl >/dev/null || apt-get install -y curl
command -v jq >/dev/null || apt-get install -y jq
# Check for unzip, install aws-cli if unzip is missing or if aws command doesn't exist
NEEDS_AWS_INSTALL=false
if ! command -v unzip >/dev/null; then
    echo "[INFO] Installing unzip..."
    apt-get install -y unzip
    NEEDS_AWS_INSTALL=true # Assume we need AWS CLI if unzip wasn't there
fi
if ! command -v aws >/dev/null; then
    NEEDS_AWS_INSTALL=true
fi

if [ "$NEEDS_AWS_INSTALL" = true ]; then
     echo "[INFO] Installing AWS CLI v2..."
     curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip
     # Verify installation
     command -v aws >/dev/null || { echo "[ERROR] AWS CLI installation failed."; exit 1; }
     echo "[SUCCESS] AWS CLI installed."
else
     echo "[INFO] AWS CLI already installed."
fi


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


# Wait for the control plane to become ready
echo "[WAIT] Waiting for Control Plane to become available"

timeout=600 # 10 minutes
interval=30 # 30 seconds
elapsed=0
control_plane_ready=false # Flag to track success

while [ "$elapsed" -lt "$timeout" ]; do
    echo "[WAIT] Checking SSM for Control Plane URL..."
    # Fetch URL, suppress stderr if parameter not found yet
    K3S_URL=$(aws ssm get-parameter --name "/k3s/url" --with-decryption --query "Parameter.Value" --output text 2>/dev/null)
    SSM_EXIT_CODE=$? # Check if SSM command was successful

    # Only proceed if SSM command succeeded and URL is non-empty
    if [ "$SSM_EXIT_CODE" -eq 0 ] && [ -n "$K3S_URL" ]; then
        echo "[DEBUG] K3S_URL retrieved from SSM: $K3S_URL"
        echo "[WAIT] Attempting to reach Control Plane health endpoint..."
        # Use -k for self-signed certs, capture HTTP code, add timeouts
        HTTP_CODE=$(curl --connect-timeout 5 --max-time 10 -k -s -o /dev/null -w "%{http_code}" "${K3S_URL}/healthz")
        CURL_EXIT_CODE=$? # Capture curl's exit code

        echo "[DEBUG] curl exit code: $CURL_EXIT_CODE, HTTP code: $HTTP_CODE"

        # Check if curl succeeded (exit 0) AND got HTTP 200
        if [ "$CURL_EXIT_CODE" -eq 0 ] && [ "$HTTP_CODE" = "200" ]; then
            echo "[SUCCESS] Control Plane is available at $K3S_URL"
            control_plane_ready=true # Set success flag
            break # Exit the loop
        else
            echo "[WAIT] Control Plane health check failed (curl exit: $CURL_EXIT_CODE, http code: $HTTP_CODE), retrying..."
        fi
    elif [ "$SSM_EXIT_CODE" -ne 0 ]; then
         echo "[WAIT] Failed to execute aws ssm get-parameter command (Exit Code: $SSM_EXIT_CODE). Check permissions/region. Retrying..."
    else
        echo "[WAIT] Control plane URL not yet available in SSM, retrying..."
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "[INFO] Elapsed Time: $((elapsed / 60))m $((elapsed % 60))s / $((timeout / 60))m $((timeout % 60))s"
done

# Check if the loop timed out or never found a working URL
if [ "$control_plane_ready" = false ]; then
    echo "[ERROR] Timeout or failure: Control Plane did not become ready via SSM URL after $((timeout / 60))m."
    echo "[INFO] Attempting fallback: Get Control Plane IP via EC2 API..."
    # Ensure AWS CLI has region configured correctly (usually via instance metadata)
    CONTROL_PLANE_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=MemVerge-ControlPlane" "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)

    if [ -n "$CONTROL_PLANE_IP" ]; then
        echo "[INFO] Fallback successful. Found running Control Plane IP: $CONTROL_PLANE_IP"
        # Construct the URL - assuming standard K3s port 6443
        K3S_URL="https://${CONTROL_PLANE_IP}:6443"
        echo "[INFO] Using fallback K3S_URL: $K3S_URL"
        # Optionally, add one last health check here before proceeding
        echo "[INFO] Performing health check on fallback URL..."
        HTTP_CODE=$(curl --connect-timeout 5 --max-time 10 -k -s -o /dev/null -w "%{http_code}" "${K3S_URL}/healthz")
        if [ "$?" -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
             echo "[ERROR] Fallback URL $K3S_URL health check failed (curl exit: $?, http code: $HTTP_CODE). Exiting."
             exit 1
        fi
        echo "[INFO] Fallback URL health check successful."
    else
        echo "[ERROR] Fallback failed: Could not get running Control Plane IP Address from EC2 API. Exiting."
        exit 1
    fi
    # If we are here, the fallback succeeded in getting an IP, constructing a URL, and health check passed.
fi

# Proceed using the K3S_URL found either via SSM or the fallback
echo "[K3S] Joining cluster using URL: $K3S_URL"
K3S_TOKEN=$(aws ssm get-parameter --name "/k3s/join-token" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$K3S_TOKEN" ]; then
   echo "[ERROR] Failed to get the K3s Control Plane Token from AWS SSM. Exiting."
   exit 1
fi

# Install K3s as a worker node and join it to the cluster (Control Plane)
# Explicitly pass agent arguments for Docker runtime.
echo "[INFO] Executing K3s join command..."
curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - agent --docker || { echo "[ERROR] K3s worker node agent failed"; exit 1; }

echo "[SUCCESS] Worker joined cluster successfully."

exit 0 # Explicitly exit with success
