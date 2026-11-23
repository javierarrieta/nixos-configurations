# LAN Segregation via VLANs

- **Status:** draft for review
- **Date:** 2026-11-17
- **Scope:** OPNsense, two switches (management capability **unconfirmed** — see
  Phase 0.1/0.2), Omada wireless, and (in later phases) the
  NixOS fleet's addressing.
- **Owner repos:** this repo (`nixos-configurations`) for the fleet side; `k8s-casa` for
  cluster-side scrape lists and app DNS. OPNsense and Omada config is manual today and
  has no repo — see [Config as code](#12-config-as-code--an-open-gap).

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
   initiate a connection to any trusted-LAN host — except the single documented Zigbee
   flow, and only if Phase 0.4 measures that flow as coordinator-initiated. It **can**
   still reach the public internet (see §7.3, rule 4); that is deliberate.
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
  [Landmine: the management VLAN breaks mesh](#91-the-management-vlan-breaks-mesh).
  Rejected on evidence.
- **mDNS/SSDP reflection.** Not needed today. Documented as an additive seam in
  [Deferred seams](#13-deferred-seams) — it can be turned on later without touching a
  single VLAN assignment.
- **Guest captive portal, bandwidth shaping, per-client quotas.** YAGNI.
- **IPv6 on IoT and Guest.** Out of scope and actively undesirable; see
  [IPv6 policy](#74-ipv6-policy).

## 3. Current state

### 3.1 Physical

```
LIVING ROOM                                    OFFICE
OPNsense (4 NICs: WAN, LAN, 2 free)            rack switch (model unknown)
  ├─ WAN                                       ├─ k8s-server01/02/03   .11 .12 .13
  └─ LAN ── 8-port switch (managed?) ──┐          ├─ k8s-node01..04, k8s-pi01..03
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
- Static per-host addresses arrive by **three different mechanisms**, and an
  implementer who assumes one will silently miss four hosts. Verified per host against
  `hosts/*/vars.nix` and `secrets.yaml`:

  | mechanism | hosts |
  |---|---|
  | `$IP_ADDRESS` placeholder resolved from `secrets.yaml#<host>/network_env` at activation | `k8s-server01/02/03`, `k8s-node01/02/03`, `k8s-node05` — **seven** |
  | `$IP_ADDRESS` resolved from **`secrets/titan.yaml`**, not `secrets.yaml` | `titan` |
  | **build-time literal** in `vars.nix` — no SOPS layer at all | `k8s-node04` (`192.168.0.17`), `k8s-pi01/02/03` (`.21/.22/.23`) |
  | NetworkManager-managed, no `vars.nix` address | `llm01` |

  `modules/nixos/static-network.nix:8-12` is what makes the literals bypass SOPS:
  `useRuntimeConfig` is true only when the address, gateway or a nameserver starts with
  `$`. Note the trap on `k8s-node04`: a `k8s-node04/network_env` key **does** exist in
  `secrets.yaml`, and editing it changes nothing, because `vars.nix` hands the module a
  literal. Since nixpkgs 26.05 the module parses addresses at eval time, so the runtime
  layer is the only place real values can appear — for the hosts that use it.
- k3s control plane endpoint is a **bare IP**, hardcoded in every agent's `vars.nix`, and
  there is no VIP — but it is **not one literal**. `k8s-server01` and `k8s-server03` use
  `https://192.168.0.12:6443`; `k8s-server02` and all eight agents use
  `https://192.168.0.11:6443`. Grepping for `.11` therefore leaves two control-plane
  members pointing at the old range.
- `networking.firewall.enable` is `mkDefault false` on k3s hosts, so nothing on the LAN
  is fenced from the control plane. Two different etcd/control-plane metrics binds are
  easy to conflate, and conflating them overstates the exposure:
  - **`2381/metrics` (etcd)** is published on the **node address** by
    `--etcd-expose-metrics` in addition to loopback, and is **unauthenticated**. It is
    reachable from the LAN only because the host firewall is off — it is not bound to
    `0.0.0.0`.
  - **`10257`/`10259`** (scheduler, controller-manager) are the `0.0.0.0` bind, via
    `controlPlaneMetricsBindAddress`, and those **are** authenticated.

    See `hosts/k8s-server01/vars.nix:32-40`, which says this in words. The repo already
    contains the purpose-built answer to the etcd case — `modules/nixos/etcd-metrics-proxy.nix`,
    which refuses a wildcard bind and forwards to loopback — in use on `titan`.
- WireGuard mesh `192.168.133.0/24`, hub on `titan`, with `forwardToLan` SNAT-ing mesh
  traffic into `192.168.0.0/24`.
- `192.168.0.41` is `DNS2`, the rsyslog target, and answers `l.arrieta.eu`.
- `192.168.0.6` is the out-of-cluster MinIO (`:9000`) and the iSCSI portal (`:3260`)
  used by the coder helper.
- `192.168.0.29` is `llm01`, referenced from `coderHost.allowedApiSources`,
  `home/hosts/coder-workspace-titan/userOptions.nix`, and the titan coder workspace's
  `pi.baseUrl`. `modules/nixos/ssh.nix` mentions it only as an `example`, so it is not a
  live site despite matching a grep.
- Longhorn uses iSCSI to TrueNAS over this LAN. **There is no automated safety net for
  that path**, which matters because §8 recommends a VLAN layout on the strength of one.
  The comin health gate's `iscsi` check (`modules/nixos/comin-health-gate.nix:114-146`)
  runs `iscsiadm -m node`, which reads the host's **local node DB** — it contacts no
  portal and performs no I/O. Exit 21 ("no records found") is deliberately treated as
  healthy, and the module's own comment at `:102-107` states that **Longhorn is invisible
  to this check**, with a 2026-09-21 measurement behind it: `-m node` and `-m session`
  both 21, empty `/etc/iscsi/nodes`, 20 healthy Longhorn pods running. A routing change
  that breaks the path to the portal therefore yields exit 0 or 21 and **nothing rolls
  back**. Scope is narrower than "every deploy" too: the check is emitted only where
  `openiscsi.enable` is set *and* `iscsi` is in `cominGitOps.healthGate.checks` — so not
  on `titan` (no `openiscsi` import at all) and not on `llm01` (its checks are
  `current-system` and `halogen-flash` only).

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

The scheme below is chosen now so no segment is migrated **twice** — but it is not the
whole scheme. The replacement CIDR for the legacy LAN is deliberately **not** decided
here; naming it is the first deliverable of the Phase 3 spec (§8.1), because it depends on
the Phase 0.5 IP map and on a tested restore. Claiming a complete scheme now would be a
deferral dressed as a decision.

| VLAN | Name | Subnet | Phase | Notes |
|---|---|---|---|---|
| 1 | native / legacy LAN | `192.168.0.0/24` | 1 unchanged | Untagged everywhere today. Servers, HA, TrueNAS, desktops, AP management. **Re-addressed** in Phase 3, not retired: it stays the untagged native VLAN and the documented break-glass path (§7.6), and the NAS stays on it (§8 Phase 3 scope). Its replacement CIDR is a Phase 3 deliverable. |
| 10 | iot | `10.60.10.0/24` | 1b | Wireless only, EAP225 + EAP610. |
| 20 | guest | `10.60.20.0/24` | 1a | Wireless only. No inbound hole, ever. |
| 30 | servers | `10.60.30.0/24` | 3 reserved | Only if the control plane moves. |
| 40 | storage | `10.60.40.0/24` | 3 reserved | Only if iSCSI is deliberately routed. Not recommended. |
| 50 | users | `10.60.50.0/24` | 2 | Desktops. |
| 99 | mgmt | — | never | Deliberately unused. See [the mesh landmine](#91-the-management-vlan-breaks-mesh). |

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
| `IOT_NET` | `10.60.10.0/24` | §6 |
| `GUEST_NET` | `10.60.20.0/24` | §6 |
| `RFC1918` | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | |
| `HA_SERVER` | *Phase 0* | unknown today |
| `ZIGBEE_COORD` | DHCP reservation in `10.60.10.0/24` | Phase 0 |

Aliases are created as an explicit step in Phase 1a step 2 and Phase 1b step 3 — a rule
naming an alias that does not exist on the router silently matches nothing, which in a
block rule reads as "the rule is not working" and in an allow rule reads as a hole.

**Interface `GUEST` (VLAN 20), evaluated top to bottom:**

| # | Src | Dst | Action | Why |
|---|---|---|---|---|
| 1 | GUEST | firewall | allow DNS, DHCP | clients need name and address |
| 2 | GUEST | `RFC1918` | **block + log** | one rule kills LAN, IoT, mesh, and every future private range |
| 3 | GUEST | any | allow | internet |
| 4 | any | GUEST | block | no inbound, ever |

Rule 2 is deliberately `RFC1918` rather than `LAN_NET`. It cannot go stale when Phase 2
and 3 create new ranges, which is exactly when a narrower rule would be forgotten.

**Interface `IOT` (VLAN 10), evaluated top to bottom:**

| # | Src | Dst | Action | Why |
|---|---|---|---|---|
| 1 | IOT | firewall | allow DNS, DHCP | |
| 2 | `ZIGBEE_COORD` | `HA_SERVER:<z2m port>` | allow + log | **conditional** — only if Phase 0.4 measures the coordinator as the TCP client. `<z2m port>` is recorded by Phase 0.4, not guessed. Must sit above rule 3 or it can never match |
| 3 | IOT | `RFC1918` | **block + log** | the boundary — one rule kills the LAN, the mesh, Guest, and every private range Phase 2 and Phase 3 create |
| 4 | IOT | any | allow | vendor cloud, OTA — see the §13 egress seam |
| 5 | `HA_SERVER` | IOT | allow | the only trusted initiator from the LAN |
| 6 | any | IOT | **block + log** | no other source may open a session into IoT; rule 2 is the only exception |

Two things changed here from the first draft, both of them shadowing bugs:

- **The conditional Zigbee allow now sits above the private-space block.** Printed below
  it, it could never match — `HA_SERVER` is inside `LAN_NET`, so the block would have
  swallowed it and Zigbee would fail silently in exactly the case rule 2 exists for.
  Rule order in these tables is load-bearing, which is why "evaluated top to bottom" is
  now in both headings.
- **The block is `RFC1918`, not `LAN_NET`,** for the same reason it is for Guest: once
  Phase 2 puts desktops on `10.60.50.0/24` and Phase 3 creates VLAN 30/40, an
  `IOT → LAN_NET` block plus `IOT → any` allow would leave IoT reaching every new range,
  defeating Phase 2's entire purpose. Consequence: the separate `IOT → MESH_NET` and
  `IOT → GUEST_NET` block rules are **gone**, because both ranges are inside `RFC1918`
  and a rule behind rule 3 is dead code — the same failure mode as the first bullet.

Rules 5 and 6 are the design's spine, and the order is load-bearing: the allow from
`HA_SERVER` must be evaluated before the block. The firewall is stateful, so "HA may
initiate into IoT" automatically admits the replies.

What that spine does **not** claim, because it is false: IoT cannot open a session to any
private address, but rule 4 lets it open sessions to the public internet on every
protocol and port. Every vendor-cloud beacon, OTA poll and telemetry upload from an owned
bulb is such a connection, and it is deliberate — the alternative is breaking the devices
that ship that way. The boundary is *IoT cannot reach the rack, the mesh, Guest, or any
trusted-LAN host*; it is not *IoT cannot phone home*. Narrowing that egress is a deferred
seam in §13, not a property of this design.

Rule 2 exists only in the fallback case, and it is narrower than rule 5 in both
directions: one source address, one destination, one port. Because zigbee2mqtt and the
MQTT broker are both Home Assistant add-ons, MQTT traffic stays on HA's docker bridge and
**never crosses the VLAN** — the only cross-boundary flow in the Zigbee chain is z2m to
the coordinator socket.

**Phase 0.4 decides whether rule 2 is needed, and the direction must be read correctly.**
A first draft of this document had it backwards, which produces a silent Zigbee failure
with a correct observation:

| observation on HA (while z2m is running) | what it means | rule 2 |
|---|---|---|
| a **listening** socket on the z2m port **on HA** | the coordinator connects *to* HA, so the coordinator is the TCP client and IoT is opening a session into the trusted LAN | **required** |
| no listening socket on HA, but an established connection from HA to the coordinator's address | HA dials out (the `serial.port: socket://<ip>:<port>` case), so the trusted LAN initiates and statefulness admits the replies | **not needed** |

Check with `ss -tlnp` / `sockstat -la` on HA while z2m is connected, and record the exact
port — rule 2 names `<z2m port>` and Phase 0.4 is what gives it a value. Whichever way it
goes, Phase 1b step 5 must be written against the measured result rather than against an
assumption.

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

The names of the **pre-existing** SSIDs are not known to this document — §7.5 lists only
"existing trusted", and every step that disables or rolls back an SSID needs a literal
name. Phase 0.9 records the exact SSID name, VLAN/untagged status, security mode and
per-AP broadcast set of every SSID in use, and Phase 1a/1b and both rollbacks reference
those recorded names verbatim. If there is no current guest SSID at all, Phase 1a step 12
is deleted and its rollback rewritten — do not disable an object by guessing at its name
in the Omada UI at 11pm.

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

Phases 0-2 are independently valuable and independently reversible; each carries a
`**Rollback:**` line. **Phase 3 is not reversible** — it is a cluster migration whose
rebuild option is a one-way door with an outage window, and it depends on Phase 2 having
happened. Saying otherwise was a promise the document then did not keep.

### Phase 0 — inventory and proof (no changes to anything)

| # | Item | Resolves |
|---|---|---|
| 0.1 | Model and 802.1Q support of the 8-port switch; whether all ports trunk. | Finding B, §7.1 |
| 0.2 | Model of the rack switch; managed or unmanaged; PoE budget. | the only hardware purchase |
| 0.3 | Home Assistant IP and how it addresses IoT devices today (IP vs mDNS name). | `HA_SERVER`, and whether "no mDNS" is actually true today |
| 0.4 | Zigbee coordinator model, firmware, socket direction (`ss -tlnp` on HA while z2m runs) **and the port it listens/dials on**. | firewall rule 2 (whether it is needed at all, and its `<z2m port>` value) |
| 0.5 | Authoritative map of every static IP on `192.168.0.0/24`, including non-NixOS hosts: TrueNAS/MinIO `.6`, DNS/registry `.41`, HA, printers, the Omada controller. | Phase 3 blast radius |
| 0.6 | **Prove the current boundary.** From a client on each of IoT and Guest: reach `192.168.0.1`, `HA:8123`, `192.168.0.6:9000`, a node's `9100`, and `1.1.1.1`. Record what answers. | Finding A |
| 0.7 | Confirm OPNsense console access and export config. | §7.6 |
| 0.8 | Confirm where the Omada controller runs (hardware, software, cloud). | rollback mechanics |
| 0.9 | Inventory every SSID in use: exact name, VLAN or untagged, security mode, and the set of APs broadcasting it. | §7.5, Phase 1a step 6, both rollbacks |

0.6 is the one that decides whether this project is a hardening or a fix, and it costs
ten minutes.

**Phase 0 exit artifact — this is the gate for entering Phase 1a.** Eight facts with no
record are eight facts no later gate can read. Produce:

- `docs/superpowers/specs/2026-11-17-lan-vlan-phase0-findings.md`, one section per `0.x`,
  each holding the answer, the exact command or screen used, and the date it was taken.
- The OPNsense XML export, stored off-router at a named path (not only on the router).

Phase 1a does not start until that file is complete. "Record what answers" is not an
artifact; a file with a path is.

### Phase 1a — Guest VLAN

Guest first, deliberately: nothing on it needs to be reachable, so a wrong rule produces
"guest phone has no internet" — trivially visible, trivially reversible — while
exercising the entire path: trunk, VLAN, DHCP, DNS, firewall.

1. Create VLAN 20 on the LAN NIC (Interfaces → Assignments → VLANs, priority 0).
2. Assign it as an interface and rename `opt20` → `GUEST`.
3. Give it its IPv4 address **`10.60.20.1/24`** — the literal, not "an address from the
   table".
4. Enable DHCPv4: range `.100`–`.200`, gateway `.1`, DNS `.1`, lease time recorded.
5. Add `10.60.20.0/24` to Unbound's **client access list** and confirm it is in the
   listening set. If the new subnet is not permitted there, guests resolve nothing and the
   failure looks exactly like a firewall bug.
6. **Record the interface's "block private networks / block RFC1918" checkboxes as an
   explicit observation.** One of them silently kills the internet path in rule 3 and
   makes the step 5 test below fail for entirely the wrong reason.
7. Create the aliases in §7.3 (`RFC1918`, `GUEST_NET`, and the rest the rules name). A
   rule naming a missing alias matches nothing, silently.
8. Add the GUEST ruleset **before the SSID exists**, so there is never an unfiltered
   window. Remove the default per-interface allow-all as part of this step, not later.
9. Tag VLAN 20 on the inter-room trunk, **both ends**.
10. Create the `home-guest` SSID on the two wired APs, VLAN 20. Leave it disabled on the
    mesh and garage APs.
11. **Test from a client at each AP's location**: gets `10.60.20.x`, reaches internet,
    cannot reach `192.168.0.1`, HA, `.6`, or any node — and the block appears in
    Firewall → Live View filtered on the GUEST interface, which distinguishes "blocked"
    from "target happens to be down".
12. Disable the old guest SSID, using the name recorded in Phase 0.9. **Decision (§8.2):**
    retire it everywhere, including the mesh and garage APs. Guest Wi-Fi stops working in
    the kitchen, entrance and garage at this step — that is the plan working, not a fault.

**Open decision required before step 12** — see §8.2.

**Rollback:** disable the new SSID, re-enable the old one. Nothing on the trusted LAN
moved, so nothing else can break.

### Phase 1b — IoT VLAN

1. Reserve the coordinator's address in the VLAN 10 DHCP scope. **Conditional on Phase
   0.3:** this step assumes HA addresses IoT devices by IP. If Phase 0.3 finds HA uses
   mDNS names today, a reservation does not help and the real prerequisite is making HA
   address the coordinator by IP first — record which branch applies and do not proceed
   on the assumption.
2. Create VLAN 10, interface, address **`10.60.10.1/24`**, DHCP range `.100`–`.200`, DNS,
   Unbound client access for `10.60.10.0/24`, and the block-private checkbox observation —
   same substeps as Phase 1a steps 3-6.
3. Create the aliases the IOT ruleset names, then add the ruleset, including rule 2 only
   if Phase 0.4 requires it.
4. Tag VLAN 10 on the trunks.
5a. **Move the coordinator itself onto VLAN 10** — static address below the pool, or its
    switch port to untagged 10 — and verify it is reachable from OPNsense. This is the
    single most critical device move in the phase and it used to be implicit.
5b. Then point z2m's `serial.port` at `socket://<reserved-ip>:<port>`, restart the
    add-on, and verify the z2m log reaches "Connected" with no reconnect loop. State the
    expected downtime between 5a and 5b; Zigbee devices do **not** need re-pairing for
    it.
6. Create `home-iot` on the two wired APs, VLAN 10.
7. Move IoT devices over in batches, verifying HA control after each batch.
8. Test from a client: gets `10.60.10.x`, HA controls its devices, and an IoT client
   cannot reach `192.168.0.1`, HA, `.6`, or any node — with the block visible in Live
   View.

**Rollback:** move devices back to the old SSID (name from Phase 0.9), **and** revert the
coordinator's address from 5a as well as z2m's `serial.port`. Reverting only the port
field does not roll the move back.

### Phase 2 — B-lite: desktops to VLAN 50

**Not yet planned.** This phase currently has no steps, no literal values, no port list and
no verification — and its one security sentence ("allow only what is needed") is the
vaguest line in the document, which is the kind of line an implementer gets wrong in the
permissive direction at midnight. Writing it to the standard of Phase 1a/1b means a VLAN 50
interface, address, DHCP scope, resolver access, aliases, a §7.3-style ruleset table, the
named list of rack-switch ports, §10 rows and a rollback verification. None of that exists
yet, so it is declared unbuilt rather than gestured at — the same treatment Phase 3 gets in
§8.1.

What is settled: the intent is cheap breach containment, moving the operator's desktops off
the segment a compromised cluster could reach. It requires the rack switch to be managed
(Phase 0.2). Nothing in this repo changes — the desktops are not managed here — but the
ruleset it needs lives in no repo either (§12), which is part of why it needs its own plan.
It also changes what a roadwarrior on the mesh sees, since the mesh advertises `LAN_NET`
only.

**Rollback (once planned):** set the desktop ports back to untagged 1.

### Phase 3 — move off `192.168.0.0/24`

This is the expensive one and it is a **cluster event**, not a network change. It is
listed with its real cost so it can be scheduled knowingly rather than discovered.

What must change together, `[measured]` from this repo:

| Item | Where |
|---|---|
| Per-host address, gateway, DNS — **SOPS-resolved** | `secrets.yaml#<host>/network_env` for `k8s-server01/02/03`, `k8s-node01/02/03`, `k8s-node05` (seven hosts) |
| Per-host address — **separate secret file** | `secrets/titan.yaml` for `titan`; not in `secrets.yaml` |
| Per-host address — **build-time literals, no SOPS** | `hosts/k8s-node04/vars.nix` (`192.168.0.17`), `hosts/k8s-pi01/02/03/vars.nix` (`.21/.22/.23`). Re-keying `network_env` changes nothing here and raises no error |
| Per-host address — **not managed here** | `llm01`, NetworkManager-managed |
| k3s API endpoint | `k3s.serverAddr`, hardcoded in every agent `vars.nix` — as **two** literals: `https://192.168.0.12:6443` on `k8s-server01`/`k8s-server03`, `https://192.168.0.11:6443` on `k8s-server02` and the agents |
| etcd member peer and client URLs | live etcd cluster — members are IP-pinned |
| k3s serving certificate SANs | include the node IP and API endpoint `[unverified]` — confirm against the running k3s version before planning around it |
| MinIO and iSCSI portal | `common/etcd-snapshot-s3.nix` (the live flag is a **hostname**; `192.168.0.6` appears there only in a comment), `modules/nixos/coder-host.nix`, and two hardcoded `.6` defaults in `pkgs/coder-iscsi-helper/helper.py` |
| `l.arrieta.eu` split-horizon record | live data is `hosts/titan/configuration.nix` `meshDns.splitZones` (`192.168.0.41`); `modules/nixos/mesh-dns.nix` holds only an `example`. The `casa.arrieta.` half of the split is named nowhere in this spec |
| rsyslog target | `modules/nixos/rsyslog.nix` default (`192.168.0.41`) |
| llm01 references | `hosts/llm01/configuration.nix` `allowedApiSources`, `home/hosts/coder-workspace-titan/userOptions.nix`, and a module-level default in `modules/home-manager/pi/default.nix`. `modules/nixos/ssh.nix` holds `.29` only inside an `example = [...]` for `listenAddresses`, so grepping it produces a false positive |
| Mesh LAN CIDR | `wireguard.lanSubnet` (**currently unset** — inherited from the module default, so this is a new override, not an edit), `wireguard.forwardToLan` SNAT, `hosts/titan/configuration.nix` `publicHost.meshTCPPortExtraSources`, the OPNsense WireGuard peer's `allowedIPs` (the one edit that actually moves the route), `meshDns.splitZones`, and `networking.hosts` (pins `s3.l.arrieta.eu` to `192.168.0.42`) |
| `AGENTS.md` | runbook examples, routewatch commands, and a k3s snippet already stale in both option name and address |
| Firewall aliases and rules | OPNsense (no repo, §12) — `LAN_NET`'s value changes, and both the IOT and GUEST rulesets must be re-verified against every new range. `RFC1918` keeps the blocks correct by construction, but the aliases and the Live View tests do not update themselves |
| Cluster side | `k8s-casa` Prometheus static scrape list, app DNS, anything with a hardcoded node IP |
| Rollout | `scripts/comin-approve.sh` bind zone `casa.arrieta` resolution |

**Re-derive this table before acting on it.** It rotted within days of being written —
four rows were wrong when checked against the repository. Run a fresh
`grep -rn '192\.168\.0\.'` across the tree at planning time and treat the table as a
starting checklist, not as ground truth.

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
the flat segment it is on. Routing Longhorn's iSCSI across a router is a real risk and
**nothing in the current toolchain would detect it**: MTU is a path property, so routing
does not "remove" jumbo frames — it makes end-to-end MTU ≥ 9000 a requirement on every
segment, switch port and VLAN interface in between, and a path that advertises 9000 but
silently fragments or drops is exactly the failure Longhorn would eat. The comin health
gate's `iscsi` check would **not** catch it: it reads only the local node DB, treats an
empty DB as healthy, cannot see Longhorn at all, and does not run on `titan` or `llm01`
(§3.2). So VLAN 40 stays reserved and unused unless there is a specific reason, and
Phase 3 must carry its own per-node Longhorn attach-and-IO verification step rather than
leaning on the deploy gate. `[unverified]` whether OPNsense and both switches support
MTU 9000 on a VLAN interface at all.

### 8.1 Phase 3 gets its own spec

Phases 0 through 2 are one implementation plan. Phase 3 is a cluster migration with a
restore-validation prerequisite and two viable strategies that have not been costed
against each other. It should be written up as its own spec, after Phase 0.5 has produced
the authoritative IP map and after a restore has actually been tested. Do not fold it
into the Phase 1 plan.

### 8.2 Decision — guest coverage in the mesh rooms

**Decided: option (a), retire the old guest SSID everywhere. 2026-11-23.**

The kitchen, entrance and garage APs are the mesh/bridge units — the APs most likely to
be broadcasting today's guest SSID. The new `home-guest` SSID is enabled only on the two
wired APs, because a VLAN must not depend on a wireless mesh backhaul (§4, Finding B).
So retiring the old SSID removes guest coverage from those three rooms; leaving it
running keeps an unfiltered guest network on the flat LAN, which is the hole this whole
project exists to close.

The two options as they were weighed:

| option | what you get | what it costs |
|---|---|---|
| **(a) Retire the old SSID everywhere** — **chosen** | no residual hole; the plan is honest | no guest Wi-Fi in kitchen, entrance and garage until the cables in §13 are pulled |
| **(b) Keep the old SSID on the mesh APs** | guest coverage everywhere today | an unfiltered guest network on the trusted LAN persists; per-AP Omada isolation stays on and is **per-AP only** `[community]`, so it is not a boundary |

Consequences of (a), stated so nobody rediscovers them mid-phase:

- Guest Wi-Fi stops working in the kitchen, entrance and garage the moment Phase 1a step 12
  runs. That is the intended outcome, not a regression to chase.
- The coverage gap is closed only by pulling cables (§13), which is now a remediation with a
  dependency rather than a nice-to-have.
- No accepted security risk results from this choice, so §11 gains no entry — the gap is a
  coverage consequence, recorded in §11 as a certainty so it is not mistaken for an
  oversight.
- Record the decision and its date in the Phase 0 findings artifact alongside the Phase 0.9
  SSID inventory, since step 12 acts on those recorded names.

## 9. Landmines

### 9.1 The management VLAN breaks mesh

`[community]` Adopting an EAP in mesh mode fails
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
to be a TCP client and rule 2 is omitted, Zigbee silently fails to come up after the
move. Phase 0.4 exists for this.

## 10. Testing and acceptance

Every row names the command and where it is run. A pass condition stated as a predicate is
satisfied by any unrelated failure — a target that is down, a client with no route, the
wrong SSID joined — and a broken test is indistinguishable from a working boundary. That
is exactly what success criterion 5 promises against, so the observation point is part of
the test.

| Test | Phase | Pass condition | Observed with |
|---|---|---|---|
| **Positive control** — the probes can detect an open port at all | before 1a | from a trusted-LAN client, `HA:8123`, `.6:9000` and a node's `9100` all report OPEN | `nc -vz <ip> <port>` from a trusted-LAN host, one line per target, recorded in the Phase 0 artifact |
| Boundary from IoT client, at each enabled AP | 1b | `10.60.10.x` lease; `192.168.0.1`, `HA:8123`, `192.168.0.6:9000`, `192.168.0.11:9100` all refused/filtered; internet up | at the AP's location: `ip -4 addr` (lease), `nc -vz` per named target, `nc -vz 1.1.1.1 443`, **and** OPNsense Firewall → Live View filtered on the IOT interface showing the drop |
| Boundary from Guest client, at each enabled AP | 1a | `10.60.20.x` lease; `192.168.0.1`, `192.168.0.6:9000`, `192.168.0.11:9100`, `192.168.133.1` and `10.60.10.1` all unreachable; internet up | same shape as above on the GUEST interface. "All RFC1918 unreachable" is not a test — it is unbounded and unfalsifiable, so it is replaced by one named target per blocked range plus the Live View drop |
| No silent fallback on mesh/garage APs | 1a, 1b | IoT and Guest SSIDs not broadcast there | from a client in each of kitchen, entrance, garage: `nmcli dev wifi list` (or phone Wi-Fi list) shows no `home-iot` / `home-guest` |
| Zigbee | 1b | z2m connected, devices responsive from HA, no reconnect loop | z2m frontend log, plus one device toggled from the HA UI per batch |
| Cluster untouched | 1a, 1b | all 12 nodes Ready before and after; no rollback recorded | `kubectl --context casa get nodes` from the usual admin host, and `grep -c 'health gate' /var/log/comin-health-gate.log` compared to the pre-change count |
| Mesh unaffected | 1a, 1b | roadwarrior reaches the API and the rack as before, and gains no route to the new ranges | from the named roadwarrior peer: `wg show` for the allowedIPs actually handed out, `ip route get 10.60.10.1` (must not resolve via `wg0`), then `nc -vz 192.168.0.11 6443` |
| Fleet rollout path | 1a, 1b | `scripts/comin-approve.sh` still resolves and reaches every host | run it in run-1 (verify-only) mode; if it has no dry-run, that is itself the finding and must be recorded rather than worked around |

Success criterion 3, rewritten as something observable: *a guest client receives a
`10.60.20.x` lease, completes a TLS connection to a public host, and every probe to the
named private targets above is logged as a drop on the GUEST interface.*

## 11. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Rack switch is unmanaged | medium | office gets no VLANs | Phase 0.2; hardware purchase, not redesign |
| VLAN falls back to native on an AP | medium | boundary silently absent | client-side test per AP; SSIDs disabled on mesh |
| Coordinator needs an inbound hole | low | Zigbee down | Phase 0.4 measures it; rule 2 is narrow and IP-pinned |
| Trunk change drops the inter-room link during a deploy | low | fleet host mid-switch | schedule the change; check no comin deploy is running |
| Phase 3 etcd IP migration goes wrong | medium | cluster down | rebuild alternative; restore tested before scheduling |
| Guest intra-VLAN traffic | certain | guests can reach each other | accepted and documented, not hidden |
| No guest Wi-Fi in kitchen, entrance, garage | certain | guests have no coverage in three rooms | **decided** (§8.2, option a, 2026-11-23): retire the old SSID rather than leave an unfiltered guest net on the LAN. §13 cabling is the remediation |

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
  `2381/metrics` is unauthenticated — published on the node address by
  `--etcd-expose-metrics`, not bound to `0.0.0.0` (see §3.2 for the distinction and for
  `modules/nixos/etcd-metrics-proxy.nix`, which already solves the etcd case on `titan`
  by binding one address and forwarding to loopback). A one-way rule — only the rack and
  the mesh may reach `6443`, `10250`, `2379`, `2380`, `2381` — costs nothing to maintain
  because it never needs editing for new workloads. This is the cheap half of the
  containment goal and it is independent of every phase here.
- **IoT outbound egress allow-list.** Rule 4 lets IoT reach the public internet on every
  protocol and port, which is every vendor-cloud beacon, OTA poll and telemetry upload an
  owned bulb makes. That is deliberate — the alternative breaks the devices as shipped —
  but it is not a property of the boundary, it is a permission. Narrowing it to a per-device
  allow-list is additive and is worth doing per device as each one is retired from its
  vendor cloud, not as a blanket rule on day one.
- **Kitchen and entrance VLAN coverage.** Needs a cable, not more mesh. This is the
  remediation behind the §8.2 decision — option (a) was chosen on 2026-11-23, so guest Wi-Fi
  is absent from those rooms until this lands. It is a dependency with a consequence now,
  not a nice-to-have.
- **Guest intra-VLAN isolation.** Needs switch private-VLAN or ACL support.
- **IPv6 on IoT and Guest.** Only with a plan for RA-based SLAAC and prefix changes.

## 14. Out of scope

Cluster-internal segmentation, captive portal, bandwidth control, IDS/IPS, replacing the
Omada controller, and any change to `titan` in Phase 3 beyond the mesh LAN-CIDR items
listed in the Phase 3 table — `wireguard.lanSubnet` (**currently unset**, inherited from
the module default, so setting it is a new override rather than an edit),
`wireguard.forwardToLan`, the OPNsense peer's `allowedIPs`,
`publicHost.meshTCPPortExtraSources`, `meshDns.splitZones`, and `networking.hosts`.
