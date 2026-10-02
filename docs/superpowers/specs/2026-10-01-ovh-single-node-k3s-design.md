# OVH single-node k3s host — design

- **Date:** 2026-10-01
- **Status:** draft — open questions in §16 must be answered before implementation
- **Repo:** `nixos-configurations`
- **Hostname:** `titan` (confirmed)

---

## 0. This repo is public — read before editing

`javierarrieta/nixos-configurations` is a **public** GitHub repo, so everything in this
file is published the moment it is pushed. Concrete addresses are therefore written here as
`<OVH_PUBLIC_IP>` and `<OVH_GW>`; the real values, the DNS snippet with the literal target,
the OVH panel state, and the WireGuard peer inventory live in the gitignored companion
**`2026-10-01-ovh-single-node-k3s-design.private.md`** (`*.private.md` is in `.gitignore`).

Never commit, in any file:

- **credentials** — OVH API application key/secret/consumer key, k3s join tokens,
  WireGuard private keys or PSKs, age secrets, rescue-mode passwords. These belong in
  `secrets.yaml` (sops) or the password manager.
- **concrete public addresses** of infrastructure — IPv4 *and* IPv6 (the routed OVH v6 block counts). RFC1918 (`10/8`, `172.16/12`,
  `192.168/16`) is fine — it is design-relevant and not reachable from the internet.

Two things deliberately kept in the open, because hiding them buys nothing: the SSH port
`13491` (it has to appear in the public host config to work, and the defence is key-only
auth, not the port number) and the mesh's RFC1918 topology.

The ignore rule stops an accidental `git add .`; it does not stop `git add -f`. Before
committing docs, check the staged diff:

```bash
# secret *shapes*, not variable names — naming OVH_APPLICATION_KEY is fine, a value is not
# (grep -v drops this checker line, which matches its own pattern)
git diff --cached | grep -nE 'AGE-SECRET-KEY-|BEGIN [A-Z ]*PRIVATE KEY|ssh-ed25519 AAAA|psk=[A-Za-z0-9+/=]{20,}' | grep -v 'grep -nE' && echo "CREDENTIAL LEAK"
# any IPv4 outside RFC1918 (10/8, 172.16/12, 192.168/16) and the public resolvers in the allowlist
git diff --cached | grep -noE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  | grep -vE '(^|[^0-9])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|1\.1\.1\.1|8\.8\.[48]\.4|213\.186\.33\.99|224\.)' && echo "PUBLIC IPv4 IN DIFF"
```

---

## 1. Decision record

| # | Decision | Choice | Status |
|---|---|---|---|
| D0 | Hostname / flake attr / dir | `titan` — `hosts/titan/`, `. #titan`, `titan/network_env`, apex DNS `titan.arrieta.eu` + `*.titan.arrieta.eu` | confirmed |
| D1 | Cluster shape | Standalone single-node k3s server, embedded etcd, own cluster (no join to the home fleet) | confirmed |
| D2 | Reachability model | **Hybrid**: public IPv4 for 80/443 + WireGuard for the management plane | confirmed |
| D3 | SSH | Public on **13491**, key-only, never depends on WireGuard. No WG-only SSH. | confirmed |
| D4 | Ingress | k3s' bundled **Traefik + ServiceLB stay enabled** (unlike the home cluster, which disables both) | confirmed |
| D5 | Certificates | cert-manager **DNS-01 via the OVH webhook**, same pattern as `../k8s-techdelivery` | confirmed |
| D6 | Public domain | `titan.arrieta.eu` + `*.titan.arrieta.eu` (DNS not yet created) | confirmed, DNS pending |
| D7 | Workloads | Mostly self-hosted services behind HTTPS ingress | confirmed |
| D8 | Firewall | **On**, default-deny inbound, explicit allowlist (§4.4). Overrides the fleet-wide `firewall.enable = false`. | proposed |
| D9 | Root disk encryption | **Unencrypted root** for the first build. LUKS + initrd SSH unlock deferred to a follow-up PR. | confirmed |
| D10 | GitOps ring | `main` + `confirmerMode = "auto"` (canary). **"For now"** — revisit once `titan` holds workloads whose outage would hurt; then move it to `stable`/manual. | confirmed |
| D11 | Storage class | k3s `local-path-provisioner` (matches `k8s-techdelivery`, which is also k3s + `local-path`) | proposed |
| D12 | `stateVersion` | `26.05` (new host; do not copy the fleet's `23.11`/`25.11`) | proposed |
| D13 | Disk layout | **mdraid-1 under LVM**: plain 1 GiB ESP on the low-wear disk, `/dev/md/titan` (RAID1) → VG `vg0` → `lv-root` 150 G → `/` (store, containerd images/overlays, emptyDir, logs, k3s db) + `lv-pvc` 240 G → `/var/lib/rancher/k3s/storage` (**PVs only** — the only irreplaceable data), ~29 G unallocated as VG headroom. systemd-boot unchanged (§7a) | confirmed 2026-10-01 |
| D14 | WireGuard topology | **`titan` becomes the hub.** `techdelivery.es` is a VPS that cannot run arbitrary OS (no NixOS), so it stays a *client* of the new hub. All existing WG clients get rewired to `titan`. **Amended 2026-10-02 — the core is a triangle:** `titan`, `techdelivery.es` and the OPNsense box each hold a direct link to the other two, each with its own keypair; the leaves (`chiclana`, `llm01`, roadwarriors) dial `titan` alone. No standby hub, no shared keypair, no failover procedure — losing `titan` costs the leaves and what sits behind `titan`, not home↔VPS. See §4.3. | confirmed |
| D15 | WG migration style | **Renumber the mesh `192.168.2.0/24` → `192.168.133.0/24`** as part of the hub move. Every client config changes anyway, and disjoint subnets let both hubs run in parallel without a duplicate hub address. | confirmed (checklist in §11a) |

---

## 2. Scope / non-goals

**In scope**
- One new `x86_64-linux` NixOS host in this repo: `hosts/titan/`, flake output, CI leg, SOPS secrets.
- Module work required to make a *public* host safe (§9) — this is the bulk of the engineering.
- Bootstrap runbook for OVH rescue mode via `nixos-anywhere`.
- The k3s control plane config itself.

**Out of scope (referenced only)**
- The Kubernetes manifests for the workloads, cert-manager, Traefik tuning, external-dns. Those live in a Flux/kustomize repo shaped like `k8s-techdelivery`; §13 lists what that repo must provide.
- DNS zone creation for `titan.arrieta.eu` (sub-delegation or A records — §16 Q2).
- Backups of the cluster's PVs (follow-up; `k8s-techdelivery/apply/30-backup` is the pattern).

---

## 3. Inputs

**Confirmed by the operator**
- OVH baremetal, `x86_64-linux`, single host, own k3s cluster.
- Mostly self-hosted services, HTTPS ingress on 80/443, wildcard `*.titan.arrieta.eu`.
- SSH on port 13491, public (option 1).
- DNS-01, same mechanism as `../k8s-techdelivery`.
- Hardware (read from rescue mode 2026-10-01): **Intel Xeon E5-1650 v4 (6c/12t), 125 GiB RAM, 2× Intel SSDPE2MX450G7 450 GB NVMe** — identical model and size, both with **no partition table at all**, SMART self-assessment PASSED on both. UEFI (no BIOS), no TPM. Interfaces `eno1` (up, OVH public) and `eth1` (down, unused — no vRack).
- **Public IPv4: `<OVH_PUBLIC_IP>`** (OVH — literal in the gitignored companion, §0). Netmask and gateway still to be read from rescue mode — see §4.2.

**Discovered in the existing repos (drives the design)**
- `../k8s-techdelivery` DNS-01 = `cert-manager-webhook-ovh` 0.6.0, `ClusterIssuer le-prod-techdelivery`, `ovhEndpointName: ovh-eu`, creds in sops Secret `ovh-domain-secrets` (`OVH_APPLICATION_KEY` / `_SECRET` / `_CONSUMER_KEY`), `groupName: acme.techdelivery.es`.
- **`arrieta.eu` is already served by that same OVH DNS account** — `v.arrieta.eu` / `*.v.arrieta.eu` is issued by the OVH issuer. So `*.titan.arrieta.eu` needs no new ACME provider, only DNS records + a `Certificate`.
- A live WireGuard mesh exists: `192.168.2.0/24` (prefix confirmed 2026-10-02; earlier drafts said `/28`, which cannot contain the `.101`/`.102` roadwarriors), endpoint `techdelivery.es:51820`, already carrying LAN↔OVH traffic (MinIO backups to `s3.l.arrieta.eu` from the OVH side).
- `k8s-techdelivery` is k3s with `local-path` as the only StorageClass and Traefik as ingress.
- This repo has **no** `networking.wireguard` module anywhere — the WG peers are configured outside it.

**Missing — must be collected (§16)**
OVH model/RAM/disk count, primary IP + netmask + gateway as OVH states them, interface name, disk by-id paths, UEFI vs BIOS, WG hub owner + free address, k3s CIDR collision check, whether the Attic cache is reachable off-LAN.

---

## 4. Network design

### 4.1 Interfaces

| Interface | Purpose | Addressing |
|---|---|---|
| `eno1` | OVH public IPv4, ingress, SSH, WireGuard endpoint | static `<OVH_PUBLIC_IP>/24`, gateway `<OVH_GW>` — **on-link, confirmed from rescue mode** (§4.2) |
| `eth1` | present, `DOWN`, unused (no vRack on this box) | left unconfigured |
| `wg0` | WireGuard **hub** for the whole mesh (§4.3, D14) | `192.168.133.1/24` in the new `192.168.133.0/24` (D15) — `/24`, not `/32`: the hub is the endpoint every peer's routes point at, so it holds the whole mesh prefix on its own address rather than a point-to-point /32 |

`vars.nix` carries `networkInterface = "eno1"` and it is threaded into `staticNetwork.interface`, `k8sNetwork.primaryInterface`, and `--flannel-iface`.

**IPv6 is deliberately not configured for v1.** Rescue mode showed a routed `<OVH_IPV6>`/128 with live router advertisements, but `static-network.nix` is IPv4-only, so `titan` comes up IPv4-only and gets no `AAAA` record (§13a publishes A + wildcard A only). Follow-up, not a gap: OVH routed IPv6 is a `/128` plus a link-local default, and the NixOS firewall default-drops inbound v6 either way.

Resolver: `213.186.33.99` (OVH, seen in rescue) as `DNS1`, `1.1.1.1` as `DNS2` in the `titan/network_env` secret.

### 4.2 OVH addressing — resolved from rescue mode (2026-10-01)

Rescue mode answered it: `eno1` carries `<OVH_PUBLIC_IP>` as a **/24**, and `default via <OVH_GW> dev eno1` sits inside the on-link `scope link` route, with the gateway resolving to OVH's virtual MAC (`00:00:0c:…`). This is the **classic on-link /24** shape, not the `/32` + off-link pattern.

Consequences:

1. `staticNetwork.prefixLength = 24` — the module default is already correct, no change needed.
2. **`onlink` is not required.** The `routeFlags` option in `static-network.nix` is still worth implementing (§9), because it is what lets the config survive an OVH re-assignment to a routed/failover shape — but it ships empty on `titan`.
3. The health-gate heal branch and `network-route-watch` work as written, since the gateway is reachable.

*Correction kept on the record:* an earlier draft of this spec asserted `/32 + off-link` as fact. That is the Additional-IP pattern, not the primary-IP one, and it would have added a route flag the kernel did not need.


### 4.3 WireGuard — `titan` is the hub, and the core is a triangle (D14)

The mesh moves: `titan` listens, everything else dials in. `techdelivery.es` (VPS, non-NixOS) becomes a peer like any other; its A record may later be repointed at `titan`, which would let clients that resolve the endpoint by hostname follow automatically.

**The triangle (amended 2026-10-02).** Three boxes — `titan`, `techdelivery.es`, OPNsense — each hold a direct link to the other two, so the mesh survives `titan` for the one path worth saving (home↔VPS). Everything else dials `titan` and only `titan`.

A standby hub was considered and rejected. A standby reachable under one name forces both boxes to hold the **same private key**, because a WireGuard peer entry binds a key, not an address — which would put the hub key on a long-lived public VPS, where rooting it means impersonating the hub to every peer. It also drags in a shared identity that cannot peer with itself, a bounce-on-DNS-change step, and a firewall-parity rule to verify under pressure. The triangle buys the part that mattered with none of it.

Two consequences for this repo. First, the two extra core links live in the VPS's and OPNsense's own hand-maintained configs, so **`titan`'s own peer list carries no `endpoint` at all** — every peer dials in — and the module's hub assertion keeps holding. Second, those configs must advertise `titan`'s `/32` *plus the leaf `/32`s* `titan` forwards for, or the core has no route to the leaves.

**Roadwarriors sit at `.129`/`.130`, not the `.101`/`.102` they had on the old flat `/24`.** `public-host.nix` answers 6443/10250/9100/4243 only to `wireguard.staticSubnet` (`192.168.133.0/25` = `.0`–`.127`), so the old numbers would have put both laptops inside the trusted static range and made the static/roadwarrior split decorative.

New module `modules/nixos/wireguard.nix` (none exists today) must support **both** roles, because this repo will now own the hub:

```nix
wireguard = {
  enable = true;
  interface = "wg0";
  role = "hub";                      # "hub" | "peer"
  port = 51820;                      # hub listens; peer uses it as source port
  privateKeyFile = config.sops.secrets."wireguard/titan_private_key".path;
  address = "192.168.133.1/24";       # new mesh subnet, D15; /24 because the hub routes the whole mesh from its own address
  forward = true;                    # hub only: ip_forward + FORWARD accept
  peers = [                          # hub: no endpoint; AllowedIPs = peer's own /32
    { label = "home-lan";        publicKey = …; allowedIPs = [ "192.168.133.2/32" "192.168.0.0/24" ]; }
    { label = "chiclana";        publicKey = …; allowedIPs = [ "192.168.133.3/32" ]; }
    { label = "llm01";           publicKey = …; allowedIPs = [ "192.168.133.4/32" ]; }
    { label = "pixel7";          publicKey = …; allowedIPs = [ "192.168.133.101/32" ]; }   # roadwarrior
    { label = "macbookair";      publicKey = …; allowedIPs = [ "192.168.133.102/32" ]; }   # roadwarrior
    { label = "techdelivery-vps"; publicKey = …; allowedIPs = [ "192.168.133.5/32" ]; }
  ];
};
```

Design notes the module has to encode:
- **Hub peers have no `endpoint`** (they dial in; roaming is automatic). A `peer`-role host has an `endpoint` and no per-peer list. Two shapes, one option set — do not model them as two modules.
- **`forward = true` on the hub** is what makes the mesh a mesh: without it, home ↔ VPS paths that today traverse the VPS hub die. Needs `net.ipv4.ip_forward = 1` (k3s already sets it), a FORWARD accept for `wg0`, and a decision on **masquerade** (Q5d — **decided 2026-10-02: route, do not masquerade**; see §11a).
- **Return routes are the trap.** The home-LAN peer advertises `192.168.0.0/24`, which is how the OVH side reaches `192.168.0.42` today. The mirror image must exist on the router: a route for `192.168.133.0/24` pointing into its WG peer, or nothing home-initiated gets a reply. Verify this before declaring the migration done.
- **k3s coexistence**: kube-proxy owns FORWARD/nat heavily. Verify WG forwarding survives a k3s restart, and that flannel's vxlan (on the public iface) is unaffected.
- **`AllowedIPs` on `titan`'s side must include `192.168.0.0/24`** — it needs the home LAN for the Attic cache, rsyslog, and inbound Prometheus. llm01's existing secret allows only the WG subnet because it is already on the LAN; copying that value would silently break all three.
- **Roadwarriors are mesh-only — decided (Q13)** — and get their own slice — decided (Q14). Client `AllowedIPs` = `192.168.133.0/24` + `192.168.0.0/24`; no default route into the tunnel, so no OVH egress/abuse surface and no captive-portal weirdness. Their configs are not NixOS-managed (WireGuard app on the phone; `macbookair` runs macOS home-manager, which manages no WG here), so `wireguard.nix` generates the hub side and the client configs are handed out by hand.
- **Two subnets, one source of truth.** Static peers live in `192.168.133.0/25`, roadwarriors in `192.168.133.128/25`. `wireguard.nix` must **export** both ranges as options (e.g. `wireguard.staticSubnet` / `wireguard.roadwarriorSubnet`) and `public-host.nix` must consume them, so the split is declared once. Two files hardcoding `/25` is how the two modules drift apart and the firewall silently re-admits the phones.
- **Consequence to accept:** `kubectl` from the MacBook Air on the road is blocked by the /25 rule. If that ever matters, allow `6443` from a single `/32` rather than widening back to /24. Open sub-question (Q14): give them a slice (`192.168.133.128/25`) and scope the k3s/metrics allowlist to `192.168.133.0/25`, so a lost phone gets ingress apps and SSH but not the control plane.
- **MTU**: WG 1420 under a 1500 public link, with flannel vxlan (1450) inside it for any path that crosses both. Management traffic (API, metrics, SSH) is fine; flag it if anything large starts crossing the mesh.

**Ordering consequence for bootstrap:** the mesh does not exist until `titan` is up *and* every client is rewired. So `titan`'s own bootstrap must never depend on WG — which is exactly why D3 (public SSH on 13491) and D9 (no LUKS) matter. See §14.

### 4.3a Why `192.168.133.0/24` (D15)

Staying inside `192.168/16` is deliberate: `172.17.0.0/16` is Docker's bridge and `172.18–172.31` is what Docker/compose auto-assign — on a container host that is a collision generator — and `10.42/10.43` are already k3s pod/service CIDRs on both clusters.

Within `192.168/16`, the documented vendor and tool defaults to avoid:

| Range | Owner |
|---|---|
| `.0 .1 .2 .3 .4 .8 .15 .16` | Linksys / Huawei / D-Link / ZyXEL / Zoom defaults — `.2` is also macOS Internet Sharing **and** the current mesh |
| `.50` | ASUS (and AiMesh node) |
| `.56` | VirtualBox host-only |
| `.88` | MikroTik |
| `.99` | Vagrant / boot2docker |
| `.100` | common mgmt VLAN, VMware |
| `.122` | **libvirt/KVM `virbr0`** — several hosts here run `kvm-*` |
| `.123` | Sitecom |
| `.137` | Windows Internet Connection Sharing |
| `.168` | SonicWall |
| `.178` | AVM Fritz!Box |
| `.223` | Trendnet |
| `.254` | Siemens / Actiontec |
| `172.20.10.0/28` | **Apple personal hotspot** — directly relevant to the roadwarriors |

`192.168.133.0/24` clears all of them, sits above the low band people hand-pick, and keeps the last-octet scheme (`1` hub, `2` home-lan, `3` chiclana, `4` llm01, `5` VPS, `101`/`102` roadwarriors). Runner-up was `192.168.222.0/24`.

*Correction kept on the record:* an earlier draft called `192.168.31.0/24` a common ASUS default. It is not — ASUS ships `192.168.1.1` and `192.168.50.1`. `.31` was already acceptable; `.133` is simply tidier.

Q12 is **closed (2026-10-02)**: `192.168.133.0/24` confirmed unused at home, at chiclana, and on the OVH host network.

### 4.4 Exposure matrix (the contract the firewall implements)

| Port | Service | Allowed source | Notes |
|---|---|---|---|
| 13491/tcp | sshd | `0.0.0.0/0` | key-only, `PermitRootLogin no`, `PasswordAuthentication no` |
| 51820/udp | wireguard (**hub**) | `0.0.0.0/0` | every mesh client authenticates here now; rate-limit if easy |
| 80/tcp | Traefik (via ServiceLB) | `0.0.0.0/0` | redirect-only |
| 443/tcp | Traefik (via ServiceLB) | `0.0.0.0/0` | the only published app surface |
| 6443/tcp | k3s API | `192.168.133.0/25` (**static peers only**) | `kubectl` from home; roadwarriors excluded |
| 10250/tcp | kubelet | `192.168.133.0/25` | **never public** — authenticated but RCE-shaped |
| 10257/10259 | controller-mgr / scheduler metrics | `192.168.133.0/25` | `controlPlaneMetricsBindAddress = "0.0.0.0"`, authenticated `/metrics` |
| 2379/2380 | embedded etcd | none (drop) | single node; nothing needs it off-box |
| 9100/tcp | node_exporter | `192.168.133.0/25` | scraped by home Prometheus (Q9 = full) |
| 4243/tcp | comin exporter | `192.168.133.0/25` | |
| 514/tcp | rsyslog **outbound** to `192.168.0.41` | n/a (egress) | over WG; journald is the buffer when the mesh is down |
| `192.168.133.128/25` | roadwarrior slice | — | gets ingress apps on 443, SSH on 13491, and the home LAN; **no** k3s control plane, no exporters |
| 30000-32767 | kube-proxy NodePort | **none** | anything that needs publishing goes through Traefik on 443 |
| UDP 8472 | flannel vxlan | none needed | single node |

Everything else: inbound default DROP, plus the OVH **Edge Network Firewall** as an off-box second layer (Q19 rule set in §14 step 1). Note it is *stateless*, first-match-wins over priorities 0–19, IPv4-only, and **an Accept-only rule set does nothing — a `Deny` rule is mandatory**. It also only filters traffic arriving from outside the OVH network, so OVH's own management paths (monitoring, rescue netboot, IP-KVM) are not what these rules are for.

### 4.5 Firewall implementation

`modules/nixos/k3s.nix:76` and `modules/nixos/k8s-network.nix:28` both hard-set `networking.firewall.enable = false`. Change both to `lib.mkDefault false` — a one-word change that preserves every existing host — and add `modules/nixos/public-host.nix` that sets it back to `true` and owns the allowlist, including source-scoped rules that `allowedTCPPorts` cannot express:

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 13491 80 443 ];
  allowedUDPPorts = [ 51820 ];
  extraCommands = ''
    iptables -N titan-wg
    iptables -A titan-wg -s 192.168.133.0/25 -j ACCEPT   # static peers only; roadwarriors (.128/25) excluded
    iptables -A titan-wg -j DROP
    for p in 6443 9100 4243 10250 10257 10259; do
      iptables -A INPUT -p tcp --dport $p -j titan-wg
    done
    iptables -A INPUT -p tcp -m multiport --dports 2379,2380,30000:32767 -j DROP
  '';
};
```

**Verification item:** confirm whether nixos-26.05's `networking.firewall` backend is iptables or nftables before writing `extraCommands`; the snippet above assumes iptables. Also confirm k3s/kube-proxy's own rules and the NixOS input chain coexist (kube-proxy DNATs to pod IPs, so the filter INPUT chain still has to accept 80/443 explicitly — it does, above).

---

## 5. Break-glass ladder

Under D3 SSH never depends on WireGuard, so "WG is down" is not a lockout — it degrades monitoring/Attic/rsyslog only. The ladder, in order:

1. `ssh -p 13491 javier@<public-ip>` — always available; this is the primary path, not the emergency one.
2. If the box is up but the config is broken: `nixos-rebuild switch --rollback` over that SSH session, or boot the previous systemd-boot entry from the panel's KVM.
3. If WG is down and you need a *home-side* thing (Prometheus, Attic, rsyslog): nothing breaks the box; those just go stale. Note `atticCache.url` defaults to `nix-cache.l.arrieta.eu` — if that name is LAN-only, an OVH host without WG builds the whole closure from source (§16 Q7).
4. If the box won't boot: OVH **rescue mode** (netboot from the panel) → mount the root FS → chroot → `nixos-rebuild switch` from `/run/current-system`, or re-run `nixos-anywhere`.
5. If the network config is wrong and SSH is unreachable: OVH **IP-KVM** (JNLP on older ranges) to see the console.
6. OVH **panel IP firewall** to cut inbound while a bad rule is live.

Rules this imposes on the design:
- `PasswordAuthentication = false` on this host (the fleet default in `modules/nixos/ssh.nix` is `true` — must not ship here).
- The systemd-boot generation limit must stay > 1 so a rollback entry always exists.
- Rescue-mode root password and KVM access must be recorded as *collected inputs*, not discovered during an incident.

---

## 6. k3s design

```nix
k3s = {
  enable = true;
  role = "server";
  # no serverAddr — standalone
  tokenFile = config.sops.secrets."k3s_token_titan".path;   # NOT the existing k3s_token
  disable = [ ];                    # keep traefik + servicelb (D4)
  taints = [ ];                     # single node must be schedulable
  controlPlaneMetricsBindAddress = "0.0.0.0";                # firewalled to wg (§4.4)
  extraFlags = [ "--flannel-iface=<pub0>" "--node-external-ip=<public-ip>" ];
};
```

- `modules/nixos/k3s.nix` currently makes `serverAddr` and `tokenFile` **mandatory** options. `serverAddr` must become `lib.mkOption { type = lib.types.str; default = ""; }` (k3s ignores it for `role = server`). `tokenFile` stays required but gets its own secret so the two clusters never share a token.
- **CIDRs — checked directly against both live clusters (2026-10-01, Q8).** `k8s-casa` nodes report `10.42.4.0/24`–`10.42.7.0/24` and `k8s-techdelivery` reports `10.42.0.0/24`; both use `10.43.x` ClusterIPs. So **both existing clusters already occupy the k3s defaults `10.42.0.0/16` + `10.43.0.0/16`.** Nothing routes pod/service ranges across the mesh today, so defaults would work — but changing a CIDR later means rebuilding the cluster, while choosing now costs nothing. Recommendation: **`--cluster-cidr=10.62.0.0/16 --service-cidr=10.63.0.0/16`**, which collides with nothing here and keeps cross-cluster routing possible forever.
- **`--node-external-ip` is probably unnecessary.** `k8s-techdelivery`'s single node reports **its public address** as `Internal-IP` and runs fine, which proves k3s is happy on a public-only host and picks the public IP as InternalIP by itself. Verify on `titan` after install rather than assuming the flag is needed; the corollary is that kubelet and the API are reachable *by that address*, which is exactly what §4.4 exists to fence.
- flannel: default vxlan is correct; `host-gw` is not usable on OVH's public L3 network.
- `networking.firewall.enable` interplay is handled in §4.5, not here.
- Swap: existing hosts carry 8 G swap partitions and run k3s fine; keep the same shape unless the kubelet complains.

---

## 7. Disk layout & encryption

Hardware (confirmed from rescue mode): **2× Intel SSDPE2MX450G7, 450 GB NVMe, identical model and size, both completely empty, SMART PASSED**. UEFI, no TPM. ~419 GiB usable per disk, so a RAID-1 gives ~419 GiB.

**The constraint that decides this: UEFI firmware cannot read a Linux mdraid array.** The ESP must be a plain FAT partition no matter which layout is chosen, so "mdraid-1 for everything" was never really on the table — the only question is whether the *boot partition* is mirrored, and mirroring it means leaving systemd-boot for GRUB.

**A. Single disk** — one SSD, second idle. Rejected: the second disk is free.

**B. mdraid-1 for `/`, plain ESP on disk0 — recommended.** Both disks mirror everything below a single 1 GiB ESP on disk0, so `/var/lib/rancher` — the k3s data, i.e. the only state on the box — is inside the mirror. `boot.swraid.enable = true` is mandatory (disko does not set it) and the initrd needs `nvme` + `raid1`. systemd-boot from `base.nix` stays untouched, so `titan` boots exactly like the other 13 hosts.

**B-full. mdraid-1 + GRUB `mirroredBoots`** — same as B, both ESPs mirrored. Costs a per-host bootloader fork away from the fleet's systemd-boot (`boot.loader.grub.mirroredBoots = [ … ]`) to protect the one component whose loss is a 5-minute reinstall rather than data.

**C. System on disk0, mirror for data only** — disk0 holds ESP + `/` like today; both disks carry a mdraid-1 mounted under `/var/lib/rancher`. Protects the same data as B but splits the layout, adds a mount, and leaves `/` (with `/etc`, secrets, the nix store) single-disk for no gain.

**Recommendation: B, with LVM on top — decided (D13).** Identical empty disks make mirroring everything free, and one array is less to reason about than C's split. Losing disk1 costs nothing; losing disk0 costs a boot-partition rebuild from rescue — **not** data.

### 7a. Decided layout: mdraid-1 → LVM → two logical volumes

**Doctrine: the cluster is disposable, the PVs are not.** Everything k3s rebuilds — images, overlay layers, `emptyDir`, logs, even its own datastore, which Flux re-applies from git — belongs on `/`. The one thing that cannot be regenerated is `local-path` volume data, so that gets its own logical volume and nothing else shares it.

```
disk0  pci-0000:02:00.0-nvme-1   (2 % wear)
  ├─ esp        1 GiB  vfat → /boot     plain, NOT in the array (firmware can't read mdraid)
  └─ md member  rest   ┐
disk1  pci-0000:03:00.0-nvme-1  (22 % wear)
  └─ md member  rest   ┘  → /dev/md/titan  RAID1, metadata 1.2, --homehost=titan
                             └─ PV → VG vg0
                                  ├─ lv-root  150 GiB  ext4 → /
                                  ├─ lv-pvc   240 GiB  ext4 → /var/lib/rancher/k3s/storage
                                  └─ (~29 GiB left unallocated in vg0 on purpose)
```

| volume | holds | why |
|---|---|---|
| `lv-root` → `/` | Nix store + generations, `/etc`, **containerd images and overlayfs layers** (`/var/lib/rancher/k3s/agent/containerd`), `emptyDir` (`…/agent/kubelet/pods`), container logs (`…/agent/logs`), k3s datastore (`…/server/db`), journald + `/var/log/messages` | all rebuildable or re-appliable from git; `nodefs` for `ephemeral-storage` accounting, which is exactly right — ephemeral limits should measure the ephemeral filesystem, not PV capacity |
| `lv-pvc` → `/var/lib/rancher/k3s/storage` | `local-path` PV data only | the only irreplaceable bytes on the box, so it is the only thing restic must capture (Q15) |

Sizing is deliberately lopsided. `/` carries the Nix store *and* the image store, so 60 GiB would be a slow-motion incident; 150 GiB is the safe side for a services box. **Growing an LV is easy (`lvresize` + online `resize2fs`); shrinking ext4 is offline and risky** — so bias `/` large and let the 240 GiB PV volume take the rest. The ~29 GiB unallocated in `vg0` is the LVM payoff: rebalancing root vs PVs later without repartitioning. Without slack, LVM is ceremony.

**Three things this layout makes mandatory:**

1. **`k3s` must not start before the PV mount exists.** If the mount is missing, k3s happily creates `storage/` on `/` and PV data lands on the wrong filesystem — silently, and then half the data is in each place. So the k3s unit needs `systemd.services.k3s.requires = [ "var-lib-rancher-k3s-storage.mount" ]` and `after` it (disko generates the mount unit; the ordering does not happen by itself). This belongs in `modules/nixos/k3s.nix` gated on a new option, not in the host file.
2. **Image GC has to be bounded**, because images now share `/` with the store: `--kubelet-arg image-gc-high-threshold=80`, `image-gc-low-threshold=70`, plus an eviction hard threshold on `nodefs.available`. Otherwise a registry pull storm fills root and kubelet evicts pods to free the wrong thing.
3. **Backups: two streams, both in v1.** `lv-pvc` holds the only irreplaceable bytes, and the k3s datastore on `/` is cheap to snapshot — so etcd goes to S3 as part of v1, not as a later extra (§13b). Flux can re-apply specs, but replaying a whole cluster by hand is not a restore plan.

**Consequence to keep honest:** "only the PVs need persisting" is about *durability*, not *confidentiality*. The k3s datastore sits on `/`, and etcd stores Kubernetes Secrets unencrypted at rest — so the unencrypted-root risk in §17 covers every Secret the cluster holds, not just the PVs. That does not change the D9 decision, but it does mean the deferred LUKS work is protecting more than the PVs.

Why this shape and not something cleverer:

- **mdraid under LVM, not LVM-RAID across two PVs.** Redundancy lives at the md layer — one array to reason about — and `lvresize` grows either LV independently. The alternative (two `lvm_pv` partitions with `lvm_type = "mirror"` per LV, which is what disko's own `example/lvm-raid.nix` does) buys a per-LV redundancy choice nothing here needs, and root on LVM-RAID in the initrd is a less travelled road.
- **No swap LV.** 125 GiB RAM, and k3s prefers swap absent.
- **Journald capped** (`base.journald.systemMaxUse = "2G"`, which `base.nix` renders into `services.journald.extraConfig`): the fleet already ate a runaway loop flooding `/var/log/messages` on k8s-node03 (AGENTS.md, 2026-08-27), and here that file shares `/` with the store and the image store.

What LVM does *not* buy: no redundancy of its own, and the VG cannot outgrow `/dev/md/titan` — capacity growth means larger disks, re-growing the array, then `pvresize`. Snapshots exist but are not the backup; restic → MinIO is (Q15).

**This is new ground for the repo.** `grep` finds no `mdraid`, `mdadm` or `lvm_vg` in `hosts/` or `modules/` — `titan` is the first disko layout of its kind here. The pinned disko (rev `725ea35e`) supports the legacy schema the repo already uses (`disko.devices.disk` + `mdadm` + `lvm_vg`, per disko's `example/lvm-raid.nix`), so no schema migration is needed. But assembly happens in stage 1, so alongside disko: `boot.swraid.enable = true` (disko does not set it), `boot.initrd.availableKernelModules = [ "nvme" ]`, `raid1` + `dm-mod` in the initrd, and `--metadata=1.2 --homehost=titan` so `mdadm --assemble --scan` works from rescue. **Keep OVH IP-KVM open for the first boot.** Rescue recovery if stage 1 does not assemble:

```sh
mdadm --assemble --scan; vgchange -ay vg0
mount /dev/vg0/lv-root /mnt; mount /dev/vg0/lv-pvc /mnt/var/lib/rancher/k3s/storage
nixos-rebuild boot --flake /mnt/…#titan   # or re-run nixos-anywhere --phases install
```

**Wear readout (2026-10-01) — both healthy, but not equally:**

| disk | by-path | Percentage Used | Available Spare | Written | Power-on |
|---|---|---|---|---|---|
| `nvme0n1` | `pci-0000:02:00.0-nvme-1` | **2 %** | 98 % (thresh 10 %) | 37 TB | 35,446 h |
| `nvme1n1` | `pci-0000:03:00.0-nvme-1` | **22 %** | 98 % | **509 TB** | 51,071 h |

Mixed-use (≈3 DWPD-class) parts: 22 % used against 509 TB written implies roughly 2.3 PB rated endurance, so `nvme1n1` still has ~1.9 PB left and both sit far above the spare threshold. Consequences: the array's first failure is most likely `nvme1n1` — which is exactly what RAID-1 is for — and the **ESP goes on `nvme0n1`**, the near-new disk, because a single ESP is a single point of failure worth putting on the healthiest hardware. Copy these numbers into `hosts/titan/README.md` as a replacement baseline.

**Boot-entry risk (low, but name it).** `efibootmgr -v` printed nothing in rescue, so NVRAM may hold no boot entries. `bootctl install` writes the removable-media fallback `\EFI\BOOT\BOOTX64.EFI` as well as `EFI/systemd/`, which is what firmware falls back to, so this is expected to boot regardless — verify `efibootmgr` after the first install, and if there is still no entry, do not chase it while the fallback works.

Swap: with 125 GiB RAM, **no swap partition** — k3s prefers it absent, and the fleet's swap shape is not a constraint here.

**Encryption (D9) — decided: unencrypted root.** OVH has no TPM, so the fleet's `crypttabExtraOpts = [ "tpm2-device=auto" ]` is dead weight here and is dropped from `titan`'s disko.

Consequences of the choice:
- No `luks` node in `disko.nix`, no `passwordFile`, no initrd SSH unlock module, no initrd host key in SOPS. The bootstrap is the shortest path in the repo.
- `bootstrap_host.sh` still *requires* `--disk-password` (it passes `--disk-encryption-keys /tmp/disko-password` to nixos-anywhere). With no LUKS node nothing reads it — pass a throwaway value and note why in `hosts/titan/README.md`.
- Accepted exposure: `/run/secrets` (age key, k3s token), etcd, and every PV are plaintext to anyone who pulls a disk. Bounded by the fact that the age key alone cannot decrypt `secrets.yaml` without… nothing — it *is* the decrypt key, so a disk pull plus this repo equals full secret access. Say the quiet part: that is the real cost of D9.

**Deferred follow-up (own PR, not blocking bootstrap):** LUKS + initrd SSH unlock — stage-1 SSH on the public NIC; on 26.05 with `boot.initrd.systemd.enable = true` (already set in `base.nix`) that means `boot.initrd.network.enable` + `boot.initrd.network.ssh.enable` + host key + authorized keys, `boot.initrd.systemd.network.networks.*` for the address, and the NIC driver in `boot.initrd.availableKernelModules`. Note it is **not retrofit-able without a reinstall** — adding LUKS later means re-running disko, so if this ever matters, it must be decided before `titan` takes state.

Whatever is chosen later, **the initrd must never require an interactive passphrase with no remote path in** — that is a datacenter visit.

---

## 8. Host file layout

```
hosts/titan/
  configuration.nix          # module wiring only
  default.nix                # mandatory (flake.nix imports the dir)
  hardware-configuration.nix # generated during install
  disko.nix                  # §7
  vars.nix                   # hostname, interface, $IP_ADDRESS/$DEFAULT_GATEWAY/$DNS1/$DNS2, k3s block
  README.md                  # OVH-specific runbook (panel steps, KVM, rescue mode)
```

`configuration.nix` imports the fleet modules **minus** `openiscsi`, **plus** `wireguard`, `public-host`, `prometheus` (node_exporter) and `rsyslog` — the last one only works over WG, since `192.168.0.41` is LAN-only.

Two host-level opts decided late in review: `cominGitOps.hermesEnable = false` (Q17 — needs the `comin.nix`/`hermes-ssh.nix` opt-out in §9) and the lean home-manager set (Q18 — `host-common` + `shell` only, via the same hostname gate the Pis use).

---

## 9. Module work

| Module | Change | Why |
|---|---|---|
| `k3s.nix` | `serverAddr` → default `""`; `networking.firewall.enable = lib.mkDefault false` | standalone server has no server URL; firewall must be flippable |
| `k8s-network.nix` | `networking.firewall.enable = lib.mkDefault false` | same |
| `static-network.nix` | new `routeFlags` option (e.g. `onlink`) applied to every `ip route replace` it emits | insurance against a future re-addressing to a routed/failover shape; it ships empty on `titan` (§4.2) |
| `comin-health-gate.nix` | route check + heal must honour `routeFlags` | it duplicates the same `ip route replace` |
| `ssh.nix` | options for `ListenAddresses` and `PasswordAuthentication = false`. **Deviation from the original "public + wg0" plan:** only the mesh address can ever be filled in. The public address exists only at runtime (SOPS `network_env`, §4.2 + §10), so it cannot be baked into `sshd_config` at build time; `ssh.listenAddresses` stays available for the `wg0` address alone and empty (bind-all) remains the default | fleet default is unsafe on the open internet |
| **new** `wireguard.nix` | declarative **hub and peer** roles, SOPS-backed keys, `forward` for the hub, and **exported `staticSubnet`/`roadwarriorSubnet` options** the firewall consumes (§4.3) | none exists; this repo now owns the hub |
| **new** `public-host.nix` | firewall on + allowlist + source-scoped chains (§4.5) | encodes the exposure matrix once |
| `attic-cache.nix` | per-host URL override for off-LAN hosts | default URL is the `.l.` LAN name |
| `rsyslog.nix` | enabled, target `192.168.0.41` **over WG**; needs a disk-backed remote queue so logs survive a mesh outage instead of filling the journal | LAN-only target, reachable only via the mesh |
| `base.nix` | unchanged unless disk layout B (bootloader) | systemd-boot assumption |
| `flake.nix` | `nixosConfigurations.titan` with the same module set as `k8s-node05` (disko, sops, home-manager, comin, nix-sweep) | host registration |
| `.github/workflows/verify.yml` | add `- { host: titan, runner: ubuntu-24.04, arch: x86_64 }` | the matrix is explicit; an unlisted host is never built or cached |
| `scripts/comin-approve.sh` | `COMIN_DOMAIN` is one suffix for every host; this host needs a different name (WG address or `titan.titan.arrieta.eu`) | otherwise the gatekeeper cannot reach it |
| **new** `hermes-ssh.nix` opt-out | `comin.nix` force-sets `hermesSsh.enable = true`; needs a flag so `titan` can turn it off (Q17) | comin currently gives no veto |
| `modules/home-manager/base.nix` | hostname gate extended to `titan`: `host-common` + `shell` only, skipping `dev-tools`/`python`/`k8s` (Q18) — the same mechanism already used for `k8s-pi01..03` | a public box needs vim/git/htop/jq, not rustup and nodejs |
| `common/ssh-keys.nix` | unchanged — already the single source of truth | — |

---

## 10. Secrets inventory (add to `secrets.yaml`)

| Key | Content | Notes |
|---|---|---|
| `titan/network_env` | `IP_ADDRESS=`, `DEFAULT_GATEWAY=`, `DNS1=`, `DNS2=` | same shape as the fleet; DNS must be public resolvers, not `192.168.0.x` |
| `ssh_keys/titan_host_private` / `_public` | pre-generated `ssh-keygen -t ed25519 -C titan` | **trailing newline required** (AGENTS.md) |
| `k3s_token_titan` | new random cluster token | must not reuse `k3s_token` |
| `wireguard/titan_private_key` | `wg genkey` | public half goes to the hub |
| `wireguard/titan_address` | `192.168.133.1` | hub address (D15) |
| `wireguard/hub_public_key` | no longer needed on `titan` — **`titan` is the hub**; each *client* needs the hub pubkey instead | see §11a |
| ~~`initrd/ssh_host_key` + `initrd/authorized_keys`~~ | not needed — D9 = unencrypted root | revisit with the deferred LUKS PR |

No `.sops.yaml` change: recipients are unchanged, and hosts receive the age key at bootstrap (`/var/lib/sops-nix/key.txt`), so no `updatekeys` run is needed. Verify with `sops -d secrets.yaml >/dev/null` after editing.

---

## 11. GitOps & rollout

- `cominGitOps.branch = "main"`, `confirmerMode = "auto"` (D10, "for now") — a fresh empty box is the ideal canary, and it is the **only canary reached over WAN**: today both canaries (`k8s-node05`, `llm01`) are on the LAN, so nothing exercises comin + the health gate across a real network path. That coverage is the main reason to put it here rather than in the fleet ring.
- `cominGitOps.healthGate.checks = [ "route" "k3s" "current-system" ]` — **`iscsi` must be off** (no `openiscsi` here; the check is documented as a no-op without it, but leaving it out is clearer).
- The route check must honour `routeFlags` (§9) so a future re-addressing cannot silently break self-heal. On `titan` the flag is empty (§4.2), so today the check behaves exactly as it does on the fleet.
- Fleet promotion (`main` → `stable`) does not apply to this host if it stays on `main`. If it is instead put on `stable`, `scripts/comin-approve.sh` needs the name fix in §9 before it can be accepted.
- `hermesSsh` comes along with comin unconditionally (forced-command account), reachable on 13491 like any SSH user. **Decided (Q17): disabled on `titan`** — with D10 = auto nobody needs `comin confirmation accept` over SSH, so it has no job here. `comin.nix` needs an opt-out flag (§9); re-enable if `titan` ever moves to `stable`.

---

## 11a. WireGuard hub migration + renumber (D14, D15)

Two changes at once: the hub moves from the `techdelivery.es` VPS to `titan`, **and** the mesh is renumbered `192.168.2.0/24` → `192.168.133.0/24`. Doing both together is defensible because every client config changes anyway, and disjoint subnets mean the old and new hubs can run in parallel with no duplicate hub address (sharing a subnet would put both hubs on the same hub IP). This has the largest blast radius in the spec: the mesh carries the home↔OVH backup path, Prometheus scrapes, and whatever `techdelivery.es` reaches over it.

**Current hub inventory** — read from `/etc/wireguard/wg0.conf` on the VPS, 2026-10-01:

| Peer `AllowedIPs` today | Reading | Proposed new |
|---|---|---|
| `192.168.2.2/32, 192.168.0.0/24` | **home LAN gateway** — it advertises the whole LAN; this is how the OVH side reaches `192.168.0.42` | `192.168.133.2/32` + keep `192.168.0.0/24` |
| `192.168.2.3/32` (`#`, `192.168.1.1/32` commented) | chiclana site; the commented `192.168.1.1/32` suggests its LAN route was deliberately disabled | `192.168.133.3/32` |
| `192.168.2.4/32` | llm01 — **leaves the mesh entirely, do not renumber.** Its peer was a leftover from bridging llm01 to the VPS; llm01 now sits inside the home LAN and is reached at `192.168.0.29` via the gateway peer. **Checked 2026-10-02: llm01 configures no WireGuard interface at all** — no `networking.wireguard`, no import of `wireguard.nix`, nothing. | peer deleted; verify on the host first (see Task 15) |
| `192.168.2.101/32` | **roadwarrior** — Pixel 7 | `192.168.133.101/32` |
| `192.168.2.102/32` | **roadwarrior** — MacBook Air | `192.168.133.102/32` |
| `192.168.2.1/32` (hub itself) | **confirmed 2026-10-02** — the current hub's own address, read from the VPS. Retires when every peer has handshaked with `titan`. | `192.168.133.1/24` on `titan`; the VPS rejoins as a plain client at `.5` |

Keeping the last octet keeps the diff legible. The VPS becomes an ordinary peer (`192.168.133.5` proposed). The hub's own address is written `/24`, not `/32`: `titan` is the endpoint every peer's routes point at, so its wg0 has to carry the whole mesh prefix (§4.1).

**Renumber checklist** — every hard-coded reference grep found across the three repos. This is grep-complete, not truth-complete: anything outside these repos (router configs, the VPS, dashboards, alert rules) is not covered.

| Where | Reference | Action |
|---|---|---|
| `k8s-techdelivery/apply/50-apps/apps/chiclana-hass.yaml:8` | `ip: 192.168.2.3` | → `192.168.133.3` |
| `k8s-techdelivery/apply/50-apps/apps/gatus.yaml:57` | `http://192.168.2.3:8123` | → `192.168.133.3` |
| `k8s-techdelivery/apply/50-apps/monitoring/node-exporter-llm01.yaml:11` | `192.168.2.3:9100` | **already looks wrong** — llm01's WG address is `.4`, `.3` is chiclana. Fix to `192.168.133.4` while renumbering; if this scrape is green today it is lying. |
| `nixos-configurations/secrets.yaml` → `wireguard/{private_key,address,publicKey,endpoint,allowedIPs}` | materialised on llm01 as five files | **not a renumber — a deletion.** Nothing in this repo reads any of the five: no `networking.wireguard`, no module import, no script. They are dead files on disk, one of them a private key with a 0600 owner-root mode that no process ever opens. Remove the `sops.secrets` entries and the secrets themselves. |
| VPS `/etc/wireguard/wg0.conf` | whole file | superseded by `titan`'s hub config; retire last |
| each client's `wg0.conf` | endpoint + address | generated by `wireguard.nix` where the client is NixOS; by hand on the VPS and the routers |

**Return routes — Q5d, decided 2026-10-02: route, do not masquerade.** The home router (`OPNsense`) must route `192.168.133.0/24` back into its WG peer, or nothing home-initiated (Prometheus scrapes, `kubectl` to 6443, comin-approve SSH) gets a reply.

Why route rather than NAT:

- **Source fidelity.** With a route, `titan` sees `192.168.133.4` when `llm01` scrapes it and `192.168.133.2` when the router itself connects. Masquerading collapses every home-originated connection onto the router's mesh address, which throws away exactly the signal `public-host.nix` is built on — its mesh allowlist matches on `-i wg0 -s 192.168.133.0/25` — and it flattens the `hermes` SSH audit trail and any future per-peer rule.
- **No double NAT.** Mesh to LAN to k3s already crosses enough boundaries; one fewer is one fewer conntrack and MTU mystery.
- **It is the cheaper option anyway.** The OPNsense WireGuard plugin installs the route from the peer's Allowed IPs, so "route" is the default if the endpoint advertises `192.168.133.0/24`.

What masquerade buys is immunity to a missing route — which is why many meshes have it and never notice. That is also why it hides misconfiguration: a scrape that times out with a green `wg show` is the signature of a missing route, and NAT would have papered over it until something else broke.

**Sequence, which matters more than the decision.** Add the route first — it is required either way. Leave any existing masquerade on the old hub alone until that hub is retired; pulling it mid-migration creates a second failure mode while six configs are already in flight. Only afterwards, as a separate quiet change, test whether anything still needs it (`tcpdump -ni wg0` on `titan`, send traffic from a home-LAN host, read the source address) and drop it if nothing does.

Whether the old hub masquerades today is still worth recording for the audit — Firewall → NAT → Outbound on OPNsense, or Routing → Static Routes for `192.168.2.0/24` — but it no longer gates the migration.

Order of operations:

1. `titan` installed, public, stable — old mesh untouched, nothing depends on `titan` yet.
2. Inventory finished (Q5, Q12); keys generated per peer.
3. `wireguard.nix` hub deployed to `titan` on the **new** subnet with all peers defined. Two hubs coexist, nobody is connected to `titan` yet, so nothing breaks.
3a. **Bridge the two hubs** (added 2026-10-02). Add `titan` as a peer on the old hub with `192.168.133.0/24` in AllowedIPs, and the old hub as a peer on `titan` with `192.168.2.0/24`. Without this, the moment a peer moves every peer still on the old mesh black-holes traffic to it — the old hub still routes that peer's old address, which no longer exists. The bridge makes the whole flip window non-breaking, and retiring the old hub becomes deleting one peer instead of untangling a half-migrated mesh. Cost: two hubs routing each other's subnets for a few hours, which is precisely what is wanted while peers move one at a time. **Update 2026-10-02:** the bridge is not throwaway — the `titan`↔`techdelivery.es` link it creates is permanent, because that pair is two corners of the core triangle (§4.3). What gets deleted at the end is the old hub role, not the link.
4. Flip clients **one at a time**, least-critical first: `pixel7` → `macbookair` → chiclana → home LAN → `llm01` → `techdelivery.es` VPS. Roadwarriors first because nothing runs behind them. Home LAN before `llm01` because the backup restore drill needs MinIO through it. The VPS is demoted last because it *is* the old hub. Each flip changes that peer's endpoint *and* address in one step; a star mesh means only that peer blips.
5. Verify each flip: `wg show` handshake on `titan`, ping the peer's new WG IP, then the real consumer (Prometheus target, MinIO, gatus check). Tick the checklist row.
6. Confirm the home router's return route by connecting **from home toward** `titan` (not just `titan` toward home) — the direction people forget.
7. Retire the VPS hub last; optionally move the `techdelivery.es` A record to `titan`.

Hard constraints:
- The hub move must not be attempted on the same day as the `titan` bootstrap. Two first-times at once is how you cannot tell which one failed. **Live constraint: the bootstrap completed 2026-10-02, so Task 15 waits for its own session.**
- Rollback per client = revert that client to the old hub + old address. Keep the VPS hub running until every peer is confirmed flipped.
- Do not delete the old hub config until every checklist row is verified on the new addresses.

---

## 12. CI

Add the leg to `verify.yml`. Note the workflow's Attic-push step and the substitution summary grep `nix-cache.home.arrieta.eu` — CI runners reach Attic over the public name, which is the same question as §16 Q7.

---

## 13. Cluster-side deliverables (different repo, listed so they are not forgotten)

**Repo decided (Q16, 2026-10-01): a new GitOps tree mirroring `k8s-techdelivery`** — Flux + sops-encrypted k8s Secrets. It is the closest sibling (k3s, `local-path`, bundled Traefik, OVH DNS-01), so the manifests port almost unchanged; `k8s-casa`'s layout does not.

- cert-manager + `cert-manager-webhook-ovh` with its own `groupName` (e.g. `acme.titan.arrieta.eu`) and a `ClusterIssuer le-prod-titan` using OVH API creds that can write `arrieta.eu` DNS.
- `Certificate` for `titan.arrieta.eu` + `*.titan.arrieta.eu`.
- Traefik tuned down: dashboard/API off, `hostNetwork`/ServiceLB binding to the public IP on 80/443 only.
- `local-path` StorageClass (k3s default) — matches `k8s-techdelivery`'s constraint.
- **Backups — see §13b.** etcd snapshots to S3 via k3s itself, and restic for the PVs, both to the home MinIO over WireGuard. Not optional polish: `titan` is a **single** unencrypted node, so without them the failure mode of one bad disk is "recreate everything by hand".
- No external-dns for v1 — the wildcard A record from §13a means every service name already resolves.

---

### 13a. DNS records — `../public-dns-tf` (Q2, decided 2026-10-01)

`titan.arrieta.eu` is **plain records in the existing `arrieta.eu` OVH zone**, and that zone is managed with Terraform in `../public-dns-tf` (OVH provider, `endpoint = ovh-eu`), so the change lands there — not in the OVH panel. New file `titan.arrieta.eu.tf`, following the style of `home.arrieta.eu.tf` / `local.arrieta.eu.tf`:

```hcl
resource "ovh_domain_zone_record" "titan" {
  zone      = "arrieta.eu"
  subdomain = "titan"
  fieldtype = "A"
  ttl       = 300
  target    = "<OVH_PUBLIC_IP>"
}

resource "ovh_domain_zone_record" "star_titan" {
  zone      = "arrieta.eu"
  subdomain = "*.titan"
  fieldtype = "A"
  ttl       = 300
  target    = "<OVH_PUBLIC_IP>"
}
```

The literal `target` is `<OVH_PUBLIC_IP>` here on purpose — the copy with the real address is in the gitignored companion (§0), and `../public-dns-tf` is a **private** repo, so the literal belongs there.

Wildcard A + the wildcard cert means every self-hosted service resolves with no per-app DNS work and no external-dns. TTL 300 matches `local.arrieta.eu.tf`, so the IP can move without a long tail.

Three things this repo taught me that change the plan:
- **The zone is only partially managed by TF.** `v.arrieta.eu` / `*.v.arrieta.eu` — used all over `k8s-techdelivery` — is **not** declared here, so records exist out-of-band. `titan` should be TF-only, and migrating `v` into TF is a worthwhile follow-up; until then nobody should trust `terraform plan` as the whole truth about the zone.
- **TF and cert-manager share the zone.** That is fine — `ovh_domain_zone_record` manages only what it declares, so TF will not delete the ephemeral `_acme-challenge.titan` TXT records the webhook writes. It is worth saying out loud because a zone-sync-style provider would have deleted them on every apply.
- **The webhook and TF need OVH API credentials that can write `arrieta.eu`.** The new cluster needs its own copy of `OVH_APPLICATION_KEY/SECRET/CONSUMER_KEY` as a sops-encrypted k8s Secret (the `k8s-techdelivery` `ovh-domain-secrets` pattern), scoped to DNS.

`titan.arrieta.eu` is also the **WireGuard endpoint hostname** for every peer and the **SSH/comin hostname** — decided 2026-10-01. That decouples the mesh from the `techdelivery.es` A record entirely.


### 13b. Backup design (Q15) — two streams, both in v1

| what | how | destination | why this way |
|---|---|---|---|
| k3s datastore (embedded etcd) | **k3s's own snapshot-to-S3** — no sidecar, no CronJob | `s3.l.arrieta.eu` (MinIO at `192.168.0.42`, reachable only over WG), bucket `titan-etcd` | k3s already speaks S3 for etcd snapshots; a CronJob would be a second, worse copy of a mechanism the control plane has built in |
| `local-path` PVs on `lv-pvc` | restic CronJob against `/var/lib/rancher/k3s/storage` | same MinIO, bucket `titan-pvc` | etcd does not contain volume data; this is the only stream that carries the irreplaceable bytes |

Sketch of the k3s side (`services.k3s.extraFlags`, credentials from a sops `EnvironmentFile` as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`):

```
--etcd-snapshot-s3
--etcd-snapshot-s3-endpoint=https://s3.l.arrieta.eu
--etcd-snapshot-s3-bucket=titan-etcd
--etcd-snapshot-s3-region=home
--etcd-snapshot-s3-force-path-style     # MinIO needs path-style addressing
--etcd-snapshot-cron=0 3 * * *
--etcd-snapshot-retention=14
--etcd-snapshot-compress
```

Four things to get right:

- **Verify the flag names against the k3s version nixpkgs 26.05 actually ships** (`nix eval .#nixosConfigurations.titan.config.services.k3s.package.version`) before writing them. `--etcd-snapshot-cron` and the S3 flags are all relatively recent, and a typo here fails silently — the snapshots just never appear.
- **`networking.hosts` gets a static entry `192.168.0.42 s3.l.arrieta.eu`.** `.l.` names are split-horizon and not in `../public-dns-tf`, so resolving them from `titan` would make backups depend on the mesh *and* on the home resolver. Pinning the address in the host file removes that dependency and closes Q7 by making it moot.
- **An etcd snapshot is every Secret in the cluster, in plaintext.** The bucket is therefore the most sensitive object in the whole design — more so than the node's disk. Scope the MinIO key to exactly these two buckets, and remember the mesh is the only path to it (no WG, no backup — which is why the WG migration in §11a has to be treated as a backup-affecting change).
- **A backup that has never been restored is a wish.** The v1 exit criteria include a restore drill: stand up a scratch k3s elsewhere, restore the snapshot, confirm the workloads and a PV come back. The exact restore invocation differs between k3s versions (`--cluster-reset` plus the snapshot name, or `--etcd-snapshot restore`), so write it down from the installed version's docs during the drill rather than trusting this spec.


---

## 14. Bootstrap runbook (OVH)

1. Panel: record rescue-mode root password, confirm IP-KVM availability, **disable OVH monitoring/HDV only for the bootstrap window** (kexec looks like a dead server and can trigger an intervention that locks netboot) and **re-enable it once the first disk boot succeeds** — Q20 chose interventions ON, and that ICMP monitoring is the signal that makes them happen.

   Then set the **OVH Edge Network Firewall** (Q19). The naive "allow 13491/80/443/51820" is not a working rule set: the ENF is stateless, so return traffic for titan's *own outbound* TCP (Attic fetches, `git fetch`, HTTPS) is dropped unless established traffic is accepted, and DNS replies (UDP source port 53 to `213.186.33.99` / `1.1.1.1`) are dropped without a matching rule. Working shape, first match wins:

   | prio | rule | why |
   |---|---|---|
   | 0 | Accept TCP, state `established` | return traffic for titan's outbound TCP; without it the box cannot fetch or pull |
   | 1 | Accept UDP, source port 53 | DNS answers |
   | 2 | Accept ICMP | OVH monitoring + your own reachability probes |
   | 3 | Accept TCP dst 22 | **rescue-mode ssh only** — see below |
   | 4 | Accept TCP dst 13491 | sshd (the only port it listens on) |
   | 5 | Accept TCP dst 80 | ingress |
   | 6 | Accept TCP dst 443 | ingress |
   | 7 | Accept UDP dst 51820 | WireGuard; the ENF drops UDP fragments by default, so leave the WG MTU at 1420 |
   | 19 | **Deny IPv4** | mandatory — an Accept-only set is a no-op |

   Port 22 is deliberate and safe: `publicHost.sshPort = 13491`, sshd listens on 13491 only, and the host's own default-deny drops 22 — so in normal operation the edge rule buys an attacker a `connection refused`. In rescue mode, where the rescue image's sshd *does* listen on 22 and the host firewall is not running, it is the difference between a chroot and an IP-KVM session. With Q20 on, rescue mode is a routine post-intervention step, not a once-a-decade emergency.

   Two ENF traps: rules are applied **automatically during DDoS mitigation even if the firewall is toggled off**, so a wrong set bites on an attack day; and the ENF is IPv4-only, which matches §4.2's v1 decision. **Write the rule set into `hosts/titan/README.md`**, because a rule the repo cannot see is the one that surprises future-you. Record the **Q20 = interventions ON** decision in the same place.
2. Panel: boot into **rescue mode**; `ssh root@<ip>`.
3. ~~Collect on-machine facts~~ **done 2026-10-01** (§3, §4.2, §7a): `eno1` on-link `/24`, 2× empty 450 GB Intel DC NVMe, UEFI, wear recorded. Re-check only if the hardware changed.
4. Fill in `vars.nix`, `disko.nix`, secrets (§10); `nix eval .#nixosConfigurations.titan.config.system.build.toplevel --show-trace`.
5. `make bootstrap HOST=titan IP=<rescue-ip> AGE_KEY=… DISK_PASSWORD=<throwaway>` — `bootstrap_host.sh` already runs `nixos-anywhere` with `--phases kexec,disko,install` (no reboot phase: OVH netboot is panel-controlled, so a reboot phase drops the box back into rescue). `DISK_PASSWORD` is required by the script but unused, since D9 removed the LUKS node.

   **Do not use `--build-on-remote` for the first build.** The script passes it, and it makes the *target* compile the closure — on a box with no Attic access (the mesh does not exist yet, D14) that means compiling everything against `cache.nixos.org` only, on OVH hardware, over the install SSH session. Build locally (or take the closure from the CI Attic leg) and let nixos-anywhere copy it.
6. Panel: switch netboot to **boot from hard disk**, reboot from the panel.
7. Verify: SSH on 13491, `wg0` present and listening on 51820 (empty until §11a flips peers onto it), `k3s` active, `kubectl get nodes`, `comin status --json`, health gate log shows `health gate OK`. Storage checks: `findmnt /var/lib/rancher/k3s/storage` shows the LV (not `/`), `lsblk` shows `md/titan` with both members `active`, `mdadm --detail /dev/md/titan` reports 2 active / 0 spare, and `systemctl show k3s -p Requires,After` lists the storage mount unit (§7a).
8. Only then publish DNS — a `terraform apply` in `../public-dns-tf` (§13a), not an OVH panel edit — and let cert-manager issue.

---

## 15. Verification plan

- **Backup restore drill (v1 exit criterion):** restore an etcd snapshot and a PV into a scratch cluster and confirm the workloads come back (§13b). Record the exact working commands in `hosts/titan/README.md`.
- `nix fmt` / `nixfmt .`
- `nix eval .#nixosConfigurations.titan.config.system.build.toplevel --show-trace`
- `nix flake check`
- CI leg green (build + Attic push).
- On-host assertions after bootstrap:
  - `ip route show default` shows the OVH gateway **on-link, with no `onlink` flag needed** — the primary IP is a /24 whose gateway lives inside the on-link `scope link` route (§4.2), so `staticNetwork.routeFlags` ships empty. Seeing `onlink` on a live `titan` would mean OVH re-assigned the box to a routed/failover shape, not that the config is correct.
  - `nmap`/`ss -lntp` from the box and from an external scanner: only 13491, 80, 443, 51820 reachable from the internet; 6443/9100/4243/10250 reachable **only** from `192.168.133.0/25` — and specifically **not** from a roadwarrior peer; 2379/2380 and 30000-32767 unreachable.
  - `sops -d` works on-host (age key present), k3s token file readable.
  - `nixos-rebuild switch` a second time and confirm the default route survives (the known fleet-wide route-drop failure mode).
  - `wg show` on `titan` after the mesh migration: every peer has a recent handshake; `ping` each peer's WG IP and one real service behind it.
  - WG forwarding survives a k3s restart: `systemctl restart k3s` then re-ping a peer through `titan`.
  - Deliberate bad-config drill on the canary: confirm the health gate rolls back and the box is still SSH-able.
- Document the external port scan output in the host `README.md`.

---

## 16. Open questions

| # | Question | Blocks | Who |
|---|---|---|---|
| ~~Q1~~ | **ANSWERED 2026-10-01: hostname = `titan`.** | — | — |
| ~~Q2~~ | **ANSWERED 2026-10-01: plain A + wildcard A records in the existing `arrieta.eu` zone, managed in `../public-dns-tf` (OVH Terraform provider).** WG endpoint and SSH hostname = `titan.arrieta.eu`. See §13a. | — | — |
| ~~Q3~~ | **ANSWERED 2026-10-01 from rescue mode:** E5-1650 v4 (6c/12t), 125 GiB RAM, 2× identical Intel SSDPE2MX450G7 450 GB NVMe (empty, SMART PASSED), UEFI, `eno1`, gateway on-link `/24`. Follow-ups: NVMe wear counters (§7) and `efibootmgr` after first install. | — | — |
| ~~Q4~~ | **ANSWERED 2026-10-01: unencrypted root (option 2).** LUKS + initrd SSH unlock deferred to its own PR — but it must be decided *before* `titan` takes state, since it cannot be retrofitted without a reinstall. | — | — |
| Q5 | **MOSTLY ANSWERED 2026-10-01; (c) CLOSED 2026-10-02:** hub config is `/etc/wireguard/wg0.conf` on the VPS; peer inventory captured in §11a. (c) **confirmed: the hub's own old address is `192.168.2.1`** — so the VPS is *not* `.5` in the old mesh, and `.5` is only its planned address as a client of the new hub. Still open: (d) does the current hub masquerade, or does the home router carry a return route for the mesh subnet? — **downgraded from a decision to a verification**, because `titan` ships `wireguard.forwardToLan = true`, which SNATs mesh→LAN and needs no home-router return route at all; Task 15 step 1 checks the live behaviour rather than gating on it. Prefix also confirmed: the old mesh is `192.168.2.0/24`, not the `/28` earlier drafts assumed — `.101`/`.102` could not have lived in a `/28`. | §11a step 6 verification, not a code decision | operator |
| ~~Q6~~ | **ANSWERED 2026-10-01: `main` + auto, "for now".** Revisit when `titan` holds workloads worth the manual gate; moving it to `stable` later also means the approve-script name fix becomes mandatory. | — | — |
| Q7 | **Largely resolved by D14:** `titan` is the hub, so it reaches `192.168.0.0/24` (and `nix-cache.l.arrieta.eu`) only once the mesh is flipped to it — which is *after* bootstrap. Confirm the `.l.` name resolves to a LAN-routable address from `titan` over WG. | `atticCache.url` per-host override, §14 build-on-remote note | operator / verify on host |
| ~~Q8~~ | **ANSWERED + CONFIRMED 2026-10-01: `--cluster-cidr=10.62.0.0/16 --service-cidr=10.63.0.0/16`.** | — | — |
| ~~Q9~~ | **ANSWERED 2026-10-01: full observability** — home Prometheus scrapes node_exporter, comin, and control-plane metrics over WG; rsyslog forwards to `192.168.0.41` over WG. | — | — |
| Q10 | Confirm nixos-26.05 `networking.firewall` backend (iptables vs nftables) before writing `extraCommands` | §4.5 | agent, during implementation |
| ~~Q11~~ | **ANSWERED 2026-10-01: renumber to `192.168.133.0/24` (D15).** | — | — |
| ~~Q12~~ | **CLOSED 2026-10-02: `192.168.133.0/24` confirmed free at home, at chiclana, and on the OVH host network.** Peers: `.101` = Pixel 7, `.102` = MacBook Air (roadwarriors). | — | — |
| ~~Q13~~ | **ANSWERED 2026-10-01: roadwarriors are mesh-only split tunnel.** | — | — |
| ~~Q14~~ | **ANSWERED 2026-10-01: yes, segregate.** Static peers `192.168.133.0/25`, roadwarriors `192.168.133.128/25`; control plane + exporters restricted to the /25. | — | — |
| ~~Q15~~ | **ANSWERED 2026-10-01: yes, and etcd snapshots are in v1 too** — k3s snapshot-to-S3 for the datastore + restic for the PVs, both to MinIO over WG (§13b). Restore drill is an exit criterion. | — | — |
| ~~Q16~~ | **ANSWERED 2026-10-01: new GitOps tree mirroring `k8s-techdelivery` (Flux + sops k8s Secrets).** | — | — |
| ~~Q17~~ | **ANSWERED 2026-10-01: disabled on `titan`.** `comin.nix` needs a `hermesSsh` opt-out (§9). | — | — |
| ~~Q18~~ | **ANSWERED 2026-10-01: lean** — `host-common` + `shell` only, same hostname gate as the Pis (§9). | — | — |
| ~~Q19~~ | **ANSWERED 2026-10-01, CORRECTED 2026-10-02**: yes, an off-box layer, but the rule set is the nine-rule ENF table in §14 step 1 — not "allow 13491/80/443/51820", which is an Accept-only set (a no-op) and drops titan's own outbound TCP and DNS. Record it in `hosts/titan/README.md`. | — | — |
| ~~Q20~~ | **ANSWERED 2026-10-02: interventions stay ENABLED.** Consequences, all recorded in §14 step 1: OVH monitoring is re-enabled after bootstrap (it is the trigger), the ENF must accept TCP dst 22 so rescue mode is reachable after a hardware intervention, WG MTU stays at 1420 because the ENF drops UDP fragments, and every intervention needs a post-boot check (boot mode back to disk, `mdadm` rebuilt, WG peers reconnected, etcd healthy). Residual accepted risk: an unannounced reboot is a full outage of a single-node cluster, mitigated by the health gate + rollback entry, not by redundancy. | — | — |

---

## 17. Risks

| Risk | Mitigation |
|---|---|
| Fleet modules assume a trusted LAN; re-enabling the firewall could break k3s/ServiceLB in a way the LAN hosts never show | `mkDefault` flip keeps other hosts byte-identical; canary ring; explicit port scan in §15 |
| Route self-heal silently breaks if OVH re-addresses the box to a routed/failover shape (the fleet's known route-drop failure mode) | `routeFlags` exists in both `static-network.nix` and the health gate so the fix is one option value; §15 tells the operator what a live `onlink` would mean |
| LUKS with no remote unlock = unrecoverable without a visit | D9 forces the choice before install; rescue-mode + KVM recorded as inputs, not discovered under pressure |
| Attic unreachable → every deploy compiles from source on a small box | Q7 answered before bootstrap |
| Wildcard DNS + DNS-01 creds are a juicy target | OVH API token scoped to DNS write on `arrieta.eu` only, kept in the k8s SOPS file, never in this repo |
| Single node = no HA; a bad deploy is a full outage of whatever it hosts | canary ring + health gate + rollback entry + panel IP firewall |
| `*.titan.arrieta.eu` wildcard means any compromised workload can mint certs for any subdomain | accepted; revisit if the workload set grows past "mostly self-hosted" |
| Unencrypted root on rented hardware: a disk pull plus this repo = full secret access (the age key lives in `/var/lib/sops-nix/key.txt`) | accepted knowingly (D9); deferred LUKS PR is the remediation, and it must land before `titan` holds anything that would hurt to lose |
| **The IP is already public and already being scanned.** A datacenter IPv4 sees SSH probes within minutes of boot, so "harden it later" is not a sequence that exists | the first deployed config must already carry `PasswordAuthentication = false`, key-only auth, and the default-deny `public-host` firewall — no permissive first boot |
| **Hub migration takes down the mesh if done wrong** — backup path, Prometheus scrapes, and VPS↔LAN paths all ride it | §11a: two hubs coexist, flip one peer at a time, same addressing (D15), old hub retired last |
| `titan` now co-hosts the hub and the workloads: a `titan` outage kills the whole mesh, not just its own services | accepted (the VPS hub was already a single point); note it in monitoring so a `titan` deploy is understood as a mesh-wide event |
| WG forwarding on the same box as k3s — kube-proxy owns FORWARD/nat | `forward = true` in `wireguard.nix`, verified after a k3s restart (§15) |
