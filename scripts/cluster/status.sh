#!/bin/bash
###############################################################################
# status.sh
#
# Quick overview of the cluster and all Justin components.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo "============================================================"
echo " Justin Cluster Status"
echo " $(date)"
echo "============================================================"

echo ""
echo "── Nodes ────────────────────────────────────────────────────"
kubectl get nodes -o wide 2>/dev/null || echo -e "${RED}Cannot reach API server${NC}"

echo ""
echo "── Node Labels (tier) ───────────────────────────────────────"
for node in "${ALL_NODES[@]}"; do
    tier=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null || echo "none")
    status=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}')
    printf "  %-10s status=%-10s tier=%s\n" "$node" "$status" "$tier"
done

echo ""
echo "── Helm Releases ────────────────────────────────────────────"
helm list --all-namespaces 2>/dev/null || echo "  (none)"

echo ""
echo "── Flink Operator ───────────────────────────────────────────"
kubectl get pods -l app.kubernetes.io/name=flink-kubernetes-operator 2>/dev/null || echo "  (not installed)"

echo ""
echo "── Flink Deployments ────────────────────────────────────────"
kubectl get flinkdeployment 2>/dev/null || echo "  (none)"

echo ""
echo "── Flink Pods ───────────────────────────────────────────────"
kubectl get pods -l app=flink 2>/dev/null || echo "  (none)"

echo ""
echo "── Monitoring (manager namespace) ───────────────────────────"
kubectl get pods -n manager 2>/dev/null || echo "  (not deployed)"

echo ""
echo "── Docker Registry ──────────────────────────────────────────"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q registry; then
    echo -e "  ${GREEN}✓${NC} Running at ${REGISTRY}"
    echo "  Images:"
    curl -s "http://${REGISTRY}/v2/_catalog" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (could not query catalog)"
else
    echo -e "  ${YELLOW}!${NC} Not running"
fi

echo ""
echo "── Problem Pods (all namespaces) ────────────────────────────"
PROBLEM_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null \
    | grep -Ev "Running|Completed" || true)
if [[ -n "$PROBLEM_PODS" ]]; then
    echo "$PROBLEM_PODS"
else
    echo -e "  ${GREEN}✓${NC} All pods healthy"
fi

echo ""
echo "============================================================"
