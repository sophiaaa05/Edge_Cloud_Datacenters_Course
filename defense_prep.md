# IK2227 Project — Defense Preparation
> Full Q&A + Command Cheat Sheet

---

## Topology Quick Reference

```
Internet
   |
as1r1 (AS 1) ── as30r1 (AS 30) ── dns1
   |                 |
   |             as100r1 (AS 100)
   |                 |
as40r1 (AS 40) ── as50r1 (AS 50)
   |
dc_exit (AS 65003)
   |  eth1.800 → cluster A (2.0.0.0/24)
   |  eth1.900 → cluster B (1.0.0.0/24)
   |
[leaf/spine/core fabric]

Fabric:
  leaf_1_1 (AS 64512, lo=192.168.0.1)  VNI 8000 + 9000
  leaf_1_2 (AS 64513, lo=192.168.0.2)  VNI 9000
  leaf_2_1 (AS 64515, lo=192.168.0.3)  VNI 8000
  leaf_2_2 (AS 64516, lo=192.168.0.4)
  spine_1_1/1_2 (AS 64514)
  spine_2_1/2_2 (AS 64517)
  core_1_1/1_2  (AS 64518)

Kubernetes:
  controller1 → worker11 (cluster A, 2.0.0.0/24, RDMA-capable)
  controller2 → worker21 (cluster B, 1.0.0.0/24, RDMA-capable)

Port chain:
  Client → Ingress (clustera.com/completion) → Service :8000 → Pod :8080
```

---

# SECTION 1 — BGP / ROUTING

---

## Basic Questions

**Q: Show the BGP routing table on core_1_1. How many prefixes?**

```bash
kathara connect core_1_1
vtysh -c "show ip bgp"
vtysh -c "show bgp summary"
```

**A:** 4 prefixes — the 4 leaf loopbacks:
- `192.168.0.1/32` → leaf_1_1
- `192.168.0.2/32` → leaf_1_2
- `192.168.0.3/32` → leaf_2_1
- `192.168.0.4/32` → leaf_2_2

Each has 2 ECMP paths (8 total paths). Cores only see leaf loopbacks because only leaves run `redistribute connected route-map LOOPBACKS`. Spines and cores don't advertise their own addresses.

---

**Q: How many prefixes does each device type have?**

| Device | Prefixes | Why |
|--------|----------|-----|
| leaf | 3 | Receives the 3 other leaf loopbacks, 2 paths each |
| spine (pod 1) | 4 | Hears leaf_1_x from local leaves, leaf_2_x from cores |
| spine (pod 2) | 4 | Hears leaf_2_x from local leaves, leaf_1_x from cores |
| core | 4 | Hears all 4 via all 4 spines |

---

**Q: Why does leaf_1_1 have `redistribute connected route-map LOOPBACKS` but spines do not?**

**A:** Leaves must advertise their loopback `/32` — this is the VTEP IP used for VXLAN tunnels. Spines are pure transit devices that just propagate routes between leaves and cores. If spines advertised their own IPs it would bloat the routing table with addresses that no VXLAN tunnel needs.

---

**Q: What does `bgp bestpath as-path multipath-relax` do?**

**A:** By default, ECMP in BGP requires identical AS paths. In this fabric, two paths to `192.168.0.3` might traverse different spines, giving different AS path lengths. `multipath-relax` ignores AS path differences when selecting equal-cost paths — it only compares weight, local-pref, MED, and origin. This enables full ECMP across all spine uplinks.

---

**Q: What happens if spine_1_1 goes down?**

**A:** BGP detects the session is down via hold-timer expiry (9 seconds, configured with `timers bgp 3 9`). leaf_1_1 withdraws paths learned via eth0 and all traffic shifts to eth1 → spine_1_2. BGP reconverges automatically. The `timers connect 10` means it will retry the session every 10 seconds.

---

**Q: What is `no bgp ebgp-requires-policy`?**

**A:** Newer FRR versions require explicit route-maps (import/export policies) on all eBGP sessions by default. This directive disables that requirement, allowing routes to flow freely without writing route-maps for every neighbor. Used here to keep configuration simple.

---

**Q: What is `maximum-paths 64`?**

**A:** Allows BGP to install up to 64 equal-cost paths into the RIB simultaneously, enabling ECMP. Without this, only 1 best path is installed. Since leaves have 2 uplinks and cores have 4, setting this high ensures all paths are used.

---

**Q: How does BGP know where to send packets if there are no IGP routes?**

**A:** The BGP sessions use **interface-based peering** (`neighbor eth0 interface peer-group SPINES`), not IP addresses. This means BGP runs over link-local IPv6 addresses on each physical link. The next hop at every hop is always a directly connected interface — no additional route lookup is needed. This is the RFC 7938 BGP-only datacenter design.

---

## Hard Questions

**Q: Why are spine_1_1 and spine_1_2 in the same AS (64514)? What problem could this cause?**

**A:** A problem arises with eBGP loop prevention: if spine_1_1 learns a route containing AS 64514 in the path, it will reject it (AS path loop). However, since spines only peer with leaves (downward) and cores (upward) — never with each other — they never receive routes that already contain their own AS. So same-AS is safe here. The alternative (RFC 7938 recommendation) is to give each device a unique private AS, which eliminates the problem entirely but requires more ASN management.

---

**Q: What does `neighbor SPINES remote-as external` mean? How is this different from specifying an AS number?**

**A:** `remote-as external` means "accept any AS number as long as it's different from mine" — it creates a dynamic eBGP peer. This is used with interface-based peering where you don't know the peer's AS in advance (it's negotiated during BGP OPEN). If you specified a fixed AS number, only a peer with exactly that AS would be accepted.

---

**Q: Explain `neighbor SPINES advertisement-interval 0`.**

**A:** By default, BGP waits up to 30 seconds (for eBGP) before advertising new routes to a peer, to batch updates and reduce churn. Setting this to 0 disables the delay, making BGP advertise route changes immediately. This reduces convergence time at the cost of potentially more UPDATE messages. Critical in a datacenter where fast failover matters.

---

**Q: What is the BGP table version and what does it tell you?**

**A:** `BGP table version is 4` — it increments every time the BGP table changes (a route is added, removed, or updated). If you see a rapidly incrementing table version, it indicates route flapping (instability). Stable networks have a steady table version.

---

**Q: What is the difference between `RIB entries` and `Displayed routes` in `show ip bgp`?**

**A:**
- `RIB entries` — total number of path entries in FRR's internal Routing Information Base, including all ECMP paths and both best/non-best paths.
- `Displayed routes` — number of distinct network prefixes (4 in core_1_1).
- `Total paths` — all individual paths including multipath duplicates (8 in core_1_1 = 4 prefixes × 2 paths each).

---

**Q: core_1_1 receives 2 prefixes per neighbor (`PfxRcd=2`). Why 2 and not 4?**

**A:** Each spine only knows the loopbacks of the 2 leaves directly connected to it:
- spine_1_1 connects to leaf_1_1 and leaf_1_2 → advertises `192.168.0.1/32` and `192.168.0.2/32`
- spine_2_1 connects to leaf_2_1 and leaf_2_2 → advertises `192.168.0.3/32` and `192.168.0.4/32`

Spines don't have `redistribute connected` so they only pass through what they learned from their leaf neighbors. Each spine sends 2 prefixes upward, and receives 4 back from the core (`PfxSnt=4`).

---

**Q: What does `bgp router-id` do and what happens if two routers have the same router-id?**

**A:** The router-id is a 32-bit identifier used to uniquely identify a BGP speaker. It is sent in BGP OPEN messages. If two routers have the same router-id, BGP sessions between them will fail with a NOTIFICATION error (Bad BGP Identifier). In this project each device has a unique router-id set to its loopback IP.

---

**Q: What does `*>` and `*=` mean in the BGP table output?**

**A:**
- `*` — route is valid (next-hop reachable)
- `>` — best path (selected by BGP decision process, installed in FIB)
- `=` — equal-cost multipath (also installed in FIB alongside the best path)
- `i` — learned via iBGP
- `s` — suppressed

So `*>` = best path installed, `*=` = ECMP path also installed.

---

# SECTION 2 — VXLAN / EVPN

---

## Basic Questions

**Q: Walk through the entire VXLAN packet flow between two servers.**

**A:** (Example: server on leaf_1_1 → server on leaf_2_1, both in VNI 8000)

1. Server sends Ethernet frame tagged **VLAN 800** out to leaf_1_1 on eth2
2. Bridge `br100` on leaf_1_1 sees VLAN 800 → forwards to `vtep5010` (strips VLAN tag, `pvid untagged`)
3. `vtep5010` **encapsulates**: outer IP src=`192.168.0.1`, dst=`192.168.0.3` (remote VTEP), UDP dstport=4789, VNI=8000
4. Packet goes into the underlay BGP fabric: leaf→spine→core→spine→leaf
5. Remote leaf_2_1 `vtep5010` **decapsulates**: strips VXLAN header, recovers original Ethernet frame
6. Bridge `br100` on leaf_2_1 assigns VLAN 800 and forwards out eth2 to destination server

---

**Q: What does `nolearning` on the VXLAN interface do?**

**A:** Disables flood-and-learn MAC discovery. Normally a bridge/VTEP learns which MACs are behind which port by flooding frames and observing replies. `nolearning` disables this — instead, MAC/IP mappings are distributed by **BGP EVPN Type-2 routes**. This prevents unnecessary flooding across the fabric and scales to large deployments.

---

**Q: What does `advertise-all-vni` do?**

**A:** Tells FRR to automatically detect all VNIs configured on the Linux system (vtep5010=VNI 8000, vtep5020=VNI 9000) and advertise them into BGP EVPN as Type-3 (IMET) routes. Without this, you'd have to manually declare each VNI in the BGP config. Remote VTEPs use these advertisements to know which VNIs exist and where the remote VTEP is.

---

**Q: What is `neigh_suppress on`?**

**A:** ARP suppression. When a server sends an ARP request ("who has IP X?"), normally it would flood across the VXLAN fabric to all VTEPs. With `neigh_suppress on`, the local leaf answers ARP requests directly using MAC/IP mappings learned from BGP EVPN Type-2 routes. This eliminates ARP flooding overhead across the fabric.

---

**Q: What is a Type-3 (IMET) route in EVPN?**

**A:** Inclusive Multicast Ethernet Tag route. Advertised by each VTEP to announce:
- "I exist as a VTEP at this IP"
- "I serve VNI X"
- "Send BUM (Broadcast, Unknown-unicast, Multicast) traffic for VNI X to me"

Without Type-3 routes, VTEPs wouldn't know about each other and couldn't form the tunnel mesh.

---

## Hard Questions

**Q: Why is the MTU set to 1450 on worker11/controller1?**

**A:** Kubernetes runs its pod network inside VXLAN tunnels. VXLAN adds a 50-byte overhead (8 outer Ethernet + 20 IP + 8 UDP + 8 VXLAN + 4 FCS ≈ 50 bytes). The standard Ethernet MTU is 1500 bytes, so the inner MTU must be reduced: `1500 - 50 = 1450`. Without this, packets would be fragmented or silently dropped, causing connection issues inside the cluster.

---

**Q: What is the difference between VNI 8000 and VNI 9000 in this topology?**

**A:** They represent two separate Layer 2 broadcast domains extended across the fabric:
- VNI 8000 (VLAN 800): present on leaf_1_1 and leaf_2_1 — connects cluster A workers
- VNI 9000 (VLAN 900): present on leaf_1_1 and leaf_1_2 — connects cluster B workers (or different tenant)

Traffic inside VNI 8000 is completely isolated from VNI 9000. The dc_exit also separates these: `eth1.800` for cluster A (`2.0.0.0/24`) and `eth1.900` for cluster B (`1.0.0.0/24`).

---

**Q: How does leaf_1_1 know where to send a VXLAN packet for a MAC it has never seen?**

**A:** Three mechanisms:
1. **BGP EVPN Type-2** (MAC/IP route): remote leaf advertised the MAC→VTEP IP mapping. Leaf_1_1 knows "MAC X is behind VTEP 192.168.0.3" without ever flooding.
2. **BGP EVPN Type-3** (IMET): if MAC is unknown, leaf can send BUM traffic to all remote VTEPs in the same VNI (listed in Type-3 routes).
3. **ARP suppression** (`neigh_suppress on`): the local leaf answers ARP requests from the MAC/IP table so the frame never even needs to go to a remote VTEP if the IP is known.

---

**Q: What does `addrgenmode none` on the bridge and VTEP interfaces do?**

**A:** Disables automatic IPv6 link-local address generation on those interfaces. Bridge and VTEP interfaces don't need IP addresses — they operate purely at Layer 2. Having a link-local address would be unnecessary and could cause unintended IPv6 traffic. `addrgenmode none` keeps these interfaces clean L2-only ports.

---

**Q: Why does `local 192.168.0.1` matter in the VXLAN interface definition?**

```bash
ip link add vtep5010 type vxlan id 8000 dev lo dstport 4789 local 192.168.0.1 nolearning
```

**A:** This sets the **source IP** of the outer VXLAN UDP packet to `192.168.0.1` (the loopback). This is critical because:
1. It anchors the VTEP to the loopback, which is always up (loopback never goes down even if a physical link fails)
2. Remote VTEPs and BGP peers know this leaf by its loopback IP — the same IP that BGP EVPN advertises as the VTEP address
3. Using a physical interface IP would break tunnels if that interface failed

---

**Q: What does `dev lo` mean in the VXLAN definition?**

**A:** It binds the VXLAN interface to the **loopback interface** for the underlay routing. The VXLAN packets (outer UDP/IP) will be routed by the kernel using the loopback as the anchor. Combined with `local 192.168.0.1`, it means VXLAN encapsulated packets use the loopback IP as source and are routed via the BGP underlay.

---

**Q: Show all VXLAN-related info on a leaf. What commands?**

```bash
# Show VXLAN interfaces with details
ip -d link show type vxlan

# Show bridge ports and VLAN assignments
bridge vlan show

# Show MAC forwarding table on bridge
bridge fdb show

# Show remote VTEP entries learned via EVPN (on a specific vtep interface)
bridge fdb show dev vtep5010

# Show EVPN routes in BGP
vtysh -c "show bgp l2vpn evpn"

# Show EVPN VNI summary
vtysh -c "show bgp l2vpn evpn vni"

# Show EVPN neighbor info
vtysh -c "show bgp l2vpn evpn summary"
```

---

# SECTION 3 — KUBERNETES / INGRESS

---

## Basic Questions

**Q: Explain the Ingress configuration.**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: llm-ing
  namespace: llm-ns
spec:
  ingressClassName: nginx         # use nginx ingress controller
  rules:
  - host: clustera.com            # match HTTP Host header
    http:
      paths:
      - pathType: Prefix
        path: /completion         # match URL paths starting with /completion
        backend:
          service:
            name: llm             # forward to Service named "llm"
            port:
              number: 8000        # on Service port 8000 (which maps to pod port 8080)
```

---

**Q: What do the domain name and service port represent?**

**A:**
- `host: clustera.com` — the external domain name clients use. The nginx Ingress Controller matches the HTTP `Host:` header to this value. DNS must resolve this to the MetalLB-assigned LoadBalancer IP.
- `port: 8000` — the Kubernetes Service port. The Service then maps this to `targetPort: 8080`, which is the actual port the llama2 container listens on inside the pod. So the chain is: Ingress → Service:8000 → Pod:8080.

---

**Q: Full request flow from client to LLM pod.**

```
1. Client: GET http://clustera.com/completion
2. DNS: clustera.com → MetalLB LoadBalancer IP (e.g. 2.0.0.10)
3. Packet routed via BGP through fabric to cluster A
4. nginx Ingress Controller receives request
5. Matches: Host=clustera.com, path=/completion → backend: llm:8000
6. Service "llm" selects pod via label selector (app=llm)
7. kube-proxy/iptables forwards to Pod IP on port 8080
8. llama2 container processes request, returns response
```

---

**Q: What is the role of MetalLB?**

**A:** Kubernetes on bare metal has no cloud provider to assign external IPs to `LoadBalancer` type Services. MetalLB fills this gap — it assigns IPs from a configured pool and advertises them via **BGP** to `dc_exit` (AS 65003). `dc_exit` then has routes to the cluster IPs and can forward external traffic into the cluster. Without MetalLB, Services would never get an external IP on bare metal.

---

**Q: What is `pathType: Prefix`?**

**A:** The path `/completion` with `Prefix` type matches any URL that **starts with** `/completion` as a complete path segment:
- `/completion` ✓
- `/completion/generate` ✓
- `/completion?prompt=hello` ✓
- `/completions` ✗ (different path segment)
- `/other` ✗

---

## Hard Questions

**Q: What is a PersistentVolumeClaim and why is it needed here?**

```yaml
# pvc.yaml
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: weights
```

**A:** A PVC is a request for storage in Kubernetes. The LLM pod needs the model weights file (`stories15M.bin`) to be available on disk. The PVC provisions a 100Mi volume from the `weights` StorageClass, which is then mounted into the pod at `/data`. `ReadWriteOnce` means only one pod on one node can mount it at a time. Without this, the pod would have no persistent storage and the weights would be lost on restart.

---

**Q: What does `restartPolicy: Always` do and why is it important?**

**A:** It tells Kubernetes to always restart the container if it crashes or exits. Since the LLM is a critical microservice, `Always` ensures it's automatically rescheduled if it fails. Combined with the Deployment's `replicas: 1`, Kubernetes ensures exactly one pod is always running. If the node fails, the pod is rescheduled on another node.

---

**Q: What does `kubectl label nodes worker11 supports=rdma` do and why?**

**A:** It adds a label to the worker11 node. Node labels are used for **node selection** — you can configure pods to only run on nodes with specific labels using `nodeSelector` or `nodeAffinity`. Since RDMA requires specific hardware (SoftRoCE or real RDMA NIC), labeling `supports=rdma` allows pods that need RDMA to be scheduled only on capable nodes. If you tried to run an RDMA workload on a non-RDMA node, it would fail.

---

**Q: Why is nginx used as the Ingress class? What does it actually do?**

**A:** nginx is deployed as a pod inside the cluster that watches for Ingress resources. When an Ingress is created with `ingressClassName: nginx`, nginx automatically:
1. Updates its configuration to add the new routing rule (host + path → backend)
2. Reloads its config without downtime
3. Acts as a reverse proxy — receives external HTTP, matches rules, forwards to the correct Service

Without an Ingress Controller, the Ingress object is just metadata — nothing acts on it.

---

**Q: What happens if you `kubectl delete -f ing.yaml`?**

**A:** The Ingress object is removed from Kubernetes. nginx Ingress Controller detects this and removes the routing rule for `clustera.com/completion` from its config and reloads. New requests to `clustera.com/completion` will get a 404 from nginx (default backend). The underlying Service and pods are **not** affected — only the HTTP routing rule is removed.

---

**Q: Useful troubleshooting commands for Kubernetes:**

```bash
# Show all resources in namespace
kubectl get all -n llm-ns

# Describe a pod (events, errors, image pull status)
kubectl describe pod -n llm-ns <pod-name>

# Show pod logs
kubectl logs -n llm-ns <pod-name>
kubectl logs -n llm-ns <pod-name> --previous   # if pod crashed

# Check Ingress (shows assigned IP)
kubectl describe ingress llm-ing -n llm-ns

# Check MetalLB
kubectl get all -n metallb-system

# Check nginx ingress controller
kubectl get all -n ingress-nginx

# Test connectivity from inside cluster
kubectl run test --rm -it --image=busybox -- wget -qO- http://llm:8000/completion

# Apply / delete configs
kubectl apply -f ing.yaml
kubectl delete -f ing.yaml

# Check node labels
kubectl get nodes --show-labels
kubectl label nodes worker11 supports=rdma

# Check PVC status (should be Bound)
kubectl get pvc -n llm-ns
```

---

# SECTION 4 — RDMA / RoCE

---

## Basic Questions

**Q: Describe the code where QP information is exchanged. How and through what connection?**

**A:** QP info is exchanged over a **plain TCP socket** (port 12345) — this is the out-of-band channel before RDMA is set up.

The `QpConnectionData` struct contains everything needed to connect:
```python
class QpConnectionData(ctypes.BigEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('qp_num', ctypes.c_uint32),   # identifies this QP on the device
        ('rkey',   ctypes.c_uint32),   # authorization token for remote memory access
        ('addr',   ctypes.c_uint64),   # virtual address of the weights memory region
        ('gid',    ctypes.c_ubyte * 16) # GID = RoCE equivalent of an IP address
    ]
```

Exchange in `server.py`:
```python
# Build local info
local_con_obj.qp_num = qp.qp_num
local_con_obj.rkey   = mr.rkey
local_con_obj.addr   = mr.buf
local_con_obj.gid[:] = ipaddress.ip_address(local_gid.gid).packed

# Send to client over TCP
conn.sendall(bytes(local_con_obj))

# Receive client's info over TCP
remote_data = recvn(conn, ctypes.sizeof(QpConnectionData))
remote_con  = QpConnectionData.from_buffer_copy(remote_data)
```

---

**Q: Walk through the QP state machine.**

**A:**
```
RESET → INIT → RTR → RTS
```

| State | Meaning | Parameters set |
|-------|---------|----------------|
| INIT | QP created, not usable | port_num, pkey_index, access_flags |
| RTR (Ready-to-Receive) | Can receive RDMA ops, knows remote | dest_qp_num, GID, MTU, rq_psn, AV (address vector) |
| RTS (Ready-to-Send) | Fully operational | sq_psn, timeout, retry_cnt, rnr_retry |

You cannot skip states — the RDMA hardware enforces this order.

---

**Q: Why TCP for QP exchange and not UDP?**

**A:** The QP exchange must be **reliable and ordered** — both sides must receive the complete `QpConnectionData` struct (28 bytes) before setting up RDMA. TCP guarantees delivery and ordering. Since this is just a small one-time control exchange, TCP overhead is irrelevant. The actual heavy data transfer (60MB model weights) happens over RDMA, which bypasses the kernel entirely.

---

**Q: What is an `rkey` and why does the client need it?**

**A:** `rkey` (remote key) is a hardware-enforced **authorization token** for a Memory Region. The server registers a memory buffer and receives an `rkey` from the RDMA hardware:
```python
mr = pyverbs.mr.MR(pd, BUFFER_SIZE, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ)
```
The server sends `mr.rkey` to the client over TCP. When the client issues an RDMA READ, the request includes this `rkey`. The server-side NIC hardware verifies it — without a valid `rkey`, the operation is rejected. This prevents unauthorized remote memory access.

---

**Q: What is a GID in RoCE?**

**A:** GID = Global Identifier — a 128-bit identifier for an RDMA port. In RoCE (RDMA over Ethernet), the GID is derived from the interface's IPv6 address or MAC. It is analogous to an **IP address** in regular networking — it's used to route RDMA packets across the network to the correct host. The GID is exchanged over TCP so each side can build an Address Handle (the RDMA equivalent of a next-hop entry) pointing to the remote peer.

---

## Hard Questions

**Q: What is `IBV_QPT_RC`? What are the alternatives and why is RC used here?**

**A:** RC = Reliable Connected. One-to-one QP connection with hardware-guaranteed delivery, ordering, and retransmission (similar to TCP but implemented in the NIC).

| Type | Description | Use case |
|------|-------------|----------|
| IBV_QPT_RC | Reliable Connected | Point-to-point, RDMA READ/WRITE, large transfers |
| IBV_QPT_UC | Unreliable Connected | Connected but no retransmit |
| IBV_QPT_UD | Unreliable Datagram | One-to-many, like UDP |
| IBV_QPT_XRC | Extended RC | Many-to-one scalability |

RC is used here because:
1. Transferring model weights must be **reliable** — any loss = corrupted model
2. RC supports **RDMA READ** (one-sided operation where client pulls data from server without server CPU involvement)
3. Point-to-point — server knows exactly which client connects

---

**Q: What is `poll_cq` and what is a Completion Queue?**

**A:** Every RDMA operation posts a Work Request (WR) to a Queue Pair. When the operation completes, the NIC posts a Completion Queue Entry (CQE) to the Completion Queue (CQ). `poll_cq` runs in a loop checking for completed operations:

```python
def poll_cq(cq, mr):
    while keep_polling:
        wc_num, wc_list = cq.poll(num_entries=1)
        if wc_num > 0:
            for wc in wc_list:
                if wc.wr_id == 0xdead:         # sentinel: this was the READ completion
                    callback(mr.read(...))      # weights are in memory, use them
                    keep_polling = False
```

`wr_id == 0xdead` is a sentinel value set when posting the RDMA READ Work Request, used to identify which specific operation completed.

---

**Q: Why is RDMA faster than regular TCP for transferring model weights?**

| Aspect | TCP | RDMA |
|--------|-----|------|
| CPU involvement | Full kernel processing per packet | Zero — NIC handles everything |
| Memory copies | Multiple (socket buffer → kernel → user space) | Zero-copy direct to/from registered MR |
| Interrupts | Per-packet interrupts | Minimal (polling CQ) |
| Latency | µs to ms | Sub-µs |
| Bandwidth | Limited by CPU | Near wire speed |

In RDMA READ, the client's NIC directly fetches `BUFFER_SIZE = 60816028` bytes (~60MB) from `mr.buf` on the server using the `rkey` and `addr`. The server CPU never wakes up. This is critical for loading model weights quickly at inference startup.

---

**Q: What does `IBV_ACCESS_REMOTE_READ` allow? How does it differ from `REMOTE_WRITE`?**

**A:**
- `IBV_ACCESS_REMOTE_READ` — remote side can **pull** data from this MR. Server CPU uninvolved. Used here so the client can fetch weights from the server's registered memory.
- `IBV_ACCESS_REMOTE_WRITE` — remote side can **push** data into this MR. Local CPU not notified unless you post a receive WR. Used when the initiator sends data to the target.
- `IBV_ACCESS_LOCAL_WRITE` — required on the server's MR to allow the local NIC to write incoming RDMA data into it (needed alongside REMOTE_READ in practice).

---

**Q: What is SoftRoCE and why is it used here?**

**A:** SoftRoCE (`rdma_rxe` kernel module) is a software implementation of RoCE (RDMA over Converged Ethernet) that works over any standard Ethernet interface. Real RDMA requires special hardware (InfiniBand HCA or RoCE-capable NIC). In this lab, we don't have real RDMA hardware, so SoftRoCE emulates the RDMA verbs interface in software. This allows testing RDMA applications on regular virtual/simulated network interfaces without specialized hardware, at the cost of not getting the real performance benefits.

```bash
# Load SoftRoCE module
modprobe rdma_rxe

# Create SoftRoCE device on an interface
rdma link add rxe0 type rxe netdev eth0

# Verify
rdma dev show
ibv_devinfo
```

---

**Q: What is `recvn` and why is it needed instead of just `sock.recv()`?**

```python
def recvn(sock, n):
    data = b''
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            break
        data += chunk
    return data
```

**A:** TCP is a **stream protocol** — `sock.recv(n)` is not guaranteed to return exactly `n` bytes. It may return fewer if the data arrives in multiple segments (TCP segmentation, network buffering). `recvn` loops until exactly `n` bytes are received. This is critical for the QP exchange: the `QpConnectionData` struct is 28 bytes and must be received complete and intact. A partial read would result in corrupted QP parameters and a failed RDMA connection.

---

# SECTION 5 — COMMAND CHEAT SHEET

---

## Kathara

```bash
# Start the entire lab
kathara lstart

# Start a specific machine only
kathara lstart core_1_1

# Connect to a running machine
kathara connect core_1_1
kathara connect leaf_1_1

# List all running machines
kathara list

# Stop the lab (destroys containers)
kathara lclean

# Show machine info
kathara linfo
```

---

## BGP (run inside container via vtysh)

```bash
# Enter vtysh interactive shell
vtysh

# Or run single commands directly
vtysh -c "show ip bgp"

# --- Viewing State ---

# BGP summary: neighbors, state, prefix counts
show bgp summary

# Full IPv4 BGP table
show ip bgp

# Route to a specific prefix
show ip bgp 192.168.0.3/32

# Detailed neighbor info (state, timers, capabilities)
show bgp neighbors
show bgp neighbors eth0

# Installed routes in RIB (what's actually used for forwarding)
show ip route
show ip route bgp

# EVPN table
show bgp l2vpn evpn
show bgp l2vpn evpn vni
show bgp l2vpn evpn summary
show bgp l2vpn evpn route type 2     # MAC/IP routes
show bgp l2vpn evpn route type 3     # IMET routes

# --- Modifying Config ---

# Enter config mode
configure terminal

# Change BGP timer
router bgp 64512
 timers bgp 1 3

# Add a new network advertisement
router bgp 64512
 address-family ipv4 unicast
  network 10.0.0.0/8

# Save config
write memory
# or
copy running-config startup-config

# Reload FRR without restart
systemctl reload frr
```

---

## VXLAN / Bridge (inside leaf container)

```bash
# Show VXLAN interfaces with full detail
ip -d link show type vxlan

# Show all interfaces
ip link show
ip addr show

# Show bridge ports and VLAN memberships
bridge vlan show

# Show MAC forwarding table (all bridge ports)
bridge fdb show

# Show remote VTEPs learned on a specific VTEP interface
bridge fdb show dev vtep5010

# Show kernel routing table
ip route show

# Add a VXLAN interface manually (if needed)
ip link add vtep_test type vxlan id 9999 dev lo dstport 4789 local 192.168.0.1 nolearning

# Add a bridge VLAN
bridge vlan add vid 800 dev vtep5010 pvid untagged

# Enable an interface
ip link set up dev vtep5010

# Check if traffic is flowing (packet counts)
ip -s link show vtep5010
```

---

## Kubernetes (inside controller1 or controller2)

```bash
# --- Viewing State ---

# All resources in a namespace
kubectl get all -n llm-ns

# Pods
kubectl get pods -n llm-ns
kubectl get pods -n llm-ns -o wide    # shows node and IP

# Services
kubectl get svc -n llm-ns
kubectl describe svc llm -n llm-ns

# Ingress
kubectl get ingress -n llm-ns
kubectl describe ingress llm-ing -n llm-ns

# Nodes and labels
kubectl get nodes
kubectl get nodes --show-labels

# PersistentVolumeClaim status
kubectl get pvc -n llm-ns

# Check MetalLB
kubectl get all -n metallb-system

# Check nginx ingress controller
kubectl get all -n ingress-nginx

# --- Deploying ---

# Apply all manifests in order
kubectl apply -f ns.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deploy_llm.yaml
kubectl apply -f svc.yaml
kubectl apply -f ing.yaml

# Delete and reapply
kubectl delete -f ing.yaml && kubectl apply -f ing.yaml

# --- Debugging ---

# Pod logs
kubectl logs -n llm-ns <pod-name>
kubectl logs -n llm-ns <pod-name> --previous    # if pod crashed

# Describe pod (events, errors, resource status)
kubectl describe pod -n llm-ns <pod-name>

# Exec into a pod
kubectl exec -it -n llm-ns <pod-name> -- sh

# Test HTTP from inside cluster
kubectl run test --rm -it --image=busybox -- wget -qO- http://llm:8000/completion

# Test from client machine
curl http://clustera.com/completion -d '{"prompt":"hello"}'

# Watch pod status live
kubectl get pods -n llm-ns -w

# Add node label
kubectl label nodes worker11 supports=rdma

# --- Troubleshooting ---

# Pod stuck in Pending? Check node resources and PVC
kubectl describe pod -n llm-ns <pod-name>
kubectl get pvc -n llm-ns

# No external IP on ingress? Check MetalLB
kubectl get svc -n metallb-system
kubectl logs -n metallb-system -l component=speaker

# Ingress not routing? Check nginx controller
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

---

## RDMA / RoCE (inside worker node)

```bash
# Load SoftRoCE kernel module
modprobe rdma_rxe

# Install RDMA tools (on Alpine)
apk add iproute2 iproute2-rdma

# Create a SoftRoCE device on an interface
rdma link add rxe0 type rxe netdev eth0

# Show RDMA devices
rdma dev show
ibv_devinfo

# Show RDMA links
rdma link show

# Run the RDMA server (llama_weights container)
python3 server.py <iface>
# Example:
python3 server.py rxe0

# Run the RDMA client
python3 rdma.py <iface>
# Example:
python3 rdma.py rxe0

# Check if RDMA module is loaded
lsmod | grep rdma_rxe

# Show RDMA statistics
rdma stat show

# Remove a SoftRoCE link
rdma link delete rxe0/1
```

---

## General Network Debugging

```bash
# Ping between nodes (test underlay reachability)
ping 192.168.0.3

# Traceroute (shows path through fabric)
traceroute 192.168.0.3

# Test TCP connectivity
nc -zv 192.168.0.3 12345

# Capture VXLAN traffic (UDP port 4789)
tcpdump -i eth0 udp port 4789

# Capture BGP traffic
tcpdump -i eth0 tcp port 179

# Show interface stats (rx/tx packets, errors)
ip -s link show eth0

# Check listening ports
ss -tlnp
netstat -tlnp

# DNS lookup
nslookup clustera.com
dig clustera.com
```

---

## Quick Troubleshooting Guide

| Problem | Where to look | Command |
|---------|--------------|---------|
| BGP session down | Neighbor state, hold timer | `vtysh -c "show bgp neighbors eth0"` |
| Routes not propagating | BGP table, route-map | `vtysh -c "show ip bgp"` |
| VXLAN tunnel not working | Remote VTEP in FDB | `bridge fdb show dev vtep5010` |
| EVPN routes missing | BGP EVPN table | `vtysh -c "show bgp l2vpn evpn"` |
| Pod not starting | Events, image pull | `kubectl describe pod -n llm-ns <name>` |
| No external IP on Service | MetalLB speaker | `kubectl get all -n metallb-system` |
| Ingress not routing | nginx controller logs | `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller` |
| RDMA connection refused | SoftRoCE loaded? | `rdma dev show` / `lsmod \| grep rdma_rxe` |
| RDMA wrong interface | Check device name | `ibv_devinfo` |
| MTU issues in K8s | Check MTU on nodes | `ip link show eth0` (should be 1450) |
