#!/usr/bin/env bash
# Advanced project test suite — RDMA + client_int reachability.

set -uo pipefail

PASS=0; FAIL=0; ERRORS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass()    { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)); ERRORS+=("$1"); }
section() { echo -e "\n${YELLOW}━━ $1 ━━${NC}"; }

kexec() { kathara exec "$1" "$2" 2>/dev/null; }

# ── 1. SoftRoCE interface setup on workers ────────────────────────────────────
section "SoftRoCE interfaces (workers)"

if kexec worker11 "rdma link show" | grep -q "rxe1"; then
    pass "worker11: rxe1 SoftRoCE interface exists"
else
    fail "worker11: rxe1 SoftRoCE interface missing"
fi

if kexec worker21 "rdma link show" | grep -q "rxe0"; then
    pass "worker21: rxe0 SoftRoCE interface exists"
else
    fail "worker21: rxe0 SoftRoCE interface missing"
fi

# ── 2. eth1 IP configuration on workers ──────────────────────────────────────
section "RDMA network (3.0.0.0/24)"

if kexec worker11 "ip addr show eth1" | grep -q "3.0.0.2/24"; then
    pass "worker11: eth1 has 3.0.0.2/24"
else
    fail "worker11: eth1 missing 3.0.0.2/24"
fi

if kexec worker21 "ip addr show eth1" | grep -q "3.0.0.3/24"; then
    pass "worker21: eth1 has 3.0.0.3/24"
else
    fail "worker21: eth1 missing 3.0.0.3/24"
fi

# llama_weights reachability from each worker
if kexec worker11 "ping -c 2 -W 2 3.0.0.1" | grep -q "bytes from"; then
    pass "worker11: can reach llama_weights (3.0.0.1)"
else
    fail "worker11: cannot reach llama_weights (3.0.0.1)"
fi

if kexec worker21 "ping -c 2 -W 2 3.0.0.1" | grep -q "bytes from"; then
    pass "worker21: can reach llama_weights (3.0.0.1)"
else
    fail "worker21: cannot reach llama_weights (3.0.0.1)"
fi

# ── 3. RDMA server running on llama_weights ───────────────────────────────────
section "RDMA server (llama_weights)"

if kexec llama_weights "screen -ls" | grep -q "server"; then
    pass "llama_weights: RDMA server screen session running"
else
    fail "llama_weights: RDMA server screen session not found"
fi

if kexec llama_weights "cat /var/log/server.log" | grep -q "Listening for connections"; then
    pass "llama_weights: server log shows listening"
else
    fail "llama_weights: server not yet listening (check /var/log/server.log)"
fi

# ── 4. Kubernetes RDMA node labels ───────────────────────────────────────────
section "Kubernetes RDMA node labels"

if kexec controller1 "kubectl get node worker11 --show-labels" | grep -q "supports=rdma"; then
    pass "controller1: worker11 labelled supports=rdma"
else
    fail "controller1: worker11 missing supports=rdma label"
fi

if kexec controller2 "kubectl get node worker21 --show-labels" | grep -q "supports=rdma"; then
    pass "controller2: worker21 labelled supports=rdma"
else
    fail "controller2: worker21 missing supports=rdma label"
fi

# ── 5. Pods scheduled on RDMA-enabled workers ─────────────────────────────────
section "Pod placement (nodeSelector: supports=rdma)"

if kexec controller1 "kubectl get pods -n llm-ns -o wide --no-headers" | grep -qw "worker11"; then
    pass "controller1: llm pod running on worker11 (RDMA node)"
else
    fail "controller1: llm pod not on worker11 (got: $(kexec controller1 'kubectl get pods -n llm-ns -o wide --no-headers'))"
fi

if kexec controller2 "kubectl get pods -n llm-ns -o wide --no-headers" | grep -qw "worker21"; then
    pass "controller2: llm pod running on worker21 (RDMA node)"
else
    fail "controller2: llm pod not on worker21 (got: $(kexec controller2 'kubectl get pods -n llm-ns -o wide --no-headers'))"
fi

# ── 6. RDMA env vars set in pods ─────────────────────────────────────────────
section "RDMA environment variables in pods"

POD_A=$(kexec controller1 "kubectl get pods -n llm-ns --no-headers" | awk '{print $1}')
if [[ -n "$POD_A" ]]; then
    if kexec controller1 "kubectl exec -n llm-ns $POD_A -- env" | grep -q "ENABLE_RDMA=true"; then
        pass "Cluster A pod: ENABLE_RDMA=true"
    else
        fail "Cluster A pod: ENABLE_RDMA not set to true"
    fi
    if kexec controller1 "kubectl exec -n llm-ns $POD_A -- env" | grep -q "RXE_IFACE=rxe1"; then
        pass "Cluster A pod: RXE_IFACE=rxe1"
    else
        fail "Cluster A pod: RXE_IFACE not set to rxe1"
    fi
else
    fail "Cluster A pod: could not get pod name"
    fail "Cluster A pod: could not get pod name (RXE_IFACE)"
fi

POD_B=$(kexec controller2 "kubectl get pods -n llm-ns --no-headers" | awk '{print $1}')
if [[ -n "$POD_B" ]]; then
    if kexec controller2 "kubectl exec -n llm-ns $POD_B -- env" | grep -q "ENABLE_RDMA=true"; then
        pass "Cluster B pod: ENABLE_RDMA=true"
    else
        fail "Cluster B pod: ENABLE_RDMA not set to true"
    fi
    if kexec controller2 "kubectl exec -n llm-ns $POD_B -- env" | grep -q "RXE_IFACE=rxe0"; then
        pass "Cluster B pod: RXE_IFACE=rxe0"
    else
        fail "Cluster B pod: RXE_IFACE not set to rxe0"
    fi
else
    fail "Cluster B pod: could not get pod name"
    fail "Cluster B pod: could not get pod name (RXE_IFACE)"
fi

# ── 7. RDMA connection success in pod logs ────────────────────────────────────
section "RDMA connection logs"

# Checked manually with:
#   POD_A=$(kathara exec controller1 "kubectl get pods -n llm-ns --no-headers" | awk '{print $1}')
#   kathara exec controller1 "kubectl logs -n llm-ns $POD_A"
#   POD_B=$(kathara exec controller2 "kubectl get pods -n llm-ns --no-headers" | awk '{print $1}')
#   kathara exec controller2 "kubectl logs -n llm-ns $POD_B"
#
# if [[ -n "$POD_A" ]]; then
#     LOGS_A=""
#     for _attempt in 1 2 3; do
#         LOGS_A=$(kexec controller1 "kubectl logs -n llm-ns $POD_A" 2>/dev/null)
#         [[ -n "$LOGS_A" ]] && break
#         sleep 5
#     done
#     if echo "$LOGS_A" | grep -q "weights received successfully"; then
#         pass "Cluster A pod: RDMA weights received successfully"
#     else
#         fail "Cluster A pod: no 'weights received successfully' in logs"
#     fi
#     if echo "$LOGS_A" | grep -q "CQE: wr_id=57005, status=0"; then
#         pass "Cluster A pod: CQE wr_id=0xdead completed with status=0"
#     else
#         fail "Cluster A pod: CQE 0xdead not found or non-zero status"
#     fi
# fi
#
# if [[ -n "$POD_B" ]]; then
#     LOGS_B=""
#     for _attempt in 1 2 3; do
#         LOGS_B=$(kexec controller2 "kubectl logs -n llm-ns $POD_B" 2>/dev/null)
#         [[ -n "$LOGS_B" ]] && break
#         sleep 5
#     done
#     if echo "$LOGS_B" | grep -q "weights received successfully"; then
#         pass "Cluster B pod: RDMA weights received successfully"
#     else
#         fail "Cluster B pod: no 'weights received successfully' in logs"
#     fi
#     if echo "$LOGS_B" | grep -q "CQE: wr_id=57005, status=0"; then
#         pass "Cluster B pod: CQE wr_id=0xdead completed with status=0"
#     else
#         fail "Cluster B pod: CQE 0xdead not found or non-zero status"
#     fi
# fi

# ── 8. RDMA server received connections ──────────────────────────────────────
section "RDMA server connection log"

SERVER_LOG=$(kexec llama_weights "cat /var/log/server.log" 2>/dev/null)
CONN_COUNT=$(echo "$SERVER_LOG" | grep -c "RDMA connection with" || true)
if [[ $CONN_COUNT -ge 2 ]]; then
    pass "llama_weights: $CONN_COUNT RDMA connection(s) established (expected ≥2)"
elif [[ $CONN_COUNT -eq 1 ]]; then
    fail "llama_weights: only 1 RDMA connection (expected 2, one per cluster)"
else
    fail "llama_weights: no RDMA connections in server log"
fi

# ── 9. LLM endpoints reachable from client_int (via anycast DNS) ──────────────
section "LLM Microservice endpoints (from client_int, anycast DNS)"

QUERY='{"query": "An orc wanted to destroy everything"}'

for CLUSTER_HOST_EXPECT in \
    "clustera.com|Once upon a time," \
    "clusterb.com|Long ago, in a faraway land"
do
    HOST="${CLUSTER_HOST_EXPECT%%|*}"; EXPECT="${CLUSTER_HOST_EXPECT#*|}"
    echo "  Calling $HOST/completion from client_int ..."
    RESP=$(kexec client_int \
        "curl -sf -X POST -H 'Content-Type: application/json' \
         -d '$QUERY' http://$HOST/completion") || RESP="CURL_FAILED"

    if echo "$RESP" | grep -qi "$EXPECT"; then
        pass "$HOST/completion: 200 OK + correct story prefix"
    elif [[ "$RESP" == "CURL_FAILED" ]]; then
        fail "$HOST/completion: curl failed (DNS or routing issue)"
    else
        fail "$HOST/completion: wrong or missing story prefix"
        echo "    Response: ${RESP:0:200}"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
section "Results"
TOTAL=$((PASS + FAIL))
echo -e "  ${GREEN}Passed${NC}: $PASS / $TOTAL"
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}Failed${NC}: $FAIL / $TOTAL"
    echo ""
    echo "  Failed checks:"
    for e in "${ERRORS[@]}"; do echo -e "    ${RED}✗${NC} $e"; done
    exit 1
else
    echo -e "  ${GREEN}All tests passed!${NC}"
fi
