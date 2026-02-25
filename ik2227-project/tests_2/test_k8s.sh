#!/bin/bash
# K8s cluster health + client_basic network check.

set -uo pipefail

# Execute a command inside a Kathará device via kathara exec.
kexec() {
    kathara exec "$1" "$2" 2>/dev/null
}

FAIL=0

# ── 1. Kubernetes cluster health ──────────────────────────────────────────────
echo "=== Kubernetes Cluster Health Check ==="

for CTRL in controller1 controller2; do
    echo
    echo "--- $CTRL ---"

    # ── Nodes ──
    NODES=$(kexec "$CTRL" "kubectl get nodes --no-headers" 2>/dev/null)
    if [[ -z "$NODES" ]] || echo "$NODES" | grep -qi "critical\|not running\|error"; then
        echo "  ❌ kubectl not responding (k3s initializing or container not running)"
        FAIL=1
    elif echo "$NODES" | awk '{print $2}' | grep -wq "NotReady"; then
        echo "  ❌ Not all nodes are Ready"
        echo "$NODES" | sed 's/^/    /'
        FAIL=1
    else
        echo "  ✅ All nodes are Ready"
        echo "$NODES" | sed 's/^/    /'
    fi

    # ── Pods ──
    PODS=$(kexec "$CTRL" "kubectl get pods -A --no-headers" 2>/dev/null)
    if [[ -z "$PODS" ]] || echo "$PODS" | grep -qi "critical\|not running\|error"; then
        echo "  ❌ Could not list pods (container not running?)"
        FAIL=1
    else
        BAD=$(echo "$PODS" | awk '$4 !~ /^(Running|Completed|Succeeded)$/ {print}')
        if [[ -n "$BAD" ]]; then
            echo "  ❌ Some pods are not healthy"
            echo "$BAD" | sed 's/^/    /'
            FAIL=1
        else
            echo "  ✅ All pods are Running or Completed"
        fi
    fi
done

# ── 2. client_basic network configuration ────────────────────────────────────
echo
echo "--- client_basic ---"

# eth0 IP: 10.1.1.2/30
if kexec client_basic "ip addr show eth0" 2>/dev/null | grep -q '10.1.1.2/30'; then
    echo "  ✅ eth0 has 10.1.1.2/30"
else
    echo "  ❌ eth0 missing 10.1.1.2/30"
    echo "     current: $(kexec client_basic 'ip addr show eth0' 2>/dev/null | grep 'inet ' || echo '(none)')"
    FAIL=1
fi

# Default gateway via 10.1.1.1 (as1r1)
if kexec client_basic "ip route show default" 2>/dev/null | grep -q '10.1.1.1'; then
    echo "  ✅ Default gateway via 10.1.1.1 (as1r1)"
else
    echo "  ❌ Default gateway not via 10.1.1.1"
    echo "     current: $(kexec client_basic 'ip route show default' 2>/dev/null || echo '(none)')"
    FAIL=1
fi

# /etc/hosts: clustera.com → 10.0.200.1
if kexec client_basic "cat /etc/hosts" 2>/dev/null | grep -q 'clustera.com'; then
    echo "  ✅ /etc/hosts has clustera.com"
else
    echo "  ❌ /etc/hosts missing clustera.com entry"
    FAIL=1
fi

# /etc/hosts: clusterb.com → 10.0.100.1
if kexec client_basic "cat /etc/hosts" 2>/dev/null | grep -q 'clusterb.com'; then
    echo "  ✅ /etc/hosts has clusterb.com"
else
    echo "  ❌ /etc/hosts missing clusterb.com entry"
    FAIL=1
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo
if [[ $FAIL -eq 0 ]]; then
    echo "✔ Kubernetes clusters healthy and client_basic configured"
else
    echo "✖ One or more checks failed"
    exit 1
fi
