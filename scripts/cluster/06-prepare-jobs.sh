#!/bin/bash
###############################################################################
# 06-prepare-jobs.sh
#
# Prepares the Nexmark benchmark query YAML files so they use the correct
# Docker image from our local registry, and patches the node selectors
# for our cluster layout.
#
# This does NOT submit any jobs — it only rewrites the YAML files so they
# are ready to be submitted via:
#     kubectl apply -f <query>.yaml
#
# For each query (q1, q2, q3, q5, q8, q11), two variants are prepared:
#   - queryX-ds2.yaml      (job.autoscaler.justin.enabled = false)
#   - queryX-justin.yaml   (job.autoscaler.justin.enabled = true)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

NOTEBOOKS_DIR="${PROJECT_ROOT}/notebooks/nexmark"
OUTPUT_DIR="${PROJECT_ROOT}/scripts/cluster/jobs"

echo "============================================================"
echo " Preparing Nexmark Benchmark Jobs"
echo "============================================================"

mkdir -p "${OUTPUT_DIR}"

# ── Find all query YAML files ───────────────────────────────────────────────
QUERY_FILES=$(find "${NOTEBOOKS_DIR}" -name "query*.yaml" -type f | sort)

if [[ -z "$QUERY_FILES" ]]; then
    echo -e "${YELLOW}! No query YAML files found in ${NOTEBOOKS_DIR}${NC}"
    exit 1
fi

echo ""
echo "── Found query files ────────────────────────────────────────"
for f in $QUERY_FILES; do
    echo "  $(basename "$(dirname "$f")")/$(basename "$f")"
done

echo ""
echo "── Generating vanilla + justin variants ─────────────────────"
for f in $QUERY_FILES; do
    query_dir=$(basename "$(dirname "$f")")
    query_base=$(basename "$f" .yaml)

    # Generate ds2 variant (justin disabled, default autoscaler)
    DS2_OUT="${OUTPUT_DIR}/${query_base}-ds2.yaml"
    sed -e "s|image: flink-justin:dais|image: ${FLINK_IMAGE}|g" \
        -e 's|job.autoscaler.justin.enabled: "JUSTIN"|job.autoscaler.justin.enabled: "false"|g' \
        "$f" > "$DS2_OUT"
    echo -e "  ${GREEN}✓${NC} ${query_base}-ds2.yaml"

    # Generate justin variant (justin enabled)
    JUSTIN_OUT="${OUTPUT_DIR}/${query_base}-justin.yaml"
    sed -e "s|image: flink-justin:dais|image: ${FLINK_IMAGE}|g" \
        -e 's|job.autoscaler.justin.enabled: "JUSTIN"|job.autoscaler.justin.enabled: "true"|g' \
        "$f" > "$JUSTIN_OUT"
    echo -e "  ${GREEN}✓${NC} ${query_base}-justin.yaml"
done

echo ""
echo "── Generated files ──────────────────────────────────────────"
ls -la "${OUTPUT_DIR}/"

echo ""
echo "============================================================"
echo -e "${GREEN} Job YAML files prepared!${NC}"
echo ""
echo " To submit a job (example):"
echo "   kubectl apply -f ${OUTPUT_DIR}/query5-justin.yaml"
echo ""
echo " To delete a running job:"
echo "   kubectl delete -f ${OUTPUT_DIR}/query5-justin.yaml"
echo ""
echo " To watch job status:"
echo "   kubectl get flinkdeployment"
echo "   kubectl get pods -w"
echo ""
echo " To access Flink UI after a job is running:"
echo "   kubectl port-forward svc/flink-rest 8081:8081"
