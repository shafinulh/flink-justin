#!/bin/bash
###############################################################################
# 07-port-forward.sh
#
# Sets up port-forwarding for Grafana, Prometheus, and (optionally) Flink UI.
# Runs all three in the background and prints access URLs.
#
# Kill them all with: kill $(jobs -p)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Starting Port Forwarding"
echo "============================================================"

# Kill any existing port-forwards
pkill -f "kubectl port-forward.*prom-grafana" 2>/dev/null || true
pkill -f "kubectl port-forward.*prometheus-stack-prometheus" 2>/dev/null || true
pkill -f "kubectl port-forward.*flink-rest" 2>/dev/null || true
sleep 1

echo ""
echo "── Grafana (port 3001) ──────────────────────────────────────"
kubectl port-forward --address 0.0.0.0 -n manager svc/prom-grafana 3001:80 &>/dev/null &
echo -e "  ${GREEN}✓${NC} http://${CONTROL_PLANE_IP}:3001  (admin / prom-operator)"

echo ""
echo "── Prometheus (port 9091) ───────────────────────────────────"
kubectl port-forward --address 0.0.0.0 -n manager svc/prom-kube-prometheus-stack-prometheus 9091:9090 &>/dev/null &
echo -e "  ${GREEN}✓${NC} http://${CONTROL_PLANE_IP}:9091"

echo ""
echo "── Flink UI (port 8081) ─────────────────────────────────────"
if kubectl get svc flink-rest &>/dev/null; then
    kubectl port-forward --address 0.0.0.0 svc/flink-rest 8081:8081 &>/dev/null &
    echo -e "  ${GREEN}✓${NC} http://${CONTROL_PLANE_IP}:8081"
else
    echo -e "  ${YELLOW}!${NC} flink-rest service not found (no job submitted yet)"
    echo "     Run this again after submitting a Flink job."
fi

echo ""
echo "============================================================"
echo " Port forwarding is running in the background."
echo " To stop all: kill \$(jobs -p)"
echo "============================================================"

# Keep script alive so background jobs survive
wait
