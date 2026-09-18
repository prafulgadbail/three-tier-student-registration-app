#!/bin/bash

set -euo pipefail

# ============================================================
# Metrics Server - EKS Platform Component
#
# Purpose:
#   Install/update and verify Metrics Server.
#
# Provides:
#   - Kubernetes Metrics API
#   - kubectl top nodes
#   - kubectl top pods
#   - HPA resource metrics
#
# Scope:
#   Cluster-level only.
#
# Application-specific configuration is NOT used here.
#
# Safe to run:
#   - New EKS cluster
#   - Existing EKS cluster
#   - Multiple times
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

METRICS_SERVER_VERSION="v0.9.0"

NAMESPACE="kube-system"
DEPLOYMENT_NAME="metrics-server"
SERVICE_NAME="metrics-server"
API_SERVICE_NAME="v1beta1.metrics.k8s.io"

MANIFEST_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

echo "=========================================="
echo " METRICS SERVER SETUP"
echo "=========================================="

# ------------------------------------------------------------
# 1. Check required commands
# ------------------------------------------------------------

for CMD in aws kubectl curl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $CMD"
        exit 1
    fi
done

echo "Required commands: OK"

# ------------------------------------------------------------
# 2. Verify EKS cluster
# ------------------------------------------------------------

echo
echo "Checking EKS cluster..."

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text)"

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Status: $CLUSTER_STATUS"
    exit 1
fi

echo "Cluster: $CLUSTER_NAME"
echo "Region : $AWS_REGION"
echo "Status : $CLUSTER_STATUS"

# ------------------------------------------------------------
# 3. Update kubeconfig
# ------------------------------------------------------------

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    >/dev/null

kubectl cluster-info >/dev/null

echo "Kubernetes API: OK"

# ------------------------------------------------------------
# 4. Download official Metrics Server manifest
# ------------------------------------------------------------

TEMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TEMP_DIR"' EXIT

MANIFEST_FILE="$TEMP_DIR/components.yaml"

echo
echo "Downloading Metrics Server ${METRICS_SERVER_VERSION}..."

curl -fsSL \
    --retry 3 \
    --retry-delay 2 \
    "$MANIFEST_URL" \
    -o "$MANIFEST_FILE"

if [ ! -s "$MANIFEST_FILE" ]; then
    echo "ERROR: Metrics Server manifest download failed."
    exit 1
fi

echo "Manifest downloaded successfully."

# ------------------------------------------------------------
# 5. Apply official manifest
#
# Do NOT delete existing Metrics Server resources.
# kubectl apply reconciles the existing installation.
# ------------------------------------------------------------

echo
echo "Applying Metrics Server manifest..."

kubectl apply -f "$MANIFEST_FILE"

echo "Metrics Server manifest applied."

# ------------------------------------------------------------
# 6. Configure kubelet connectivity
#
# EKS worker nodes expose InternalIP and the kubelet
# certificate may not be trusted by Metrics Server.
#
# InternalIP is preferred because it is the node's
# private cluster-reachable address.
# ------------------------------------------------------------

echo
echo "Configuring Metrics Server kubelet connectivity..."

kubectl patch deployment "$DEPLOYMENT_NAME" \
    -n "$NAMESPACE" \
    --type='strategic' \
    -p '{
      "spec": {
        "template": {
          "spec": {
            "containers": [
              {
                "name": "metrics-server",
                "args": [
                  "--secure-port=10250",
                  "--cert-dir=/tmp",
                  "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP",
                  "--kubelet-use-node-status-port",
                  "--kubelet-insecure-tls"
                ]
              }
            ]
          }
        }
      }
    }'

echo "Metrics Server kubelet configuration updated."

# ------------------------------------------------------------
# 7. Wait for rollout
# ------------------------------------------------------------

echo
echo "Waiting for Metrics Server rollout..."

kubectl rollout status \
    deployment/"$DEPLOYMENT_NAME" \
    -n "$NAMESPACE" \
    --timeout=5m

# ------------------------------------------------------------
# 8. Verify service
# ------------------------------------------------------------

echo
echo "Checking Metrics Server service..."

kubectl get service "$SERVICE_NAME" \
    -n "$NAMESPACE"

# ------------------------------------------------------------
# 9. Verify service endpoints
# ------------------------------------------------------------

echo
echo "Checking Metrics Server endpoints..."

for ATTEMPT in {1..30}; do

    ENDPOINTS="$(kubectl get endpoints "$SERVICE_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"

    if [ -n "$ENDPOINTS" ]; then
        echo "Metrics Server endpoints: $ENDPOINTS"
        break
    fi

    if [ "$ATTEMPT" -eq 30 ]; then
        echo "ERROR: Metrics Server has no service endpoints."
        kubectl get pods -n "$NAMESPACE" -l k8s-app=metrics-server
        kubectl describe service "$SERVICE_NAME" -n "$NAMESPACE"
        exit 1
    fi

    sleep 5
done

# ------------------------------------------------------------
# 10. Verify Metrics API
# ------------------------------------------------------------

echo
echo "Checking Metrics API..."

for ATTEMPT in {1..30}; do

    API_STATUS="$(kubectl get apiservice "$API_SERVICE_NAME" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
        2>/dev/null || true)"

    if [ "$API_STATUS" = "True" ]; then
        echo "Metrics API: Available"
        break
    fi

    if [ "$ATTEMPT" -eq 30 ]; then
        echo "ERROR: Metrics API is not available."
        kubectl describe apiservice "$API_SERVICE_NAME"
        exit 1
    fi

    sleep 5
done

# ------------------------------------------------------------
# 11. Verify kubectl top nodes
# ------------------------------------------------------------

echo
echo "Checking node metrics..."

if ! kubectl top nodes; then
    echo "ERROR: kubectl top nodes failed."
    exit 1
fi

# ------------------------------------------------------------
# 12. Verify pod metrics
# ------------------------------------------------------------

echo
echo "Checking pod metrics..."

if ! kubectl top pods -A >/dev/null; then
    echo "ERROR: kubectl top pods failed."
    exit 1
fi

echo "Pod metrics: Available"

# ------------------------------------------------------------
# 13. Final verification
# ------------------------------------------------------------

echo
echo "=========================================="
echo " METRICS SERVER READY"
echo "=========================================="

echo
echo "Version:"
echo "$METRICS_SERVER_VERSION"

echo
echo "Deployment:"
kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE"

echo
echo "Pods:"
kubectl get pods \
    -n "$NAMESPACE" \
    -l k8s-app=metrics-server \
    -o wide

echo
echo "APIService:"
kubectl get apiservice "$API_SERVICE_NAME"

echo
echo "Node metrics:"
kubectl top nodes

echo
echo "Metrics Server setup completed successfully."
