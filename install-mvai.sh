#!/bin/bash
# set -xe
# Validate environment variables
if [ -z "$MEMVERGE_VERSION" ] || [ -z "$MEMVERGE_SUBDOMAIN" ] || [ -z "$MEMVERGE_GITHUB_TOKEN" ]; then
    echo "[ERROR] Missing required environment variables. Exiting."
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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
helm registry logout ghcr.io/memverge || true
helm registry login ghcr.io/memverge -u mv-customer-support -p $MEMVERGE_GITHUB_TOKEN
if [ $? -ne 0 ]; then
    echo "[ERROR] Helm login failed. Exiting."
    exit 1
fi

kubectl create namespace cattle-system || true
kubectl create secret generic memverge-dockerconfig --namespace cattle-system \
    --from-file=.dockerconfigjson=$HOME/.config/helm/registry/config.json \
    --type=kubernetes.io/dockerconfigjson || true

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
