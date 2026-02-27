#!/bin/bash
###############################################################################
# 03-deploy-monitoring.sh
#
# Deploys the monitoring & infrastructure stack:
#   1. ClusterRoleBinding for default SA (needed by Flink pods)
#   2. cert-manager
#   3. local-path-provisioner (for PVCs)
#   4. Prometheus + Grafana via kube-prometheus-stack Helm chart
#   5. PodMonitor for Flink metrics
#   6. Loki for log aggregation
#
# Adapted from the original authors' common_modules.sh
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Deploying Monitoring & Infrastructure Stack"
echo "============================================================"

echo ""
echo "── Step 1: ClusterRoleBinding (default SA → cluster-admin) ──"
kubectl apply -f "${COMMON_INFRA}/cluster-role-binding-default.yaml"
echo -e "${GREEN}✓${NC} ClusterRoleBinding applied"

echo ""
echo "── Step 2: cert-manager ─────────────────────────────────────"
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml
echo "  Waiting for cert-manager webhook..."
kubectl --namespace cert-manager rollout status deployment/cert-manager-webhook --timeout=120s
echo -e "${GREEN}✓${NC} cert-manager ready"

echo ""
echo "── Step 3: Create 'manager' namespace ───────────────────────"
kubectl create namespace manager 2>/dev/null || echo "  (already exists)"
echo -e "${GREEN}✓${NC} manager namespace ready"

echo ""
echo "── Step 4: local-path-provisioner ───────────────────────────"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.21/deploy/local-path-storage.yaml
echo -e "${GREEN}✓${NC} local-path-provisioner installed"

echo ""
echo "  Sleeping 30s for provisioner to settle..."
sleep 30

echo ""
echo "── Step 5: Prometheus + Grafana ─────────────────────────────"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
helm install --namespace manager \
    --version "${PROM_CHART_VERSION}" \
    prom prometheus-community/kube-prometheus-stack \
    -f "${COMMON_INFRA}/values-prom.yaml"
echo -e "${GREEN}✓${NC} Prometheus stack installed"

echo ""
echo "── Step 6: PodMonitor for Flink metrics ─────────────────────"
kubectl apply -f "${COMMON_INFRA}/pod-monitor.yaml"
echo -e "${GREEN}✓${NC} PodMonitor applied"

echo ""
echo "── Step 7: Loki ─────────────────────────────────────────────"
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
helm upgrade --install loki grafana/loki-stack \
    --namespace manager \
    --version 2.10.2 \
    -f "${COMMON_INFRA}/values-loki.yaml" \
    --set loki.podSecurityPolicy.enabled=false \
    --set promtail.podSecurityPolicy.enabled=false
echo -e "${GREEN}✓${NC} Loki installed"

echo ""
echo "── Step 8: Grafana dashboards ───────────────────────────────"
# Provision Justin dashboards via labeled ConfigMaps (Grafana sidecar auto-detects them)
kubectl create configmap grafana-dashboard-justin \
    --from-file=justin-dashboard.json="${COMMON_INFRA}/grafana.json" \
    -n manager 2>/dev/null || true
kubectl label configmap grafana-dashboard-justin grafana_dashboard=1 -n manager --overwrite

kubectl create configmap grafana-dashboard-autoscaling \
    --from-file=autoscaling-dashboard.json="${PROJECT_ROOT}/flink-kubernetes-operator/examples/autoscaling/grafana.json" \
    -n manager 2>/dev/null || true
kubectl label configmap grafana-dashboard-autoscaling grafana_dashboard=1 -n manager --overwrite

kubectl rollout restart deployment prom-grafana -n manager
kubectl rollout status deployment prom-grafana -n manager --timeout=90s
echo -e "${GREEN}✓${NC} Grafana dashboards provisioned"

echo ""
echo "  Sleeping 10s for things to settle..."
sleep 10

echo ""
echo "── Step 9: Verify monitoring pods ───────────────────────────"
echo "  Pods in 'manager' namespace:"
kubectl get pods -n manager
echo ""
echo "  Pods in 'cert-manager' namespace:"
kubectl get pods -n cert-manager

echo ""
echo "============================================================"
echo -e "${GREEN} Monitoring stack deployed!${NC}"
echo ""
echo " Access services via port-forward:"
echo "   Grafana:    kubectl port-forward -n manager svc/prom-grafana 3000:80"
echo "               (login: admin / prom-operator)"
echo "   Prometheus: kubectl port-forward -n manager svc/prom-kube-prometheus-stack-prometheus 9090:9090"
echo ""
echo "Next: run 04-build-images.sh"
