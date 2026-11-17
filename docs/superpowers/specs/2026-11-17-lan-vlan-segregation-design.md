# LAN Segregation via VLANs

- **Status:** draft for review
- **Date:** 2026-11-17
- **Scope:** OPNsense, two managed switches, Omada wireless, and (in later phases) the
  NixOS fleet's addressing.
- **Owner repos:** this repo (`nixos-configurations`) for the fleet side; `k8s-casa` for
  cluster-side scrape lists and app DNS. OPNsense and Omada config is manual today and
  has no repo — see [Config as code](#12-config-as-code-an-open-gap).

## Confidence markers

Every non-trivial claim below is tagged. Nothing tagged `[unverified]` should be acted on
before Phase 0 resolves it.

| Marker | Meaning |
|---|---|
| `[measured]` | Read out of this repository at flake lock `0f59e3f`, or from the devices themselves. |
| `[vendor-doc]` | TP-Link / Omada official documentation. |
| `[community]` | TP-Link community forum or Reddit report. Directional, not proof. |
| `[unverified]` | Believed but not checked. Phase 0 must confirm it. |

## 1. Goal

Move the IoT and Guest wireless networks from *apparent* isolation to a real L2/L3
boundary enforced by 802.1Q VLANs terminated on OPNsense, without disrupting the k3s
cluster, Home Assistant, or Longhorn storage.

Long term, also move the trusted LAN off `192.168.0.0/24`, because that range collides
with the default LAN pools of consumer routers — which is a live problem for WireGuard
roadwarriors, who get `192.168.0.0/24` injected as a route into the tunnel and lose
their own local network. `[measured]` — `wireguard.lanSubnet` defaults to
`192.168.0.0/24` and `hosts/titan/configuration.nix` sets `forwardToLan = true`.

**Success criteria**

1. An IoT device on the IoT SSID cannot reach any host on the trusted LAN, and cannot
   initiate any connection to the LAN at all.
2. Home Assistant controls every IoT device it controls today, with no regression.
3. A guest on the Guest SSID has internet and nothing else — no LAN, no IoT, no
   cluster, no mesh.
4. No NixOS host changes IP in Phase 1. The cluster stays up through every Phase 1 step.
5. Every boundary is *tested from a client*, not inferred from a config screen.

## 2. Non-goals

- **Cluster-internal segmentation.** etcd, kubelet, flannel VXLAN and Longhorn need
  unrestricted node-to-node traffic. Fencing the cluster from itself is a permanent
  maintenance tax for a threat this homelab does not have. Explicitly rejected.
- **A dedicated management VLAN for switches and APs.** See
  [Landmine: the management VLAN breaks mesh](#landmine-the-management-vlan-breaks-mesh).
  Rejected on evidence.
- **mDNS/SSDP reflection.** Not needed today. Documented as an additive seam in
  [Deferred seams](#13-deferred-seams) — it can be turned on later without touching a
  single VLAN assignment.
- **Guest captive portal, bandwidth shaping, per-client quotas.** YAGNI.
- **IPv6 on IoT and Guest.** Out of scope and actively undesirable; see
  [IPv6 policy](#ipv6-policy).

## 3. Current state

### 3.1 Physical

```
LIVING ROOM                                    OFFICE
OPNsense (4 NICs: WAN, LAN, 2 free)            rack switch (model unknown)
  ├─ WAN                                       ├─ k8s-server01/02/03   .11 .12 .13
  └─ LAN ── 8-port managed switch ──┐          ├─ k8s-node01..04, k8s-pi01..03
              EAP225 (wired)        └─────────├─ TrueNAS / MinIO        .6 [unverified]
                                    [inter-room cable]                 ├─ Home Assistant   IP unknown
                                                                       ├─ desktops (mac/win/linux)
                                                                       └─ EAP610 (wired)

  kitchen EAP225 ─┐
  entrance EAP225 ┴── wireless mesh off a wired parent   ← cannot be relied on for VLANs
  garage EAP225 ──── CEP wireless bridge                 ← cannot be relied on for VLANs
```

### 3.2 Logical `[measured]`

- Flat `192.168.0.0/24`, gateway `192.168.0.1`, prefix length 24.
- Static per-host addresses delivered from the SOPS secret
  `secrets.yaml#<host>/network_env` at activation; `vars.nix` holds `$IP_ADDRESS`
  placeholders that Nix ignores. Since nixpkgs 26.05 the module parses addresses at
  eval time, so the runtime layer is the only place real values can appear.
- k3s control plane endpoint is a **bare IP**, `https://192.168.0.11:6443`, hardcoded in
  every agent's `vars.nix`. There is no VIP.
- `networking.firewall.enable` is `mkDefault false` on k3s hosts, so nothing on the LAN
  is fenced from the control plane. `hosts/k8s-server01/vars.nix` documents that etcd's
  `2381/metrics` is bound to `0.0.0.0` and is **unauthenticated**.
- WireGuard mesh `192.168.133.0/24`, hub on `titan`, with `forwardToLan` SNAT-ing mesh
  traffic into `192.168.0.0/24`.
- `192.168.0.41` is `DNS2`, the rsyslog target, and answers `l.arrieta.eu`.
- `192.168.0.6` is the out-of-cluster MinIO (`:9000`) and the iSCSI portal (`:3260`)
  used by the coder helper.
- `192.168.0.29` is `llm01`, referenced from `modules/nixos/ssh.nix`,
  `coderHost.allowedApiSources`, and the titan coder workspace's `pi.baseUrl`.
- Longhorn uses iSCSI to TrueNAS over this LAN. The comin health gate runs an `iscsi`
  check on every deploy and **rolls the host back** if it breaks.

### 3.3 What is not known

Produced in Phase 0, not assumed here: the two switch models and their 802.1Q support,
Home Assistant's IP, the Zigbee coordinator's model and socket mode, an authoritative
map of every static IP on the LAN (including the non-NixOS ones), and what actually
enforces the current IoT/Guest boundary.

## 4. Two findings that shaped the design

### Finding A — the current boundary is probably not a boundary `[community]`

Omada's guest-network / client-isolation feature blocks traffic between clients **on the
same AP only**. It is not a router and it does nothing by itself toward the wired LAN.
Multiple TP-Link community reports describe an "isolated" SSID reaching the LAN, and
describe needing switch-level rules or EAP ACLs to get real isolation, with IPv6 being
the part that resists ACLs entirely.

Consequence: Phase 0 begins by *proving* what enforces the boundary today. If it is an
OPNsense rule on a routed WLAN interface, a real boundary already exists and the VLAN
work is about making it per-segment and permanent. If it is the Omada checkbox, there is
no boundary and this project is closing a hole, not tidying one.

### Finding B — VLANs must not depend on a wireless mesh backhaul

`[vendor-doc]` TP-Link support states that mesh EAP units inherit the VLAN settings of
their uplink AP. `[community]` The same forums report that **adopting an EAP in mesh
mode fails outright when a management VLAN is used on the wired parent**, and there is no
solid public evidence that arbitrary 802.1Q tags survive a wireless mesh backhaul.

Consequence, and this is the single most dangerous item in the whole project:

> **An SSID configured with a VLAN on an AP that cannot tag that VLAN may fall back to
> untagged — which means it lands on the native VLAN, which is the trusted LAN. The
> failure mode of a half-working VLAN is not "no network"; it is "your IoT devices are
> quietly back on the LAN".**

Therefore: IoT and Guest VLANs exist only on the two **wired** APs (living-room EAP225,
office EAP610). The IoT and Guest SSIDs are **disabled** on the kitchen, entrance, and
garage APs until each is individually tested. Acceptance criterion 5 exists because of
this.

## 5. Approaches considered

| # | Approach | Verdict |
|---|---|---|
| A | Two tagged islands (IoT, Guest); trusted LAN stays untagged native `192.168.0.0/24`. | **Adopted as Phase 1.** Delivers the stated goal, touches zero NixOS hosts, rules written once. |
| B | Full tagged redesign: servers, storage, users, mgmt each on their own VLAN; native VLAN unused. | Deferred to Phase 2/3, and reduced — see B-lite. Full B requires re-IPing the fleet, which is an etcd and k3s certificate event. |
| B-lite | A, then move only the **desktops** to their own VLAN; servers and NAS stay put. | **Adopted as Phase 2.** Cheap, and it is the half of "contain a breach" that protects the operator's machines from a cluster compromise. |
| C | Guest VLAN only, IoT deferred. | Folded into Phase 1a/1b staging rather than chosen as an endpoint. |
| D | No VLANs; filter with OPNsense on the flat LAN. | **Rejected on physics.** Two hosts on the same switch never traverse the router, so intra-LAN traffic cannot be filtered without a VLAN boundary. |
| E | Re-address the LAN off `192.168.0.0/24` first, then add VLANs. | Rejected as an *order*. The re-address is the expensive, cluster-risky step; doing it first means the cluster risk lands before any security benefit. Doing it last means Phase 1 delivers value before any risk is taken. |

**Why A then B rather than B directly.** A is not a detour from B, provided three
forward-compatibility rules hold:

1. **Reserve the final VLAN IDs and subnets now**, including the unused ones. Retiring a
   VLAN ID is cheap; renaming one across OPNsense, Omada, two switches and every host is
   not.
2. **Tag every VLAN on the inter-room trunk from day one.** One cable, all VLANs, always.
   Otherwise Phase 2 begins with a dead VLAN 30 in the office and the cause is a config
   someone forgot in another room.
3. **Buy the office switch with B in mind**: 802.1Q, port count with headroom, PoE budget
   sufficient for the EAP610. This is the only hardware the project needs.

## 6. VLAN and addressing plan

The final scheme is chosen now so no segment is migrated twice. New segments get their
final addresses in Phase 1 even though the legacy LAN keeps its old range until Phase 3.

| VLAN | Name | Subnet | Phase | Notes |
|---|---|---|---|---|
| 1 | native / legacy LAN | `192.168.0.0/24` | 1 unchanged | Untagged everywhere today. Servers, HA, TrueNAS, desktops, AP management. Retired in Phase 3. |
| 10 | iot | `10.60.10.0/24` | 1b | Wireless only, EAP225 + EAP610. |
| 20 | guest | `10.60.20.0/24` | 1a | Wireless only. No inbound hole, ever. |
| 30 | servers | `10.60.30.0/24` | 3 reserved | Only if the control plane moves. |
| 40 | storage | `10.60.40.0/24` | 3 reserved | Only if iSCSI is deliberately routed. Not recommended. |
| 50 | users | `10.60.50.0/24` | 2 | Desktops. |
| 99 | mgmt | — | never | Deliberately unused. See the mesh landmine. |

**Why `10.60.0.0/16`.** Chosen to avoid every range this fleet already owns:
`10.42.0.0/16` and `10.43.0.0/16` (k3s pods and services), `172.17.0.0/16` plus the
`172.16/12` Docker compose pools, `192.168.133.0/24` (WireGuard mesh), and the common
consumer-router defaults `192.168.0/24`, `192.168.1/24`, `10.0.0/24`, `10.10/16`.
`10.8/10.9` are avoided as classic OpenVPN defaults. Any `/16` under `10/8` that clears
that list works; the choice is recorded so it is a decision, not an accident.

**Why IoT and Guest take their final addresses in Phase 1.** They are never advertised
into the WireGuard tunnel, so their addresses cannot collide with a roadwarrior's local
LAN — the collision argument applies only to networks the tunnel advertises. Giving them
final addresses now means Phase 3 migrates one thing (the legacy LAN) instead of three.
The cost is two addressing schemes coexisting for a while, which is a cosmetic cost in
OPNsense and nothing else.

## 7. Design

### 7.1 Layer 2

- OPNsense `LAN` NIC → 8-port switch port 1, **trunk**, tagged `{10, 20, 30, 40, 50}`,
  untagged/native 1.
- 8-port switch → inter-room cable → rack switch, **trunk**, same tag set. Tagged from
  day one even though 30/40/50 carry nothing yet.
- EAP225 (living room) and EAP610 (office): **trunk**, same tag set.
- Rack switch server and desktop ports: untagged/native 1. In Phase 2 the desktop ports
  become untagged 50.
- Kitchen, entrance, garage APs: unchanged, native 1 only.

If the rack switch turns out to be unmanaged, the office gets no tagged VLANs and the
EAP610 cannot carry IoT or Guest. That is a hardware purchase, not a redesign.

### 7.2 Layer 3 — OPNsense

- Interfaces → Assignments → VLANs: VLAN 10 and 20 on the LAN NIC.
- Assign each as an interface, `opt10` → `IOT`, `opt20` → `GUEST`, with the addresses
  from the table, `/24`.
- Enable DHCPv4 on both. Small pools, wireless-only: `.100`–`.200` on each range, with
  static reservations (the Zigbee coordinator above all) allocated below `.100` so a
  reservation can never be handed out dynamically.
- Serve DNS from OPNsense on both. **Do not** allow IoT or Guest to reach `192.168.0.41`
  for DNS — that would open a path to the registry and logging host for no benefit.
- Replace OPNsense's default per-interface "pass all" with the explicit ruleset below.

### 7.3 Firewall ruleset

Aliases first, so the rules read as intent:

| Alias | Value | Source |
|---|---|---|
| `LAN_NET` | `192.168.0.0/24` | `[measured]` |
| `MESH_NET` | `192.168.133.0/24` | `[measured]` |
| `RFC1918` | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | |
| `HA_SERVER` | *Phase 0* | unknown today |
| `ZIGBEE_COORD` | DHCP reservation in `10.60.10.0/24` | Phase 0 |

**Interface `GUEST` (VLAN 20), evaluated top to bottom:**

| # | Src | Dst | Action | Why |
|---|---|---|---|---|
| 1 | GUEST | firewall | allow DNS, DHCP | clients need name and address |
| 2 | GUEST | `RFC1918` | **block + log** | one rule kills LAN, IoT, mesh, and every future private range |
| 3 | GUEST | any | allow | internet |
| 4 | any | GUEST | block | no inbound, ever |

Rule 2 is deliberately `RFC1918` rather than `LAN_NET`. It cannot go stale when Phase 2
and 3 create new ranges, which is exactly when a narrower rule would be forgotten.

**Interface `IOT` (VLAN 10):**

| # | Src | Dst | Action | Why |
|---|---|---|---|---|
| 1 | IOT | firewall | allow DNS, DHCP | |
| 2 | IOT | `LAN_NET` | **block + log** | the boundary |
| 3 | IOT | `MESH_NET` | block | no path into the tunnel |
| 4 | IOT | `GUEST_NET` | block | |
| 5 | `ZIGBEE_COORD` | `HA_SERVER:<z2m port>` | allow | **only if** Phase 0.4 finds the coordinator is a TCP client; see note |
| 6 | IOT | any | allow | vendor cloud, OTA |
| 7 | `HA_SERVER` | IOT | allow | the one trusted initiator into IoT |
| 8 | any | IOT | **block + log** | nothing else may initiate into IoT |

Rules 7 and 8 are the design's spine, and the order is load-bearing: the allow from
`HA_SERVER` must be evaluated before the block. The firewall is stateful, so "HA may initiate into IoT"
automatically admits the replies, while IoT can never start a connection to HA or
anything else on the LAN. Home Assistant keeps working and an owned bulb still cannot
phone home or scan the rack.

Rule 5 exists only in the fallback case, and it is narrower than rule 7 in both
directions: one source address, one destination, one port. Because zigbee2mqtt and the MQTT broker are both
Home Assistant add-ons, MQTT traffic stays on HA's docker bridge and **never crosses the
VLAN** — the only cross-boundary flow in the Zigbee chain is z2m to the coordinator
socket. If the coordinator listens (TCP server) and z2m dials out via
`serial.port: socket://<ip>:<port>`, HA initiates and rule 5 is not needed at all. If
the coordinator is a TCP client, it needs `IOT:ZIGBEE_COORD → HA_SERVER:<z2m port>` and
nothing wider. Phase 0 decides this with a `sockstat`/`ss` check on HA while z2m is
running: a listening socket on the z2m port means HA dials out.

**Intra-VLAN traffic is not covered by any of this.** Two guests on different APs sit in
the same broadcast domain and switch frames to each other without touching OPNsense.
Omada's isolation is per-AP `[community]`, so guest-to-guest isolation across APs would
need switch-level private-VLAN or ACL work. **Accepted risk** for a homelab guest
network, recorded here rather than left as a surprise.

### 7.4 IPv6 policy

Do not delegate an IPv6 prefix to IoT or Guest. `[community]` reports describe guest
isolation being defeated by SLAAC and router advertisements, with the workaround being to
disable IPv6 for guests or to rewrite ACLs every time an ISP changes a prefix. With no
IPv6 on those VLANs there is nothing to get wrong. The trusted LAN's IPv6 behaviour is
unchanged and out of scope.

### 7.5 Omada wireless

| SSID | VLAN | APs enabled | Notes |
|---|---|---|---|
| existing trusted | 1 (untagged) | all | unchanged |
| `home-iot` | 10 tagged | EAP225 living room, EAP610 office only | **disabled** on kitchen, entrance, garage |
| `home-guest` | 20 tagged | EAP225 living room, EAP610 office only | same |

WPA2/WPA3-PSK, per-SSID passphrase. Keep the existing SSIDs and passphrases for the
trusted network so no client has to be reconfigured.

### 7.6 Break-glass

Misapplied VLAN or firewall config can lock the operator out of OPNsense itself, and the
OPNsense web UI is on the interface being edited. Before any Phase 1 change:

- Confirm console access to OPNsense (monitor and keyboard, or serial) actually works.
  Not "should work" — confirmed.
- Export the OPNsense config (`Diagnostics: Backup & Restore`) and keep the XML.
- Never remove the untagged native-1 membership from the LAN trunk port. That is the
  path back in.
- Change one thing at a time, with the console session open in the background.

## 8. Phases

Each phase is independently valuable and independently reversible.

### Phase 0 — inventory and proof (no changes to anything)

| # | Item | Resolves |
|---|---|---|
| 0.1 | Model and 802.1Q support of the 8-port switch; whether all ports trunk. | Finding B, §7.1 |
| 0.2 | Model of the rack switch; managed or unmanaged; PoE budget. | the only hardware purchase |
| 0.3 | Home Assistant IP and how it addresses IoT devices today (IP vs mDNS name). | `HA_SERVER`, and whether "no mDNS" is actually true today |
| 0.4 | Zigbee coordinator model, firmware, and socket direction (`ss -ltnp` on HA while z2m runs). | firewall rule 5 |
| 0.5 | Authoritative map of every static IP on `192.168.0.0/24`, including non-NixOS hosts: TrueNAS/MinIO `.6`, DNS/registry `.41`, HA, printers, the Omada controller. | Phase 3 blast radius |
| 0.6 | **Prove the current boundary.** From a client on each of IoT and Guest: reach `192.168.0.1`, `HA:8123`, `192.168.0.6:9000`, a node's `9100`, and `1.1.1.1`. Record what answers. | Finding A |
| 0.7 | Confirm OPNsense console access and export config. | §7.6 |
| 0.8 | Confirm where the Omada controller runs (hardware, software, cloud). | rollback mechanics |

0.6 is the one that decides whether this project is a hardening or a fix, and it costs
ten minutes.

### Phase 1a — Guest VLAN

Guest first, deliberately: nothing on it needs to be reachable, so a wrong rule produces
"guest phone has no internet" — trivially visible, trivially reversible — while
exercising the entire path: trunk, VLAN, DHCP, DNS, firewall.

1. Create VLAN 20, interface, address, DHCP, DNS on OPNsense.
2. Add the GUEST ruleset before the SSID exists, so there is never an unfiltered window.
3. Tag VLAN 20 on the inter-room trunk, both ends.
4. Create the `home-guest` SSID on the two wired APs, VLAN 20. Leave it disabled on the
   mesh and garage APs.
5. **Test from a client at each AP's location**: gets `10.60.20.x`, reaches internet,
   cannot reach `192.168.0.1`, HA, `.6`, or any node.
6. Only then disable the old guest SSID.

**Rollback:** disable the new SSID, re-enable the old one. Nothing on the trusted LAN
moved, so nothing else can break.

### Phase 1b — IoT VLAN

1. Reserve the coordinator's address in the VLAN 10 DHCP scope. No mDNS means HA
   addresses IoT devices by IP, and a random lease means a router reboot silently
   breaks Zigbee. This is a requirement, not a nicety.
2. Create VLAN 10, interface, DHCP, DNS.
3. Add the IOT ruleset, including rule 5 only if Phase 0.4 requires it.
4. Tag VLAN 10 on the trunks.
5. Point z2m's `serial.port` at the reserved coordinator address.
6. Create `home-iot` on the two wired APs, VLAN 10.
7. Move IoT devices over in batches, verifying HA control after each batch.
8. Test from a client: gets `10.60.10.x`, HA controls its devices, and an IoT client
   cannot reach `192.168.0.1`, HA, `.6`, or any node.

**Rollback:** move devices back to the old SSID. z2m's `serial.port` is one field.

### Phase 2 — B-lite: desktops to VLAN 50

Cheap, and it is the half of breach containment that protects the operator's machines
from a cluster compromise. Nothing in this repo changes — the desktops are not managed
here. Requires the rack switch to be managed.

Add to the ruleset: `users → LAN_NET` allow only what is needed (SSH to nodes, the
cluster API), and `LAN_NET → users` block inbound. Note this also changes what a
roadwarrior on the mesh sees, since the mesh advertises `LAN_NET` only.

**Rollback:** set the desktop ports back to untagged 1.

### Phase 3 — move off `192.168.0.0/24`

This is the expensive one and it is a **cluster event**, not a network change. It is
listed with its real cost so it can be scheduled knowingly rather than discovered.

What must change together, `[measured]` from this repo:

| Item | Where |
|---|---|
| Per-host address, gateway, DNS | `secrets.yaml#<host>/network_env`, all 13 hosts |
| k3s API endpoint | `k3s.serverAddr` hardcoded as `https://192.168.0.11:6443` in every agent `vars.nix` |
| etcd member peer and client URLs | live etcd cluster — members are IP-pinned |
| k3s serving certificate SANs | include the node IP and API endpoint `[unverified]` — confirm against the running k3s version before planning around it |
| MinIO and iSCSI portal | `common/etcd-snapshot-s3.nix`, `modules/nixos/coder-host.nix` (`192.168.0.6`) |
| `l.arrieta.eu` split-horizon record | `modules/nixos/mesh-dns.nix` (`192.168.0.41`) |
| rsyslog target | `modules/nixos/rsyslog.nix` default (`192.168.0.41`) |
| llm01 references | `modules/nixos/ssh.nix`, `hosts/llm01/configuration.nix` `allowedApiSources`, `home/hosts/coder-workspace-titan` |
| Mesh LAN CIDR | `wireguard.lanSubnet`, `wireguard.forwardToLan` SNAT, `modules/nixos/public-host.nix` LAN allow-list, `hosts/titan/configuration.nix` |
| Cluster side | `k8s-casa` Prometheus static scrape list, app DNS, anything with a hardcoded node IP |
| Rollout | `scripts/comin-approve.sh` bind zone `casa.arrieta` resolution |

Two ways to do it, and the choice should be made with the etcd risk in view:

- **Live migration.** One control-plane member at a time, `etcdctl member update` to move
  each peer URL, etcd snapshot to MinIO first, control plane before workers per the skew
  rule already in `AGENTS.md`. Preserves everything, and a mistake takes the cluster down
  mid-flight.
- **Rebuild on the new range.** Bring up a fresh cluster with the new addressing and
  restore from what already exists: etcd snapshots off-node to MinIO (already
  automated), Longhorn backups, and Flux for the apps. Often *less* risky than a live
  etcd IP migration of a 3-node cluster, at the cost of a real outage window and the
  work of validating restores.

`[unverified]` which of these is cheaper here depends on the restore path actually being
tested. Phase 3 should not be scheduled until an etcd snapshot and a Longhorn backup have
both been restored successfully at least once.

**Recommended Phase 3 scope:** servers to VLAN 30, desktops already on 50, NAS left on
the flat segment it is on. Routing Longhorn's iSCSI across a router removes jumbo frames
and adds latency, and the comin health gate's `iscsi` check will roll a host back if that
degrades — so VLAN 40 stays reserved and unused unless there is a specific reason.

### 8.1 Phase 3 gets its own spec

Phases 0 through 2 are one implementation plan. Phase 3 is a cluster migration with a
restore-validation prerequisite and two viable strategies that have not been costed
against each other. It should be written up as its own spec, after Phase 0.5 has produced
the authoritative IP map and after a restore has actually been tested. Do not fold it
into the Phase 1 plan.

## 9. Landmines

**The management VLAN breaks mesh.** `[community]` Adopting an EAP in mesh mode fails
when a management VLAN is used on the wired parent AP. The kitchen and entrance APs are
mesh children of the wired ones, so the textbook "dedicated management VLAN" step would
break roaming in two rooms. Rejected from the plan on that evidence. If it is ever
revisited, it needs a bench test with one mesh child first.

**A half-working VLAN fails open.** Restating Finding B because it is the one that bites:
an AP that cannot tag a VLAN may emit those frames untagged, onto the native VLAN, which
is the trusted LAN. Every phase therefore ends with a client-side test at each AP
location, not a screenshot of a config page.

**Tagging the trunk is a brief outage on the inter-room link.** On some switches,
changing the native VLAN or the tag set on a live trunk drops everything crossing it,
including the path to the rack. Schedule it; do not do it while a deploy is running or
while comin is mid-switch on a fleet host.

**OPNsense's default per-interface allow-all.** Until the explicit ruleset replaces it, a
new interface passes everything. Create the rules before the SSID.

**DHCP scope exhaustion or overlap** on the new ranges is invisible until a client fails
to get a lease. Wireless-only scopes can be small and static reservations should live
outside the dynamic pool.

**The Zigbee coordinator's socket direction is a guess until measured.** If it turns out
to be a TCP client and rule 5 is omitted, Zigbee silently fails to come up after the
move. Phase 0.4 exists for this.

## 10. Testing and acceptance

| Test | Phase | Pass condition |
|---|---|---|
| Boundary from IoT client, at each enabled AP | 1b | `10.60.10.x` lease; `192.168.0.1`, `HA:8123`, `.6:9000`, node `9100` all unreachable; internet up |
| Boundary from Guest client, at each enabled AP | 1a | `10.60.20.x` lease; all RFC1918 unreachable; internet up |
| No silent fallback on mesh/garage APs | 1a, 1b | IoT and Guest SSIDs not broadcast there, or proven tagged |
| Zigbee | 1b | z2m connected, devices responsive from HA, no reconnect loop in the z2m log |
| Cluster untouched | 1a, 1b | `kubectl get nodes` all Ready before and after; no comin rollback in `/var/log/comin-health-gate.log` |
| Mesh unaffected | 1a, 1b | roadwarrior reaches `192.168.0.11:6443` and the rack as before, and gains no route to `10.60.10.0/24` or `10.60.20.0/24` |
| Fleet rollout path | 1a, 1b | `scripts/comin-approve.sh` still resolves and reaches every host |

## 11. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Rack switch is unmanaged | medium | office gets no VLANs | Phase 0.2; hardware purchase, not redesign |
| VLAN falls back to native on an AP | medium | boundary silently absent | client-side test per AP; SSIDs disabled on mesh |
| Coordinator needs an inbound hole | low | Zigbee down | Phase 0.4 measures it; rule 5 is narrow and IP-pinned |
| Trunk change drops the inter-room link during a deploy | low | fleet host mid-switch | schedule the change; check no comin deploy is running |
| Phase 3 etcd IP migration goes wrong | medium | cluster down | rebuild alternative; restore tested before scheduling |
| Guest intra-VLAN traffic | certain | guests can reach each other | accepted and documented, not hidden |

## 12. Config as code — an open gap

OPNsense and Omada configuration lives only in those devices. Everything else in this
fleet is declarative and rolled out by comin, so this spec's network boundary is the one
part with no diff, no review, and no rollback other than a restored XML export.

Not in scope to fix here, but the options worth a decision later: OPNsense has
REST/`configd` APIs and a well-trodden `ansible`/terraform-provider path; Omada has a
controller API. A minimal version — the VLAN table, the interface definitions, and the
firewall ruleset rendered from a Nix module and diffed against the live device — would
make Phase 2 and 3 far safer than hand-editing a firewall while the cluster depends on
it.

## 13. Deferred seams

Deliberately excluded, each additive, none requiring a VLAN change to add later:

- **mDNS/SSDP reflection.** An Avahi reflector on OPNsense, scoped to specific VLAN
  pairs. Add it when a device needs it; nothing about the VLAN plan changes.
- **Cluster control-plane inbound allow-list.** Today the control plane is reachable from
  anywhere on the LAN because the firewall is off on k3s hosts by design, and etcd's
  `2381/metrics` is unauthenticated on `0.0.0.0`. A one-way rule — only the rack and the
  mesh may reach `6443`, `10250`, `2379`, `2380`, `2381` — costs nothing to maintain
  because it never needs editing for new workloads. This is the cheap half of the
  containment goal and it is independent of every phase here.
- **Kitchen and entrance VLAN coverage.** Needs a cable, not more mesh.
- **Guest intra-VLAN isolation.** Needs switch private-VLAN or ACL support.
- **IPv6 on IoT and Guest.** Only with a plan for RA-based SLAAC and prefix changes.

## 14. Out of scope

Cluster-internal segmentation, captive portal, bandwidth control, IDS/IPS, replacing the
Omada controller, and any change to `titan` beyond the `wireguard.lanSubnet` value in
Phase 3.
