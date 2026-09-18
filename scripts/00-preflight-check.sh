#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

echo "=========================================="
echo " EKS PLATFORM PREFLIGHT CHECK"
echo "=========================================="

for CMD in aws kubectl helm curl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi

    echo "OK: $CMD"
done

echo
echo "Checking AWS identity..."

AWS_ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

AWS_ARN="$(aws sts get-caller-identity \
    --query Arn \
    --output text)"

echo "AWS Account : $AWS_ACCOUNT_ID"
echo "AWS Identity: $AWS_ARN"

echo
echo "Checking EKS cluster..."

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text)"

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
    echo "ERROR: EKS cluster status is $CLUSTER_STATUS"
    exit 1
fi

echo "Cluster: $CLUSTER_NAME"
echo "Region : $AWS_REGION"
echo "Status : $CLUSTER_STATUS"

echo
echo "Updating kubeconfig..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION"

echo
echo "Checking Kubernetes API..."

kubectl cluster-info >/dev/null

echo "Kubernetes API: OK"

echo
echo "Cluster nodes:"

kubectl get nodes -o wide

echo
echo "Kubernetes version:"

kubectl version

echo
echo "=========================================="
echo " PREFLIGHT CHECK PASSED"
echo "=========================================="
