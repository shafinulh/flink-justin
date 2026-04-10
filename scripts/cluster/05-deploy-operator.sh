#!/bin/bash
###############################################################################
# 05-deploy-operator.sh
#
# Deploys the Flink Kubernetes Operator using Helm.
# The operator manages FlinkDeployment CRDs and includes the Justin
# autoscaler logic.
#
# Uses:
#   - Helm chart from: flink-kubernetes-operator/helm/flink-kubernetes-operator
#   - Values override:  flink-kubernetes-operator/examples/autoscaling/values.yaml
#     (sets DEBUG logging for both operator and Flink deployments)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Deploying Flink Kubernetes Operator"
echo "============================================================"

# ── Check if operator is already installed ──────────────────────────────────
echo ""
if helm list | grep -q flink-kubernetes-operator; then
    echo -e "${YELLOW}!${NC} Operator already installed. Uninstall first with:"
    echo "    helm uninstall flink-kubernetes-operator"
    echo "  Or run scripts/delete.sh to clean everything."
    read -p "  Uninstall and reinstall? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        helm uninstall flink-kubernetes-operator || true
        kubectl delete crd/flinkdeployments.flink.apache.org 2>/dev/null || true
        kubectl delete crd/flinksessionjobs.flink.apache.org 2>/dev/null || true
        sleep 5
    else
        echo "Aborted."
        exit 0
    fi
fi

# ── Install the operator via Helm ───────────────────────────────────────────
echo ""
echo "── Installing Flink Kubernetes Operator ─────────────────────"
helm install flink-kubernetes-operator \
    "${HELM_CHART}" \
    --set "image.repository=${REGISTRY}/${OPERATOR_IMAGE_NAME}" \
    --set "image.tag=${OPERATOR_IMAGE_TAG}" \
    --set "image.pullPolicy=Always" \
    -f "${AUTOSCALER_VALUES}"
echo -e "${GREEN}✓${NC} Helm install complete"

# ── Wait for operator pod to be ready ───────────────────────────────────────
echo ""
echo "── Waiting for operator pod to be ready ─────────────────────"
for i in $(seq 1 30); do
    POD_STATUS=$(kubectl get pods -l app.kubernetes.io/name=flink-kubernetes-operator \
        --no-headers 2>/dev/null | awk '{print $2 " " $3}' | head -1)
    if [[ "$POD_STATUS" == *"Running"* ]]; then
        echo -e "  ${GREEN}✓${NC} Operator is running: ${POD_STATUS}"
        break
    fi
    echo "  Waiting... (${POD_STATUS:-not found yet})"
    sleep 10
done

echo ""
echo "── Operator pods ────────────────────────────────────────────"
kubectl get pods -l app.kubernetes.io/name=flink-kubernetes-operator

echo ""
echo "── Flink CRDs installed ─────────────────────────────────────"
kubectl get crd | grep flink || echo "  (none found - this may indicate an issue)"

echo ""
echo "============================================================"
echo -e "${GREEN} Flink Kubernetes Operator deployed!${NC}"
echo ""
echo " The operator is watching for FlinkDeployment resources."
echo " You can now submit Flink jobs using kubectl apply."
echo ""
echo "Next: run 06-prepare-jobs.sh to set up the query YAML files"
