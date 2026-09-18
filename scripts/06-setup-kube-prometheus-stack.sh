#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.env not found."
    exit 1
fi

source "$CONFIG_FILE"

: "${CLUSTER_NAME:?CLUSTER_NAME is not set in config.env}"
: "${AWS_REGION:?AWS_REGION is not set in config.env}"

HELM_REPO_NAME="prometheus-community"
HELM_REPO_URL="https://prometheus-community.github.io/helm-charts"

RELEASE_NAME="kube-prometheus-stack"
NAMESPACE="monitoring"
CHART_NAME="${HELM_REPO_NAME}/kube-prometheus-stack"

echo "=========================================="
echo " KUBE PROMETHEUS STACK SETUP"
echo "=========================================="
echo

# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------
echo "Checking required commands..."

for cmd in aws kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

echo "Required commands: OK"
echo

# ------------------------------------------------------------
# AWS identity
# ------------------------------------------------------------
echo "Checking AWS identity..."

AWS_ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo

# ------------------------------------------------------------
# EKS cluster validation
# ------------------------------------------------------------
echo "Checking EKS cluster..."

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Status: ${CLUSTER_STATUS}"
    exit 1
fi

K8S_VERSION="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text)"

echo "Cluster: ${CLUSTER_NAME}"
echo "Region : ${AWS_REGION}"
echo "Status : ${CLUSTER_STATUS}"
echo "K8s    : ${K8S_VERSION}"
echo

# ------------------------------------------------------------
# Kubernetes connectivity
# ------------------------------------------------------------
echo "Updating kubeconfig..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    >/dev/null

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API is not reachable."
    exit 1
fi

echo "Kubernetes API: OK"
echo

# ------------------------------------------------------------
# Helm repository
# ------------------------------------------------------------
echo "Checking Prometheus Community Helm repository..."

if helm repo list | awk 'NR > 1 {print $1}' | grep -qx "$HELM_REPO_NAME"; then
    echo "Helm repository already exists."
else
    echo "Adding Helm repository..."

    helm repo add \
        "$HELM_REPO_NAME" \
        "$HELM_REPO_URL" \
        >/dev/null

    echo "Helm repository added."
fi

echo
echo "Updating Helm repository..."

helm repo update "$HELM_REPO_NAME" >/dev/null

echo "Helm repository updated."
echo

# ------------------------------------------------------------
# Chart discovery
# ------------------------------------------------------------
echo "Checking kube-prometheus-stack chart..."

CHART_SEARCH_OUTPUT="$(
    helm search repo "$CHART_NAME" --versions 2>/dev/null
)"

if [[ -z "$CHART_SEARCH_OUTPUT" ]]; then
    echo "ERROR: kube-prometheus-stack chart is not available."
    exit 1
fi

CHART_VERSION="$(
    printf '%s\n' "$CHART_SEARCH_OUTPUT" |
    awk 'NR == 2 {print $2}'
)"

APP_VERSION="$(
    printf '%s\n' "$CHART_SEARCH_OUTPUT" |
    awk 'NR == 2 {print $3}'
)"

if [[ -z "$CHART_VERSION" ]]; then
    echo "ERROR: Unable to determine kube-prometheus-stack chart version."
    exit 1
fi

echo "Chart version: ${CHART_VERSION}"
echo "App version  : ${APP_VERSION}"
echo

# ------------------------------------------------------------
# Existing release check
# ------------------------------------------------------------
echo "Checking existing Helm release..."

if helm status "$RELEASE_NAME" \
    --namespace "$NAMESPACE" >/dev/null 2>&1; then

    echo "Helm release already exists."

    CURRENT_REVISION="$(
        helm list \
            --namespace "$NAMESPACE" \
            --filter "^${RELEASE_NAME}$" |
        awk 'NR == 2 {print $3}'
    )"

    echo "Current revision: ${CURRENT_REVISION:-unknown}"
else
    echo "Helm release does not exist."
fi

echo

# ------------------------------------------------------------
# Install or upgrade
# ------------------------------------------------------------
echo "Installing/upgrading kube-prometheus-stack..."

helm upgrade --install "$RELEASE_NAME" \
    "$CHART_NAME" \
    --version "$CHART_VERSION" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --set grafana.enabled=true \
    --set alertmanager.enabled=true \
    --set kubeStateMetrics.enabled=true \
    --set nodeExporter.enabled=true \
    --set prometheusOperator.enabled=true \
    --wait \
    --timeout 10m

echo
echo "Helm installation completed."
echo

# ------------------------------------------------------------
# Deployment verification
# ------------------------------------------------------------
echo "Checking monitoring deployments..."

kubectl get deployments \
    --namespace "$NAMESPACE"

echo

# ------------------------------------------------------------
# Pod verification
# ------------------------------------------------------------
echo "Checking monitoring pods..."

kubectl get pods \
    --namespace "$NAMESPACE"

echo

# ------------------------------------------------------------
# Service verification
# ------------------------------------------------------------
echo "Checking monitoring services..."

kubectl get svc \
    --namespace "$NAMESPACE"

echo

# ------------------------------------------------------------
# Helm verification
# ------------------------------------------------------------
echo "Checking Helm release..."

helm list \
    --namespace "$NAMESPACE" \
    --filter "^${RELEASE_NAME}$"

echo

# ------------------------------------------------------------
# Final release status
# ------------------------------------------------------------
RELEASE_STATUS="$(
    helm status "$RELEASE_NAME" \
        --namespace "$NAMESPACE" |
    awk -F': ' '/^STATUS:/ {print $2}'
)"

if [[ "$RELEASE_STATUS" != "deployed" ]]; then
    echo "ERROR: Helm release is not deployed."
    echo "Status: ${RELEASE_STATUS:-unknown}"
    exit 1
fi

echo "=========================================="
echo " KUBE PROMETHEUS STACK SETUP COMPLETED"
echo "=========================================="
echo
echo "Namespace    : ${NAMESPACE}"
echo "Release      : ${RELEASE_NAME}"
echo "Chart        : ${CHART_VERSION}"
echo "App version  : ${APP_VERSION}"
echo
echo "Prometheus        : Enabled"
echo "Grafana           : Enabled"
echo "Alertmanager      : Enabled"
echo "Node Exporter     : Enabled"
echo "Kube State Metrics: Enabled"
echo "Prometheus Operator: Enabled"
echo

