#!/bin/bash

set -euo pipefail

# ============================================================
# Cluster Autoscaler Setup
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.env not found."
    exit 1
fi

source "$CONFIG_FILE"

: "${CLUSTER_NAME:?CLUSTER_NAME is not set in config.env}"
: "${AWS_REGION:?AWS_REGION is not set in config.env}"

NAMESPACE="kube-system"
RELEASE_NAME="cluster-autoscaler"

HELM_REPO_NAME="autoscaler"
HELM_REPO_URL="https://kubernetes.github.io/autoscaler"

# Current Cluster Autoscaler release for Kubernetes 1.36.
CA_VERSION="1.36.1"
CHART_VERSION="9.59.0"

IAM_ROLE_NAME="ClusterAutoscalerRole"
IAM_POLICY_NAME="ClusterAutoscalerPolicy"

echo "=========================================="
echo " CLUSTER AUTOSCALER SETUP"
echo "=========================================="
echo

# ============================================================
# Required commands
# ============================================================

echo "Checking required commands..."

for command in aws kubectl helm; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command"
        exit 1
    fi
done

echo "Required commands: OK"
echo

# ============================================================
# AWS identity
# ============================================================

echo "Checking AWS identity..."

AWS_ACCOUNT_ID="$(aws sts get-caller-identity \
    --query 'Account' \
    --output text)"

echo "AWS Account: $AWS_ACCOUNT_ID"
echo

# ============================================================
# EKS cluster
# ============================================================

echo "Checking EKS cluster..."

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Status: $CLUSTER_STATUS"
    exit 1
fi

echo "Cluster: $CLUSTER_NAME"
echo "Region : $AWS_REGION"
echo "Status : $CLUSTER_STATUS"
echo

# ============================================================
# Kubernetes access
# ============================================================

echo "Updating kubeconfig..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" >/dev/null

kubectl cluster-info >/dev/null 2>&1

echo "Kubernetes API: OK"
echo

# ============================================================
# Kubernetes version
# ============================================================

echo "Detecting Kubernetes version..."

K8S_VERSION="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text)"

if [[ -z "$K8S_VERSION" || "$K8S_VERSION" == "None" ]]; then
    echo "ERROR: Unable to detect Kubernetes version."
    exit 1
fi

K8S_MINOR="$(echo "$K8S_VERSION" | cut -d. -f1,2)"

echo "Kubernetes version        : $K8S_VERSION"
echo "Cluster Autoscaler version: v$CA_VERSION"
echo "Helm chart version        : $CHART_VERSION"
echo

# ============================================================
# Compatibility check
# ============================================================

CA_MINOR="$(echo "$CA_VERSION" | cut -d. -f1,2)"

if [[ "$K8S_MINOR" != "$CA_MINOR" ]]; then
    echo "ERROR: Kubernetes and Cluster Autoscaler minor versions do not match."
    echo "Kubernetes : $K8S_MINOR"
    echo "Autoscaler : $CA_MINOR"
    exit 1
fi

echo "Version compatibility: OK"
echo

# ============================================================
# Managed node groups
# ============================================================

echo "Checking EKS managed node groups..."

NODEGROUPS="$(aws eks list-nodegroups \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'nodegroups[]' \
    --output text)"

if [[ -z "$NODEGROUPS" ]]; then
    echo "ERROR: No managed node groups found."
    exit 1
fi

NODEGROUP_COUNT="$(echo "$NODEGROUPS" | wc -w | tr -d ' ')"

echo "Managed node groups found: $NODEGROUP_COUNT"
echo

for NODEGROUP in $NODEGROUPS; do

    echo "Node group: $NODEGROUP"
    echo "---------------------------------------"

    aws eks describe-nodegroup \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP" \
        --region "$AWS_REGION" \
        --query 'nodegroup.scalingConfig' \
        --output table

    echo

done

# ============================================================
# Helm repository
# ============================================================

echo "Checking Cluster Autoscaler Helm repository..."

if helm repo list 2>/dev/null | \
    awk 'NR > 1 {print $1}' | \
    grep -qx "$HELM_REPO_NAME"; then

    echo "Helm repository already exists."

else

    echo "Adding Helm repository..."

    helm repo add \
        "$HELM_REPO_NAME" \
        "$HELM_REPO_URL" >/dev/null

fi

echo
echo "Updating Helm repository..."

if ! timeout 120s helm repo update "$HELM_REPO_NAME" >/dev/null; then
    echo "ERROR: Helm repository update failed or timed out."
    exit 1
fi

echo "Helm repository updated."
echo

# ============================================================
# Existing release check
# ============================================================

echo "Checking existing Cluster Autoscaler release..."

RELEASE_EXISTS="false"

if helm status "$RELEASE_NAME" \
    --namespace "$NAMESPACE" >/dev/null 2>&1; then

    RELEASE_EXISTS="true"
    echo "Helm release already exists."

else

    echo "Helm release does not exist."

fi

echo

# ============================================================
# OIDC provider
# ============================================================

echo "Checking EKS OIDC provider..."

OIDC_ISSUER="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.identity.oidc.issuer' \
    --output text)"

OIDC_PROVIDER="${OIDC_ISSUER#https://}"

OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

echo "OIDC provider: $OIDC_PROVIDER"

if ! aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
    >/dev/null 2>&1; then

    echo "ERROR: IAM OIDC provider not found."
    exit 1
fi

echo "IAM OIDC provider: OK"
echo

# ============================================================
# IAM role
# ============================================================

echo "Checking Cluster Autoscaler IAM role..."

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then

    echo "IAM role already exists."

else

    echo "Creating IAM role..."

    TRUST_POLICY="$(mktemp)"

    cat > "$TRUST_POLICY" <<EOF
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
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${RELEASE_NAME}"
        }
      }
    }
  ]
}
EOF

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "file://${TRUST_POLICY}" \
        >/dev/null

    rm -f "$TRUST_POLICY"

    echo "IAM role created."

fi

echo

# ============================================================
# IAM policy
# ============================================================

echo "Checking Cluster Autoscaler IAM policy..."

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then

    echo "IAM policy already exists."

else

    echo "Creating IAM policy..."

    POLICY_FILE="$(mktemp)"

    cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF

    aws iam create-policy \
        --policy-name "$IAM_POLICY_NAME" \
        --policy-document "file://${POLICY_FILE}" \
        >/dev/null

    rm -f "$POLICY_FILE"

    echo "IAM policy created."

fi

echo

# ============================================================
# IAM policy attachment
# ============================================================

echo "Checking IAM policy attachment..."

ATTACHED_POLICY="$(aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyArn" \
    --output text)"

if [[ "$ATTACHED_POLICY" == "$POLICY_ARN" ]]; then

    echo "IAM policy already attached."

else

    echo "Attaching IAM policy..."

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$POLICY_ARN"

    echo "IAM policy attached."

fi

echo

# ============================================================
# Kubernetes ServiceAccount
# ============================================================

echo "Configuring Kubernetes ServiceAccount..."

kubectl create serviceaccount "$RELEASE_NAME" \
    --namespace "$NAMESPACE" \
    --dry-run=client \
    -o yaml |
kubectl apply -f - >/dev/null

kubectl annotate serviceaccount "$RELEASE_NAME" \
    --namespace "$NAMESPACE" \
    "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
    --overwrite >/dev/null

echo "ServiceAccount configured."
echo

# ============================================================
# Auto Scaling Group discovery tags
# ============================================================

echo "Checking node-group Auto Scaling Groups..."
echo

for NODEGROUP in $NODEGROUPS; do

    ASG_NAME="$(aws eks describe-nodegroup \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP" \
        --region "$AWS_REGION" \
        --query 'nodegroup.resources.autoScalingGroups[0].name' \
        --output text)"

    if [[ -z "$ASG_NAME" || "$ASG_NAME" == "None" ]]; then
        echo "ERROR: Unable to detect ASG for node group: $NODEGROUP"
        exit 1
    fi

    echo "Node group: $NODEGROUP"
    echo "ASG        : $ASG_NAME"

    aws autoscaling create-or-update-tags \
        --tags \
        "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=true" \
        "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/${CLUSTER_NAME},Value=owned,PropagateAtLaunch=true"

    echo

done

echo "Autoscaler discovery tags reconciled."
echo

# ============================================================
# Helm installation / reconciliation
# ============================================================

if [[ "$RELEASE_EXISTS" == "false" ]]; then

    echo "Installing Cluster Autoscaler..."

    if ! helm show chart \
        "$HELM_REPO_NAME/cluster-autoscaler" \
        --version "$CHART_VERSION" >/dev/null 2>&1; then

        echo "ERROR: Helm chart $CHART_VERSION is not available."
        exit 1
    fi

    timeout 300s helm upgrade --install "$RELEASE_NAME" \
        "$HELM_REPO_NAME/cluster-autoscaler" \
        --namespace "$NAMESPACE" \
        --version "$CHART_VERSION" \
        --set "autoDiscovery.clusterName=${CLUSTER_NAME}" \
        --set "awsRegion=${AWS_REGION}" \
        --set "cloudProvider=aws" \
        --set "rbac.serviceAccount.create=false" \
        --set "rbac.serviceAccount.name=${RELEASE_NAME}" \
        --set "image.tag=v${CA_VERSION}" \
        --wait \
        --timeout 5m

    echo "Cluster Autoscaler installed."

else

    echo "Existing Helm release detected."
    echo "Skipping unnecessary reinstall."

fi

echo

# ============================================================
# Dynamic Deployment detection
# ============================================================

echo "Detecting Cluster Autoscaler deployment..."

AUTOSCALER_DEPLOYMENT="$(kubectl get deployment \
    --namespace "$NAMESPACE" \
    -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$AUTOSCALER_DEPLOYMENT" ]]; then

    echo "ERROR: Cluster Autoscaler Deployment not found."

    echo
    echo "Helm release:"
    helm status "$RELEASE_NAME" \
        --namespace "$NAMESPACE" 2>/dev/null || true

    echo
    echo "Matching resources:"
    kubectl get all \
        --namespace "$NAMESPACE" \
        -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
        2>/dev/null || true

    exit 1
fi

echo "Deployment: $AUTOSCALER_DEPLOYMENT"
echo

# ============================================================
# Deployment rollout
# ============================================================

echo "Waiting for Cluster Autoscaler deployment..."

if ! timeout 300s kubectl rollout status \
    "deployment/${AUTOSCALER_DEPLOYMENT}" \
    --namespace "$NAMESPACE"; then

    echo
    echo "ERROR: Cluster Autoscaler rollout failed."

    kubectl get deployment "$AUTOSCALER_DEPLOYMENT" \
        --namespace "$NAMESPACE" \
        -o wide || true

    kubectl get pods \
        --namespace "$NAMESPACE" \
        -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
        -o wide || true

    exit 1
fi

echo

# ============================================================
# Verify image
# ============================================================

echo "Checking Cluster Autoscaler image..."

CA_IMAGE="$(kubectl get deployment "$AUTOSCALER_DEPLOYMENT" \
    --namespace "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo "Image: $CA_IMAGE"

if [[ "$CA_IMAGE" != *":v${CA_VERSION}" ]]; then
    echo "WARNING: Running image does not match expected version v${CA_VERSION}."
else
    echo "Cluster Autoscaler image version: OK"
fi

echo

# ============================================================
# Final verification
# ============================================================

echo "=========================================="
echo " CLUSTER AUTOSCALER VERIFICATION"
echo "=========================================="
echo

echo "Deployment:"
kubectl get deployment "$AUTOSCALER_DEPLOYMENT" \
    --namespace "$NAMESPACE"

echo
echo "Pods:"
kubectl get pods \
    --namespace "$NAMESPACE" \
    -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
    -o wide

echo
echo "ServiceAccount:"
kubectl get serviceaccount "$RELEASE_NAME" \
    --namespace "$NAMESPACE"

echo
echo "Helm release:"
helm status "$RELEASE_NAME" \
    --namespace "$NAMESPACE"

echo
echo "Cluster Autoscaler setup completed successfully."