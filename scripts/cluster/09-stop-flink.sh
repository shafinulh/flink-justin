#!/bin/bash
###############################################################################
# 09-stop-flink.sh
#
# Stop the in-cluster Flink deployment and free the local Flink UI port-forward.
#
# This does NOT tear down Kubernetes, monitoring, or the Flink operator.
# It only deletes the FlinkDeployment resource and kills any local
# `kubectl port-forward` process for `svc/flink-rest`.
#
# Usage:
#   ./09-stop-flink.sh
#   ./09-stop-flink.sh <deployment-name>
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

DEPLOYMENT_NAME="${1:-flink}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"

echo "============================================================"
echo " Stopping in-cluster Flink deployment: ${DEPLOYMENT_NAME}"
echo "============================================================"

echo ""
echo "── Killing local Flink UI port-forward ──────────────────────"
if pkill -f "kubectl port-forward.*flink-rest.*8081:8081" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Killed matching port-forward on 8081"
else
    echo -e "  ${YELLOW}!${NC} No matching port-forward found"
fi

echo ""
echo "── Deleting FlinkDeployment ─────────────────────────────────"
if kubectl get flinkdeployment "${DEPLOYMENT_NAME}" &>/dev/null; then
    kubectl delete flinkdeployment "${DEPLOYMENT_NAME}" --wait=false

    if kubectl wait --for=delete "flinkdeployment/${DEPLOYMENT_NAME}" --timeout="${WAIT_SECONDS}s" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} FlinkDeployment deleted"
    else
        echo -e "  ${YELLOW}!${NC} Delete timed out; removing finalizers and retrying"
        kubectl patch flinkdeployment "${DEPLOYMENT_NAME}" \
            -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        kubectl delete flinkdeployment "${DEPLOYMENT_NAME}" --ignore-not-found=true --wait=false
        kubectl wait --for=delete "flinkdeployment/${DEPLOYMENT_NAME}" --timeout=60s &>/dev/null || true

        if kubectl get flinkdeployment "${DEPLOYMENT_NAME}" &>/dev/null; then
            echo -e "  ${RED}✗${NC} FlinkDeployment still exists"
            exit 1
        fi

        echo -e "  ${GREEN}✓${NC} FlinkDeployment deleted after finalizer cleanup"
    fi
else
    echo -e "  ${YELLOW}!${NC} FlinkDeployment '${DEPLOYMENT_NAME}' not found"
fi

echo ""
echo "── Remaining Flink resources ────────────────────────────────"
kubectl get flinkdeployment 2>/dev/null || true
echo ""
kubectl get pods -l app=flink 2>/dev/null || true
echo ""
kubectl get svc flink-rest 2>/dev/null || echo "flink-rest service not found"

echo ""
echo "============================================================"
echo -e "${GREEN} In-cluster Flink stop complete.${NC}"
echo " Kubernetes and the Flink operator are still running."
echo "============================================================"
