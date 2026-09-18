#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.env not found."
    exit 1
fi

source "$CONFIG_FILE"

: "${CLUSTER_NAME:?CLUSTER_NAME is required in config.env}"
: "${AWS_REGION:?AWS_REGION is required in config.env}"
: "${GRAFANA_HOSTNAME:?GRAFANA_HOSTNAME is required in config.env}"
: "${ALB_GROUP_NAME:?ALB_GROUP_NAME is required in config.env}"
: "${ACM_CERTIFICATE_ARN:?ACM_CERTIFICATE_ARN is required in config.env}"

NAMESPACE="monitoring"
INGRESS_NAME="grafana-ingress"
GRAFANA_SERVICE="kube-prometheus-stack-grafana"
GRAFANA_SERVICE_PORT="80"

echo "=============================================="
echo "Grafana Ingress Setup"
echo "=============================================="
echo "Cluster        : $CLUSTER_NAME"
echo "Region         : $AWS_REGION"
echo "Namespace      : $NAMESPACE"
echo "Grafana Host   : $GRAFANA_HOSTNAME"
echo "ALB Group      : $ALB_GROUP_NAME"
echo "=============================================="

echo
echo "Checking required commands..."

for cmd in aws kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is not installed."
        exit 1
    fi
done

echo "Required commands: OK"

echo
echo "Checking AWS identity..."

aws sts get-caller-identity >/dev/null

echo "AWS identity: OK"

echo
echo "Checking EKS cluster..."

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Current status: $CLUSTER_STATUS"
    exit 1
fi

echo "EKS cluster: ACTIVE"

echo
echo "Updating kubeconfig..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" >/dev/null

echo "Kubeconfig updated."

echo
echo "Checking Grafana service..."

if ! kubectl get service "$GRAFANA_SERVICE" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: Grafana service not found."
    echo "Expected service: $GRAFANA_SERVICE"
    exit 1
fi

GRAFANA_SERVICE_TYPE="$(kubectl get service "$GRAFANA_SERVICE" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.type}')"

if [[ "$GRAFANA_SERVICE_TYPE" != "ClusterIP" ]]; then
    echo "ERROR: Expected Grafana service type ClusterIP."
    echo "Current type: $GRAFANA_SERVICE_TYPE"
    exit 1
fi

echo "Grafana service: OK"
echo "Service type   : ClusterIP"

echo
echo "Checking existing application Ingress..."

if ! kubectl get ingress student-app-ingress -n student-app >/dev/null 2>&1; then
    echo "ERROR: Existing student-app-ingress not found."
    exit 1
fi

EXISTING_GROUP="$(kubectl get ingress student-app-ingress \
    -n student-app \
    -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/group\.name}')"

if [[ "$EXISTING_GROUP" != "$ALB_GROUP_NAME" ]]; then
    echo "ERROR: Existing application Ingress is using group:"
    echo "$EXISTING_GROUP"
    echo
    echo "Expected shared ALB group:"
    echo "$ALB_GROUP_NAME"
    exit 1
fi

echo "Existing ALB group: $EXISTING_GROUP"
echo "Grafana will reuse the existing ALB."

echo
echo "Checking ACM certificate..."

CERT_STATUS="$(aws acm describe-certificate \
    --certificate-arn "$ACM_CERTIFICATE_ARN" \
    --region "$AWS_REGION" \
    --query 'Certificate.Status' \
    --output text)"

if [[ "$CERT_STATUS" != "ISSUED" ]]; then
    echo "ERROR: ACM certificate is not ISSUED."
    echo "Certificate status: $CERT_STATUS"
    exit 1
fi

echo "ACM certificate: ISSUED"

echo
echo "Checking ACM certificate hostname coverage..."

CERT_NAMES="$(aws acm describe-certificate \
    --certificate-arn "$ACM_CERTIFICATE_ARN" \
    --region "$AWS_REGION" \
    --query 'Certificate.SubjectAlternativeNames' \
    --output text)"

CERT_MATCH="false"

for name in $CERT_NAMES; do
    if [[ "$name" == "$GRAFANA_HOSTNAME" || "$name" == "*.${GRAFANA_HOSTNAME#*.}" ]]; then
        CERT_MATCH="true"
        break
    fi
done

if [[ "$CERT_MATCH" != "true" ]]; then
    echo "ERROR: ACM certificate does not cover:"
    echo "$GRAFANA_HOSTNAME"
    echo
    echo "Certificate names:"
    echo "$CERT_NAMES"
    exit 1
fi

echo "ACM certificate hostname coverage: OK"

echo
echo "Applying Grafana Ingress..."

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    alb.ingress.kubernetes.io/group.name: ${ALB_GROUP_NAME}
    alb.ingress.kubernetes.io/group.order: "20"
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/certificate-arn: ${ACM_CERTIFICATE_ARN}
spec:
  ingressClassName: alb
  rules:
    - host: ${GRAFANA_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${GRAFANA_SERVICE}
                port:
                  number: ${GRAFANA_SERVICE_PORT}
EOF

echo
echo "Ingress applied."

echo
echo "Waiting for ALB hostname..."

ALB_HOSTNAME=""

for i in {1..30}; do
    ALB_HOSTNAME="$(kubectl get ingress "$INGRESS_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [[ -n "$ALB_HOSTNAME" ]]; then
        break
    fi

    sleep 10
done

if [[ -z "$ALB_HOSTNAME" ]]; then
    echo "ERROR: ALB hostname was not assigned within timeout."
    kubectl describe ingress "$INGRESS_NAME" -n "$NAMESPACE" || true
    exit 1
fi

echo "ALB hostname:"
echo "$ALB_HOSTNAME"

echo
echo "Finding Route53 hosted zone..."

ZONE_NAME="${GRAFANA_HOSTNAME#*.}."

HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
    --dns-name "$ZONE_NAME" \
    --query "HostedZones[?Name=='$ZONE_NAME' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text)"

if [[ -z "$HOSTED_ZONE_ID" || "$HOSTED_ZONE_ID" == "None" ]]; then
    echo "ERROR: Public Route53 hosted zone not found."
    echo "Expected zone: $ZONE_NAME"
    exit 1
fi

HOSTED_ZONE_ID="${HOSTED_ZONE_ID##*/}"

echo "Route53 hosted zone: $HOSTED_ZONE_ID"

echo
echo "Finding existing ALB..."

ALB_DNS_NAME="$ALB_HOSTNAME"

ALB_ZONE_ID="$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='$ALB_DNS_NAME'].CanonicalHostedZoneId | [0]" \
    --output text)"

if [[ -z "$ALB_ZONE_ID" || "$ALB_ZONE_ID" == "None" ]]; then
    echo "ERROR: Existing ALB was not found."
    exit 1
fi

echo "ALB hosted zone: $ALB_ZONE_ID"

echo
echo "Updating Route53 DNS record..."

cat > /tmp/grafana-route53.json <<EOF
{
  "Comment": "Alias Grafana hostname to shared ALB",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${GRAFANA_HOSTNAME}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_ZONE_ID}",
          "DNSName": "dualstack.${ALB_DNS_NAME}",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch file:///tmp/grafana-route53.json \
    >/dev/null

rm -f /tmp/grafana-route53.json

echo "Route53 record: UPSERT completed."

echo
echo "=============================================="
echo "Verifying Grafana Ingress"
echo "=============================================="

kubectl get ingress "$INGRESS_NAME" \
    -n "$NAMESPACE" \
    -o wide

echo
echo "Grafana service:"
kubectl get service "$GRAFANA_SERVICE" -n "$NAMESPACE"

echo
echo "ALB hostname:"
echo "$ALB_HOSTNAME"

echo
echo "Grafana URL:"
echo "https://${GRAFANA_HOSTNAME}"

echo
echo "=============================================="
echo "GRAFANA INGRESS SETUP COMPLETED"
echo "=============================================="
echo "Existing ALB : Reused"
echo "ALB group    : $ALB_GROUP_NAME"
echo "Grafana host : $GRAFANA_HOSTNAME"
echo "HTTPS        : Enabled"
echo "Route53      : Configured"
echo "=============================================="