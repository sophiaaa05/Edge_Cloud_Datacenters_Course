#!/usr/bin/env bash
# Basic project test suite.


set -uo pipefail

LAB_DIR="${LAB_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0; FAIL=0; ERRORS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass()    { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)); ERRORS+=("$1"); }
section() { echo -e "\n${YELLOW}━━ $1 ━━${NC}"; }

# Execute a command string inside a Kathará device via docker exec
kexec() {
    local cname
    cname=$(docker ps --filter "name=$1" --format '{{.Names}}' | head -1)
    [[ -z "$cname" ]] && return 1
    docker exec "$cname" bash -c "$2" 2>/dev/null
}

# ── 1. BGP ECMP multipath verification ───────────────────────────────────────
section "BGP ECMP Multipath (all leaves)"

# Each leaf should see ECMP routes to all other leaf loopbacks (via both spines)
declare -A EXPECTED_PREFIXES=(
    [leaf_1_1]="192.168.0.2/32 192.168.0.3/32 192.168.0.4/32"
    [leaf_1_2]="192.168.0.1/32 192.168.0.3/32 192.168.0.4/32"
    [leaf_2_1]="192.168.0.1/32 192.168.0.2/32 192.168.0.4/32"
    [leaf_2_2]="192.168.0.1/32 192.168.0.2/32 192.168.0.3/32"
)

for LEAF in leaf_1_1 leaf_1_2 leaf_2_1 leaf_2_2; do
    OUTPUT=$(kexec "$LEAF" "vtysh -c 'show ip bgp'" 2>&1)

    CURRENT=""
    declare -A PATHS=()
    declare -A ECMP=()

    while read -r LINE; do
        if echo "$LINE" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32"; then
            CURRENT=$(echo "$LINE" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32" | head -1)
            PATHS["$CURRENT"]=1
            [[ "$LINE" == *"="* ]] && ECMP["$CURRENT"]=1
        elif [[ "$LINE" =~ ^[[:space:]]*[\*=\>]+ ]] && [[ -n "$CURRENT" ]]; then
            PATHS["$CURRENT"]=$(( ${PATHS[$CURRENT]:-1} + 1 ))
            [[ "$LINE" == *"="* ]] && ECMP["$CURRENT"]=1
        fi
    done <<< "$OUTPUT"

    for PREFIX in ${EXPECTED_PREFIXES[$LEAF]}; do
        NPATH=${PATHS[$PREFIX]:-0}
        HAS_ECMP=${ECMP[$PREFIX]:-0}
        if [[ $NPATH -gt 1 && $HAS_ECMP -eq 1 ]]; then
            pass "$LEAF: $PREFIX has ECMP ($NPATH paths)"
        else
            fail "$LEAF: $PREFIX missing ECMP (paths=$NPATH, ecmp=$HAS_ECMP)"
        fi
    done

    unset PATHS ECMP
    declare -A PATHS=()
    declare -A ECMP=()
done

# ── 2. EVPN VNIs advertised on leaves ────────────────────────────────────────
section "EVPN / VXLAN (VNI advertisement)"

# leaf_1_1: controller1 (Cluster A/8000) + worker21 (Cluster B/9000) → both VNIs
for vni in 8000 9000; do
    if kexec leaf_1_1 "vtysh -c 'show evpn vni' | grep -q $vni" &>/dev/null; then
        pass "leaf_1_1: VNI $vni present"
    else
        fail "leaf_1_1: VNI $vni missing"
    fi
done

# leaf_1_2: controller2 (Cluster B/9000) only
if kexec leaf_1_2 "vtysh -c 'show evpn vni' | grep -q 9000" &>/dev/null; then
    pass "leaf_1_2: VNI 9000 present"
else
    fail "leaf_1_2: VNI 9000 missing"
fi
if kexec leaf_1_2 "vtysh -c 'show evpn vni' | grep -q 8000" &>/dev/null; then
    fail "leaf_1_2: VNI 8000 should NOT be present (only Cluster B here)"
else
    pass "leaf_1_2: VNI 8000 correctly absent"
fi

# leaf_2_1: worker11 (Cluster A/8000) only
if kexec leaf_2_1 "vtysh -c 'show evpn vni' | grep -q 8000" &>/dev/null; then
    pass "leaf_2_1: VNI 8000 present"
else
    fail "leaf_2_1: VNI 8000 missing"
fi
if kexec leaf_2_1 "vtysh -c 'show evpn vni' | grep -q 9000" &>/dev/null; then
    fail "leaf_2_1: VNI 9000 should NOT be present (only Cluster A here)"
else
    pass "leaf_2_1: VNI 9000 correctly absent"
fi

# leaf_2_2: exit node for internet – must carry both VNIs
for vni in 8000 9000; do
    if kexec leaf_2_2 "vtysh -c 'show evpn vni' | grep -q $vni" &>/dev/null; then
        pass "leaf_2_2: VNI $vni present (exit node)"
    else
        fail "leaf_2_2: VNI $vni missing (exit node)"
    fi
done

# ── 3. VTEP loopback reachability ────────────────────────────────────────────
section "VTEP loopback reachability"

declare -A LOOPBACKS=([leaf_1_1]="192.168.0.1" [leaf_1_2]="192.168.0.2" [leaf_2_1]="192.168.0.3" [leaf_2_2]="192.168.0.4")

for SRC in leaf_1_1 leaf_2_2; do
    for DST in leaf_1_1 leaf_1_2 leaf_2_1 leaf_2_2; do
        [[ "$SRC" == "$DST" ]] && continue
        IP="${LOOPBACKS[$DST]}"
        if kexec "$SRC" "ping -c 2 -W 2 $IP > /dev/null 2>&1" &>/dev/null; then
            pass "$SRC -> $DST ($IP)"
        else
            fail "$SRC -> $DST ($IP) unreachable"
        fi
    done
done

# ── 4. Kubernetes Cluster A health (controller1) ─────────────────────────────
section "Kubernetes Cluster A (controller1)"

for CHECK_DESC_CMD in \
    "nodes Ready|kubectl get nodes --no-headers | grep -qv NotReady" \
    "no crashloop/pending pods|! kubectl get pods -A --no-headers | grep -qE 'Error|CrashLoop|Pending|Unknown'" \
    "llm-ns namespace exists|kubectl get ns llm-ns -o name" \
    "llm-ns pod Running|kubectl get pods -n llm-ns --no-headers | grep -q Running" \
    "llm-ns Service port 8000|kubectl get svc -n llm-ns --no-headers | grep -q 8000"
do
    DESC="${CHECK_DESC_CMD%%|*}"; CMD="${CHECK_DESC_CMD#*|}"
    if kexec controller1 "$CMD" &>/dev/null; then
        pass "controller1: $DESC"
    else
        fail "controller1: $DESC"
    fi
done

# ── 5. Kubernetes Cluster B health (controller2) ─────────────────────────────
section "Kubernetes Cluster B (controller2)"

for CHECK_DESC_CMD in \
    "nodes Ready|kubectl get nodes --no-headers | grep -qv NotReady" \
    "no crashloop/pending pods|! kubectl get pods -A --no-headers | grep -qE 'Error|CrashLoop|Pending|Unknown'" \
    "llm-ns namespace exists|kubectl get ns llm-ns -o name" \
    "llm-ns pod Running|kubectl get pods -n llm-ns --no-headers | grep -q Running" \
    "llm-ns Service port 8000|kubectl get svc -n llm-ns --no-headers | grep -q 8000"
do
    DESC="${CHECK_DESC_CMD%%|*}"; CMD="${CHECK_DESC_CMD#*|}"
    if kexec controller2 "$CMD" &>/dev/null; then
        pass "controller2: $DESC"
    else
        fail "controller2: $DESC"
    fi
done

# ── 6. Microservice endpoints from client_basic ──────────────────────────────
section "LLM Microservice endpoints (from client_basic)"

QUERY='{"query": "An orc wanted to destroy everything"}'

for CLUSTER_HOST_EXPECT in \
    "clustera.com|Once upon a time," \
    "clusterb.com|Long ago, in a faraway land"
do
    HOST="${CLUSTER_HOST_EXPECT%%|*}"; EXPECT="${CLUSTER_HOST_EXPECT#*|}"
    echo "  Calling $HOST/completion ..."
    RESP=$(kexec client_basic \
        "curl -sf -X POST -H 'Content-Type: application/json' \
         -d '$QUERY' http://$HOST/completion") || RESP="CURL_FAILED"

    if echo "$RESP" | grep -qi "$EXPECT"; then
        pass "$HOST/completion: 200 OK + correct story prefix"
    elif [[ "$RESP" == "CURL_FAILED" ]]; then
        fail "$HOST/completion: curl failed (no route or service down)"
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
