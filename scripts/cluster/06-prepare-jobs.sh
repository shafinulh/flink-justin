#!/bin/bash
###############################################################################
# 06-prepare-jobs.sh
#
# Prepares Nexmark job YAML files so they use the correct Docker image from
# our local registry. This includes the existing DataStream CRs from
# notebooks/nexmark and a curated set of SQL CRs generated from a template.
#
# This does NOT submit any jobs. It only writes missing YAML files so they
# are ready to be submitted via:
#     kubectl apply -f <query>.yaml
#
# Existing files are preserved to allow manual tuning. Set
# FORCE_REGENERATE=true to rebuild them from source/templates.
#
# For each DataStream query (q1, q2, q3, q5, q8, q11), two variants are prepared:
#   - queryX-ds2.yaml      (job.autoscaler.justin.enabled = false)
#   - queryX-justin.yaml   (job.autoscaler.justin.enabled = true)
# For each curated SQL query, two variants are also prepared:
#   - qX-sql-ds2.yaml      (job.autoscaler.justin.enabled = false)
#   - qX-sql-justin.yaml   (job.autoscaler.justin.enabled = true)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

NOTEBOOKS_DIR="${PROJECT_ROOT}/notebooks/nexmark"
OUTPUT_DIR="${PROJECT_ROOT}/scripts/cluster/jobs"
SQL_TEMPLATE="${SCRIPT_DIR}/templates/nexmark-sql-job.yaml.template"
NEXMARK_ROOT="${NEXMARK_ROOT:-/opt/nexmark-v2}"
NEXMARK_SQL_DIR="${NEXMARK_ROOT}/nexmark-flink/src/main/resources/queries"
NEXMARK_CONF="${NEXMARK_ROOT}/nexmark-flink/src/main/resources/conf/nexmark.yaml"
DEFAULT_SQL_WORKLOAD_SUITE="${NEXMARK_SQL_WORKLOAD_SUITE:-sp1m}"
FORCE_REGENERATE="${FORCE_REGENERATE:-false}"
SQL_QUERY_NAMES=(
    q20
    q20_unique
    q9
    q9_unique
    q4
    q4_unique
    q18
    q19
    q1
    q3
    q5
    q8
    q11
)

read_suite_value() {
    local suffix="$1"
    local fallback="$2"
    local prefix="nexmark.workload.suite.${DEFAULT_SQL_WORKLOAD_SUITE}.${suffix}:"
    local value=""

    if [[ -f "${NEXMARK_CONF}" ]]; then
        value=$(awk -v prefix="${prefix}" '
            index($0, prefix) == 1 {
                sub(/^[^:]+:[[:space:]]*/, "", $0)
                gsub(/"/, "", $0)
                print $0
                exit
            }
        ' "${NEXMARK_CONF}")
    fi

    if [[ -n "${value}" ]]; then
        echo "${value}"
    else
        echo "${fallback}"
    fi
}

DEFAULT_SQL_TPS="${NEXMARK_SQL_TPS:-$(read_suite_value "tps" "50000")}"
DEFAULT_SQL_EVENTS="${NEXMARK_SQL_EVENTS:-$(read_suite_value "events.num" "12500000")}"
DEFAULT_SQL_MAX_EMIT_SPEED="${NEXMARK_SQL_MAX_EMIT_SPEED:-false}"

echo "============================================================"
echo " Preparing Nexmark Benchmark Jobs"
echo "============================================================"
echo " SQL workload suite: ${DEFAULT_SQL_WORKLOAD_SUITE}"
echo " SQL defaults: tps=${DEFAULT_SQL_TPS}, events=${DEFAULT_SQL_EVENTS}, max-emit-speed=${DEFAULT_SQL_MAX_EMIT_SPEED}"

mkdir -p "${OUTPUT_DIR}"

write_notice_for_existing_file() {
    local output_file="$1"
    if [[ -f "${output_file}" && "${FORCE_REGENERATE}" != "true" ]]; then
        echo -e "  ${YELLOW}-${NC} $(basename "${output_file}") (kept existing file)"
        return 1
    fi
    return 0
}

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
    if write_notice_for_existing_file "${DS2_OUT}"; then
        sed -e "s|image: flink-justin:dais|image: ${FLINK_IMAGE}|g" \
            -e 's|job.autoscaler.justin.enabled: "JUSTIN"|job.autoscaler.justin.enabled: "false"|g' \
            "$f" > "$DS2_OUT"
        echo -e "  ${GREEN}✓${NC} ${query_base}-ds2.yaml"
    fi

    # Generate justin variant (justin enabled)
    JUSTIN_OUT="${OUTPUT_DIR}/${query_base}-justin.yaml"
    if write_notice_for_existing_file "${JUSTIN_OUT}"; then
        sed -e "s|image: flink-justin:dais|image: ${FLINK_IMAGE}|g" \
            -e 's|job.autoscaler.justin.enabled: "JUSTIN"|job.autoscaler.justin.enabled: "true"|g' \
            "$f" > "$JUSTIN_OUT"
        echo -e "  ${GREEN}✓${NC} ${query_base}-justin.yaml"
    fi
done

echo ""
echo "── Generated files ──────────────────────────────────────────"
ls -la "${OUTPUT_DIR}/"

if [[ -f "${SQL_TEMPLATE}" && -d "${NEXMARK_SQL_DIR}" ]]; then
    echo ""
    echo "── Generating Nexmark SQL job variants ─────────────────────"
    for query_name in "${SQL_QUERY_NAMES[@]}"; do
        query_file="${NEXMARK_SQL_DIR}/${query_name}.sql"
        if [[ ! -f "${query_file}" ]]; then
            echo -e "${YELLOW}! Missing SQL file: ${query_file}${NC}"
            exit 1
        fi

        DS2_OUT="${OUTPUT_DIR}/${query_name}-sql-ds2.yaml"
        if write_notice_for_existing_file "${DS2_OUT}"; then
            sed -e "s|__FLINK_IMAGE__|${FLINK_SQL_IMAGE}|g" \
                -e 's|__JUSTIN_ENABLED__|false|g' \
                -e "s|__QUERY__|${query_name}|g" \
                -e "s|__TPS__|${DEFAULT_SQL_TPS}|g" \
                -e "s|__EVENTS__|${DEFAULT_SQL_EVENTS}|g" \
                -e "s|__MAX_EMIT_SPEED__|${DEFAULT_SQL_MAX_EMIT_SPEED}|g" \
                -e "s|__PIPELINE_NAME__|${query_name}-sql-ds2|g" \
                "${SQL_TEMPLATE}" > "${DS2_OUT}"
            echo -e "  ${GREEN}✓${NC} ${query_name}-sql-ds2.yaml"
        fi

        JUSTIN_OUT="${OUTPUT_DIR}/${query_name}-sql-justin.yaml"
        if write_notice_for_existing_file "${JUSTIN_OUT}"; then
            sed -e "s|__FLINK_IMAGE__|${FLINK_SQL_IMAGE}|g" \
                -e 's|__JUSTIN_ENABLED__|true|g' \
                -e "s|__QUERY__|${query_name}|g" \
                -e "s|__TPS__|${DEFAULT_SQL_TPS}|g" \
                -e "s|__EVENTS__|${DEFAULT_SQL_EVENTS}|g" \
                -e "s|__MAX_EMIT_SPEED__|${DEFAULT_SQL_MAX_EMIT_SPEED}|g" \
                -e "s|__PIPELINE_NAME__|${query_name}-sql-justin|g" \
                "${SQL_TEMPLATE}" > "${JUSTIN_OUT}"
            echo -e "  ${GREEN}✓${NC} ${query_name}-sql-justin.yaml"
        fi
    done
fi

echo ""
echo "── Final job set ────────────────────────────────────────────"
ls -la "${OUTPUT_DIR}/"

echo ""
echo "============================================================"
echo -e "${GREEN} Job YAML files prepared!${NC}"
echo " Existing files are preserved unless FORCE_REGENERATE=true is set."
echo ""
echo " To submit a job (example):"
echo "   kubectl apply -f ${OUTPUT_DIR}/query5-justin.yaml"
echo "   kubectl apply -f ${OUTPUT_DIR}/q20_unique-sql-justin.yaml"
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
