#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPTS=(
    "00-preflight-check.sh"
    "01-setup-aws-load-balancer-controller.sh"
    "02-setup-metrics-server.sh"
    "03-setup-ebs-csi-driver.sh"
    "04-setup-external-secrets-operator.sh"
    "05-setup-cluster-autoscaler.sh"
    "06-setup-kube-prometheus-stack.sh"
    "07-setup-grafana-ingress.sh"
    "08-setup-reloader.sh"
)

echo
echo "======================================================"
echo "        EKS PLATFORM SETUP - ALL COMPONENTS"
echo "======================================================"
echo
echo "Execution order:"
printf '  %s\n' "${SCRIPTS[@]}"
echo
echo "======================================================"

for script in "${SCRIPTS[@]}"; do

    SCRIPT_PATH="${SCRIPT_DIR}/${script}"

    echo
    echo "------------------------------------------------------"
    echo "Starting: ${script}"
    echo "------------------------------------------------------"

    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo "ERROR: Script not found:"
        echo "$SCRIPT_PATH"
        exit 1
    fi

    if [[ ! -x "$SCRIPT_PATH" ]]; then
        echo "Making script executable..."
        chmod +x "$SCRIPT_PATH"
    fi

    echo
    echo "Running ${script}..."
    echo

    if "$SCRIPT_PATH"; then
        echo
        echo "SUCCESS: ${script}"
    else
        echo
        echo "FAILED: ${script}"
        echo
        echo "Platform setup stopped."
        echo "Fix the failed component and run setup-all.sh again."
        exit 1
    fi

done

echo
echo "======================================================"
echo "       EKS PLATFORM SETUP COMPLETED"
echo "======================================================"
echo
echo "All platform components completed successfully:"
echo

printf '  ✓ %s\n' "${SCRIPTS[@]}"

echo
echo "======================================================"
