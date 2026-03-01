LAB_DIR  := $(shell pwd)
TESTS    := $(LAB_DIR)/tests
TESTS2   := $(LAB_DIR)/tests_2
KATHARA  := kathara
TERMINAL ?= xterm

.PHONY: help start stop restart test test-net test-k8s test-llm test-advanced rdma-on rdma-off k8s-status test-scripts test-scripts2 connect-% logs-% \
        shells shells-leaves shells-spines shells-all bgp-summary evpn-vni

# ── default ──────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  IK2227 Final Project – Makefile"
	@echo ""
	@echo "  Lab control:"
	@echo "    make start          – start the Kathará lab"
	@echo "    make stop           – stop and clean the lab"
	@echo "    make restart        – stop then start"
	@echo ""
	@echo "  Testing (Basic):"
	@echo "    make test           – run all basic tests (tests_2/test_basic.sh)"
	@echo "    make test-net       – BGP + VTEP reachability only"
	@echo "    make test-k8s       – Kubernetes cluster health only"
	@echo "    make test-llm       – LLM endpoint curl tests only"
	@echo "    make test-advanced  – RDMA + client_int reachability tests"
	@echo "    make rdma-on        – switch both clusters to RDMA deployment"
	@echo "    make rdma-off       – switch both clusters back to basic deployment"
	@echo "    make k8s-status     – detailed nodes + pods for both clusters"
	@echo ""
	@echo "  Testing (Individual scripts):"
	@echo "    make test-scripts   – run all .sh scripts in tests/"
	@echo "    make test-scripts2  – run both suites in tests_2/"
	@echo ""
	@echo "  Debugging:"
	@echo "    make connect-<dev>  – open shell in a device (e.g. make connect-leaf_1_1)"
	@echo "    make logs-<dev>     – tail FRR log for a device"
	@echo "    make bgp-summary    – show BGP summary on all leaves"
	@echo "    make evpn-vni       – show EVPN VNIs on all leaves"
	@echo ""
	@echo "  Multi-terminal (one window per device):"
	@echo "    make shells-leaves  – open shells on all 4 leaves"
	@echo "    make shells-spines  – open shells on all 4 spines"
	@echo "    make shells-all     – open shells on all routing nodes"
	@echo "    make shells DEVS=\"leaf_1_1 spine_2_1\"  – open specific devices"
	@echo ""

# ── lab control ──────────────────────────────────────────────────────────────
start:
	sudo $(KATHARA) lstart --privileged -d $(LAB_DIR)

stop:
	$(KATHARA) lclean -d $(LAB_DIR)

restart: stop start

# ── test targets ─────────────────────────────────────────────────────────────
test:
	@chmod +x $(TESTS2)/test_basic.sh
	@LAB_DIR=$(LAB_DIR) $(TESTS2)/test_basic.sh

test-advanced:
	@chmod +x $(TESTS2)/test_advanced.sh
	@LAB_DIR=$(LAB_DIR) $(TESTS2)/test_advanced.sh

rdma-on:
	@echo "=== Switching to RDMA deployment ==="
	@docker exec $$(docker ps --filter name=controller1 --format '{{.Names}}' | head -1) \
		sh -c 'kubectl delete -f /shared/clustera/deploy_llm.yaml --ignore-not-found && kubectl apply -f /shared/clustera/deploy_llm_rdma.yaml'
	@docker exec $$(docker ps --filter name=controller2 --format '{{.Names}}' | head -1) \
		sh -c 'kubectl delete -f /shared/clusterb/deploy_llm.yaml --ignore-not-found && kubectl apply -f /shared/clusterb/deploy_llm_rdma.yaml'
	@echo "Waiting 180s for RDMA transfer + model init (60 MB SoftRoCE)..."
	@sleep 180
	@echo "Done. Run: make test-advanced"

rdma-off:
	@echo "=== Switching to basic deployment ==="
	@docker exec $$(docker ps --filter name=controller1 --format '{{.Names}}' | head -1) \
		sh -c 'kubectl delete -f /shared/clustera/deploy_llm_rdma.yaml --ignore-not-found && kubectl apply -f /shared/clustera/deploy_llm.yaml'
	@docker exec $$(docker ps --filter name=controller2 --format '{{.Names}}' | head -1) \
		sh -c 'kubectl delete -f /shared/clusterb/deploy_llm_rdma.yaml --ignore-not-found && kubectl apply -f /shared/clusterb/deploy_llm.yaml'
	@echo "Done. Watch pods: make k8s-status"

# Run only the BGP + VTEP sections (tests 1–3)
test-net:
	@chmod +x $(TESTS2)/test_basic.sh
	@LAB_DIR=$(LAB_DIR) TESTS_ONLY=net $(TESTS2)/test_basic.sh 2>/dev/null || true
	@echo "Hint: 'make test' runs the full suite; test-net shows BGP/EVPN/ping output."
	@echo ""
	@$(MAKE) bgp-summary
	@$(MAKE) evpn-vni

# Run only the Kubernetes health sections (tests 4–5) + client_basic checks
test-k8s:
	@chmod +x $(TESTS2)/test_k8s.sh
	@LAB_DIR=$(LAB_DIR) $(TESTS2)/test_k8s.sh

# Run all individual .sh scripts in tests/
test-scripts:
	@echo "=== Running all scripts in tests/ ==="
	@for f in $(TESTS)/*.sh; do \
		echo ""; \
		echo "--- $$f ---"; \
		chmod +x $$f && LAB_DIR=$(LAB_DIR) $$f || true; \
	done

# Run test suites from tests_2/
test-scripts2:
	@echo "=== Running test_basic.sh (tests_2/) ==="
	@chmod +x $(TESTS2)/test_basic.sh
	@LAB_DIR=$(LAB_DIR) $(TESTS2)/test_basic.sh || true
	@echo ""
	@echo "=== Running test_k8s.sh (tests_2/) ==="
	@chmod +x $(TESTS2)/test_k8s.sh
	@LAB_DIR=$(LAB_DIR) $(TESTS2)/test_k8s.sh || true

# Detailed system resource check – matches the project guideline checklist
k8s-status:
	@for ctrl in controller1 controller2; do \
		echo ""; \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
		echo "  $$ctrl"; \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
		cname=$$(docker ps --filter name=$$ctrl --format '{{.Names}}' | head -1); \
		echo ""; \
		echo "-- Nodes --"; \
		docker exec $$cname kubectl get nodes -o wide 2>/dev/null || echo "  (not ready)"; \
		echo ""; \
		echo "-- System pods (kube-system) --"; \
		docker exec $$cname kubectl get pods -n kube-system 2>/dev/null || echo "  (not ready)"; \
		echo ""; \
		echo "-- llm-ns --"; \
		docker exec $$cname kubectl get all -n llm-ns 2>/dev/null || echo "  (namespace not found)"; \
	done

# Run only the LLM curl tests (test 6)
test-llm:
	@echo "=== Cluster A: onceupon ==="
	docker exec $$(docker ps --filter name=client_basic --format '{{.Names}}' | head -1) \
		curl -s -X POST -H "Content-Type: application/json" \
		-d '{"query": "An orc wanted to destroy everything"}' \
		http://clustera.com/completion | python3 -m json.tool || true
	@echo ""
	@echo "=== Cluster B: faraway ==="
	docker exec $$(docker ps --filter name=client_basic --format '{{.Names}}' | head -1) \
		curl -s -X POST -H "Content-Type: application/json" \
		-d '{"query": "An orc wanted to destroy everything"}' \
		http://clusterb.com/completion | python3 -m json.tool || true

# ── multi-terminal helpers ────────────────────────────────────────────────────
# Opens one alacritty window per device. Install tmux for a better split layout.
DEVS ?=

shells:
	@if [ -z "$(DEVS)" ]; then echo "Usage: make shells DEVS=\"leaf_1_1 spine_2_1\""; exit 1; fi
	@for dev in $(DEVS); do \
		cname=$$(docker ps --filter name=$$dev --format '{{.Names}}' | head -1); \
		if [ -z "$$cname" ]; then echo "WARNING: $$dev not running, skipping"; continue; fi; \
		$(TERMINAL) -title "$$dev" -e bash -c "docker exec -it $$cname bash; exec bash" & \
	done

shells-leaves:
	@$(MAKE) shells DEVS="leaf_1_1 leaf_1_2 leaf_2_1 leaf_2_2"

shells-spines:
	@$(MAKE) shells DEVS="spine_1_1 spine_1_2 spine_2_1 spine_2_2"

shells-all:
	@$(MAKE) shells DEVS="leaf_1_1 leaf_1_2 leaf_2_1 leaf_2_2 spine_1_1 spine_1_2 spine_2_1 spine_2_2 core_1_1 core_1_2"

# ── debugging helpers ─────────────────────────────────────────────────────────
connect-%:
	docker exec -it $$(docker ps --filter name=$* --format '{{.Names}}' | head -1) bash

logs-%:
	docker exec $$(docker ps --filter name=$* --format '{{.Names}}' | head -1) journalctl -u frr -f

bgp-summary:
	@for dev in leaf_1_1 leaf_1_2 leaf_2_1 leaf_2_2; do \
		echo ""; \
		echo "=== $$dev BGP summary ==="; \
		docker exec $$(docker ps --filter name=$$dev --format '{{.Names}}' | head -1) \
			vtysh -c "show bgp summary" 2>/dev/null || true; \
	done

evpn-vni:
	@for dev in leaf_1_1 leaf_1_2 leaf_2_1 leaf_2_2; do \
		echo ""; \
		echo "=== $$dev EVPN VNIs ==="; \
		docker exec $$(docker ps --filter name=$$dev --format '{{.Names}}' | head -1) \
			vtysh -c "show evpn vni" 2>/dev/null || true; \
	done
