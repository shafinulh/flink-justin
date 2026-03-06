#!/bin/bash
###############################################################################
# 04-build-images.sh
#
# Builds the two Docker images needed by Justin:
#   1. flink-justin:dais         – Custom Flink with Justin memory management
#   2. flink-kubernetes-operator:dais – Custom K8s operator with autoscaler
#
# After building, the images are pushed to the local registry
# (running on c180:5000) so that all worker nodes can pull them.
#
# NOTE: The Flink build can take 15+ minutes due to the large codebase.
# SQL jobs are packaged separately by 04b-build-nexmark-sql-image.sh.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Building Docker Images"
echo "============================================================"

# ── Ensure local registry is running ────────────────────────────────────────
echo ""
echo "── Checking local registry ──────────────────────────────────"
if docker ps --format '{{.Names}}' | grep -q registry; then
    echo -e "${GREEN}✓${NC} Registry already running at ${REGISTRY}"
else
    echo -e "${YELLOW}!${NC} Starting local registry..."
    docker run -d -p 5000:5000 --restart=always --name registry registry 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Registry started at ${REGISTRY}"
fi

# ── Build flink-justin image ───────────────────────────────────────────────
echo ""
echo "── Building flink-justin:dais ───────────────────────────────"
echo -e "${YELLOW}  This may take 15+ minutes...${NC}"
cd "${PROJECT_ROOT}"
docker build . -t "${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}"
echo -e "${GREEN}✓${NC} flink-justin image built"

# ── Build flink-kubernetes-operator image ──────────────────────────────────
echo ""
echo "── Building flink-kubernetes-operator:dais ──────────────────"
cd "${PROJECT_ROOT}/flink-kubernetes-operator"
docker build . -t "${OPERATOR_IMAGE_NAME}:${OPERATOR_IMAGE_TAG}"
echo -e "${GREEN}✓${NC} operator image built"

# ── Tag and push to local registry ─────────────────────────────────────────
echo ""
echo "── Pushing to local registry (${REGISTRY}) ─────────────────"
docker tag "${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}" "${FLINK_IMAGE}"
docker push "${FLINK_IMAGE}"
echo -e "${GREEN}✓${NC} ${FLINK_IMAGE} pushed"

docker tag "${OPERATOR_IMAGE_NAME}:${OPERATOR_IMAGE_TAG}" "${OPERATOR_IMAGE}"
docker push "${OPERATOR_IMAGE}"
echo -e "${GREEN}✓${NC} ${OPERATOR_IMAGE} pushed"

echo ""
echo "── Verify images in registry ────────────────────────────────"
echo "  Images on control-plane:"
docker images | grep -E "flink-justin|flink-kubernetes-operator" | head -10

echo ""
echo "============================================================"
echo -e "${GREEN} Images built and pushed to registry!${NC}"
echo ""
echo " Workers will pull images from ${REGISTRY} when pods start."
echo ""
echo "Next: run 04b-build-nexmark-sql-image.sh if you need SQL jobs,"
echo "      then run 05-deploy-operator.sh"
