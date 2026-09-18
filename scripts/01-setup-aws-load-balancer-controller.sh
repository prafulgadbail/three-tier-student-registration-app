#!/bin/bash

set -euo pipefail

# ============================================================
# AWS Load Balancer Controller - EKS Platform Component
#
# Purpose:
#   Install and verify AWS Load Balancer Controller.
#
# Scope:
#   Cluster-level only.
#
# This script does NOT know:
#   - application name
#   - application namespace
#   - ECR repository
#   - application ingress hostname
#   - frontend/backend
#
# Safe to run:
#   - on a new EKS cluster
#   - on an existing EKS cluster
#   - multiple times on the same cluster
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

CONTROLLER_VERSION="v2.14.1"

CONTROLLER_NAMESPACE="kube-system"
SERVICE_ACCOUNT="aws-load-balancer-controller"
IAM_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
IAM_ROLE_NAME="AmazonEKSLoadBalancerControllerRole"

CHART_REPO="https://aws.github.io/eks-charts"
RELEASE_NAME="aws-load-balancer-controller"
CHART_NAME="eks/aws-load-balancer-controller"

IAM_POLICY_URL="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${CONTROLLER_VERSION}/docs/install/iam_policy.json"

echo "=========================================="
echo " AWS LOAD BALANCER CONTROLLER SETUP"
echo "=========================================="

# ------------------------------------------------------------
# 1. Check required commands
# ------------------------------------------------------------

for CMD in aws kubectl helm curl openssl; do
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

echo "Cluster : $CLUSTER_NAME"
echo "Region  : $AWS_REGION"
echo "Status  : $CLUSTER_STATUS"

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
# 4. Get AWS account information
# ------------------------------------------------------------

AWS_ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

echo "AWS Account: $AWS_ACCOUNT_ID"

# ------------------------------------------------------------
# 5. Detect EKS VPC
# ------------------------------------------------------------

VPC_ID="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)"

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    echo "ERROR: Unable to detect EKS VPC."
    exit 1
fi

echo "EKS VPC: $VPC_ID"

# ------------------------------------------------------------
# 6. Detect OIDC provider
# ------------------------------------------------------------

OIDC_ISSUER="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.identity.oidc.issuer' \
    --output text)"

if [ -z "$OIDC_ISSUER" ] || [ "$OIDC_ISSUER" = "None" ]; then
    echo "ERROR: EKS OIDC issuer not available."
    exit 1
fi

OIDC_PROVIDER="${OIDC_ISSUER#https://}"

echo "OIDC Provider: $OIDC_PROVIDER"

# ------------------------------------------------------------
# 7. Check IAM OIDC provider
# ------------------------------------------------------------

echo
echo "Checking IAM OIDC provider..."

OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_ARN" \
    >/dev/null 2>&1; then

    echo "OIDC provider already exists."

else

    echo "OIDC provider does not exist."

    echo
    echo "ERROR: IAM OIDC provider is required."
    echo
    echo "Create it using your AWS/EKS infrastructure setup, then"
    echo "run this script again."
    echo

    exit 1
fi

# ------------------------------------------------------------
# 8. Download IAM policy
# ------------------------------------------------------------

TEMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TEMP_DIR"' EXIT

IAM_POLICY_FILE="$TEMP_DIR/iam_policy.json"

echo
echo "Downloading AWS Load Balancer Controller IAM policy..."

curl -fsSL \
    --retry 3 \
    --retry-delay 2 \
    "$IAM_POLICY_URL" \
    -o "$IAM_POLICY_FILE"

if [ ! -s "$IAM_POLICY_FILE" ]; then
    echo "ERROR: IAM policy download failed."
    exit 1
fi

echo "IAM policy downloaded."

# ------------------------------------------------------------
# 9. Create or verify IAM policy
# ------------------------------------------------------------

echo
echo "Checking IAM policy..."

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    >/dev/null 2>&1; then

    echo "IAM policy already exists:"
    echo "$POLICY_ARN"

else

    echo "Creating IAM policy..."

    aws iam create-policy \
        --policy-name "$IAM_POLICY_NAME" \
        --policy-document "file://$IAM_POLICY_FILE" \
        >/dev/null

    echo "IAM policy created."
fi

# ------------------------------------------------------------
# 10. Create IAM trust policy
# ------------------------------------------------------------

TRUST_POLICY_FILE="$TEMP_DIR/trust-policy.json"

cat > "$TRUST_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${CONTROLLER_NAMESPACE}:${SERVICE_ACCOUNT}"
        }
      }
    }
  ]
}
EOF

# ------------------------------------------------------------
# 11. Create or verify IAM role
# ------------------------------------------------------------

echo
echo "Checking IAM role..."

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    >/dev/null 2>&1; then

    echo "IAM role already exists."

else

    echo "Creating IAM role..."

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "file://$TRUST_POLICY_FILE" \
        >/dev/null

    echo "IAM role created."
fi

# ------------------------------------------------------------
# 12. Reconcile IAM trust policy
# ------------------------------------------------------------

echo
echo "Updating IAM trust relationship..."

aws iam update-assume-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-document "file://$TRUST_POLICY_FILE"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

echo "IAM Role:"
echo "$ROLE_ARN"

# ------------------------------------------------------------
# 13. Attach IAM policy to role
# ------------------------------------------------------------

echo
echo "Ensuring IAM policy is attached..."

if aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyArn" \
    --output text | grep -q "$POLICY_ARN"; then

    echo "IAM policy already attached."

else

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$POLICY_ARN"

    echo "IAM policy attached."
fi

# ------------------------------------------------------------
# 14. Create/update Kubernetes ServiceAccount
# ------------------------------------------------------------

echo
echo "Configuring Kubernetes ServiceAccount..."

kubectl create serviceaccount \
    "$SERVICE_ACCOUNT" \
    --namespace "$CONTROLLER_NAMESPACE" \
    --dry-run=client \
    -o yaml | kubectl apply -f -

kubectl annotate serviceaccount \
    "$SERVICE_ACCOUNT" \
    --namespace "$CONTROLLER_NAMESPACE" \
    "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
    --overwrite

echo "ServiceAccount configured."

# ------------------------------------------------------------
# 15. Add/update Helm repository
# ------------------------------------------------------------

echo
echo "Configuring AWS EKS Helm repository..."

helm repo add eks "$CHART_REPO" >/dev/null 2>&1 || true

helm repo update

# ------------------------------------------------------------
# 16. Install or upgrade AWS Load Balancer Controller
# ------------------------------------------------------------

echo
echo "Installing/upgrading AWS Load Balancer Controller..."

helm upgrade --install \
    "$RELEASE_NAME" \
    "$CHART_NAME" \
    --namespace "$CONTROLLER_NAMESPACE" \
    --set clusterName="$CLUSTER_NAME" \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="$SERVICE_ACCOUNT" \
    --wait \
    --timeout 10m

# ------------------------------------------------------------
# 17. Verify deployment rollout
# ------------------------------------------------------------

echo
echo "Waiting for controller rollout..."

kubectl rollout status \
    deployment/"$RELEASE_NAME" \
    --namespace "$CONTROLLER_NAMESPACE" \
    --timeout=5m

# ------------------------------------------------------------
# 18. Verify pods
# ------------------------------------------------------------

echo
echo "Controller pods:"

kubectl get pods \
    --namespace "$CONTROLLER_NAMESPACE" \
    -l app.kubernetes.io/name=aws-load-balancer-controller \
    -o wide

# ------------------------------------------------------------
# 19. Verify ServiceAccount annotation
# ------------------------------------------------------------

echo
echo "Verifying ServiceAccount IAM role..."

ANNOTATION="$(kubectl get serviceaccount \
    "$SERVICE_ACCOUNT" \
    --namespace "$CONTROLLER_NAMESPACE" \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')"

if [ "$ANNOTATION" != "$ROLE_ARN" ]; then
    echo "ERROR: ServiceAccount IAM role annotation is incorrect."
    echo "Expected: $ROLE_ARN"
    echo "Actual  : $ANNOTATION"
    exit 1
fi

echo "ServiceAccount IAM role: OK"

# ------------------------------------------------------------
# 20. Verify controller deployment
# ------------------------------------------------------------

READY_REPLICAS="$(kubectl get deployment \
    "$RELEASE_NAME" \
    --namespace "$CONTROLLER_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}')"

DESIRED_REPLICAS="$(kubectl get deployment \
    "$RELEASE_NAME" \
    --namespace "$CONTROLLER_NAMESPACE" \
    -o jsonpath='{.spec.replicas}')"

if [ "${READY_REPLICAS:-0}" != "$DESIRED_REPLICAS" ]; then
    echo "ERROR: Controller replicas are not fully ready."
    echo "Ready   : ${READY_REPLICAS:-0}"
    echo "Desired : $DESIRED_REPLICAS"
    exit 1
fi

# ------------------------------------------------------------
# 21. Final verification
# ------------------------------------------------------------

echo
echo "=========================================="
echo " AWS LOAD BALANCER CONTROLLER READY"
echo "=========================================="

echo
echo "Version:"
echo "$CONTROLLER_VERSION"

echo
echo "Cluster:"
echo "$CLUSTER_NAME"

echo
echo "Region:"
echo "$AWS_REGION"

echo
echo "VPC:"
echo "$VPC_ID"

echo
echo "IAM Role:"
echo "$ROLE_ARN"

echo
echo "Controller:"
kubectl get deployment \
    "$RELEASE_NAME" \
    --namespace "$CONTROLLER_NAMESPACE"

echo
echo "ServiceAccount:"
kubectl get serviceaccount \
    "$SERVICE_ACCOUNT" \
    --namespace "$CONTROLLER_NAMESPACE"

echo
echo "Setup completed successfully."
