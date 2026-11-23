# stage8-zoomout — cumulative fix-set audit

Lens: skeptical architect / minimalism, run **after** `comprehension_report.md`, `.review-raw/stage7-design.md`, `.review-raw/stage7-structural.md`. This report does not restate their findings; it audits **the fix set they collectively demand** and asks whether applying it leaves a simple design or a bloated one, which demanded mitigations are worse than the risk they address, and what should be deleted rather than repaired.

Target: `docs/superpowers/specs/2026-11-17-lan-vlan-segregation-design.md`, 513 lines.

---

## 0. The one-sentence answer

The design core survives all three reviews essentially untouched — two VLANs, two DHCP scopes, twelve firewall rules, one device-native resolver, no new code — which is the strongest available evidence that §7 is near-minimal. **Every gram of bloat the reviews would add lands outside §7**: in Phase 3, the alternatives table, the risk and acceptance tables, glossaries and checklists. The correct response is therefore asymmetric: hold §7 firm, shrink everything around it, and pay for the necessary additions by deletion first.

## 1. Fix-load arithmetic (why cut-first is mandatory, not stylistic)

**Severity:** MAJOR
**Scope:** whole document; the aggregate of the three reviews.

Naive application of the three reports:

| Source | Additive demand | Approx. lines |
|---|---|---|
| comprehension #8, #9 | project glossary **+** general networking glossary (~30 terms) | +45 |
| comprehension #7 | Sources list for every `[vendor-doc]`/`[community]` claim | +12 |
| comprehension #13, #19, #24, #25, #26 | Phase 2/3 acceptance rows, Phase 2 concrete rules, forward-ref pointers, terminology sentence, nit fixes | +25 |
| stage7-design | `inet6` rules + DHCPv6/RA disable, `IOT_INITIATORS` alias, cross-boundary-flow procedure, per-change checklist, mDNS two-branch remedy, UDP-control-path inventory, 4 new §11 rows, 5 new §10 rows, Phase 1b leftover-SSID step, Longhorn drain step, §5 D1/D2/D3 split + dead-native-VLAN option, DNS resolver scoping + 853 block, §7.6 bullets, egress seam in §13 | +75 |
| stage7-structural | TOC, `§0.1` reading order, §6 table split into two columns, §8 renumbering, §10 row splits, marker scale key | +35 |

Result: **~700 lines** for a change whose executable content is twelve firewall rules and two SSIDs — a 37% growth in a document whose author is also its only implementer, and whose §12 already admits it has no diff, no review and no rollback.

The cut list in §2 removes ~130 lines, and the authorised subset of the additions is ~50. **Net target: ~430 lines, smaller than today and strictly better.** If the cuts do not land first, the additions should not land at all.

**Fix:** sequence the revision as (a) deletions from §2 below, (b) the four factual corrections the other reviews raised that are one-line edits (rule order, `GUEST_NET`, the backwards Phase 0.4 diagnostic, the z2m port), (c) the authorised additions in §4. Do not interleave: structural renumbering (their #3, #15, #28) churns lines that the deletions remove.

---

## 2. Cut outright rather than fix

**Severity:** MAJOR (blocker for keeping this document executable)
**Scope:** as listed.

| Cut | Lines | What it deletes for free |
|---|---|---|
| **Phase 3 body + §8.1** → four lines (separate spec; gated on Phase 0.5 **and** on a *tested* etcd + Longhorn restore; inputs are a fresh `grep -rn '192\.168\.0\.'`, the SOPS `network_env` entries, and the `hosts/*/vars.nix` entries that hardcode addresses) | 378–426 (~49) | §11 row 477; §14's `titan` carve-out (512) vs 395 contradiction; comprehension #11, #12, #16; structural #7, #8; the "Retired in Phase 3" self-contradiction at 172; the §7.6 "Phase 3 must replace the break-glass path" demand |
| **Phase 2** → one §6 row ("VLAN 50 reserved for operator desktops; its ruleset and its switch dependency make it its own spec") | 366–376 (~11) | comprehension #13 and #19; the Phase 2 acceptance rows two reviews demand; the roadwarrior-sees-VLAN-50 aside (373–374); half of the "rules written once" objection at 147 |
| **§14 Out of scope** (duplicate of §2) | 509–513 (~5) | structural #10; comprehension #12 |
| **§9's restatements** — keep only 430–435 (mesh/management landmine) and 441–444 (trunk-change outage) | 436–439, 445–455 (~12) | structural #10, #11; the Finding B triple statement |
| **§12's tooling menu** (OPNsense REST/`configd`, ansible/terraform, Omada API, Nix-rendered diff) — keep the gap statement and "the XML export is the only rollback" | 486–491 (~6) | a speculative project masquerading as a deferred decision |
| **The rule-5 prose essay** — see §3 below | 264–273 (~10) | comprehension #1, #4, #6; stage7-design's first blocker; §11 row 475 |
| **VLAN 30/40 conditional prose** ("Only if the control plane moves", "Only if iSCSI is deliberately routed", 175–176) and their presence in the day-one tag set at 200–201 | ~4 | structural #8; the permanently-dead-tags objection; the §6↔Phase 3 disagreement |
| **`or proven tagged`** in the §10 mesh row | 463 | comprehension #22 (deletion, not repair) |

**Fix:** execute the table. Then §1's success criteria, §6, §10 and §11 each shrink to the scope the document actually executes, and the claim at 314 ("each phase is independently valuable and independently reversible") becomes true without needing to be reworded into a hedge.

---

## 3. The single largest simplification available: delete rule 5's conditional apparatus

**Severity:** MAJOR
**Scope:** 254 (rule 5), 265–273 (the note), 323 (Phase 0.4), 232 (`ZIGBEE_COORD` alias), 475 (§11 row), 37–38 (criterion 1).

Both prior reviews try to *repair* rule 5: renumber it above the block, name the port, correct the backwards socket diagnostic, compare it to the right neighbour, qualify criterion 1, add a UDP-state-expiry caveat. That is six repairs to keep a rule the document has already admitted it cannot write yet ("only if Phase 0.4 finds…", 254). Ten lines of prose (265–273) exist solely to describe two alternative topologies of a zigbee2mqtt add-on, which is an altitude drop into another project's internals and is Phase 0.4's job to observe, not §7.3's to speculate about.

**Simpler construction — write the rule after the measurement, not before it.** Replace 254 + 265–273 with three lines in §7.3:

> One conditional rule may exist in this table. Phase 0.4 records the coordinator's static address, its port, and which end has the listening socket. Phase 1b then writes exactly one narrow allow (`<coordinator> → HA_SERVER:<port>` **or** `HA_SERVER → <coordinator>:<port>`, whichever direction was measured) and places it **above** the `IOT → LAN_NET` block. Until Phase 0.4 reports, the rule does not exist.

That is a deletion, and it retires: the shadowing blocker (the rule is written in the right position by the person who measured), the undefined port, the `ZIGBEE_COORD` alias, Phase 0.4's role as a design input rather than an inventory item, §11 row 475, the criterion-1 contradiction (criterion 1 stays absolute because no IoT-initiated LAN flow is *designed* — one may be *added*, recorded in the Phase 1b change log), and the UDP state-expiry caveat if the measured direction is HA-dials-out.

**Optional variant, stated with its honest cost:** allowing `IOT → HA_SERVER` outright (one destination host, all ports) makes the socket direction irrelevant and deletes Phase 0.4 entirely. The cost is that any IoT device may then initiate against the single most exposed LAN host. I do **not** recommend it by default; I recommend it if Phase 0.4 turns out to be awkward to run. Either variant is smaller than what is written now.

---

## 4. Demanded mitigations that are worse than the risk they address

### 4.1 Dead native VLAN on the two AP trunk ports — the mesh landmine in disguise
**Severity:** MAJOR
**Scope:** stage7-design's §5 fix (the "cheap partial" that sets the AP ports' native VLAN to a dead VLAN and tags VLAN 1); interacts with 131–134, 307–308, 430–435.

This is the most attractive addition any of the three reviews proposed — it structurally neutralises Finding B, the document's self-declared most dangerous item, at the cost of two switch-port edits. It is also not free, and the review does not notice why:

- The two APs that would receive this treatment (living-room EAP225, office EAP610) are the **mesh parents** (74–76, 433). Omada EAPs are managed on their untagged/native VLAN; moving their port native off VLAN 1 and tagging management is precisely the management-VLAN-on-a-wired-parent pattern that 430–435 says breaks mesh adoption. The mitigation re-imports the rejected risk onto the two APs whose failure costs roaming in two rooms.
- It directly contradicts the document's own break-glass rule at 307–308 ("never remove the untagged native-1 membership … that is the path back in"), and there is no bench environment mentioned for it.

**Fix:** do **not** add it as an alternatives-table row or a Phase 1 step. Add one line to §13: *"Fail-open mitigation candidate: dead native VLAN on the two wired AP trunk ports with VLAN 1 tagged. Requires tagging AP management, which is the pattern §9 says breaks mesh adoption — bench-test on one mesh child before it is even discussed for the parents."* One line, no new phase.

### 4.2 Per-device static address + local DNS record as the mDNS fallback
**Severity:** MAJOR
**Scope:** stage7-design's mDNS fix option (ii); interacts with 51–53, 322, 352–355, 480–491.

The demanded remedy for "Phase 0.3 finds IoT devices addressed by name" is a hand-maintained per-device static address plus a local DNS record on OPNsense. That converts a one-time discovery problem into a permanent per-device hand-edit on the one device §12 says has no diff, no review and no rollback — the exact maintenance tax §2 rejects for cluster segmentation, applied to the fleet's most-churned device class. It also pre-builds **two** remediation branches for a condition nobody has measured.

**Fix:** a gate, not a mechanism. One line after Phase 0.3: *"If any HA integration or IoT device resolves the other by name, §2's mDNS deferral is void and Phase 1b does not proceed until a reflector is scoped to the VLAN 1 ↔ VLAN 10 pair."* Delete the pinning branch. (The reflector is one config; the pinning table is a job.)

### 4.3 A Longhorn drain runbook for one scheduled trunk edit
**Severity:** MAJOR
**Scope:** stage7-design's trunk/iSCSI finding; interacts with 341, 357, 441–444, 464.

The risk is real (TrueNAS/MinIO `.6` and Longhorn iSCSI cross the single inter-room link, 70–71, 98–99). The demanded mitigation — identify the volumes crossing the link, pause or drain the workloads using them, confirm no deploy — is a per-change runbook for an operation that, once comprehension #15 is applied, happens **exactly once**.

**Fix:** ordering beats procedure. Make the single full-tag-set trunk edit (comprehension #15) the **first action of Phase 1a**, before any new SSID or client exists, on a link carrying only storage and cluster traffic, with one line: *"expect a few seconds of interruption on the inter-room link; confirm no comin deploy is running and Longhorn reports all volumes healthy afterwards."* Then extend the existing §10 "Cluster untouched" row (465) with `kubectl get volumes.longhorn.io -A` rather than adding a new row and a drain procedure. Zero new machinery, same exposure removed.

### 4.4 Deliberately stopping the Omada controller and rebooting a production AP
**Severity:** MAJOR
**Scope:** stage7-design's §10 row ("stop the controller, reboot one wired AP, confirm `home-iot`/`home-guest` return tagged, not untagged"); interacts with 131–134, 347, 364.

The question is the right one — an AP that comes back untagged is Finding B's failure mode, and both rollbacks (347, 364) are controller operations. The test is disproportionate: it induces a controller-outage re-adoption on the two APs that carry the mesh, in production, on the path the document itself says may fail. A mitigation that can take out the office's wireless and both new VLANs is not a test, it is an incident.

**Fix:** cheap half only. Add to §7.6: *"export the Omada controller backup and each wired AP's config before Phase 1a; record where they live."* Add to Phase 0.8: *"does a wired AP retain SSID/VLAN config with the controller stopped, and after re-adoption? — answer from TP-Link docs or a bench unit, not from the production office."* Drop the §10 row.

### 4.5 Blocking DNS-over-TLS while rule 6 leaves 443 wide open
**Severity:** NIT
**Scope:** stage7-design's DNS finding; interacts with 255 (rule 6), 218–219.

The reviewer's own conclusion is that DNS is not a trust boundary here (DoH over 443 is unfixable without TLS inspection). Adding an 853 block to a ruleset whose catch-all allows every port is theater with a rule number on it. The genuinely valuable half is one sentence: the resolver listening on `opt10`/`opt20` must not serve or forward the private zones (`casa.arrieta`, `l.arrieta.eu`), because 219 blocks `.41` while the boundary itself would answer.

**Fix:** add the resolver-scoping sentence to 218–220; add one plain sentence "DNS is not a trust boundary on these VLANs: DoH over 443 is reachable and is not mitigated"; do **not** add the 853 rule.

### 4.6 WPA3/OWE migration on the guest SSID
**Severity:** NIT
**Scope:** 297; stage7-design's guest-to-guest finding.

Accept the free half: enable Omada per-AP client isolation on `home-guest` and `home-iot` — a checkbox, and since both VLANs exist on only two APs (289–295) it covers the majority of guest pairs. Reject the passphrase/OWE migration: it forces reconfiguring every guest device to reduce an exposure that is already confined to other guests on a segment with no route to anything private. Record the residual in one clause at 275–279 instead.

---

## 5. Demanded additions to refuse outright

### 5.1 The general-vocabulary glossary
**Severity:** MAJOR
**Scope:** comprehension #9 (~30 terms: 802.1Q, trunk, native VLAN, SNAT, stateful, SLAAC, iSCSI, VXLAN, kubelet, etcd peer/client URL, SAN, PoE, VIP, CIDR, jumbo frames, captive portal, YAGNI, SSDP, Avahi, DHCP reservation).

This is a homelab operations spec whose reader is the person who owns the router, the switches and the cluster, executing it in a web UI at their own kitchen table. A networking textbook appendix is scope creep, will drift from every other doc in `docs/superpowers/specs`, and buys nothing for Phase 1a. The comprehension finding is real but its severity is inflated: the only general terms whose *absence changes a decision* are **native VLAN / untagged** (the entire fail-open argument at 131–134 depends on them) and **trunk/tagged**.

**Fix:** accept comprehension #8 (project-specific names — `comin`, SOPS, Longhorn, `titan`, `k8s-casa`, `DNS2`, CEP, z2m, the coder helper, split-horizon — ~10 lines with links). Refuse #9 except a one-clause gloss at first use of native/untagged near 131 and at 199. That is ~12 lines instead of ~45.

### 5.2 Turning §5 into a decision matrix
**Severity:** MAJOR
**Scope:** 142–153; stage7-design's D1/D2/D3 split plus stage5's options F and G.

Two reviews independently conclude the table is staged, and their combined remedy takes it from 6 rows to 10–11 with a new costed option. That is the clearest single bloat vector in the whole fix set, and it is aimed at the section with the least executable content in the document.

**Fix:** the table's job is to prove rivals were considered, not to survey them. Add **two** rows, both of which change a decision: (i) the real no-new-VLAN rival — existing OPNsense rules on a routed WLAN interface, Omada EAP ACLs, switch private-VLAN — as **one** row with the three mechanisms named in the rationale cell; (ii) narrow the roadwarrior client `AllowedIPs` instead of re-IPing the fleet, which is the cheap rival to §1's long-term goal and must appear or §1's motivation is unexamined. Add one clause to row B's cell: an unused native VLAN is the only structural cure for Finding B (and see §4.1 for why the cheap partial is not free). Table goes 6 → 8 rows. Do not split D three ways.

### 5.3 A Likelihood scale for §11
**Severity:** NIT
**Scope:** 469–478; structural #25.

Inventing `low = <20%` for a six-row homelab risk table is fake precision that will be ignored on the next edit. Replace the Likelihood column values with `observed / possible / speculative`, or drop the column and keep Impact plus Mitigation. Do not add a scale key.

### 5.4 A per-change checklist that includes this document's own tables
**Severity:** NIT
**Scope:** stage7-design's maintenance-economics fix.

The checklist is worth its six lines — it is the only honest statement of the ongoing cost, and it partly substitutes for §12. But the instruction to also edit "this document's §6 table, §7.3 alias table and §10 test rows" makes the spec a second source of truth for live config, which guarantees drift and turns every change into three edits. Keep the checklist to three rows (new IoT device / new VLAN / new cross-boundary service) naming the **systems** to edit, require an XML export committed after every manual change, and state that the tables here are descriptive, not authoritative.

---

## 6. Where mass should be added: Phase 0, and only Phase 0

**Severity:** MAJOR
**Scope:** 316–330 (Phase 0), 312–314.

Phase 0 is the only section where the reviews' additions are unambiguously good value: it changes nothing, costs an afternoon, and every item replaces a guess currently load-bearing in §7. Let it grow from 8 items to ~12, not 15 — several demanded items collapse into existing ones:

- **0.3 absorbs**: whether anything resolves IoT by mDNS/SSDP name; whether any IoT device resolves a LAN hostname (firmware/OTA URL) now that DNS moves to OPNsense; whether any control path is UDP with long idle gaps; the z2m port number.
- **0.4 absorbs**: the coordinator's **static** address on the device itself (below `.100`, outside the pool) rather than a DHCP reservation — accept this from both reviews, it is simpler *and* removes the reservation-dies-on-restore failure mode; and the observed socket direction.
- **0.8 absorbs**: where the controller runs, where its restorable backup lives, and the config-retention question from §4.4.
- **New 0.9**: every SSID currently broadcast per AP with its current VLAN/isolation setting, and a count of the devices that will join VLAN 10 with which need a reservation. (This is comprehension #18 and stage5's unmeasured-Phase-1b-labour item, merged.)
- **New 0.10**: does the operator reach any IoT or Guest device from the mesh or from outside today? Name the device and the client. Without this, §10's "gains no route to `10.60.10.0/24`" pass condition at 466 encodes an unmeasured assumption as a *success* criterion, and the regression is discovered in the dark.

**Do not add** a Phase 0 item for the WAN address family / `100.64.0.0/10`: widen the alias at 229 instead. One cell, not one inventory item.

**Fix for 312–314 as well:** scope the claim to "Phases 0–2", since Phase 3 is being cut to a pointer.

---

## 7. Two conflicts between the prior reviews, resolved

### 7.1 §13's control-plane allow-list: promote to a phase, or delete?
**Severity:** MAJOR
**Scope:** 499–504, 88–90; stage7-design promotes it to Phase 1c; the earlier zoom-out pass disowns it and points at `modules/nixos/etcd-metrics-proxy.nix`.

The promotion is right in priority and wrong in mechanism, and the underlying exposure is mis-stated. The repo binds etcd metrics to the **node address** via `--etcd-expose-metrics` (`hosts/k8s-server01/vars.nix:37,41,46`, and identically on `k8s-server02`/`k8s-server03`), not to `0.0.0.0` as line 90 claims; and the repo already contains the bound-to-one-address pattern with an explicit assertion against `0.0.0.0` (`modules/nixos/etcd-metrics-proxy.nix:52-59`, whose header explains at length why `--etcd-expose-metrics` is the wrong flag). So the fix is a per-host flag change reusing an existing module, not a new OPNsense ruleset and not a new phase.

**Fix:** correct line 90 to say "bound to the node address, unauthenticated, and the NixOS firewall is off on these hosts by design"; reduce 499–504 to one line pointing at `etcd-metrics-proxy` and the flag removal as its own small spec; delete the port list. Do not create Phase 1c.

### 7.2 Does Phase 0.6's outcome change the plan?
**Severity:** MAJOR
**Scope:** 118–121, 325, 329–330.

Both Finding A and 329 say 0.6 decides whether this is hardening or a fix, and then nothing decides. This is the highest-leverage line in the document and it is currently a footnote: if 0.6 shows an enforced OPNsense boundary already exists, Phase 1's marginal security gain collapses and the ordering argument used to reject option E (154) weakens — the honest output may be "Phase 1 is optional".

**Fix:** promote to a stop condition in §1, not a remark after Phase 0: *"Gate: if Phase 0.6 shows an enforced boundary, this spec's Phase 1 is re-prioritised below the etcd-metrics fix before any switch or AP is touched."* One line, and it is the only line in the document that can save the whole project.

---

## 8. Replace six demanded mitigations with one honesty list

**Severity:** MAJOR
**Scope:** §1 (35–43), §2 (45–58), §11 (469–478); the reviews' demands on IoT internet egress, guest-to-guest + PSK decryption, DNS as a covert channel, IPv6, wired IoT, roadwarrior loss of IoT access, OPNsense as a new SPOF, etcd `2381` still open on the LAN.

Six of the critic findings are true and none of them should be *fixed* — each is either unfixable without TLS inspection, already accepted, or out of the goal's scope. What is missing is not mitigation but a short list, so a future reader does not believe more was built than was. Add **one** block, five to eight bullets, under §2 titled *"What this boundary does not buy you"*: IoT may still reach the whole public internet (vendor cloud, OTA, exfiltration); guests can reach and, on a shared passphrase, passively decrypt each other; DNS is not a boundary (DoH is reachable); wired IoT-class devices stay on VLAN 1; roadwarriors lose direct reachability to IoT; OPNsense becomes a new control-plane dependency for HA↔IoT and one inter-room cable carries every segment; the control plane remains reachable from anywhere on the trusted LAN.

Then §11 gains **at most three** rows, not six: the four demanded SPOF rows (OPNsense down, OPNsense reboot, inter-room cable, living-room switch) collapse into **one** row whose Mitigation cell reads `accepted — no mitigation planned`, plus one row for the mDNS/name-resolution unknown and one for leftover devices on the legacy SSID. §11's Mitigation column must be allowed to say "accepted"; forcing a mitigation into every cell is exactly what manufactures mitigations worse than their risks.

**Fix:** add the honesty block; cap §11 at nine rows; allow `accepted — no mitigation` as a legal cell value; drop the Likelihood column rather than scaling it.

---

## 9. Authorised addition list (the whole budget)

For the orchestrator, the net of §4–§8 — everything the revision should add, so bloat is measurable:

| Addition | ~Lines |
|---|---|
| Project-name glossary (comprehension #8 only) | 10 |
| IPv6: disable DHCPv6 + RA on `opt10`/`opt20`, one `inet6` block above each catch-all, one §10 check (`ip -6 addr` shows no global address; outbound v6 fails) | 6 |
| Rule-5 replacement (three lines, §3 above) | 3 |
| Resolver private-zone sentence + "DNS is not a boundary" sentence | 2 |
| `NON_ROUTABLE` widening to include `100.64.0.0/10` | 1 |
| Phase 0 growth (+4 items, merged per §6) | 5 |
| §10: +4 rows (IPv6, OPNsense reboot with one Zigbee and one Wi-Fi device active, no client left on the legacy SSID, Phase 0 boundary proof), split the roadwarrior row into three, delete `or proven tagged` | 6 |
| §11: +3 rows, Likelihood column dropped | 4 |
| Per-change checklist (3 rows) + "commit an XML export after every manual change" | 8 |
| §5: +2 alternative rows, +1 clause on row B | 3 |
| §7.6: switch config backup + "do not touch the management port's native VLAN" + Omada controller and per-AP export | 4 |
| Gate line in §1 (7.2 above) | 2 |
| Terminology equation sentence (trusted LAN = legacy LAN = native VLAN 1 = `LAN_NET`; rack switch = office switch) | 1 |
| §13 one-liner for the dead-native-VLAN bench candidate | 1 |
| **Total** | **~56** |

Against ~130 lines of cuts in §2. **Net: −75 lines.**

---

## 10. Residual risks of the cut-first approach

- Cutting Phase 3 and Phase 2 leaves VLAN IDs 30/40/50 reserved with no scheduled owner. That is the correct state for this document, but only if §6's rows keep the reservation and nothing else; if the reservations are also deleted, the document loses its one genuine forward-compatibility guarantee.
- Refusing the general glossary (5.1) leaves the document unreadable to anyone who is not the operator. Accepted: this is an operations spec, not an onboarding doc, and the alternative is ~45 lines of textbook that will rot.
- Deleting rule 5's prose (3) defers a real decision to Phase 0.4 with no fallback written down. If Phase 0.4 is skipped, Zigbee silently fails after the move — the same outcome §9 warns about. The mitigation is that Phase 1b's step list must make the rule-writing step explicit and unskippable.
- The §4.1 candidate (dead native VLAN) is genuinely the only structural cure for Finding B and is being deferred on cost/risk grounds, not on the merits. If the bench test ever succeeds, §5's row B should be revisited and Phase 1's "SSIDs disabled on three APs" restriction shrinks.