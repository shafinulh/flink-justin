#!/bin/bash
###############################################################################
# 06-generate-jobs.sh
#
# Generates Nexmark job YAML files from templates. Jobs are placed in the
# jobs/ directory (which is git-ignored — each collaborator generates their
# own to match their environment).
#
# Usage:
#   ./06-generate-jobs.sh [MODE...]
#
# Modes (can combine multiple):
#   default   — DataStream queries (query{N}-ds2 / query{N}-justin)
#   ssd       — DataStream queries with RocksDB on SSD
#   sql       — SQL queries (q{name}-sql-ds2 / q{name}-sql-justin)
#   sql-ssd   — SQL queries with RocksDB on SSD
#   all       — All of the above (default if none given)
#
# Options (env vars):
#   FORCE_REGENERATE=true   Overwrite existing files (default: false)
#   SSD_HOST_PATH=<path>    Host path for RocksDB SSD (default: /data/flink/rocksdb)
#   CLEAN=true              Delete all files in jobs/ before generating
#
# Examples:
#   ./06-generate-jobs.sh                             # generate everything
#   ./06-generate-jobs.sh default sql                 # DataStream + SQL (no SSD)
#   ./06-generate-jobs.sh ssd                         # only SSD DataStream variants
#   CLEAN=true ./06-generate-jobs.sh all              # wipe jobs/, regenerate all
#   FORCE_REGENERATE=true ./06-generate-jobs.sh sql   # overwrite SQL jobs
#   SSD_HOST_PATH=/mnt/nvme ./06-generate-jobs.sh ssd # custom SSD mount path
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

TEMPLATE_DIR="${SCRIPT_DIR}/templates"
OUTPUT_DIR="${SCRIPT_DIR}/jobs"
NEXMARK_ROOT="${NEXMARK_ROOT:-/opt/nexmark-v2}"
NEXMARK_SQL_DIR="${NEXMARK_ROOT}/nexmark-flink/src/main/resources/queries"
NEXMARK_CONF="${NEXMARK_ROOT}/nexmark-flink/src/main/resources/conf/nexmark.yaml"
DEFAULT_SQL_WORKLOAD_SUITE="${NEXMARK_SQL_WORKLOAD_SUITE:-sp1m}"
FORCE_REGENERATE="${FORCE_REGENERATE:-false}"
SSD_HOST_PATH="${SSD_HOST_PATH:-/data/flink/rocksdb}"
CLEAN="${CLEAN:-false}"

# ── DataStream queries (numbers must match template files) ──────────────────
DS_QUERY_NAMES=(1 2 3 5 8 11)

# ── SQL queries ─────────────────────────────────────────────────────────────
SQL_QUERY_NAMES=(
    q20 q20_unique q9 q9_unique q4 q4_unique
    q18 q19 q1 q3 q5 q8 q11
)

# ── Parse mode arguments ────────────────────────────────────────────────────
MODES=("$@")
if [[ ${#MODES[@]} -eq 0 ]]; then
    MODES=("all")
fi

DO_DEFAULT=false
DO_SSD=false
DO_SQL=false
DO_SQL_SSD=false

for mode in "${MODES[@]}"; do
    case "$mode" in
        default)  DO_DEFAULT=true ;;
        ssd)      DO_SSD=true ;;
        sql)      DO_SQL=true ;;
        sql-ssd)  DO_SQL_SSD=true ;;
        all)      DO_DEFAULT=true; DO_SSD=true; DO_SQL=true; DO_SQL_SSD=true ;;
        *)
            echo -e "${RED}Unknown mode: $mode${NC}"
            echo "Valid modes: default, ssd, sql, sql-ssd, all"
            exit 1
            ;;
    esac
done

# ── Helper: read nexmark suite value ────────────────────────────────────────
read_suite_value() {
    local suffix="$1" fallback="$2"
    local prefix="nexmark.workload.suite.${DEFAULT_SQL_WORKLOAD_SUITE}.${suffix}:"
    local value=""
    if [[ -f "${NEXMARK_CONF}" ]]; then
        value=$(awk -v prefix="${prefix}" '
            index($0, prefix) == 1 {
                sub(/^[^:]+:[[:space:]]*/, "", $0); gsub(/"/, "", $0); print $0; exit
            }' "${NEXMARK_CONF}")
    fi
    echo "${value:-${fallback}}"
}

DEFAULT_SQL_TPS="${NEXMARK_SQL_TPS:-$(read_suite_value "tps" "50000")}"
DEFAULT_SQL_EVENTS="${NEXMARK_SQL_EVENTS:-$(read_suite_value "events.num" "12500000")}"
DEFAULT_SQL_MAX_EMIT_SPEED="${NEXMARK_SQL_MAX_EMIT_SPEED:-false}"
DEFAULT_SQL_PROB_DELAYED_EVENT="${NEXMARK_SQL_PROB_DELAYED_EVENT:-0}"
DEFAULT_SQL_OCCASIONAL_DELAY_MIN_SEC="${NEXMARK_SQL_OCCASIONAL_DELAY_MIN_SEC:-60}"
DEFAULT_SQL_OCCASIONAL_DELAY_SEC="${NEXMARK_SQL_OCCASIONAL_DELAY_SEC:-240}"
DEFAULT_SQL_OUT_OF_ORDER_GROUP_SIZE="${NEXMARK_SQL_OUT_OF_ORDER_GROUP_SIZE:-1}"

# ── Print banner ────────────────────────────────────────────────────────────
echo "============================================================"
echo " Preparing Nexmark Benchmark Jobs"
echo "============================================================"
echo " Modes:        ${MODES[*]}"
echo " SQL suite:    ${DEFAULT_SQL_WORKLOAD_SUITE}"
echo " SQL defaults: tps=${DEFAULT_SQL_TPS}, events=${DEFAULT_SQL_EVENTS}"
echo " SSD path:     ${SSD_HOST_PATH}"
echo " Force regen:  ${FORCE_REGENERATE}"
echo " Clean first:  ${CLEAN}"

# ── Clean if requested ──────────────────────────────────────────────────────
if [[ "${CLEAN}" == "true" ]]; then
    echo ""
    echo -e "── ${RED}Cleaning jobs/ directory${NC} ─────────────────────────────────"
    rm -f "${OUTPUT_DIR}"/*.yaml 2>/dev/null || true
    echo "  Removed all .yaml files from jobs/"
fi

mkdir -p "${OUTPUT_DIR}"

generated=0

# ── Helper: skip existing files ─────────────────────────────────────────────
skip_existing() {
    local f="$1"
    if [[ -f "$f" && "${FORCE_REGENERATE}" != "true" ]]; then
        echo -e "  ${YELLOW}-${NC} $(basename "$f") (kept existing)"
        return 0  # true = skip
    fi
    return 1      # false = generate
}

# ── Helper: inject SSD config into any YAML (DataStream or SQL) ─────────────
# Adds:
#   - state.backend.rocksdb.localdir to flinkConfiguration
#   - hostPath volume + volumeMount to the taskManager podTemplate
inject_ssd_config() {
    local input="$1" output="$2" ssd_path="$3"
    python3 -c "
import sys, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

checkpoint_host_path = sys.argv[2]
checkpoint_mount_path = sys.argv[3]
ssd_path = sys.argv[4]

def ensure_named(entries, name, value):
    for entry in entries:
        if entry.get('name') == name:
            entry.update(value)
            return
    entries.append({'name': name, **value})

# Add rocksdb localdir
doc['spec']['flinkConfiguration']['state.backend.rocksdb.localdir'] = '/data/flink/rocksdb'

# Add volume mount to TM pod template
tm = doc['spec']['taskManager']['podTemplate']['spec']
containers = tm.setdefault('containers', [])
main_c = None
for c in containers:
    if c.get('name') == 'flink-main-container':
        main_c = c
        break
if main_c is None:
    main_c = {'name': 'flink-main-container'}
    containers.append(main_c)
mounts = main_c.setdefault('volumeMounts', [])
ensure_named(mounts, 'checkpoint-storage', {'mountPath': checkpoint_mount_path})
ensure_named(mounts, 'rocksdb-ssd', {'mountPath': '/data/flink/rocksdb'})

# Add hostPath volumes
volumes = tm.setdefault('volumes', [])
ensure_named(volumes, 'checkpoint-storage', {'hostPath': {'path': checkpoint_host_path, 'type': 'DirectoryOrCreate'}})
ensure_named(volumes, 'rocksdb-ssd', {'hostPath': {'path': ssd_path, 'type': 'DirectoryOrCreate'}})

with open(sys.argv[5], 'w') as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False, width=200)
" "$input" "$CHECKPOINT_HOST_PATH" "$CHECKPOINT_MOUNT_PATH" "$ssd_path" "$output"
}

# ── Helper: generate a job from a template ───────────────────────────────────
# Usage: generate_from_template <template> <output> <image> <justin> [extra sed args]
generate_from_template() {
    local template="$1" outfile="$2" image="$3" justin="$4"
    shift 4
    local sed_args=(
        -e "s|__FLINK_IMAGE__|${image}|g"
        -e "s|__JUSTIN_ENABLED__|${justin}|g"
        -e "s|__CHECKPOINT_HOST_PATH__|${CHECKPOINT_HOST_PATH}|g"
        -e "s|__CHECKPOINT_MOUNT_PATH__|${CHECKPOINT_MOUNT_PATH}|g"
        -e "s|__CHECKPOINT_DIR__|${CHECKPOINT_DIR}|g"
        -e "s|__SAVEPOINT_DIR__|${SAVEPOINT_DIR}|g"
    )
    # Append any extra sed expressions (for SQL placeholders)
    sed_args+=("$@")
    sed "${sed_args[@]}" "$template" > "$outfile"
}

###############################################################################
# DataStream queries (from per-query templates in templates/)
###############################################################################
if $DO_DEFAULT; then
    echo ""
    echo "── DataStream queries (default) ─────────────────────────────"
    for qnum in "${DS_QUERY_NAMES[@]}"; do
        template="${TEMPLATE_DIR}/nexmark-query${qnum}.yaml.template"
        if [[ ! -f "$template" ]]; then
            echo -e "  ${YELLOW}! Missing template: nexmark-query${qnum}.yaml.template${NC}"
            continue
        fi

        out="${OUTPUT_DIR}/query${qnum}-ds2.yaml"
        if ! skip_existing "$out"; then
            generate_from_template "$template" "$out" "$FLINK_IMAGE" "false"
            echo -e "  ${GREEN}✓${NC} query${qnum}-ds2.yaml"
            ((++generated))
        fi

        out="${OUTPUT_DIR}/query${qnum}-justin.yaml"
        if ! skip_existing "$out"; then
            generate_from_template "$template" "$out" "$FLINK_IMAGE" "true"
            echo -e "  ${GREEN}✓${NC} query${qnum}-justin.yaml"
            ((++generated))
        fi
    done
fi

if $DO_SSD; then
    echo ""
    echo "── DataStream queries (SSD) ───────────────────────────────"
    for qnum in "${DS_QUERY_NAMES[@]}"; do
        template="${TEMPLATE_DIR}/nexmark-query${qnum}.yaml.template"
        if [[ ! -f "$template" ]]; then
            echo -e "  ${YELLOW}! Missing template: nexmark-query${qnum}.yaml.template${NC}"
            continue
        fi

        out="${OUTPUT_DIR}/query${qnum}-ssd-ds2.yaml"
        if ! skip_existing "$out"; then
            tmp=$(mktemp)
            generate_from_template "$template" "$tmp" "$FLINK_IMAGE" "false"
            inject_ssd_config "$tmp" "$out" "$SSD_HOST_PATH"
            rm -f "$tmp"
            echo -e "  ${GREEN}✓${NC} query${qnum}-ssd-ds2.yaml"
            ((++generated))
        fi

        out="${OUTPUT_DIR}/query${qnum}-ssd-justin.yaml"
        if ! skip_existing "$out"; then
            tmp=$(mktemp)
            generate_from_template "$template" "$tmp" "$FLINK_IMAGE" "true"
            inject_ssd_config "$tmp" "$out" "$SSD_HOST_PATH"
            rm -f "$tmp"
            echo -e "  ${GREEN}✓${NC} query${qnum}-ssd-justin.yaml"
            ((++generated))
        fi
    done
fi

###############################################################################
# SQL queries (from single SQL template + inject_ssd_config for SSD)
###############################################################################
SQL_TEMPLATE="${TEMPLATE_DIR}/nexmark-sql-job.yaml.template"

if $DO_SQL && [[ -f "${SQL_TEMPLATE}" && -d "${NEXMARK_SQL_DIR}" ]]; then
    echo ""
    echo "── SQL queries (default) ────────────────────────────────────"
    for qname in "${SQL_QUERY_NAMES[@]}"; do
        qfile="${NEXMARK_SQL_DIR}/${qname}.sql"
        if [[ ! -f "$qfile" ]]; then
            echo -e "  ${YELLOW}! Missing SQL: ${qfile}${NC}"
            continue
        fi

        out="${OUTPUT_DIR}/${qname}-sql-ds2.yaml"
        if ! skip_existing "$out"; then
            generate_from_template "$SQL_TEMPLATE" "$out" "$FLINK_SQL_IMAGE" "false" \
                -e "s|__QUERY__|${qname}|g" \
                -e "s|__TPS__|${DEFAULT_SQL_TPS}|g" \
                -e "s|__EVENTS__|${DEFAULT_SQL_EVENTS}|g" \
                -e "s|__MAX_EMIT_SPEED__|${DEFAULT_SQL_MAX_EMIT_SPEED}|g" \
                -e "s|__PROB_DELAYED_EVENT__|${DEFAULT_SQL_PROB_DELAYED_EVENT}|g" \
                -e "s|__OCCASIONAL_DELAY_MIN_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_MIN_SEC}|g" \
                -e "s|__OCCASIONAL_DELAY_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_SEC}|g" \
                -e "s|__OUT_OF_ORDER_GROUP_SIZE__|${DEFAULT_SQL_OUT_OF_ORDER_GROUP_SIZE}|g" \
                -e "s|__PIPELINE_NAME__|${qname}-sql-ds2|g"
            echo -e "  ${GREEN}✓${NC} ${qname}-sql-ds2.yaml"
            ((++generated))
        fi

        out="${OUTPUT_DIR}/${qname}-sql-justin.yaml"
        if ! skip_existing "$out"; then
            generate_from_template "$SQL_TEMPLATE" "$out" "$FLINK_SQL_IMAGE" "true" \
                -e "s|__QUERY__|${qname}|g" \
                -e "s|__TPS__|${DEFAULT_SQL_TPS}|g" \
                -e "s|__EVENTS__|${DEFAULT_SQL_EVENTS}|g" \
                -e "s|__MAX_EMIT_SPEED__|${DEFAULT_SQL_MAX_EMIT_SPEED}|g" \
                -e "s|__PROB_DELAYED_EVENT__|${DEFAULT_SQL_PROB_DELAYED_EVENT}|g" \
                -e "s|__OCCASIONAL_DELAY_MIN_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_MIN_SEC}|g" \
                -e "s|__OCCASIONAL_DELAY_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_SEC}|g" \
                -e "s|__OUT_OF_ORDER_GROUP_SIZE__|${DEFAULT_SQL_OUT_OF_ORDER_GROUP_SIZE}|g" \
                -e "s|__PIPELINE_NAME__|${qname}-sql-justin|g"
            echo -e "  ${GREEN}✓${NC} ${qname}-sql-justin.yaml"
            ((++generated))
        fi
    done
fi

if $DO_SQL_SSD && [[ -f "${SQL_TEMPLATE}" && -d "${NEXMARK_SQL_DIR}" ]]; then
    echo ""
    echo "── SQL queries (SSD) ────────────────────────────────────────"
    for qname in "${SQL_QUERY_NAMES[@]}"; do
        qfile="${NEXMARK_SQL_DIR}/${qname}.sql"
        if [[ ! -f "$qfile" ]]; then
            echo -e "  ${YELLOW}! Missing SQL: ${qfile}${NC}"
            continue
        fi

        out="${OUTPUT_DIR}/${qname}-sql-ssd-ds2.yaml"
        if ! skip_existing "$out"; then
            tmp=$(mktemp)
            generate_from_template "$SQL_TEMPLATE" "$tmp" "$FLINK_SQL_IMAGE" "false" \
                -e "s|__QUERY__|${qname}|g" \
                -e "s|__TPS__|${DEFAULT_SQL_TPS}|g" \
                -e "s|__EVENTS__|${DEFAULT_SQL_EVENTS}|g" \
                -e "s|__MAX_EMIT_SPEED__|${DEFAULT_SQL_MAX_EMIT_SPEED}|g" \
                -e "s|__PROB_DELAYED_EVENT__|${DEFAULT_SQL_PROB_DELAYED_EVENT}|g" \
                -e "s|__OCCASIONAL_DELAY_MIN_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_MIN_SEC}|g" \
                -e "s|__OCCASIONAL_DELAY_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_SEC}|g" \
                -e "s|__OUT_OF_ORDER_GROUP_SIZE__|${DEFAULT_SQL_OUT_OF_ORDER_GROUP_SIZE}|g" \
                -e "s|__PIPELINE_NAME__|${qname}-sql-ssd-ds2|g"
            inject_ssd_config "$tmp" "$out" "$SSD_HOST_PATH"
            rm -f "$tmp"
            echo -e "  ${GREEN}✓${NC} ${qname}-sql-ssd-ds2.yaml"
            ((++generated))
        fi

        out="${OUTPUT_DIR}/${qname}-sql-ssd-justin.yaml"
        if ! skip_existing "$out"; then
            tmp=$(mktemp)
            generate_from_template "$SQL_TEMPLATE" "$tmp" "$FLINK_SQL_IMAGE" "true" \
                -e "s|__QUERY__|${qname}|g" \
                -e "s|__TPS__|${DEFAULT_SQL_TPS}|g" \
                -e "s|__EVENTS__|${DEFAULT_SQL_EVENTS}|g" \
                -e "s|__MAX_EMIT_SPEED__|${DEFAULT_SQL_MAX_EMIT_SPEED}|g" \
                -e "s|__PROB_DELAYED_EVENT__|${DEFAULT_SQL_PROB_DELAYED_EVENT}|g" \
                -e "s|__OCCASIONAL_DELAY_MIN_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_MIN_SEC}|g" \
                -e "s|__OCCASIONAL_DELAY_SEC__|${DEFAULT_SQL_OCCASIONAL_DELAY_SEC}|g" \
                -e "s|__OUT_OF_ORDER_GROUP_SIZE__|${DEFAULT_SQL_OUT_OF_ORDER_GROUP_SIZE}|g" \
                -e "s|__PIPELINE_NAME__|${qname}-sql-ssd-justin|g"
            inject_ssd_config "$tmp" "$out" "$SSD_HOST_PATH"
            rm -f "$tmp"
            echo -e "  ${GREEN}✓${NC} ${qname}-sql-ssd-justin.yaml"
            ((++generated))
        fi
    done
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "── Generated ${generated} file(s) ──────────────────────────────"
ls "${OUTPUT_DIR}/" 2>/dev/null | column || echo "  (no files)"
echo ""
echo "============================================================"
echo -e "${GREEN} Done!${NC}  Existing files preserved unless FORCE_REGENERATE=true."
echo ""
echo " Submit:  kubectl apply -f ${OUTPUT_DIR}/query5-justin.yaml"
echo " Delete:  kubectl delete -f ${OUTPUT_DIR}/query5-justin.yaml"
echo " Watch:   kubectl get flinkdeployment -w"
