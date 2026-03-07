#!/bin/bash
###############################################################################
# 04b-build-nexmark-sql-image.sh
#
# Builds a small overlay image for Nexmark SQL queries by copying the freshly
# built nexmark-flink jar into the base flink-justin image.
#
# This avoids recompiling the Flink distribution when only the Nexmark SQL
# runner or query resources change.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

NEXMARK_ROOT="${NEXMARK_ROOT:-/opt/nexmark-v2}"
NEXMARK_JAR="${NEXMARK_ROOT}/nexmark-flink/target/nexmark-flink-0.3-SNAPSHOT.jar"
DOCKERFILE_PATH="${SCRIPT_DIR}/nexmark-sql-image/Dockerfile"
PREPULL_SQL_IMAGE="${PREPULL_SQL_IMAGE:-true}"
BUILD_CONTEXT="$(mktemp -d)"
trap 'rm -rf "${BUILD_CONTEXT}"' EXIT

prepull_image_on_node() {
    local node="$1"
    local pull_command="sudo crictl --runtime-endpoint ${CRI_RUNTIME_ENDPOINT} pull ${FLINK_SQL_IMAGE}"

    if [[ "${node}" == "${CONTROL_PLANE}" ]]; then
        eval "${pull_command}"
    else
        ssh -o BatchMode=yes "${node}" "${pull_command}"
    fi
}

echo "============================================================"
echo " Building Nexmark SQL Overlay Image"
echo "============================================================"

echo ""
echo "── Checking local registry ──────────────────────────────────"
if docker ps --format '{{.Names}}' | grep -q registry; then
    echo -e "${GREEN}✓${NC} Registry already running at ${REGISTRY}"
else
    echo -e "${YELLOW}!${NC} Starting local registry..."
    docker run -d -p 5000:5000 --restart=always --name registry registry 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Registry started at ${REGISTRY}"
fi

if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
    echo -e "${RED}✗ Missing overlay Dockerfile: ${DOCKERFILE_PATH}${NC}"
    exit 1
fi

echo ""
echo "── Checking base flink-justin image ─────────────────────────"
if docker image inspect "${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}" >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Found local base image ${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}"
else
    echo -e "${YELLOW}!${NC} Local base image not found, pulling ${FLINK_IMAGE}"
    docker pull "${FLINK_IMAGE}"
    docker tag "${FLINK_IMAGE}" "${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}"
fi

echo ""
echo "── Building nexmark-flink jar ───────────────────────────────"
echo -e "${YELLOW}  Packaging nexmark-v2 against Flink ${NEXMARK_FLINK_VERSION}...${NC}"
mvn -f "${NEXMARK_ROOT}/pom.xml" \
    -pl nexmark-flink -am package \
    -DskipTests \
    -Dflink.version="${NEXMARK_FLINK_VERSION}"

if [[ ! -f "${NEXMARK_JAR}" ]]; then
    echo -e "${RED}✗ Nexmark jar not found: ${NEXMARK_JAR}${NC}"
    exit 1
fi

cp "${NEXMARK_JAR}" "${BUILD_CONTEXT}/nexmark-flink-0.3-SNAPSHOT.jar"

echo ""
echo "── Building flink-justin SQL overlay ────────────────────────"
docker build \
    --build-arg "BASE_IMAGE=${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}" \
    -f "${DOCKERFILE_PATH}" \
    "${BUILD_CONTEXT}" \
    -t "${FLINK_SQL_IMAGE_NAME}:${FLINK_SQL_IMAGE_TAG}"
echo -e "${GREEN}✓${NC} SQL overlay image built"

echo ""
echo "── Verifying overlay image contents ─────────────────────────"
docker run --rm --entrypoint sh "${FLINK_SQL_IMAGE_NAME}:${FLINK_SQL_IMAGE_TAG}" \
    -lc 'test -f /opt/flink/lib/nexmark-flink-0.3-SNAPSHOT.jar'
echo -e "${GREEN}✓${NC} Nexmark jar is present in /opt/flink/lib"

echo ""
echo "── Pushing SQL overlay image ────────────────────────────────"
docker tag "${FLINK_SQL_IMAGE_NAME}:${FLINK_SQL_IMAGE_TAG}" "${FLINK_SQL_IMAGE}"
docker push "${FLINK_SQL_IMAGE}"
echo -e "${GREEN}✓${NC} ${FLINK_SQL_IMAGE} pushed"

if [[ "${PREPULL_SQL_IMAGE}" == "true" ]]; then
    echo ""
    echo "── Pre-pulling SQL image on cluster nodes ───────────────────"
    for node in "${ALL_NODES[@]}"; do
        echo "  ${node}: pulling ${FLINK_SQL_IMAGE}"
        prepull_image_on_node "${node}"
        echo -e "  ${GREEN}✓${NC} ${node}"
    done
else
    echo ""
    echo -e "${YELLOW}!${NC} Skipping node pre-pull because PREPULL_SQL_IMAGE=${PREPULL_SQL_IMAGE}"
fi

echo ""
echo "============================================================"
echo -e "${GREEN} Nexmark SQL overlay image is ready!${NC}"
echo ""
echo " SQL jobs will use ${FLINK_SQL_IMAGE}"
