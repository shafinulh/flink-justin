#!/bin/bash
###############################################################################
# 04c-rebuild-operator-image.sh
#
# Rebuilds and pushes ONLY the flink-kubernetes-operator image.
# Use this after making changes to the autoscaler Java code (e.g. ScalingExecutor,
# AutoScalerOptions, ScalingConfigurations) without needing to rebuild the
# full Flink base image.
#
# After pushing, run 05b-redeploy-operator.sh to apply the new image.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Rebuilding flink-kubernetes-operator image"
echo "============================================================"

# ── Ensure local registry is running ────────────────────────────────────────
echo ""
echo "── Checking local registry ──────────────────────────────────"
if docker ps --format '{{.Names}}' | grep -q registry; then
    echo -e "${GREEN}✓${NC} Registry running at ${REGISTRY}"
else
    echo -e "${YELLOW}!${NC} Starting local registry..."
    docker run -d -p 5000:5000 --restart=always --name registry registry 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Registry started at ${REGISTRY}"
fi

# ── Build operator image ─────────────────────────────────────────────────────
echo ""
echo "── Building ${OPERATOR_IMAGE_NAME}:${OPERATOR_IMAGE_TAG} ────"
cd "${PROJECT_ROOT}/flink-kubernetes-operator"
docker build . -t "${OPERATOR_IMAGE_NAME}:${OPERATOR_IMAGE_TAG}"
echo -e "${GREEN}✓${NC} Operator image built"

# ── Tag and push to local registry ─────────────────────────────────────────
echo ""
echo "── Pushing to local registry (${REGISTRY}) ─────────────────"
docker tag "${OPERATOR_IMAGE_NAME}:${OPERATOR_IMAGE_TAG}" "${OPERATOR_IMAGE}"
docker push "${OPERATOR_IMAGE}"
echo -e "${GREEN}✓${NC} ${OPERATOR_IMAGE} pushed"

echo ""
echo "============================================================"
echo -e "${GREEN} Operator image rebuilt and pushed!${NC}"
echo ""
echo " Next: run ./05b-redeploy-operator.sh to apply the new image."
echo "============================================================"
