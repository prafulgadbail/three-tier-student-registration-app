#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.env not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

: "${CLUSTER_NAME:?CLUSTER_NAME is required in config.env}"
: "${AWS_REGION:?AWS_REGION is required in config.env}"

RELEASE_NAME="reloader"
NAMESPACE="reloader"
CHART_REPO_NAME="stakater"
CHART_REPO_URL="https://stakater.github.io/Reloader"
CHART_NAME="stakater/reloader"

echo
echo "=============================================="
echo " Reloader Setup"
echo "=============================================="
echo "Cluster   : ${CLUSTER_NAME}"
echo "Region    : ${AWS_REGION}"
echo "Namespace : ${NAMESPACE}"
echo "Release   : ${RELEASE_NAME}"
echo "=============================================="

# ------------------------------------------------------------
# Check required commands
# ------------------------------------------------------------

echo
echo "Checking required commands..."

for cmd in aws kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

echo "Required commands: OK"

# ------------------------------------------------------------
# Validate AWS access
# ------------------------------------------------------------

echo
echo "Checking AWS credentials..."

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "ERROR: AWS credentials are not working."
    exit 1
fi

echo "AWS identity: OK"

# ------------------------------------------------------------
# Validate EKS cluster
# ------------------------------------------------------------

echo
echo "Checking EKS cluster..."

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster status is ${CLUSTER_STATUS}"
    exit 1
fi

echo "EKS cluster: ACTIVE"

# ------------------------------------------------------------
# Configure kubectl
# ------------------------------------------------------------

echo
echo "Updating kubeconfig..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    >/dev/null

kubectl cluster-info >/dev/null

echo "Kubernetes access: OK"

# ------------------------------------------------------------
# Configure Helm repository
# ------------------------------------------------------------

echo
echo "Checking Helm repository..."

if helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "$CHART_REPO_NAME"; then
    echo "Helm repository already exists."
else
    echo "Adding Stakater Helm repository..."

    helm repo add \
        "$CHART_REPO_NAME" \
        "$CHART_REPO_URL" \
        >/dev/null

    echo "Helm repository added."
fi

helm repo update >/dev/null

echo "Helm repository updated."

# ------------------------------------------------------------
# Check chart availability
# ------------------------------------------------------------

echo
echo "Checking Reloader chart..."

CHART_SEARCH_OUTPUT="$(
    helm search repo "$CHART_NAME" --versions 2>/dev/null
)"

CHART_VERSION="$(
    printf '%s\n' "$CHART_SEARCH_OUTPUT" |
    awk 'NR == 2 {print $2}'
)"

APP_VERSION="$(
    printf '%s\n' "$CHART_SEARCH_OUTPUT" |
    awk 'NR == 2 {print $3}'
)"

if [[ -z "$CHART_VERSION" ]]; then
    echo "ERROR: Reloader chart is not available."
    exit 1
fi

echo "Chart version: ${CHART_VERSION}"
echo "App version  : ${APP_VERSION}"

# ------------------------------------------------------------
# Check existing Helm release
# ------------------------------------------------------------

echo
echo "Checking existing Helm release..."

if helm status "$RELEASE_NAME" \
    -n "$NAMESPACE" >/dev/null 2>&1; then

    echo "Helm release already exists."

    CURRENT_CHART="$(
        helm list \
            -n "$NAMESPACE" \
            --filter "^${RELEASE_NAME}$" \
            -o json |
        awk -F'"' '/"chart":/ {print $4; exit}'
    )"

    echo "Current release chart: ${CURRENT_CHART:-unknown}"

else
    echo "Helm release does not exist."
fi

# ------------------------------------------------------------
# Install / upgrade Reloader
# ------------------------------------------------------------

echo
echo "Installing/upgrading Reloader..."

helm upgrade --install "$RELEASE_NAME" \
    "$CHART_NAME" \
    --version "$CHART_VERSION" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --set reloader.watchGlobally=true \
    --wait \
    --timeout 10m

echo
echo "Helm installation completed."

# ------------------------------------------------------------
# Wait for deployment
# ------------------------------------------------------------

echo
echo "Checking Reloader deployment..."

DEPLOYMENT_NAME="$(
    kubectl get deployments \
        -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' \
        2>/dev/null || true
)"

if [[ -z "$DEPLOYMENT_NAME" ]]; then
    echo "ERROR: Reloader deployment not found."
    kubectl get deployments -n "$NAMESPACE" || true
    exit 1
fi

kubectl rollout status \
    deployment/"$DEPLOYMENT_NAME" \
    -n "$NAMESPACE" \
    --timeout=5m

echo "Deployment successfully rolled out."

# ------------------------------------------------------------
# Verify pod
# ------------------------------------------------------------

echo
echo "Checking Reloader pods..."

kubectl get pods \
    -n "$NAMESPACE" \
    -o wide

READY_PODS="$(
    kubectl get pods \
        -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' |
    grep -c '^true$' || true
)"

if [[ "$READY_PODS" -lt 1 ]]; then
    echo "ERROR: Reloader pod is not Ready."
    exit 1
fi

echo "Ready pods: ${READY_PODS}"

# ------------------------------------------------------------
# Verify deployment
# ------------------------------------------------------------

echo
echo "Reloader deployment:"

kubectl get deployment \
    "$DEPLOYMENT_NAME" \
    -n "$NAMESPACE"

# ------------------------------------------------------------
# Verify Helm release
# ------------------------------------------------------------

echo
echo "Helm release:"

helm list \
    -n "$NAMESPACE" \
    --filter "^${RELEASE_NAME}$"

echo
echo "=============================================="
echo " RELOADER SETUP COMPLETED"
echo "=============================================="
echo "Namespace : ${NAMESPACE}"
echo "Release   : ${RELEASE_NAME}"
echo "Chart     : ${CHART_VERSION}"
echo "App       : ${APP_VERSION}"
echo "Global    : Enabled"
echo "=============================================="