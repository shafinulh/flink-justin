#!/bin/bash
###############################################################################
# 01-reset-cluster.sh
#
# Tear down any existing Kubernetes state and re-initialize a fresh cluster.
#
# What this does:
#   1. Cleans up old Helm releases, CRDs, and namespaces
#   2. Removes stale NotReady nodes
#   3. Resets kubeadm on workers + control-plane (optional full reset)
#   4. Re-initializes the cluster with kubeadm
#   5. Joins workers back
#   6. Installs Calico CNI
#
# If you just want to clean Flink/monitoring but keep k8s intact,
# use 01b-soft-reset.sh instead.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "============================================================"
echo " Full Cluster Reset"
echo "============================================================"
echo ""
echo -e "${YELLOW}WARNING: This will destroy the existing Kubernetes cluster${NC}"
echo -e "${YELLOW}and create a fresh one. All workloads will be lost.${NC}"
echo ""
read -p "Are you sure? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "── Step 1: Reset workers ────────────────────────────────────"
for worker in "${WORKERS[@]}"; do
    echo "  Resetting ${worker}..."
    ssh "$worker" "sudo kubeadm reset -f 2>/dev/null || true"
    ssh "$worker" "sudo rm -rf /etc/cni/net.d /var/lib/etcd /var/lib/kubelet/*"
    ssh "$worker" "sudo systemctl restart containerd kubelet"
    echo -e "  ${GREEN}✓${NC} ${worker} reset"
done

echo ""
echo "── Step 2: Reset control-plane ──────────────────────────────"
sudo kubeadm reset -f 2>/dev/null || true
sudo rm -rf /etc/cni/net.d /var/lib/etcd
sudo systemctl restart containerd kubelet

echo ""
echo "── Step 3: Initialize control-plane ─────────────────────────"
# Use the control-plane IP as the API server advertise address
sudo kubeadm init \
    --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
    --pod-network-cidr=192.168.0.0/16 \
    --node-name="${CONTROL_PLANE}" \
    --control-plane-endpoint="${CONTROL_PLANE_IP}:6443" \
    | tee /tmp/kubeadm-init.log

echo ""
echo "── Step 4: Configure kubectl ────────────────────────────────"
mkdir -p "${HOME}/.kube"
sudo cp -f /etc/kubernetes/admin.conf "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
sudo install -d -m 750 -o root -g users "$(dirname "${SHARED_KUBECONFIG}")"
sudo install -m 640 -o root -g users /etc/kubernetes/admin.conf "${SHARED_KUBECONFIG}"
echo -e "${GREEN}✓${NC} kubectl configured"

echo ""
echo "── Step 5: Install Calico CNI ───────────────────────────────"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
echo "  Waiting for Calico to be ready..."
kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s || true
echo -e "${GREEN}✓${NC} Calico installed"

echo ""
echo "── Step 6: Generate join command ────────────────────────────"
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "  Join command: ${JOIN_CMD}"

echo ""
echo "── Step 7: Join workers ─────────────────────────────────────"
for worker in "${WORKERS[@]}"; do
    echo "  Joining ${worker}..."
    ssh "$worker" "sudo ${JOIN_CMD} --node-name=${worker}"
    echo -e "  ${GREEN}✓${NC} ${worker} joined"
done

echo ""
echo "── Step 8: Wait for nodes to be Ready ───────────────────────"
echo "  Waiting up to 120s for all nodes..."
for i in $(seq 1 24); do
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
    TOTAL=${#ALL_NODES[@]}
    echo "  ${READY_COUNT}/${TOTAL} nodes ready..."
    if [[ "$READY_COUNT" -ge "$TOTAL" ]]; then
        break
    fi
    sleep 5
done

echo ""
echo "── Final cluster state ──────────────────────────────────────"
kubectl get nodes -o wide
echo ""
echo -e "${GREEN}Cluster reset complete!${NC}"
echo "Next: run 02-label-nodes.sh"
