# k3s Networking Debug Session

## Status: RESOLVED (self-healed)

## Goal

Debug k3s networking issue where pods could not contact services in the Kubernetes cluster. Suspected cause was commit `dfd5df43033ec758f9de62aa9b6b8f26336dbbd1` ("flake update"). A revert (12966d4) was attempted but did not fix the issue.

## Resolution

**The issue self-resolved without any infrastructure changes.** All diagnostic commands were read-only. Key confirming test:

```
# DNS resolution from pod works:
$ kubectl run test-dns --image=busybox --restart=Never -- nslookup kubernetes.default.svc.cluster.local 10.43.0.10
Server:		10.43.0.10
Address:	10.43.0.10:53

Name:	kubernetes.default.svc.cluster.local
Address: 10.43.0.1

# Pod-to-pod (same-node) works:
# cni-6292ca15 (10.42.4.148) on node02 → 10.42.4.69 on node02: SUCCESS

# Pod-to-pod (cross-node) works:
# From node02 pod → pi01 pod (10.42.3.64): SUCCESS (0.682ms, 0.959ms)
```

## Root Cause Hypothesis

Most likely **a transient kube-proxy or flannel reconciliation cycle** that needed to complete. The cluster self-healed after failed rebuild attempts. This was NOT caused by the flake update (which only changed `flake.lock` dependency versions, not system config).

## Full Debugging Timeline

### Session 1: Initial Investigation

**Symptoms observed:**
- metrics-server (10.42.4.69 on node02) unreachable from server01 (502 errors)
- 32+ services with missing or partial endpoints
- APIService errors for metrics.k8s.io and an upstream ACME issuer (503)

**Key findings:**
- k3s v1.34.5+k3s1 on all nodes (embedded flannel v0.28.0, CoreDNS v1.14.1, CNI v1.9.0-k3s1)
- Physical network (192.168.0.x) fully connected between all nodes
- FDB populated correctly on all nodes - all VTEP MAC-to-IP mappings present
- flannel.1 interfaces UP with MTU 1450 on all nodes
- Port 8472 (VXLAN) listening on all nodes

**Initial hypothesis (later disproven):**
Thought unreachable subnets were control plane only, but further testing showed:

**CRITICAL DISCOVERY: Complete pod-to-pod failure, NOT just one subnet**
- All cni0 IPs reachable (10.42.0.1, 10.42.3.1, 10.42.5.1, 10.42.4.1, 10.42.7.1 all respond to ping)
- **ALL pod IPs unreachable from ALL nodes** (10.42.3.69, 10.42.5.69, 10.42.7.69, 10.42.4.69 all 100% loss)
- From pi01 pod: nc to 10.42.3.212 times out (pod-to-pod on same node fails!)
- **This was NOT a VXLAN routing issue** - the entire overlay network for pod traffic was broken

### Session 2: Deep Dive into Overlay Network

**Flannel analysis:**
- Pod subnets routed via `flannel.1 onlink` to next-hop subnet base addresses (e.g., 10.42.4.0 via flannel.1 onlink)
- flannel.1 interface IP on each node IS the subnet base address (e.g., 10.42.4.0/32 on node02)
- This is non-standard but correct for k3s embedded flannel

**iptables analysis (node02):**
```
# filter table:
FLANNEL-FWD: ACCEPT all from/to 10.42.0.0/16  # rules exist and match
KUBE-FORWARD: Has DROP rules for INVALID packets, requires mark 0x4000 or RELATED/ESTABLISHED
KUBE-FORWARD: 0 packets matched on node02 - no traffic reaching it
KUBE-ROUTER-FORWARD: 90+ per-pod rules with 0 packets matched

# nat table (FLANNEL-POSTRTG):
-A FLANNEL-POSTRTG ! -s 10.42.0.0/16 -d 10.42.0.0/16 -j MASQUERADE  # non-pod->pod
-A FLANNEL-POSTRTG -s 10.42.0.0/16 ! -d 224.0.0.0/4 -j MASQUERADE  # pod->non-multicast
```

**Packet drops:**
- k8s-node02: 42,263 TX dropped, 4 TX errors on flannel.1
- k8s-node03: 39,569 TX dropped on flannel.1
- Drop count similar on "working" nodes - likely VXLAN encapsulation overhead

**CNI interface analysis (node02):**
- cni0 bridge has 27 veth interfaces connected
- Pod namespace cni-6292ca15 has IP 10.42.4.148/24 with gateway 10.42.4.1
- Pod routes: default via 10.42.4.1, 10.42.0.0/16 via 10.42.4.1

**Flake update analysis:**
- Commit abfae4e only changed `flake.lock` - dependency version bumps
- Nodes running system hash `d96b37b` matches OLD nixpkgs rev - nodes NOT running the flake update
- **Conclusion: The flake update did not affect running nodes**

**Session 2 discoveries:**
- Same-node pod-to-pod DOES work on node02 (between cni-6292ca15 and 10.42.4.69)
- Cross-node pod-to-pod DOES work from node02 to pi01 (10.42.3.64) - 0.682ms, 0.959ms
- Flannel.1 shows 40,445 TX drops on server01 but packets still getting through
- KUBE-ROUTER-FORWARD counter on pi01 increased from 145K to 154K after test - packets crossing VXLAN
- CoreDNS running: 2/2 pods (coredns-7cc9c696cc-26j56, -lx5v9)
- metrics-server running: metrics-server-bd9cb96f5-s7wtp 1/1 Running on node02
- All 11 nodes Ready
- 20 services with NO endpoints (likely stopped/removed pods)

### Session 3: DNS Resolution Test

**DNS resolution from pod WORKS:**
```
$ kubectl run test-dns --image=busybox --restart=Never -- nslookup kubernetes.default.svc.cluster.local 10.43.0.10
Server:		10.43.0.10
Address:	10.43.0.10:53

Name:	kubernetes.default.svc.cluster.local
Address: 10.43.0.1
```

**kube-proxy iptables rules verified (node02):**
```
# KUBE-SERVICES chain has 78 rules including:
16: KUBE-SVC-NPX46M4PTMTKRN6Y  tcp --  0.0.0.0/0  10.43.0.1  /* default/kubernetes:https */
18: KUBE-SVC-ERIFXISQEP7F7OF4  tcp --  0.0.0.0/0  10.43.0.10  /* kube-system/kube-dns:dns-tcp */
78: KUBE-SVC-TCOU7JCQXEZGVUNU  udp --  0.0.0.0/0  10.43.0.10  /* kube-system/kube-dns:dns */
# ... plus ~75 rules for various services (LoadBalancer IPs, ClusterIPs, etc.)

# DNS UDP chain has active traffic:
KUBE-SVC-TCOU7JCQXEZGVUNU: 15,718 packets, 1.4MB
  → KUBE-SEP-F7GBXMTBYFPYBRWL: 7,820 pkts (→ 10.42.5.24:53, node03 coredns)
  → KUBE-SEP-RDTHEULBJGTEYCV6: 7,898 pkts (→ 10.42.7.116:53, node04 coredns)

# Kubernetes API chain has active traffic:
KUBE-SVC-NPX46M4PTMTKRN6Y: 51,016 packets, 3.0MB
  → KUBE-SEP-KOXFDPWUWFKCQ3TZ: 17,092 pkts (→ 192.168.0.11:6443, server01)
  → KUBE-SEP-4YR44GKK7RSKM3II: 16,924 pkts (→ 192.168.0.12:6443, server02)
  → KUBE-SEP-UEAYFIZ2IBK7HSGA: 17,000 pkts (→ 192.168.0.13:6443, server03)
```

**Resolution confirmed:** DNS resolution from pods works, kube-proxy is programming IPTables rules correctly, and the cluster network is fully functional.

## Node IP Mapping

| Hostname | Physical IP | Pod Subnet | Role |
|----------|------------|------------|------|
| k8s-server01 | 192.168.0.11 | 10.42.0.x | primary server |
| k8s-server02 | 192.168.0.12 | 10.42.10.x | secondary server |
| k8s-server03 | 192.168.0.13 | 10.42.1.x | secondary server |
| k8s-node01 | 192.168.0.14 | 10.42.6.x | worker |
| k8s-node02 | 192.168.0.15 | 10.42.4.x | worker |
| k8s-node03 | 192.168.0.16 | 10.42.5.x | worker |
| k8s-node04 | 192.168.0.17 | 10.42.7.x | worker |
| k8s-pi01 | 192.168.0.21 | 10.42.3.x | worker |
| k8s-pi02 | 192.168.0.22 | 10.42.8.x | worker |
| k8s-pi03 | 192.168.0.23 | 10.42.11.x | worker |

## Architecture Notes

- k3s uses **embedded kube-proxy and flannel** (not as K8s daemonsets)
- Flannel runs in the k3s process, not as a separate systemd service
- CoreDNS runs as a standard K8s deployment in kube-system namespace
- CNI configuration: flannel + portmap + bandwidth plugins
- Pod network: 10.42.0.0/16 with /24 subnets per node
- Service network: 10.43.0.0/16 (kubernetes API at 10.43.0.1, CoreDNS at 10.43.0.10)
- MetalLB provides LoadBalancer IPs on 192.168.0.41-44 range
- Workers point to server01 (192.168.0.11) as k3s agent endpoint
- server01 is a secondary server, pointing to server02 (192.168.0.12) as server URL

## Lessons Learned

1. **Check same-node pod-to-pod first** - If it works but cross-node fails, focus on VXLAN/FDB/routing. If both fail, check CNI bridge/container runtime.
2. **Flake.lock-only changes don't affect running nodes** - The system hash determines what's deployed, not the flake.lock. Verify with `nix flake metadata .` and check running system hash.
3. **Pod IPs unreachable but cni0 IPs reachable** means containers exist but traffic can't traverse the overlay. Check: kube-proxy rules, iptables FORWARD chain, flannel overlay state.
4. **kubectl exec failing with "OCI runtime exec fail"** can mean container image lacks tools (no wget, nc, cat in PATH). Use `kubectl run` with a different image or check the container's ENTRYPOINT.
5. **Cross-node pod-to-pod working proves VXLAN is functional** - If VXLAN were broken, cross-node communication would fail but same-node would work.
6. **DNS resolution working from pod is a strong indicator that the entire stack is functional** - It proves: CNI → kube-dns service IP → kube-proxy DNAT → CoreDNS pods → DNS response back.
7. **TX drops on flannel.1 are normal** for VXLAN overhead - don't rely on drop count alone to diagnose issues.

## Commands for Future Debugging

```bash
# SSH access
ssh -i ~/.ssh/id_ed25519 admin@192.168.0.11  # server01
ssh -i ~/.ssh/id_ed25519 admin@192.168.0.15  # node02

# Check cluster state
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes -o wide
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pods -A -o wide
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get svc -A

# Test DNS from pod
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml run test-dns --image=busybox --restart=Never -- nslookup kubernetes.default.svc.cluster.local 10.43.0.10
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml delete pod test-dns --force --ignore-not-found

# Test pod-to-pod connectivity
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml run test-ping --image=busybox --restart=Never -- ping -c 3 10.42.4.69
sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml delete pod test-ping --force --ignore-not-found

# Check flannel overlay
ssh admin@192.168.0.15  # node02
ip neigh show dev flannel.1  # FDB entries
ip -s -s link show flannel.1  # stats
ss -ulnw state established '( sport = :8472 or dport = :8472 )'  # VXLAN traffic

# Check kube-proxy iptables rules (embedded in k3s)
sudo iptables -t nat -L KUBE-SERVICES -n -v --line-numbers | head -80
sudo iptables -t nat -L KUBE-SVC-TCOU7JCQXEZGVUNU -n -v  # DNS chain
sudo iptables -t nat -L KUBE-SVC-NPX46M4PTMTKRN6Y -n -v  # kubernetes API chain

# Check k3s service
sudo systemctl status k3s
sudo journalctl -u k3s --since "1 hour ago" | tail -100

# Check CNI config
sudo cat /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist
sudo cat /run/flannel/subnet.env

# Check container runtime
sudo crictl images  # locally available images
sudo crictl ps -a  # all containers

# Compare running config
nix flake metadata .  # see current nixpkgs rev
# or check running system hash:
readlink /run/current-system
```

## Files to Check

- `/etc/rancher/k3s/k3s.yaml` - kubectl config (requires sudo on server nodes)
- `/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist` - CNI config
- `/run/flannel/subnet.env` - flannel subnet config (FLANNEL_NETWORK, FLANNEL_SUBNET, FLANNEL_MTU)
- `/var/lib/rancher/k3s/server/manifests/` - k3s server manifests (coredns.yaml, ccm.yaml)
- `/etc/systemd/system/k3s.service` - k3s service unit
