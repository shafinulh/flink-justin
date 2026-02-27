#!/bin/bash
###############################################################################
# run-job.sh
#
# Submit a Flink job and wait for it to be running, then start a
# port-forward to the Flink UI.
#
# Usage:
#   ./run-job.sh <query-yaml>
#
# Examples:
#   ./run-job.sh jobs/query5-justin.yaml
#   ./run-job.sh jobs/query8-ds2.yaml
#
# To stop the job later:
#   kubectl delete -f jobs/query5-justin.yaml
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <query-yaml>"
    echo ""
    echo "Available jobs:"
    ls "${SCRIPT_DIR}/jobs/"*.yaml 2>/dev/null | while read -r f; do
        echo "  $(basename "$f")"
    done
    exit 1
fi

QUERY_YAML="$1"

# Resolve relative paths against the script directory
if [[ ! -f "$QUERY_YAML" ]]; then
    QUERY_YAML="${SCRIPT_DIR}/${QUERY_YAML}"
fi

if [[ ! -f "$QUERY_YAML" ]]; then
    echo -e "${RED}✗ File not found: $1${NC}"
    exit 1
fi

QUERY_NAME=$(basename "$QUERY_YAML" .yaml)

echo "============================================================"
echo " Submitting: ${QUERY_NAME}"
echo "============================================================"

# ── Check for existing Flink deployment ─────────────────────────────────────
if kubectl get flinkdeployment flink &>/dev/null; then
    echo -e "${YELLOW}! A Flink deployment already exists.${NC}"
    read -p "  Delete it and submit the new one? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        echo "  Deleting existing deployment..."
        kubectl delete -f "$QUERY_YAML" 2>/dev/null || \
            kubectl delete flinkdeployment flink 2>/dev/null || true
        echo "  Waiting for cleanup..."
        sleep 10
    else
        echo "Aborted."
        exit 0
    fi
fi

# ── Submit the job ──────────────────────────────────────────────────────────
echo ""
echo "── Submitting job ───────────────────────────────────────────"
kubectl apply -f "$QUERY_YAML"
echo -e "${GREEN}✓${NC} Applied ${QUERY_YAML}"

# ── Wait for pods to come up ────────────────────────────────────────────────
echo ""
echo "── Waiting for Flink pods to start ──────────────────────────"
for i in $(seq 1 60); do
    JM_STATUS=$(kubectl get pods -l component=jobmanager --no-headers 2>/dev/null | awk '{print $3}' | head -1)
    TM_STATUS=$(kubectl get pods -l component=taskmanager --no-headers 2>/dev/null | awk '{print $3}' | head -1)

    if [[ "$JM_STATUS" == "Running" ]]; then
        echo -e "  ${GREEN}✓${NC} JobManager: Running"
        if [[ "$TM_STATUS" == "Running" ]]; then
            echo -e "  ${GREEN}✓${NC} TaskManager: Running"
            break
        else
            echo -e "  ${YELLOW}…${NC} TaskManager: ${TM_STATUS:-pending}"
        fi
    else
        echo -e "  ${YELLOW}…${NC} JobManager: ${JM_STATUS:-pending}  |  TaskManager: ${TM_STATUS:-pending}"
    fi
    sleep 5
done

echo ""
echo "── Pod status ───────────────────────────────────────────────"
kubectl get pods -l app=flink

# ── Wait for flink-rest service ─────────────────────────────────────────────
echo ""
echo "── Waiting for flink-rest service ───────────────────────────"
for i in $(seq 1 30); do
    if kubectl get svc flink-rest &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} flink-rest service is up"
        break
    fi
    echo "  Waiting..."
    sleep 5
done

# ── Start Flink UI port-forward ─────────────────────────────────────────────
echo ""
echo "── Starting Flink UI port-forward ───────────────────────────"
pkill -f "kubectl port-forward.*flink-rest" 2>/dev/null || true
sleep 1
kubectl port-forward --address 0.0.0.0 svc/flink-rest 8081:8081 &>/dev/null &
FLINK_PF_PID=$!
echo -e "  ${GREEN}✓${NC} Flink UI: http://${CONTROL_PLANE_IP}:8081  (pid: ${FLINK_PF_PID})"

echo ""
echo "============================================================"
echo -e "${GREEN} Job '${QUERY_NAME}' is running!${NC}"
echo ""
echo " Flink UI:    http://${CONTROL_PLANE_IP}:8081"
echo " Watch pods:  kubectl get pods -l app=flink -w"
echo " Watch state: kubectl get flinkdeployment -w"
echo ""
echo " To stop the job:"
echo "   kubectl delete -f ${QUERY_YAML}"
echo ""
echo " To stop port-forward:"
echo "   kill ${FLINK_PF_PID}"
echo "============================================================"
