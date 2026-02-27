#!/bin/bash
###############################################################################
# 01b-soft-reset.sh
#
# Clean up Flink/monitoring workloads without tearing down the k8s cluster.
# Use this when you want to redeploy services on an existing cluster.
#
# What this does:
#   1. Deletes any Flink deployments + CRDs
#   2. Uninstalls the flink-kubernetes-operator Helm release
#   3. Uninstalls monitoring (Prometheus, Loki) Helm releases
#   4. Removes old namespaces
#   5. Removes stale NotReady nodes from the cluster
#   6. Re-labels remaining nodes
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Soft Reset – Clean workloads, keep k8s cluster"
echo "============================================================"

echo ""
echo "── Step 1: Remove Flink deployments ─────────────────────────"
kubectl patch flinkdeployment.flink.apache.org flink \
    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete flinkdeployment.flink.apache.org flink 2>/dev/null || true
echo -e "${GREEN}✓${NC} Flink deployments removed"

echo ""
echo "── Step 2: Uninstall Flink Kubernetes Operator ──────────────"
helm uninstall flink-kubernetes-operator 2>/dev/null || true
echo -e "${GREEN}✓${NC} Operator Helm release removed"

echo ""
echo "── Step 3: Remove Flink CRDs ────────────────────────────────"
kubectl delete crd/flinkdeployments.flink.apache.org 2>/dev/null || true
kubectl delete crd/flinksessionjobs.flink.apache.org 2>/dev/null || true
kubectl delete crd/flinkclusters.flinkoperator.k8s.io 2>/dev/null || true
echo -e "${GREEN}✓${NC} CRDs removed"

echo ""
echo "── Step 4: Remove old Spotify flink-on-k8s-operator ────────"
kubectl delete -f https://github.com/spotify/flink-on-k8s-operator/releases/download/v0.4.0-beta.8/flink-operator.yaml 2>/dev/null || true
kubectl delete ns flink-operator-system 2>/dev/null || true
echo -e "${GREEN}✓${NC} Legacy operator removed"

echo ""
echo "── Step 5: Remove cert-manager ──────────────────────────────"
kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml 2>/dev/null || true
kubectl delete ns cert-manager --timeout=60s 2>/dev/null || true
echo -e "${GREEN}✓${NC} cert-manager removed"

echo ""
echo "── Step 6: Uninstall monitoring stack ───────────────────────"
helm uninstall prom -n manager 2>/dev/null || true
helm uninstall loki -n manager 2>/dev/null || true
echo -e "${GREEN}✓${NC} Prometheus & Loki uninstalled"

echo ""
echo "── Step 7: Clean up namespaces ──────────────────────────────"
kubectl delete ns manager --timeout=60s 2>/dev/null || true
kubectl delete ns local-path-storage --timeout=60s 2>/dev/null || true
echo -e "${GREEN}✓${NC} Namespaces cleaned"

echo ""
echo "── Step 8: Remove stale NotReady nodes ──────────────────────"
STALE_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep "NotReady" | awk '{print $1}')
if [[ -n "$STALE_NODES" ]]; then
    for node in $STALE_NODES; do
        echo "  Removing stale node: ${node}"
        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=30s 2>/dev/null || true
        kubectl delete node "$node" 2>/dev/null || true
    done
    echo -e "${GREEN}✓${NC} Stale nodes removed"
else
    echo -e "${GREEN}✓${NC} No stale nodes"
fi

echo ""
echo "── Step 9: Kill stuck Terminating pods ──────────────────────"
STUCK_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1 " " $2}')
if [[ -n "$STUCK_PODS" ]]; then
    while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        pod=$(echo "$line" | awk '{print $2}')
        echo "  Force-deleting: ${ns}/${pod}"
        kubectl delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null || true
    done <<< "$STUCK_PODS"
    echo -e "${GREEN}✓${NC} Stuck pods cleaned"
else
    echo -e "${GREEN}✓${NC} No stuck pods"
fi

echo ""
echo "── Final state ──────────────────────────────────────────────"
kubectl get nodes
echo ""
kubectl get pods --all-namespaces 2>/dev/null | head -20
echo ""
echo -e "${GREEN}Soft reset complete!${NC}"
echo "Next: run 02-label-nodes.sh"
