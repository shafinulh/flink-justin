#!/bin/bash
###############################################################################
# env.sh - Cluster environment configuration
#
# Edit this file to match your physical machines.
# All other scripts source this file.
###############################################################################

# ── Machine hostnames (must be resolvable via SSH) ──────────────────────────
export CONTROL_PLANE="c165"            # Kubernetes control-plane + JobManager
export WORKERS=("c182" "c167")         # TaskManager worker nodes
export ALL_NODES=("$CONTROL_PLANE" "${WORKERS[@]}")

# ── IP of the control-plane (used for the local Docker registry) ────────────
export CONTROL_PLANE_IP="142.150.234.165"

# ── Local Docker registry running on the control-plane ──────────────────────
export REGISTRY="${CONTROL_PLANE_IP}:5000"

# ── Image names / tags ──────────────────────────────────────────────────────
export FLINK_IMAGE_NAME="flink-justin"
export FLINK_IMAGE_TAG="dais"
export FLINK_SQL_IMAGE_NAME="flink-justin-sql"
export FLINK_SQL_IMAGE_TAG="dais"
export OPERATOR_IMAGE_NAME="flink-kubernetes-operator"
export OPERATOR_IMAGE_TAG="dais"

export FLINK_IMAGE="${REGISTRY}/${FLINK_IMAGE_NAME}:${FLINK_IMAGE_TAG}"
export FLINK_SQL_IMAGE="${REGISTRY}/${FLINK_SQL_IMAGE_NAME}:${FLINK_SQL_IMAGE_TAG}"
export OPERATOR_IMAGE="${REGISTRY}/${OPERATOR_IMAGE_NAME}:${OPERATOR_IMAGE_TAG}"
export NEXMARK_FLINK_VERSION="1.18-SNAPSHOT"
export CRI_RUNTIME_ENDPOINT="unix:///run/containerd/containerd.sock"

if [[ -n "${JAVA_HOME:-}" ]] && [[ ! -x "${JAVA_HOME}/bin/java" ]]; then
    unset JAVA_HOME
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
    for java_cmd in javac java; do
        if command -v "${java_cmd}" >/dev/null 2>&1; then
            JAVA_BIN="$(readlink -f "$(command -v "${java_cmd}")" 2>/dev/null || true)"
            if [[ -n "${JAVA_BIN}" ]]; then
                export JAVA_HOME="$(cd "$(dirname "${JAVA_BIN}")/.." && pwd)"
                break
            fi
        fi
    done
fi

# ── Paths (relative to this checkout) ──────────────────────────────────────
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AUTOSCALING_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"
export SHARED_KUBECONFIG="/etc/flink-justin/kubeconfig"
export HELM_CHART="${PROJECT_ROOT}/flink-kubernetes-operator/helm/flink-kubernetes-operator"
export AUTOSCALER_VALUES="${PROJECT_ROOT}/flink-kubernetes-operator/examples/autoscaling/values.yaml"
export COMMON_INFRA="${PROJECT_ROOT}/scripts/infra/common"
export NEXMARK_ROOT="${NEXMARK_ROOT:-${AUTOSCALING_ROOT}/nexmark-v2}"
export ROCKSDB_OPTIONS_HOME="${ROCKSDB_OPTIONS_HOME:-${AUTOSCALING_ROOT}/rocksdb-options}"
export ROCKSDB_OPTIONS_JAR_NAME="${ROCKSDB_OPTIONS_JAR_NAME:-rocksdb-options-1.0-SNAPSHOT.jar}"
export ROCKSDB_OPTIONS_JAR="${ROCKSDB_OPTIONS_JAR:-${ROCKSDB_OPTIONS_HOME}/target/${ROCKSDB_OPTIONS_JAR_NAME}}"
export EXPERIMENTS_ROOT="${EXPERIMENTS_ROOT:-/mnt/experiments/autoscaling-experiments}"
export CHECKPOINT_HOST_PATH="${CHECKPOINT_HOST_PATH:-${EXPERIMENTS_ROOT}/flink-state}"
export CHECKPOINT_MOUNT_PATH="${CHECKPOINT_MOUNT_PATH:-${EXPERIMENTS_ROOT}/flink-state}"
export CHECKPOINT_DIR="${CHECKPOINT_DIR:-file://${CHECKPOINT_MOUNT_PATH}/checkpoints}"
export SAVEPOINT_DIR="${SAVEPOINT_DIR:-file://${CHECKPOINT_MOUNT_PATH}/savepoints}"

# Use one shared kubeconfig for the machine; fall back to admin.conf when available.
if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -r "${SHARED_KUBECONFIG}" ]]; then
        export KUBECONFIG="${SHARED_KUBECONFIG}"
    elif [[ -r "/etc/kubernetes/admin.conf" ]]; then
        export KUBECONFIG="/etc/kubernetes/admin.conf"
    fi
fi

# ── Node labels used by Justin (matches the original authors' convention) ───
export LABEL_MANAGER="tier=manager"
export LABEL_JOBMANAGER="tier=jobmanager"
export LABEL_TASKMANAGER="tier=taskmanager"

# ── Prometheus / Grafana helm chart versions (keep in sync w/ values-prom) ──
export PROM_CHART_VERSION="30.0.2"
export LOKI_CHART_VERSION="2.6.0"
