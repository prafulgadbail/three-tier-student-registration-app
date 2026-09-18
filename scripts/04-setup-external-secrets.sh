#!/bin/bash

set -euo pipefail

# ============================================================
# External Secrets Operator Setup
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

ESO_VERSION="2.9.0"

RELEASE_NAME="external-secrets"
NAMESPACE="external-secrets"
SERVICE_ACCOUNT_NAME="external-secrets"

HELM_REPO_NAME="external-secrets"
HELM_REPO_URL="https://charts.external-secrets.io"

IAM_ROLE_NAME="ExternalSecretsRole-${CLUSTER_NAME}"
IAM_POLICY_NAME="ExternalSecretsPolicy"

echo "=========================================="
echo " EXTERNAL SECRETS OPERATOR SETUP"
echo "=========================================="
echo
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $AWS_REGION"
echo

# ============================================================
# Required commands
# ============================================================

echo "Checking required commands..."

for CMD in aws kubectl helm timeout; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $CMD"
        exit 1
    fi
done

echo "Required commands: OK"

# ============================================================
# AWS and EKS validation
# ============================================================

echo
echo "Checking AWS identity..."

AWS_ACCOUNT_ID="$(
    aws sts get-caller-identity \
        --query 'Account' \
        --output text
)"

echo "AWS Account: $AWS_ACCOUNT_ID"

echo
echo "Checking EKS cluster..."

CLUSTER_STATUS="$(
    aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.status' \
        --output text
)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Status: $CLUSTER_STATUS"
    exit 1
fi

echo "Cluster: $CLUSTER_NAME"
echo "Region : $AWS_REGION"
echo "Status : $CLUSTER_STATUS"

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    >/dev/null

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: Kubernetes API is not reachable."
    exit 1
fi

echo "Kubernetes API: OK"

# ============================================================
# EKS OIDC provider
# ============================================================

echo
echo "Checking EKS OIDC provider..."

OIDC_ISSUER="$(
    aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.identity.oidc.issuer' \
        --output text
)"

if [[ -z "$OIDC_ISSUER" || "$OIDC_ISSUER" == "None" ]]; then
    echo "ERROR: EKS OIDC issuer not found."
    exit 1
fi

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

# ============================================================
# IAM role and trust policy
# ============================================================

echo
echo "Checking ESO IAM role..."

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

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
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    >/dev/null 2>&1; then

    echo "IAM role already exists."

    aws iam update-assume-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-document "file://${TRUST_POLICY}"

    echo "IAM trust policy reconciled."

else

    echo "Creating IAM role..."

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "file://${TRUST_POLICY}" \
        >/dev/null

    echo "IAM role created."

fi

rm -f "$TRUST_POLICY"

# ============================================================
# IAM policy
# ============================================================

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

echo
echo "Checking ESO IAM policy..."

POLICY_FILE="$(mktemp)"

cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:*"
    }
  ]
}
EOF

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    >/dev/null 2>&1; then

    echo "IAM policy already exists."

else

    echo "Creating IAM policy..."

    aws iam create-policy \
        --policy-name "$IAM_POLICY_NAME" \
        --policy-document "file://${POLICY_FILE}" \
        >/dev/null

    echo "IAM policy created."

fi

rm -f "$POLICY_FILE"

echo
echo "Checking IAM policy attachment..."

ATTACHED_POLICY="$(
    aws iam list-attached-role-policies \
        --role-name "$IAM_ROLE_NAME" \
        --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyArn" \
        --output text
)"

if [[ "$ATTACHED_POLICY" == "$POLICY_ARN" ]]; then

    echo "IAM policy already attached."

else

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$POLICY_ARN"

    echo "IAM policy attached."

fi

# ============================================================
# Helm repository
# ============================================================

echo
echo "Checking External Secrets Helm repository..."

if helm repo list 2>/dev/null |
    awk 'NR > 1 {print $1}' |
    grep -qx "$HELM_REPO_NAME"; then

    echo "Helm repository already exists."

else

    helm repo add \
        "$HELM_REPO_NAME" \
        "$HELM_REPO_URL" \
        >/dev/null

    echo "Helm repository added."

fi

if ! timeout 120s helm repo update "$HELM_REPO_NAME" >/dev/null; then
    echo "ERROR: Helm repository update failed or timed out."
    exit 1
fi

echo "Helm repository updated."

# ============================================================
# ESO CRD ownership
# ============================================================

echo
echo "Checking existing ESO CRDs..."

mapfile -t ESO_CRDS < <(
    kubectl get crd -o name |
        sed 's#customresourcedefinition.apiextensions.k8s.io/##' |
        grep 'external-secrets.io$' |
        sort
)

if [[ "${#ESO_CRDS[@]}" -gt 0 ]]; then

    for CRD in "${ESO_CRDS[@]}"; do

        kubectl label crd "$CRD" \
            app.kubernetes.io/managed-by=Helm \
            --overwrite >/dev/null

        kubectl annotate crd "$CRD" \
            meta.helm.sh/release-name="$RELEASE_NAME" \
            meta.helm.sh/release-namespace="$NAMESPACE" \
            --overwrite >/dev/null

    done

    echo "ESO CRD ownership reconciled."

else

    echo "No existing ESO CRDs found."

fi

# ============================================================
# Install / upgrade ESO
# ============================================================

echo
echo "Installing / reconciling External Secrets Operator..."

helm upgrade --install "$RELEASE_NAME" \
    "$HELM_REPO_NAME/external-secrets" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --version "$ESO_VERSION" \
    --set installCRDs=true \
    --wait \
    --timeout 5m

echo "ESO Helm release reconciled."

# ============================================================
# ESO ServiceAccount and IRSA
# ============================================================

echo
echo "Configuring ESO ServiceAccount..."

kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" \
    --namespace "$NAMESPACE" \
    --dry-run=client \
    -o yaml |
kubectl apply -f - >/dev/null

kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" \
    --namespace "$NAMESPACE" \
    "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
    --overwrite >/dev/null

echo "ESO ServiceAccount configured."
echo "IAM Role: $ROLE_ARN"

# Restart controller so existing pods receive the IAM identity.
kubectl rollout restart deployment/"$RELEASE_NAME" \
    -n "$NAMESPACE" >/dev/null

kubectl rollout status \
    deployment/"$RELEASE_NAME" \
    -n "$NAMESPACE" \
    --timeout=5m

# ============================================================
# Verification
# ============================================================

echo
echo "Checking ESO deployments..."

for DEPLOYMENT in \
    external-secrets \
    external-secrets-webhook \
    external-secrets-cert-controller
do

    if ! kubectl get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" >/dev/null 2>&1; then

        echo "ERROR: Deployment not found: $DEPLOYMENT"
        exit 1
    fi

    kubectl rollout status \
        deployment/"$DEPLOYMENT" \
        -n "$NAMESPACE" \
        --timeout=5m

done

CURRENT_ROLE_ARN="$(
    kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
)"

if [[ "$CURRENT_ROLE_ARN" != "$ROLE_ARN" ]]; then
    echo "ERROR: ESO ServiceAccount IAM role annotation is incorrect."
    exit 1
fi

for RESOURCE in \
    externalsecrets.external-secrets.io \
    secretstores.external-secrets.io \
    clustersecretstores.external-secrets.io
do

    if ! kubectl get crd "$RESOURCE" >/dev/null 2>&1; then
        echo "ERROR: Missing CRD: $RESOURCE"
        exit 1
    fi

done

echo
echo "=========================================="
echo " EXTERNAL SECRETS OPERATOR READY"
echo "=========================================="
echo
echo "ESO Version : $ESO_VERSION"
echo "IAM Role    : $ROLE_ARN"
echo "IAM Policy  : $POLICY_ARN"
echo

kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" \
    -n "$NAMESPACE"

echo
kubectl get pods \
    -n "$NAMESPACE" \
    -o wide

echo
echo "=========================================="
echo " SETUP COMPLETED SUCCESSFULLY"
echo "=========================================="