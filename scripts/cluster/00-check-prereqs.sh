#!/bin/bash
###############################################################################
# 00-check-prereqs.sh
#
# Verify that all machines have the required binaries and services.
# Run this first to catch problems early.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

check_local_bin() {
    local bin=$1
    if command -v "$bin" &>/dev/null; then
        printf "  ${GREEN}✓${NC} %-20s %s\n" "$bin" "$(command -v "$bin")"
    else
        printf "  ${RED}✗${NC} %-20s MISSING\n" "$bin"
        MISSING+=("$bin")
    fi
}

check_remote_bin() {
    local host=$1 bin=$2
    if ssh "$host" "command -v $bin" &>/dev/null; then
        printf "  ${GREEN}✓${NC} %-20s found\n" "$bin"
    else
        printf "  ${RED}✗${NC} %-20s MISSING\n" "$bin"
        MISSING+=("${host}:${bin}")
    fi
}

check_remote_service() {
    local host=$1 svc=$2
    local status
    status=$(ssh "$host" "systemctl is-active $svc 2>/dev/null" || true)
    if [[ "$status" == "active" ]]; then
        printf "  ${GREEN}✓${NC} %-20s active\n" "$svc"
    else
        printf "  ${YELLOW}!${NC} %-20s %s\n" "$svc" "$status"
    fi
}

echo "============================================================"
echo " Prerequisite Check for Justin Cluster"
echo "============================================================"
MISSING=()

echo ""
echo "── Control-plane: ${CONTROL_PLANE} ──────────────────────────"
echo "  Binaries:"
for bin in docker kubeadm kubelet kubectl helm containerd; do
    check_local_bin "$bin"
done
echo "  Services:"
for svc in containerd kubelet docker; do
    status=$(systemctl is-active "$svc" 2>/dev/null || true)
    if [[ "$status" == "active" ]]; then
        printf "  ${GREEN}✓${NC} %-20s active\n" "$svc"
    else
        printf "  ${YELLOW}!${NC} %-20s %s\n" "$svc" "$status"
    fi
done

echo "  Docker registry:"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q registry; then
    printf "  ${GREEN}✓${NC} %-20s running on port 5000\n" "registry"
else
    printf "  ${YELLOW}!${NC} %-20s not running\n" "registry"
fi

for worker in "${WORKERS[@]}"; do
    echo ""
    echo "── Worker: ${worker} ──────────────────────────────────────"
    echo "  Binaries:"
    for bin in kubeadm kubelet kubectl containerd; do
        check_remote_bin "$worker" "$bin"
    done
    echo "  Services:"
    for svc in containerd kubelet; do
        check_remote_service "$worker" "$svc"
    done
    echo "  SSH connectivity:"
    if ssh -o ConnectTimeout=5 "$worker" "echo ok" &>/dev/null; then
        printf "  ${GREEN}✓${NC} %-20s reachable\n" "ssh"
    else
        printf "  ${RED}✗${NC} %-20s unreachable\n" "ssh"
        MISSING+=("${worker}:ssh")
    fi
    echo "  Registry access:"
    if ssh "$worker" "cat /etc/containerd/certs.d/${REGISTRY}/hosts.toml" &>/dev/null; then
        printf "  ${GREEN}✓${NC} %-20s configured\n" "insecure-registry"
    else
        printf "  ${YELLOW}!${NC} %-20s not configured (may need setup)\n" "insecure-registry"
    fi
done

echo ""
echo "============================================================"
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e " ${RED}Some prerequisites are missing:${NC}"
    for m in "${MISSING[@]}"; do
        echo "   - $m"
    done
    echo " Please install them before continuing."
    exit 1
else
    echo -e " ${GREEN}All prerequisites satisfied!${NC}"
fi
