#!/bin/bash
###############################################################################
# 05b-redeploy-operator.sh
#
# Tears down and redeploys the Flink Kubernetes Operator.
# Useful before each experiment run to get a clean operator state.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Redeploying Flink Kubernetes Operator"
echo "============================================================"

echo ""
echo "── Uninstalling existing operator ───────────────────────────"
helm uninstall flink-kubernetes-operator 2>/dev/null || echo "  (not installed)"

echo "── Deleting CRDs ────────────────────────────────────────────"
kubectl delete crd/flinkdeployments.flink.apache.org --ignore-not-found
kubectl delete crd/flinksessionjobs.flink.apache.org --ignore-not-found

echo "── Waiting for cleanup ──────────────────────────────────────"
sleep 5

echo "── Deploying fresh operator ─────────────────────────────────"
"${SCRIPT_DIR}/05-deploy-operator.sh"

echo ""
echo "── Operator pods ────────────────────────────────────────────"
kubectl get pods -l app.kubernetes.io/name=flink-kubernetes-operator
echo ""
echo -e "${GREEN}✓ Operator redeployed!${NC}"
