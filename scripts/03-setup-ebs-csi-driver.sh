#!/bin/bash

set -euo pipefail

# ============================================================
# Amazon EBS CSI Driver - EKS Platform Component
#
# Purpose:
#   Install or reconcile the Amazon EBS CSI Driver as an
#   Amazon EKS managed add-on.
#
# Scope:
#   Cluster-level only.
#
# Behavior:
#   - Reuses existing EBS CSI add-on
#   - Detects compatible version automatically
#   - Reuses existing IAM role
#   - Creates IAM role only when required
#   - Safe to run multiple times
#   - No unnecessary deletion
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

ADDON_NAME="aws-ebs-csi-driver"

IAM_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
IAM_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

SERVICE_ACCOUNT_NAME="ebs-csi-controller-sa"
SERVICE_ACCOUNT_NAMESPACE="kube-system"

echo "=========================================="
echo " EBS CSI DRIVER SETUP"
echo "=========================================="

# ------------------------------------------------------------
# 1. Required commands
# ------------------------------------------------------------

for CMD in aws kubectl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi
done

echo "Required commands: OK"

# ------------------------------------------------------------
# 2. Verify cluster
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
# 4. Detect Kubernetes version
# ------------------------------------------------------------

K8S_VERSION="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text)"

echo
echo "Kubernetes version: $K8S_VERSION"

# ------------------------------------------------------------
# 5. Detect compatible EBS CSI version
# ------------------------------------------------------------

echo
echo "Detecting compatible EBS CSI Driver version..."

EBS_CSI_VERSION="$(
    aws eks describe-addon-versions \
        --addon-name "$ADDON_NAME" \
        --kubernetes-version "$K8S_VERSION" \
        --region "$AWS_REGION" \
        --query 'addons[0].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0]' \
        --output text
)"

if [ -z "$EBS_CSI_VERSION" ] || [ "$EBS_CSI_VERSION" = "None" ]; then
    echo "ERROR: No compatible EBS CSI version found."
    exit 1
fi

echo "Compatible version: $EBS_CSI_VERSION"

# ------------------------------------------------------------
# 6. Get AWS account ID
# ------------------------------------------------------------

ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

# ------------------------------------------------------------
# 7. Check existing IAM role
# ------------------------------------------------------------

echo
echo "Checking IAM role..."

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    >/dev/null 2>&1; then

    echo "IAM role already exists."
    echo "IAM role: $IAM_ROLE_NAME"

else

    echo "IAM role does not exist."
    echo "Creating IAM role..."

    OIDC_ISSUER="$(
        aws eks describe-cluster \
            --name "$CLUSTER_NAME" \
            --region "$AWS_REGION" \
            --query 'cluster.identity.oidc.issuer' \
            --output text
    )"

    OIDC_PROVIDER="${OIDC_ISSUER#https://}"

    OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

    if ! aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
        >/dev/null 2>&1; then

        echo "ERROR: EKS OIDC provider does not exist."
        exit 1
    fi

    TRUST_POLICY_FILE="$(mktemp)"

    cat > "$TRUST_POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
        --description "IAM role for Amazon EKS EBS CSI Driver" \
        >/dev/null

    rm -f "$TRUST_POLICY_FILE"

    echo "IAM role created."
fi

# ------------------------------------------------------------
# 8. Ensure IAM policy is attached
# ------------------------------------------------------------

echo
echo "Checking IAM policy attachment..."

POLICY_ATTACHED="$(
    aws iam list-attached-role-policies \
        --role-name "$IAM_ROLE_NAME" \
        --query "AttachedPolicies[?PolicyArn=='${IAM_POLICY_ARN}'].PolicyArn" \
        --output text
)"

if [ "$POLICY_ATTACHED" = "$IAM_POLICY_ARN" ]; then

    echo "IAM policy already attached."

else

    echo "Attaching EBS CSI IAM policy..."

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$IAM_POLICY_ARN"

    echo "IAM policy attached."
fi

# ------------------------------------------------------------
# 9. Check EKS add-on
# ------------------------------------------------------------

echo
echo "Checking EKS EBS CSI add-on..."

if aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1; then

    CURRENT_VERSION="$(
        aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$ADDON_NAME" \
            --region "$AWS_REGION" \
            --query 'addon.addonVersion' \
            --output text
    )"

    CURRENT_STATUS="$(
        aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$ADDON_NAME" \
            --region "$AWS_REGION" \
            --query 'addon.status' \
            --output text
    )"

    echo "Add-on already exists."
    echo "Current version: $CURRENT_VERSION"
    echo "Current status : $CURRENT_STATUS"

    # Only update when version is different.
    if [ "$CURRENT_VERSION" != "$EBS_CSI_VERSION" ]; then

        echo
        echo "Updating EBS CSI add-on..."

        aws eks update-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$ADDON_NAME" \
            --addon-version "$EBS_CSI_VERSION" \
            --service-account-role-arn "$IAM_ROLE_ARN" \
            --resolve-conflicts OVERWRITE \
            --region "$AWS_REGION" \
            >/dev/null

        echo "Add-on update started."

    else

        echo
        echo "EBS CSI version already matches."
        echo "No add-on update required."

    fi

else

    echo "EBS CSI add-on does not exist."
    echo "Creating EKS managed add-on..."

    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$ADDON_NAME" \
        --addon-version "$EBS_CSI_VERSION" \
        --service-account-role-arn "$IAM_ROLE_ARN" \
        --resolve-conflicts OVERWRITE \
        --region "$AWS_REGION" \
        >/dev/null

    echo "Add-on creation started."
fi

# ------------------------------------------------------------
# 10. Wait for ACTIVE status
# ------------------------------------------------------------

echo
echo "Waiting for EBS CSI add-on to become ACTIVE..."

for ATTEMPT in {1..60}; do

    STATUS="$(
        aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$ADDON_NAME" \
            --region "$AWS_REGION" \
            --query 'addon.status' \
            --output text 2>/dev/null || true
    )"

    if [ "$STATUS" = "ACTIVE" ]; then
        echo "EBS CSI add-on: ACTIVE"
        break
    fi

    if [ "$STATUS" = "CREATE_FAILED" ] ||
       [ "$STATUS" = "UPDATE_FAILED" ]; then

        echo "ERROR: EBS CSI add-on failed."
        exit 1
    fi

    if [ "$ATTEMPT" -eq 60 ]; then
        echo "ERROR: Timed out waiting for EBS CSI add-on."
        exit 1
    fi

    sleep 10
done

# ------------------------------------------------------------
# 11. Verify CSIDriver
# ------------------------------------------------------------

echo
echo "Checking CSIDriver..."

if ! kubectl get csidriver ebs.csi.aws.com >/dev/null 2>&1; then
    echo "ERROR: ebs.csi.aws.com CSIDriver not found."
    exit 1
fi

kubectl get csidriver ebs.csi.aws.com

# ------------------------------------------------------------
# 12. Verify controller pods
# ------------------------------------------------------------

echo
echo "Checking EBS CSI pods..."

kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=aws-ebs-csi-driver \
    -o wide

# ------------------------------------------------------------
# 13. Final verification
# ------------------------------------------------------------

echo
echo "=========================================="
echo " EBS CSI DRIVER READY"
echo "=========================================="

aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --region "$AWS_REGION" \
    --query 'addon.{Name:addonName,Version:addonVersion,Status:status}' \
    --output table

echo
echo "CSIDriver:"
kubectl get csidriver ebs.csi.aws.com

echo
echo "EBS CSI pods:"
kubectl get pods \
    -n kube-system \
    -l app.kubernetes.io/name=aws-ebs-csi-driver \
    -o wide

echo
echo "EBS CSI Driver setup completed successfully."