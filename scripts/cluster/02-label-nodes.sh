#!/bin/bash
###############################################################################
# 02-label-nodes.sh
#
# Label nodes according to the Justin convention:
#   - control-plane (c180): also labeled as jobmanager + manager
#   - workers (c182, c167):  labeled as taskmanager
#
# These labels are used by Prometheus/Grafana (tier=manager) and by the
# Flink Kubernetes Operator (tier=jobmanager, tier=taskmanager) to schedule
# pods on the right machines.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; NC='\033[0m'

echo "============================================================"
echo " Labeling Nodes"
echo "============================================================"

echo ""
echo "── Control-plane: ${CONTROL_PLANE} ──────────────────────────"
# The control-plane doubles as manager (Prometheus/Grafana) and jobmanager
kubectl label node "${CONTROL_PLANE}" tier=jobmanager --overwrite
echo -e "  ${GREEN}✓${NC} ${CONTROL_PLANE} → tier=jobmanager"

# Allow scheduling on control-plane (needed for monitoring + JM pods)
kubectl taint nodes "${CONTROL_PLANE}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Removed control-plane NoSchedule taint"

echo ""
echo "── Workers ──────────────────────────────────────────────────"
for worker in "${WORKERS[@]}"; do
    kubectl label node "$worker" tier=taskmanager --overwrite
    echo -e "  ${GREEN}✓${NC} ${worker} → tier=taskmanager"
done

echo ""
echo "── Verification ─────────────────────────────────────────────"
kubectl get nodes --show-labels | awk '{
    # Print node name and tier label
    split($NF, labels, ",")
    tier="(none)"
    for (i in labels) {
        if (labels[i] ~ /^tier=/) tier=labels[i]
    }
    printf "  %-10s %-15s %s\n", $1, $2, tier
}'

echo ""
echo -e "${GREEN}Node labeling complete!${NC}"
echo "Next: run 03-deploy-monitoring.sh"
