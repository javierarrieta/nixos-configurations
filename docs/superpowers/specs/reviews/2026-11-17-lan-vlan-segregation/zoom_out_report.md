# Zoom-Out Review — `docs/superpowers/specs/2026-11-17-lan-vlan-segregation-design.md`

Lens: skeptical architect / minimalism. Full file (1–513).

---

## Blocker 1 — the IoT boundary is written against a range that goes stale, and the document already knew it

**Scope:** §7.3, lines 250 (`IOT → LAN_NET block`) vs 240 (`GUEST → RFC1918 block`) and the justification at 244–245.

**Problem.** The document justifies `RFC1918` for Guest with the exact argument that applies to IoT and was not applied to it: "It cannot go stale when Phase 2 and 3 create new ranges, which is exactly when a narrower rule would be forgotten." The IoT table uses `LAN_NET` (`192.168.0.0/24`) instead. Consequence: the moment Phase 2 puts desktops on VLAN 50 (`10.60.50.0/24`) or Phase 3 creates VLAN 30/40, IoT can reach every one of those new ranges, because rule 6 (line 253) allows `IOT → any`. Phase 2's stated purpose — "protects the operator's machines from a cluster compromise" (line 370) — is defeated by a Phase 1 rule that nobody will remember to edit. The same asymmetry means IoT can reach `172.16.0.0/12` Docker pools and any future private range.

**Fix.** Line 250 becomes `| 2 | IOT | RFC1918 | **block + log** | the boundary; cannot go stale when Phase 2/3 add ranges |`, and rule 5 (line 252) moves **above** it (a `ZIGBEE_COORD → HA_SERVER` allow placed below an `RFC1918` block never matches). Add one line naming the only legitimate IoT→non-LAN private destination if one exists. Do not add a per-device egress list — that is the bloat version of this fix.

---

## Blocker 2 — Phase 3 is simultaneously deferred and drafted, and its blast-radius table is wrong in three verifiable ways

**Scope:** §8 Phase 3 (378–418), §8.1 (420–426), §6 rows 30/40 (lines 172–173), §5 rows B/B-lite/E (146–152), §11 last row (478), §14 (509–513).

**Problem.** §8.1 says Phase 3 "should be written up as its own spec" and "Do not fold it into the Phase 1 plan." Lines 378–418 fold it in anyway, including a hand-written inventory table that is already inaccurate:

- Line 387 — "Per-host address, gateway, DNS | `secrets.yaml#<host>/network_env`, all 13 hosts". False. `modules/nixos/static-network.nix:7-10` only defers to the SOPS secret when the value starts with `$`. `hosts/k8s-pi01/vars.nix:8`, `hosts/k8s-pi02/vars.nix:8`, `hosts/k8s-pi03/vars.nix:8` and `hosts/k8s-node04/vars.nix:4` hardcode `192.168.0.x` **in the repo**. An implementer following line 387 would edit 13 secrets and miss four hosts.
- Line 388 — "`k3s.serverAddr` hardcoded as `https://192.168.0.11:6443` in every agent `vars.nix`". There are two distinct hardcoded endpoints: `hosts/k8s-server01/vars.nix:25` and `hosts/k8s-server03/vars.nix:25` use `https://192.168.0.12:6443`. §3.2 line 86–87 repeats the same error.
- Missing from the table: `192.168.0.42` (`hosts/titan/configuration.nix:528` pins `s3.l.arrieta.eu` for restic backups; `:166` the Attic cache resolves into that range); `modules/home-manager/dev-tools.nix:146` (a **default** `pi.baseUrl` of `http://192.168.0.29:8731/v1`, which silently survives a re-IP); `hosts/titan/configuration.nix:434-435` (`l.arrieta.eu.` and `casa.arrieta.` zone data in titan's own config, not only `modules/nixos/mesh-dns.nix`); `hosts/titan/configuration.nix:329` (`publicHost.meshTCPPortExtraSources = [ "192.168.0.0/24" ]`).

**Fix.** Delete lines 378–418 and 415–418. Replace with four lines: re-addressing is a separate spec, gated on Phase 0.5 and on a *tested* etcd + Longhorn restore; its inputs are the SOPS `network_env` entries, the `hosts/*/vars.nix` entries that hardcode `192.168.0.x` (pi01–03, node04), the two distinct `k3s.serverAddr` values (`.11` and `.12`), and a fresh `grep -rn '192\.168\.0\.'` at the time of planning — not a table transcribed here. Keep VLAN IDs 30/40 in §6 as reserved numbers with no scope prose. Then §11 line 478 and §14's titan clause shrink with it. Roughly a quarter of the document is about work this document will not execute and explicitly disowns.

---

## Major 3 — the sole stated motivation for Phase 3 is tagged `[measured]` but the cited facts do not produce the claimed effect

**Scope:** §1, lines 30–33.

**Problem.** "`wireguard.lanSubnet` defaults to `192.168.0.0/24` and `hosts/titan/configuration.nix` sets `forwardToLan = true`" does not put a route into a roadwarrior's tunnel. `lanSubnet` is used in exactly one place — the hub-side MASQUERADE scope (`modules/nixos/wireguard.nix:85-90`) — and `forwardToLan` only enables `ip_forward` plus that SNAT (`:271-280`, `hosts/titan/configuration.nix:110`). The route on the laptop or phone comes from that client's own `AllowedIPs`, which is not in this repo; titan's roadwarrior peer entries are `/32` only (`hosts/titan/configuration.nix:239, 251, 268`).

**Fix.** Retag `[unverified]`, name the real source (the hand-maintained wg-quick configs on the phone and two laptops), and add the cheap alternative to §5: narrow the roadwarrior client `AllowedIPs` to the specific `/32`s the laptops actually use (they currently receive the whole `/24` to reach `6443` on `.11`) instead of re-IPing 13 hosts and an etcd cluster. If that is rejected, one line saying why. This is the difference between a cluster migration and a client config edit.

---

## Major 4 — Phase 2 is an undecided phase inside an executable plan

**Scope:** §8 Phase 2 (366–376), §5 B-lite (147).

**Problem.** "Add to the ruleset: `users → LAN_NET` allow only what is needed (SSH to nodes, the cluster API)" is a decision not made. "Nothing in this repo changes" (line 371) means the phase touches only devices this repository does not manage, and it is gated on a hardware answer Phase 0.2 has not produced yet. Every other phase in the document has steps, a rollback and a test; Phase 2 has a paragraph and an open question. It exists because §5 committed to B-lite before the goal required it.

**Fix.** Cut to two lines in §6/§13: "VLAN 50 is reserved for operator desktops. Its ruleset and its switch dependency (0.2) make it its own spec when scheduled." The only thing Phase 2 actually needs from this document is the reserved ID, which §6 already provides.

---

## Major 5 — the design creates a new single point of failure and does not record it

**Scope:** §1 success criteria (37–41), §7.1 (196–208), §11 (469–478).

**Problem.** Today Home Assistant and the IoT devices are on one L2 segment: an OPNsense reboot, an OPNsense upgrade, or a bad firewall edit does not stop HA from reaching them. After Phase 1b, every HA↔IoT packet is routed through OPNsense (rules 7/8, lines 254–255), so the router becomes a control-plane dependency for lights, locks and Zigbee — and the single inter-room cable becomes a hard dependency for whichever AP loses its path. The document's own Phase 1 procedure involves editing that box. Nothing in §1 or §11 states this trade.

**Fix.** One §11 row: "OPNsense down or mid-upgrade → HA loses all routed IoT control; today it does not" (likelihood low, impact "no light switches until the router is back", mitigation "accepted — the same failure already costs the internet"), plus one sentence in §1 admitting the trade. This is honesty, not redesign; do not mitigate it with a HA-on-both-VLANs hack or a redundant router.

---

## Major 6 — remote and mesh access to IoT devices silently disappears, and the document treats it as an unqualified win

**Scope:** §6 lines 187–192, §10 line 466, §7.3 rules 3 and 8 (251, 255).

**Problem.** Line 187 argues IoT/Guest are safe to address permanently *because* "they are never advertised into the WireGuard tunnel", and line 466 makes "gains no route to `10.60.10.0/24`" a **pass condition**. Rule 3 blocks IOT→mesh and rule 8 blocks any inbound into IoT, so after Phase 1b a roadwarrior on the mesh can no longer reach an IoT device — which it can today, since every IoT device is on `192.168.0.0/24` and the tunnel advertises that range. Nobody asks whether the operator uses that (bulb control from a phone away from home, a camera, a presence sensor). If they do, it is discovered after the move, in the dark.

**Fix.** Add Phase 0 item 0.9: "Does the operator reach any IoT or Guest device from the mesh or from outside today? Name the device and the client." If yes, decide now whether a mesh→IoT allow is required — a deliberate, narrow hole designed on purpose — rather than a regression found later.

---

## Major 7 — "no mDNS needed today" is asserted in §2 and disowned by Phase 0.3

**Scope:** §2 lines 53–55; Phase 0.3 line 322; Phase 1b step 1 line 352; §7.2 lines 218–220; success criterion 2 line 38.

**Problem.** §2 states mDNS/SSDP reflection is "Not needed today." Phase 0.3 says it is *unknown* how HA addresses IoT devices today (IP vs mDNS name). Phase 1b step 1 then asserts "No mDNS means HA addresses IoT devices by IP" — the conclusion the phase was supposed to earn. Meanwhile §7.2 moves IoT/Guest DNS to OPNsense unicast only. If any IoT device or HA integration relies on a `.local` name or a LAN-resolved hostname today, Phase 1b breaks success criterion 2 ("no regression") and §11 has no row for it.

**Fix.** Make §2 conditional: "not needed today **unless** Phase 0.3 finds mDNS names in use; if it does, the reflection seam becomes a Phase 1b prerequisite, not a deferral." Extend 0.3 to also ask whether any IoT device resolves a LAN name (firmware/OTA URLs, an MQTT broker hostname) now that DNS moves to OPNsense. Delete the assertion in step 1 and reference 0.3 instead.

---

## Major 8 — §13's control-plane allow-list is out of scope, under-specified, and re-solves a problem the repo already solved differently

**Scope:** §13 lines 499–504; §3.2 lines 88–90.

**Problem.** "A one-way rule — only the rack and the mesh may reach `6443`, `10250`, `2379`, `2380`, `2381` — costs nothing to maintain" does not say where the rule lives, and both answers are bad. On the k3s hosts it means reversing `networking.firewall.enable = mkDefault false` (`modules/nixos/k8s-network.nix:24`), a documented deliberate choice. On OPNsense it protects nothing: a device already on the trusted LAN is exactly what the rule must survive, and IoT/Guest are already fenced by §7.3. The repo already has the source-scoped mechanism on the side where it matters (`publicHost.meshTCPPortRules`, `meshTCPPortExtras` at `modules/nixos/public-host.nix:241-256`, `meshTCPPortExtraSources` at `hosts/titan/configuration.nix:329`). And the etcd-metrics exposure it cites as the justification already has a purpose-built answer: `modules/nixos/etcd-metrics-proxy.nix`, which exists specifically to stop binding `2381` on a wide interface and asserts against `0.0.0.0`. The document also overstates the exposure: `hosts/k8s-server01/vars.nix:36-41` exposes metrics on the **node address** via `--etcd-expose-metrics`, not `0.0.0.0` (line 90).

**Fix.** Replace the entry with one line: "the unauthenticated `2381` on the three k3s servers is a per-host change — drop `--etcd-expose-metrics` and reuse the existing `etcdMetricsProxy` pattern bound to one address — its own spec, not a VLAN concern." Delete the port list. Do not add a new firewall abstraction here.

---

## Major 9 — the alternatives table omits the first alternative a reviewer will raise, so it reads as staged

**Scope:** §5 (142–154); §3.1 line 64.

**Problem.** §3.1 advertises "4 NICs: WAN, LAN, 2 free" and §5 never asks why IoT/Guest are not terminated on a free NIC instead of trunked through two switches and one shared cable. The real answer is short and defensible — the office EAP610 and the rack are reachable only through the single inter-room cable, so a physically separate network needs a new cable run plus a second switch in the office, which is strictly more work than 802.1Q — but it is not written. Same gap for the roadwarrior alternative in Major 3.

**Fix.** Add option F to the table with that one-sentence rejection, and option G for "narrow the roadwarrior client AllowedIPs instead of re-IPing". An alternatives table that omits the two cheapest objections is not an alternatives table.

---

## Nit 10 — three overlapping exclusion lists

**Scope:** §2 (45–58), §13 (493–507), §14 (509–513).

Cluster-internal segmentation appears at 46 and 510; captive portal at 56 and 510; mDNS at 53 and 497; IPv6 at 57 and 507. A reader cannot tell which list is authoritative, and every new exclusion must be written twice. **Fix:** one Non-goals section, one row per exclusion, columns `excluded / why / what would put it in scope`. Delete §14 and fold §13's revisit conditions into the last column.

## Nit 11 — §9 is half restatement of what is already written where the change happens

**Scope:** §9 lines 436–439 (restates Finding B, 133–140), 445–446 (restates §7.2 line 220), 448–450 (restates §7.2 lines 216–218), 452–455 (restates Phase 0.4 at 323 and rule 5 at 252).

**Fix:** keep only the two facts not stated at the point of the change — the mesh/management landmine (430–435) and the trunk-change outage (441–444). Delete the rest. Same for the Zigbee paragraph at 265–273: Phase 0.4 owns that reasoning; rule 5's cell should point at it and nothing else should repeat it.

## Nit 12 — Phase 0.7 duplicates §7.6

**Scope:** line 326 vs 300–310.

Console confirmation and config export are a preflight for Phase 1, not inventory. **Fix:** delete 0.7 and make §7.6 step 0 of Phase 1a.

## Nit 13 — Phase 1b's dominant cost is unmeasured

**Scope:** Phase 1b step 7 (line 360); Phase 0.5 (line 324).

"Move IoT devices over in batches" is the bulk of the labour, and Phase 0 inventories static IPs but never counts the devices that will join VLAN 10 or flags which need a reservation or a manual rejoin. **Fix:** add to Phase 0 — "count the devices joining VLAN 10 and list those needing a DHCP reservation" — so Phase 1b has an effort number and a rollback that is more than "one field".

## Nit 14 — §12 sketches a project it disowns

**Scope:** §12 lines 480–491.

The gap statement (480–485) is honest and worth keeping. The option menu (486–491: OPNsense REST/`configd`, ansible/terraform provider, Omada controller API, a Nix-rendered diff against the live device) is speculative design for a decision the section explicitly defers. **Fix:** keep the gap and the pointer to §7.6 as the only rollback; delete the menu.

## Nit 15 — wired "IoT" is neither in the plan nor declared out of it

**Scope:** §1 (37), §7.1 (204–206), §2 (45–58).

All wired ports stay untagged native 1, so a wired smart hub, an ethernet camera or a networked printer stays unsegmented. Criterion 1 is scoped to "an IoT device on the IoT SSID", which is technically consistent, but a reader finishes the document believing IoT is segmented. **Fix:** one Non-goals line — "wired IoT-class devices remain on VLAN 1 in Phase 1; segmenting them is a separate decision requiring per-port work."

---

## Scope guard (for the follow-up passes)

The executable core — Phase 0, Phase 1a, Phase 1b, §7.1–7.6, the two rulesets — is close to minimal for the goal in §1: two VLANs, two DHCP scopes, one device-native resolver, twelve rules, and it reuses the existing comin health gate for verification (§10 line 467). Findings 1–9 should be fixed by **subtraction and retagging**, not addition. Specifically, do not add: per-device IoT egress lists, an mDNS reflector now, a management VLAN, a private-VLAN pass for guest-to-guest, an OPNsense HA pair, or a hand-maintained Phase 3 inventory table.