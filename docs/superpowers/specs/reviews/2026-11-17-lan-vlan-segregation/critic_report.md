# Critic Report — Stage 7 (design critic, structural, style)

**Target:** `docs/superpowers/specs/2026-11-17-lan-vlan-segregation-design.md` (513 lines)
**Range audited by all three reviewers:** lines 1–311 (design and style) and 1–513 (structural).
**Reviewers:** `stage7-design` (hostile design critic), `stage7-structural`, `stage7-style`. All three completed.

Findings are merged, deduplicated, and ordered most severe first. Every line citation from the three source reports is preserved.

Severity tally: 3 Blockers, 41 Majors, 54 Nits.

---

## Blockers

### B1. Rule order makes IOT rule 5 unreachable, and rule 5 contradicts success criterion 1
*Reviewer: stage7-design*
**Lines:** 246–257 (IOT table), specifically 251 (rule 2) and 254 (rule 5); 259–263; 37–38.

The GUEST table is labelled "evaluated top to bottom" (234). The IOT table carries no such label, but the spine paragraph says "the order is load-bearing" (259–260), so an implementer enters the rules in printed numeric order. Rule 2 (`IOT → LAN_NET` block+log, 251) then precedes rule 5 (`ZIGBEE_COORD → HA_SERVER:<z2m port>` allow, 254). `HA_SERVER` is inside `LAN_NET` (227, 230), so rule 2 matches first and the Zigbee fallback never passes. The case rule 5 exists for is the case that silently fails.

Independent second defect: if rule 5 is enabled, an IoT-initiated connection into the trusted LAN exists, which falsifies criterion 1 ("cannot initiate any connection to the LAN at all", 37–38) and falsifies 261–262.

**Fix:** (a) put "evaluated top to bottom" above the IOT table. (b) Renumber so the conditional allow sits above the block: 1 firewall DNS/DHCP, 2 `ZIGBEE_COORD → HA_SERVER:<port>` allow (conditional), 3 `IOT → LAN_NET` block+log, 4 `IOT → MESH_NET`, 5 `IOT → GUEST_NET`, 6 `IOT → any`, 7 `HA_SERVER → IOT`, 8 `any → IOT`. (c) Reword criterion 1 to "cannot initiate a connection to any trusted-LAN host, except the single documented Zigbee flow if Phase 0.4 requires it".

### B2. The spine paragraph's two assurances are falsified by rule 6
*Reviewers: stage7-design, stage7-style (finding 7)*
**Lines:** 259–263 versus 255 (rule 6 `IOT → any allow`), 275.

"An owned bulb still cannot phone home or scan the rack" (262–263) and "IoT can never start a connection to HA or anything else on the LAN" (261–262) are false as written. Every vendor-cloud beacon, OTA poll, telemetry upload and exfiltration channel from an owned bulb is an IoT-initiated outbound connection to a public address, and rule 6 permits it on all protocols and ports. Statefulness cuts both ways: a device that opens an outbound session under rule 6 gets the replies back. Only IoT→private-space is constrained.

**Fix:** replace 262–263 with: "Home Assistant keeps working; an owned bulb cannot reach the rack or any trusted-LAN host, and can still reach the public internet. That egress is deliberate (vendor cloud, OTA) and is listed as an open item in §13." Fix 260–262 to: "…admits the replies to HA-initiated sessions. IoT cannot open a session to any LAN address. It can still open sessions to the internet under rule 6, and replies to those are admitted by state; same-VLAN traffic never reaches the firewall (§ 275)." Then add the matching §13 seam: "egress allow-list for VLAN 10, added when a specific device is retired from its vendor cloud."

### B3. Three of four internal anchor links do not resolve
*Reviewer: stage7-structural (finding 1); also raised as a comprehension consequence*
**Lines:** 9, 51, 58 (only 54 `#13-deferred-seams` resolves).

- L9 `[Config as code](#12-config-as-code-an-open-gap)` → heading L480 is `## 12. Config as code — an open gap`. GitHub strips the `.` and the em dash, leaving a double hyphen; the correct slug is `#12-config-as-code--an-open-gap`. The link is one hyphen short.
- L51 `[Landmine: the management VLAN breaks mesh](#landmine-the-management-vlan-breaks-mesh)` → no such heading exists. The target is a bold lead-in inside §9 (L430), which generates no anchor at all. This is the link carrying the evidence for a §2 non-goal.
- L58 `[IPv6 policy](#ipv6-policy)` → heading L281 is `### 7.4 IPv6 policy`, slug `#74-ipv6-policy`.

**Fix:** change L9 to `#12-config-as-code--an-open-gap` (or retitle L480 to `## 12. Config as code (open gap)`); promote L430 to `### 9.1 The management VLAN breaks mesh` and point L51 at `#91-the-management-vlan-breaks-mesh`; change L58 to `#74-ipv6-policy`.

---

## Major

### M1. Statefulness is not what protects the LAN, and the claim hides a UDP / long-session failure mode
*Reviewer: stage7-design*
**Lines:** 259–263.

The LAN boundary is rule 2 — a stateless destination block evaluated before any allow — not statefulness. The stateful argument only explains why HA's return traffic is admitted. Presenting it as the reason "IoT can never start a connection" invites a reader to conclude that removing rule 2 is safe. Separately, the design leans on HA-initiated state for the only permitted cross-boundary flows: a long-lived HA→IoT TCP session survives only while the state entry lives, and UDP-based IoT control (CoAP, MQTT-SN, RTP) with idle gaps drops out of the state table and cannot re-establish, because the device cannot initiate.

**Fix:** rewrite the paragraph to name rule 2 as the boundary and statefulness as the return-traffic mechanism only. Add: "IoT control protocols that are UDP with long idle gaps will not survive state expiry; Phase 0.3 must list any device whose control path is UDP, and those devices either need a per-flow keepalive or a dedicated pinhole."

### M2. mDNS is the load-bearing unknown and the plan assumes the favourable answer
*Reviewer: stage7-design*
**Lines:** 39 (criterion 2), 51–53 (non-goal), 210–221, 289–299, 352–355 (Phase 1b step 1).

Phase 0.3 (322) exists to discover whether HA addresses IoT devices by IP or by mDNS name. Phase 1b step 1 then asserts "No mDNS means HA addresses IoT devices by IP" (352–353) as though settled. If HA, an integration, a Matter/Thread border router, or a voice assistant resolves IoT by mDNS/SSDP name, moving those devices to VLAN 10 removes them from HA's multicast domain and criterion 2 fails — and the only fix is the Avahi reflector §2 (51–53) explicitly refuses. The design has no branch for that outcome. Multicast is also unaddressed as a mechanism: no rule mentions `224.0.0.0/4` or `255.255.255.255`, so intra-VLAN multicast falls to the catch-all allow and cross-VLAN discovery is simply absent, with no statement of which devices depend on it.

**Fix:** add an explicit branch after Phase 0.3: if any HA integration resolves an IoT device by mDNS/SSDP name, either (i) scope an Avahi reflector to the VLAN 1 ↔ VLAN 10 pair only and delete the §2 non-goal, or (ii) pin each affected device with a static address plus a local DNS record on OPNsense and record the list in §7.2. Add a Phase 0 item to enumerate devices that use mDNS/SSDP/CoAP for control, not just the coordinator.

### M3. There are no IPv6-family rules; §7.4 closes its hole by intention, not by rule
*Reviewer: stage7-design*
**Lines:** 236–241, 248–257, 281–287.

Every rule in both tables has an IPv4-only destination (`RFC1918`, `LAN_NET`, `MESH_NET`, `GUEST_NET`). OPNsense rules are per address family, and a rule whose destination is an IPv4 alias does not match IPv6 traffic. §7.4 says "do not delegate an IPv6 prefix to IoT or Guest" (283) but never says to disable the DHCPv6 server or router advertisements on `opt10`/`opt20`, and never adds an `inet6` deny. The trusted LAN keeps IPv6 (286), so a prefix exists on the box. If RA or DHCPv6 is enabled at service level it can reach the new interfaces; even without it, a device-generated link-local plus temporary address meets a default-allow inet6 ruleset and leaves via the WAN. This is the SLAAC-defeats-guest-isolation failure §7.4 cites (283–286), reintroduced by omission.

**Fix:** add to §7.2 "explicitly disable the DHCPv6 server and router advertisements on `opt10` and `opt20`". Add rule 0 to both tables: `any → any, family inet6, block`, above every IPv4 rule, plus a note that each listed rule is created with family `inet4`. Add a §10 row: "from an IoT client and a guest client, `radvdump` shows no RA and any outbound IPv6 connection fails."

### M4. Rule 7/8 assume Home Assistant is the only legitimate initiator, and there is no extension path
*Reviewer: stage7-design*
**Lines:** 230 (`HA_SERVER` single host), 256, 257, 259–263; related: 94–96, 324.

Rule 8 blocks every inbound-initiated flow into IoT except one host. Real dependencies that are inbound-initiated from a non-HA LAN host and will silently die: Frigate or go2rtc pulling RTSP from IP cameras, Node-RED/n8n on another box polling Tasmota/ESPHome/HTTP devices, Prometheus or blackbox exporters polling device metrics, ESPHome OTA from a machine other than HA, a local LLM or voice pipeline an IoT device must call (the fleet has `llm01`, 94–96), and printers — which Phase 0.5 lists as static-IP LAN hosts (324) and which phones need. Each becomes a hand-edited OPNsense rule with no diff and no review (§12, 480–491).

**Fix:** replace `HA_SERVER` with an `IOT_INITIATORS` alias (member today: HA) and write rule 7 against the alias. Add a short "adding a cross-boundary flow" procedure naming the alias to edit, the insertion position, and the mandatory XML re-export. Separately, state in §2 or §6 where printers and wired IoT (smart TV, wired camera) live — as written they have no segment in Phase 1 and the document never says so.

### M5. Rule 1 is bypassable by design, and the boundary's own resolver leaks the internal map
*Reviewer: stage7-design*
**Lines:** 218–219, 238, 250, 255.

(a) Rule 1 restricts DNS to the firewall, but rule 6 allows `IOT → any` on every port, so DoT on 853 and DoH on 443 reach any external resolver. Name resolution and DNS-tunnelled exfiltration are unrestricted; the DNS restriction is decorative, and nothing acknowledges this. (b) "Serve DNS from OPNsense on both" (218) has no resolver scoping. If Unbound holds or forwards the split-horizon zones referenced at 92–93 and 391–396 (`casa.arrieta`, `l.arrieta.eu`), IoT and guest clients can resolve internal names from the boundary interface and enumerate the LAN map. Blocking `.41` (219) does not help when the boundary itself answers.

**Fix:** state that the resolver listening on `opt10`/`opt20` must not serve private or forward zones (separate listener or access list restricting those zones to LAN and mesh). Add an outbound block for TCP/UDP 853 from VLANs 10 and 20, and state plainly that DoH over 443 is not mitigable without TLS inspection, so DNS is not a trust boundary in this design.

### M6. The admitted guest-to-guest hole skips the free mitigations, and PSK makes it worse than stated
*Reviewer: stage7-design*
**Lines:** 275–279, 297, 478.

(a) Per-AP Omada isolation is described as insufficient (277), but the design never says it will be *enabled* on the new SSIDs. Since IoT and Guest exist on only two APs (289–295), most guest pairs are on the same AP, so the free per-AP feature covers the common case at zero cost. It is not mentioned. (b) WPA2/WPA3-PSK with a shared per-SSID passphrase (297) means any client holding the passphrase can capture and decrypt other clients' airtime traffic. Combined with the intra-VLAN hole, "guests can reach each other" (478) understates the exposure to "any guest can passively decrypt every other guest's traffic". (c) The §11 mitigation cell (478) reads "accepted and documented, not hidden" — a decision, not a mitigation, and it is the only certain-likelihood risk in the table with no action attached.

**Fix:** in §7.5 add "enable Omada client isolation on `home-guest` and `home-iot` (per-AP, free, covers the same-AP majority)" and "prefer WPA3/OWE with PMF on `home-guest`; if the client mix forces WPA2-PSK, record that a guest holding the passphrase can decrypt other guests' traffic." In §11 replace the mitigation cell with the partial mitigations actually applied plus the residual.

### M7. OPNsense becomes a new single point of failure for home automation; not in the risk table
*Reviewer: stage7-design*
**Lines:** 196–209, 210–221, 469–479; only mention of a reboot is 353–354.

Today HA reaches IoT devices on one L2 segment and local automation survives a router outage. After Phase 1b, every HA↔IoT flow traverses OPNsense, and IoT DNS and DHCP live there too. An OPNsense failure or bad edit now takes down Zigbee and every IoT device — a new dependency, in the opposite direction from the document's framing. A reboot also flushes all stateful states, so long-lived HA→IoT sessions do not return without client-initiated reconnects. §11 has no row; §10 has no reboot test.

**Fix:** add §11 rows for "OPNsense down: HA loses all IoT (new dependency)" and "OPNsense reboot: stateful HA→IoT sessions lost". Mitigations: a static address on the coordinator itself, a stated long lease time in §7.2, and a §10 row "reboot OPNsense with one Zigbee and one Wi-Fi IoT device active; both rejoin unattended; z2m log shows one reconnect, not a loop."

### M8. A DHCP reservation is the wrong primitive for the coordinator
*Reviewer: stage7-design*
**Lines:** 215–217, 231, 352–355; related 306.

The firewall alias points at a DHCP-assigned address (231) and the only requirement is a reservation (352–355). If the reservation is lost — an older XML restore, which §7.6 prescribes at 306, or an OPNsense rebuild — the coordinator gets a different address, the alias silently points at nothing, and Zigbee is down behind a rule that looks correct. A reservation also does not outlive a router outage longer than the lease.

**Fix:** require a statically configured address on the coordinator itself, below `.100` and outside the pool, with the DHCP reservation kept only as documentation. Add to §10: after any config restore, re-apply and re-test Zigbee.

### M9. Steady-state single points of failure: the inter-room cable and the living-room switch
*Reviewer: stage7-design*
**Lines:** 62–78, 155–160, 199–201, 441–449, 469–479.

§5 rule 2 (157–160) and §7.1 (199–201) deliberately consolidate every VLAN onto one cable. §9 treats only the *act of reconfiguring* that trunk as a risk (441–449). The steady-state consequence is unstated: one cut cable or one failed living-room switch now removes the entire office — all four rack nodes, TrueNAS, HA, the office AP, and both new VLANs in the office — because the office path is OPNsense → 8-port switch → inter-room → rack switch (70–74). The living-room switch is an unmodelled SPOF for the whole office and its model is unknown (Phase 0.1). Neither appears in §11.

**Fix:** add two §11 rows with either an honest "no mitigation planned" or a named mitigation (second cable or LAG if the rack switch supports it). Add one sentence to §7.1: consolidating VLANs on one cable also consolidates its failure domain.

### M10. The Omada controller is now part of the boundary and has no stated role
*Reviewer: stage7-design*
**Lines:** 289–299, 326, 344–348, 364; related 130–136.

The SSID→VLAN binding *is* the boundary, and it lives in the Omada controller. Phase 0.8 asks where the controller runs (326) and nothing downstream uses the answer. Unstated dependencies: whether an AP retains SSID/VLAN config across a reboot or a re-adoption while the controller is offline; whether a factory-reset or re-adopted AP comes up with the controller's template or with a default config that emits the SSIDs untagged — the Finding B fail-open mode (130–136); and that both rollbacks (348, 364) are controller actions, so rollback requires the controller to be up. If the controller runs on a trusted-LAN host, its compromise or drift can silently return IoT to native 1.

**Fix:** extend Phase 0.8 with two questions — "does a wired AP keep SSID/VLAN config with the controller stopped, and after re-adoption?" and "where is the controller's restorable backup?" Add to §7.6: take an Omada controller backup and a per-AP config export before Phase 1a. Add a §10 row: "stop the controller, reboot one wired AP, confirm `home-iot` and `home-guest` return tagged, not untagged."

### M11. Phase 1b never removes the old IoT SSID, so the hole stays open
*Reviewer: stage7-design*
**Lines:** 350–364, contrasted with 346; acceptance row 461.

Phase 1a has an explicit "only then disable the old guest SSID" step (346). Phase 1b has no equivalent. Every IoT device that fails to rejoin stays on the old SSID, fully on the trusted LAN, with no boundary, and nothing in §10 detects it. The acceptance row at 461 tests a client that *is* on the new VLAN; it never tests that nothing remains on the old one.

**Fix:** add a Phase 1b step "disable the old IoT SSID, or move it to VLAN 10 under the same ruleset, once the client list is empty", and a §10 row "no client remains on the legacy IoT/Guest SSID", observed by diffing the Omada client list and `/var/dhcpd/var/db/dhcpd.leases` before and after.

### M12. The inter-room trunk edit interrupts iSCSI to TrueNAS, not just comin
*Reviewer: stage7-design*
**Lines:** 441–449, 70–71, 98–99, 42.

TrueNAS/MinIO `.6` sits on the rack switch (70–71) and Longhorn runs iSCSI across the inter-room cable (98–99). §9 frames the trunk change purely as "do not do it while comin is mid-switch on a fleet host" (447–449). The larger exposure is that a live tag/native change drops in-flight iSCSI for every Longhorn volume crossing the link at once — filesystem errors on live pods, which is worse than a rolled-back deploy. Criterion 4 (42) promises the cluster stays up through every Phase 1 step; this step is the most likely to break that promise.

**Fix:** state the iSCSI consequence in §9 and require, before the trunk edit: identify the Longhorn volumes crossing the link, pause or drain the workloads using them, and confirm no comin deploy. Extend the §10 "Cluster untouched" row to include `kubectl get volumes.longhorn.io -A` healthy before and after, not only `kubectl get nodes`.

### M13. The per-change cost is never stated, and "rules written once" is wrong
*Reviewer: stage7-design*
**Lines:** 147, 210–221, 222–257, 480–491.

The document nowhere lists what an operator must touch, so ongoing cost is invisible at design time. A new IoT device is free (join the SSID) *only* if it needs no inbound poll, no mDNS name and no local service; otherwise it is one hand-edited OPNsense rule plus a re-export, with no diff and no review (§12, 480–491). A new VLAN is at least eight edits across four systems — OPNsense VLAN, interface assignment, DHCP, resolver listener, ruleset and aliases, switch A trunk tag, switch B trunk tag, Omada SSID/VLAN — plus this document's §6 table, §7.3 alias table and §10 test rows. A new cross-boundary service is one alias edit and one rule inserted at a specific position in a UI with no undo. So §5's "rules written once" (147) is not true over the life of the system.

**Fix:** add a short "per-change checklist" to §7 with three cases — new IoT device, new VLAN, new cross-boundary service — each listing every place to edit including this document's own tables. Require an OPNsense XML export committed after every manual change. Delete or qualify "rules written once" at 147.

### M14. The alternatives table is staged to make A win
*Reviewer: stage7-design*
**Lines:** 142–153, with 116, 118–121, 130–136, 277–278.

(a) Option D is rejected "on physics" (152–153) using the weakest possible form. The realistic no-new-VLAN competitors are the ones the document itself names elsewhere: OPNsense rules on an already-routed WLAN interface (118–121 says this may already exist), Omada EAP ACLs and guest policy (116), and switch-level private-VLAN / protected ports on the existing 8-port switch (277–278). None appears, so A is compared against a physically impossible option rather than its actual rivals. (b) Option B is described as "full tagged redesign … native VLAN unused" and dismissed on re-IP cost (145–146). The table never says that *native VLAN unused* is the only property that structurally eliminates Finding B: if nothing is native, a mis-tagged SSID lands nowhere instead of on the trusted LAN. The design's self-declared most dangerous item (130–136) is precisely what the rejected option cures, and the reader is not told. (c) The Verdict column mixes adopted, deferred, folded, and "rejected as an order", so the rows are not comparable.

**Fix:** split D into D1 (OPNsense rules on the existing routed WLAN interface), D2 (Omada EAP ACL / guest policy), D3 (switch private-VLAN on the existing 8-port), and state for each what it fails to deliver — permanence, per-segment granularity, IPv6 coverage. Add to B's row: "unused native VLAN is the only structural cure for Finding B." Then add the cheap partial as a real option and cost it: on the two AP trunk ports only, set the native VLAN to a dead/unused VLAN and tag VLAN 1 to the AP, so a failed SSID tag lands on a dead VLAN instead of the trusted LAN — with the caveat that AP management traffic must then be tagged and that this needs the same bench test as the mesh landmine.

### M15. `GUEST_NET` is used in a firewall rule and never defined
*Reviewers: stage7-structural (finding 5), stage7-style (finding 4)*
**Lines:** 253 (IOT rule 4) versus alias table 226–232, which defines only `LAN_NET`, `MESH_NET`, `RFC1918`, `HA_SERVER`, `ZIGBEE_COORD`.

The alias table is introduced as the authoritative glossary ("Aliases first, so the rules read as intent", 224), so a rule referencing an undefined alias is a hole in the ruleset's own contract. It is also the only alias reference not wrapped in backticks.

**Fix:** add `| \`GUEST_NET\` | \`10.60.20.0/24\` | §6 |` after L231 and backtick L253.

### M16. Dangling pointer "see note" in a table cell
*Reviewer: stage7-structural (finding 6)*
**Lines:** 254 ("**only if** Phase 0.4 finds the coordinator is a TCP client; see note"); intended target 265–273.

Nothing in §7.3 is labelled "note". **Fix:** "see the note below the table", and label that paragraph `**Note on rule 5.**` at 265.

### M17. §6 table row contradicts itself, and the `Phase` column is two dimensions in one
*Reviewer: stage7-structural (finding 7)*
**Lines:** 170–178; specifically 172.

L172 says `Phase = 1 unchanged` while its Notes cell says `Retired in Phase 3`. The column also mixes phase IDs with lifecycle states (`1 unchanged`, `3 reserved`, `never`), so it cannot be read as a schedule.

**Fix:** split into `| VLAN | Name | Subnet | Introduced | Status |`, e.g. VLAN 1 → Introduced `1`, Status `retired in 3`; VLAN 30/40 → Introduced `3`, Status `reserved`; VLAN 99 → Introduced `—`, Status `never`.

### M18. §6 disagrees with §8 Phase 3 about VLAN 30
*Reviewer: stage7-structural (finding 8)*
**Lines:** 175 (`30 | servers | … | Only if the control plane moves`) versus 415 (`Recommended Phase 3 scope: servers to VLAN 30`); §6's authority claim at 167.

L167 declares §6 the single source of truth for the scheme ("The final scheme is chosen now so no segment is migrated twice"), so the conditional in the table is the version a reader will act on.

**Fix:** make L175's Notes read `Recommended in Phase 3 scope (see §8 Phase 3); conditional on the control-plane move.`

### M19. §10 does not deliver acceptance for three of the five phases, and is not tied to §1's criteria
*Reviewer: stage7-structural (finding 9)*
**Lines:** 457–467 versus 314 and 35–44; specifically criterion 4 at 40 and the nearest row at 464.

Every row is scoped `1a`/`1b`; there is no row for Phase 0, Phase 2 or Phase 3, although 314 claims "Each phase is independently valuable and independently reversible". Success criterion 4 (40, "No NixOS host changes IP in Phase 1") has no corresponding test — the nearest row (464, "Cluster untouched") checks node Ready status, not addresses.

**Fix:** add a `Criterion` column mapping each row to §1's numbers 1–5, and add rows for Phase 0 (boundary proof recorded), Phase 2 (desktops on 50, roadwarrior visibility) and Phase 3 entry gate (restore tested).

### M20. Five sections perform two jobs: §2/§14 duplicate each other, and §9/§11 duplicate each other
*Reviewers: stage7-structural (finding 10), stage7-style (findings 37, 38, 39)*
**Lines:** §2 45–58 versus §14 509–513 (cluster-internal segmentation 46 ↔ 511; captive portal/bandwidth 56 ↔ 511–512; IPv6 on IoT/Guest 57 ↔ 507); §9 428–456 versus §11 469–478 (rack switch 472 ↔ §7.1 207; VLAN fallback 474 ↔ 436; coordinator 475 ↔ 453; trunk outage 476 ↔ 441; Phase 3 etcd 477 ↔ 420). Style adds: the OPNsense default allow-all warning appears twice (220 and the landmine text adjacent to 310).

**Fix:** delete §14 and fold its three unique items (IDS/IPS, replacing the Omada controller, the `titan` `lanSubnet` carve-out) into §2 as bullets; keep §9 as prose-only "why" narrative and §11 as the only tabular risk register, with §9 items referenced by `§9.n` from the Mitigation column instead of restated. Keep 220 as the instruction and drop the cautionary restatement.

### M21. Finding B is stated three times
*Reviewers: stage7-structural (finding 11), stage7-style (finding 38)*
**Lines:** 131–134 (blockquote), 436–439 (§9, self-labelled "Restating Finding B"), 474 (§11 row 2). Style adds the third in-range restatement at 137–140 ("Therefore …" plus "Acceptance criterion 5 exists because of this").

A restated hazard is a hazard whose canonical wording drifts.

**Fix:** keep 131–134 canonical; replace 436–439 with a one-line pointer to Finding B plus the *new* content only (the per-AP client-side test requirement); §11 row 2 keeps the mitigation and cites `§4 Finding B`. Replace 139–140 with "Mitigation: §7.5 SSID scoping and acceptance criterion 5."

### M22. The management-VLAN / mesh finding is stated four times before line 311
*Reviewer: stage7-style (finding 37)*
**Lines:** 48–52 (Non-goals), 123–141 (Finding B, full statement), 178 (VLAN table note), plus the out-of-range restatement at 428–434.

**Fix:** Finding B is the single full statement. Non-goals keeps one line plus the anchor; the VLAN-99 row keeps only the anchor.

### M23. Ordering does not serve a reader who must execute Phase 0 first
*Reviewer: stage7-structural (finding 12)*
**Lines:** Phase 0 at 316, first referenced at 101 ("Produced in Phase 0, not assumed here"), then 110–121, 254, 262–273.

A reader meets Phase 0 as an undefined token 215 lines before it is defined, and must read all 311 lines of design before learning that the first executable action is an inventory.

**Fix:** add a short `## 0.1 Reading and execution order` immediately after the markers block stating: §3.3 unknowns → §8 Phase 0 → §7 → §8 Phase 1a → 1b; alternatively move §8 to directly after §6 so the plan precedes §9–§14 commentary.

### M24. §12 is an open gap with no owner, no phase and no discoverable entry point
*Reviewer: stage7-structural (finding 13)*
**Lines:** 480–491, linked from front matter 9 but absent from §2 and §14.

A reader who scans the scope sections never learns the gap exists; a reader who follows 9 finds "Not in scope to fix here" with no decision owner, deadline or follow-up item.

**Fix:** add a §2 bullet pointing at §12, and end §12 with an explicit `Deferred decision: … owner: operator, gate: before Phase 2 begins.`

### M25. The marker contract stated at line 13 is not honoured
*Reviewer: stage7-structural (finding 14)*
**Lines:** 13 ("Every non-trivial claim below is tagged") versus untagged claims at 150 (physics claim that intra-switch traffic never traverses the router), 180–186 (the list of ranges "this fleet already owns" — repo-measurable, so `[measured]`), 441–444 (switch behaviour on a live trunk change — needs `[community]`/`[vendor-doc]`), 207–209 (unmanaged-rack-switch consequence).

**Fix:** tag each, or narrow 13 to "Every claim about a device or file not read directly in this repo is tagged."

### M26. H2 numbering is not monotonic: an unnumbered section sits inside a numbered sequence
*Reviewer: stage7-structural (finding 2)*
**Lines:** 11 `## Confidence markers` between H1 and `## 1. Goal` (23).

The block is a reading key for the whole document, so its position before §1 is right; its lack of a number breaks the template (the sibling spec `2026-10-01-ovh-single-node-k3s-design.md:10` already establishes a `## 0.` section in this repo).

**Fix:** retitle to `## 0. Confidence markers`. Keep it at level 2 before §1.

### M27. Three mutually incompatible H3 conventions, and `8.1` is orphaned after Phase 3
*Reviewer: stage7-structural (finding 3)*
**Lines:** 62/79/101 (`3.1–3.3`), 110/123 (`Finding A —`, `Finding B —`), 316/332/350/366/378 (`Phase 0 —` … `Phase 3 —`), 420 (`8.1 Phase 3 gets its own spec`).

§8 uses phase names as H3s and then introduces the only numeric H3 in the section, 200+ lines after the `8.x` namespace would be expected, so the reader meets `8.1` *after* `Phase 3` and cannot tell whether it precedes or follows it.

**Fix:** either renumber §8's children `### 8.1 Phase 0 — inventory and proof` … `### 8.5 Phase 3 gets its own spec`, or keep phase names and retitle 420 as `### Phase 3 needs its own spec` placed immediately after the §8 intro (314) as a scoping note, with a one-line pointer from Phase 3 (378).

### M28. Confidence marker placed inside a heading
*Reviewer: stage7-structural (finding 4)*
**Lines:** 79 `### 3.2 Logical \`[measured]\``; body starts 81.

The marker vocabulary is defined at 13–20 as a claim-level tag; in a heading it pollutes the anchor slug (`32-logical-measured`), is invisible to a marker grep that expects body text, and makes §3.1/§3.3 look untagged by contrast.

**Fix:** heading `### 3.2 Logical`, with `[measured]` as the first token of 81.

### M29. "trusted LAN" / "legacy LAN" / "native VLAN" / `LAN_NET` / "flat LAN" are not one thing
*Reviewer: stage7-style (finding 1)*
**Lines:** 25, 29, 37, 116, 133, 146, 151, 168, 172, 190, 203, 205, 243, 287.

The document uses these interchangeably for three distinct referents: (a) untagged VLAN ID 1, (b) the `192.168.0.0/24` range, (c) the set of devices currently sitting on both. They come apart in Phase 2: desktops move to VLAN 50 but keep `192.168.0.0/24`, so after Phase 2 "trusted LAN" ≠ VLAN 1 and ≠ `LAN_NET`, and line 243's rule-2 justification ("`RFC1918` rather than `LAN_NET`") silently changes meaning mid-document.

**Fix:** add a definitions block after line 22 with exactly three terms and use them exclusively — `legacy segment` (untagged VLAN 1 + `192.168.0.0/24`), `LAN_NET` (the firewall alias, used only in rule tables), `VLAN 1 untagged` (L2 fact only). Delete "trusted LAN", "flat LAN", "native LAN" as synonyms at 25, 29, 37, 116, 133, 151, 287.

### M30. "the single most dangerous item in the whole project"
*Reviewer: stage7-style (finding 6)*
**Lines:** 130.

A superlative with no comparison set, no likelihood, no evidence marker. The quoted block below it (132–135) already carries the severity.

**Fix:** replace with "Consequence:" and let the blockquote stand. If a ranking is wanted, it belongs in the risk table with likelihood and impact columns filled.

### M31. Rule 7/8 wording ("the one trusted initiator", "nothing else may initiate") ignores rule 5
*Reviewer: stage7-style (finding 8)*
**Lines:** 256 and 257 versus 254, which is a conditional second initiator (`ZIGBEE_COORD → HA_SERVER:<z2m port>`).

**Fix:** line 256 Why → "the only trusted initiator from the LAN"; line 257 Why → "no other source may open a session into IoT (rule 5 is the only exception, and only if Phase 0.4 requires it)".

### M32. "with no regression" is unverifiable as written
*Reviewer: stage7-style (finding 9)*
**Lines:** 39, success criterion 2.

"Every IoT device it controls today, with no regression" is unbounded — no device inventory exists (Phase 0.3 produces one).

**Fix:** "Every device listed as available in Home Assistant before Phase 1b remains available after its batch move, checked per batch (Phase 1b step 7)."

### M33. "a cosmetic cost in OPNsense and nothing else"
*Reviewer: stage7-style (finding 10)*
**Lines:** 191–192.

"and nothing else" is an absolute contradicted inside the document: two coexisting ranges appear in the acceptance expectations and in the Phase 0.6 / 1a / 1b test lines, which is a real test-maintenance cost.

**Fix:** "The cost is two addressing schemes in OPNsense until Phase 3, and two address ranges in the acceptance expectations."

### M34. "It cannot go stale … which is exactly when a narrower rule would be forgotten"
*Reviewer: stage7-style (finding 11)*
**Lines:** 243–244.

Two defects. "cannot" is unearned (a later edit can narrow it), and the second clause asserts a future human failure with no evidence. The real, stronger reason is unstated: every planned range (`10.60.10.0/24`, `10.60.20.0/24`, `10.60.50.0/24`) is already inside `10.0.0.0/16`.

**Fix:** "All Phase 2 and 3 ranges fall inside `10.0.0.0/16`, hence inside `10.0.0.0/8`, so this rule needs no edit when they appear."

### M35. "for no benefit" is an opinion standing in for the reason
*Reviewer: stage7-style (finding 12)*
**Lines:** 218–219.

The reason is in the preceding bullet: OPNsense already serves DNS on both interfaces.

**Fix:** "…because OPNsense already serves DNS on both; a route to `.41` would only widen the path to the registry and logging host."

### M36. "Small pools, wireless-only: `.100`–`.200` on each range"
*Reviewer: stage7-style (finding 23)*
**Lines:** 215.

"Small" is noise once the numbers exist, and the numbers are the fact.

**Fix:** "DHCP pool `.100`–`.200` (101 addresses) on each of VLAN 10 and VLAN 20; static reservations below `.100`."

### M37. "static reservations (the Zigbee coordinator above all) allocated below `.100`"
*Reviewer: stage7-style (finding 24)*
**Lines:** 216.

"above all" is an editorial aside inside a configuration instruction, and it pre-commits the coordinator to VLAN 10 before Phase 0.4 has decided its socket direction.

**Fix:** delete the parenthesis; the coordinator reservation is already a hard requirement in Phase 1b step 1.

### M38. "Long term, also move the trusted LAN off `192.168.0.0/24`"
*Reviewer: stage7-style (finding 25)*
**Lines:** 29.

"Long term" has no referent in a document that has a named phase for exactly this.

**Fix:** "Phase 3 also moves the legacy segment off `192.168.0.0/24`".

### M39. "Produced in Phase 0, not assumed here: …" — passive with no actor
*Reviewer: stage7-style (finding 29)*
**Lines:** 103.

Passive with no actor, in the section a reader uses to decide what they still do not know.

**Fix:** "Phase 0 produces: the two switch models and their 802.1Q support, Home Assistant's IP, the Zigbee coordinator's model and socket mode, an authoritative map of every static IP on the segment, and what enforces the current IoT/Guest boundary."

### M40. The coordinator's socket direction is left undecided in one place and decided in another
*Reviewer: stage7-style (finding 41)*
**Lines:** 216 and 265–273 versus Phase 1b step 5 (357).

Rule 5's own note says the direction is unknown until Phase 0.4; step 5 assumes the coordinator-listens case.

**Fix:** step 5 → "If Phase 0.4 found the coordinator listening on the z2m port, point z2m's `serial.port` at the reserved address; otherwise leave z2m unchanged and rely on rule 5."

### M41. Finding A's heading states a conclusion the evidence does not support
*Reviewer: stage7-style (finding 46)*
**Lines:** 110 ("the current boundary is probably not a boundary `[community]`"), against the marker table 14–19 and the consequence paragraph 118–121.

The marker table defines `[community]` as "Directional, not proof", and 118–121 already reframes the item as something Phase 0 must prove. The hedged verdict in the heading arrives before the evidence.

**Fix:** heading → "Finding A — the current boundary is unproven `[community]`".

---

## Nit

### N1. `RFC1918` is not the whole non-routable space
*Reviewer: stage7-design*
**Lines:** 229, 239.
The alias omits `100.64.0.0/10` (carrier NAT — frequently the actual WAN address on consumer ISPs, and the space used by Tailscale-class meshes), `169.254.0.0/16`, and `127.0.0.0/8`. If OPNsense's WAN is in `100.64/10`, guests can reach the WAN-side interface and anything else in that space, defeating the "one rule kills every private range" claim at 239 and 243–244.
**Fix:** add `100.64.0.0/10` to the alias or create a `NON_ROUTABLE` alias that includes it, and record the WAN address family in Phase 0.

### N2. No go/no-go gate after Phase 0.6
*Reviewer: stage7-design*
**Lines:** 118–121, 325, 328–329.
Finding A says the outcome of 0.6 determines whether this is hardening or a fix, and 329 says it "decides" that — then no decision follows. If 0.6 shows a working OPNsense boundary already exists, Phase 1's marginal security drops and the ordering argument used to reject option E (154) weakens.
**Fix:** add one line after Phase 0: "Gate: if 0.6 shows an enforced boundary, Phase 1 proceeds as hardening and the §13 control-plane rule moves ahead of it; if it shows the Omada checkbox, Phase 1 is urgent."

### N3. §5 rule 1 produces permanently dead tags
*Reviewer: stage7-design*
**Lines:** 155–157, 174–176, 197–201, 415–418.
VLANs 30 and 40 are reserved with subnets and tagged on every trunk and AP (197–201) while §6 marks 40 "not recommended" (176) and Phase 3 recommends leaving storage flat (415–418). Dead tags on every trunk forever is a small permanent confusion cost with no benefit if Phase 3 declines them.
**Fix:** tag only `{10,20}` on day one; add 30/40 when Phase 3 actually schedules them. The §6 table is where a reservation is actually recorded.

### N4. §6's collision argument ignores default-route tunnels
*Reviewer: stage7-design*
**Lines:** 186–192.
"their addresses cannot collide with a roadwarrior's local LAN — the collision argument applies only to networks the tunnel advertises" holds only for split-tunnel clients. On a default-route tunnel, a roadwarrior whose home LAN is `10.60.0.0/16` has that space captured by the tunnel and loses it regardless of what the tunnel advertises.
**Fix:** add "for roadwarriors on a default-route tunnel any `/16` can collide with their own LAN; `10.60/16` is chosen as unlikely, not impossible."

### N5. Unlisted behaviour change: roadwarrior access to IoT disappears
*Reviewer: stage7-design*
**Lines:** 40–41, 186–192, 252.
Today a mesh client can reach any IoT device because everything is on `192.168.0.0/24`. After Phase 1b, IoT is on `10.60.10.0/24`, never advertised into the tunnel (186–192) and blocked from the mesh side by rule 3. Remote access to a camera, a printer, or any device not exposed through HA silently stops working. The document presents the addressing choice purely as a benefit.
**Fix:** state the regression next to the "never advertised into the tunnel" argument and name the intended answer (reach such devices through HA, or add a mesh→IoT allow-list later).

### N6. §7.6 break-glass covers only OPNsense, and its own path is retired by Phase 3
*Reviewer: stage7-design*
**Lines:** 300–311, 308–309, 172.
The four bullets protect the OPNsense UI. The switch management UI also lives on native VLAN 1, and changing a management port's native VLAN or tag set is exactly the edit being made — there is no switch backup step and no "do not touch the management port" rule. The Omada controller has no backup step either. Separately, 308 makes untagged native-1 membership the documented path back in, and 172 retires native 1 in Phase 3, with no acknowledgement that Phase 3 must replace the break-glass path before removing it.
**Fix:** add bullets for switch config backup plus "do not change the management port's native VLAN", and an Omada controller backup; add "Phase 3 must define its replacement break-glass path before retiring native VLAN 1."

### N7. Rule 1 is not implementable as written
*Reviewer: stage7-design*
**Lines:** 238, 250.
"allow DNS, DHCP" names neither protocol nor ports, and DHCP is UDP 67/68 from a client with no address — a rule written as `src GUEST dst this firewall` can fail on the source field. Whether NTP is allowed is unspecified, and some IoT devices fail setup without it. The block+log rules at 251 and 257 have no rate limit, so chatty blocked devices will flood the firewall log.
**Fix:** write rule 1 as `proto UDP, src any, dst this firewall, dst ports 53,67,68 allow`, state the NTP decision, and note a log rate limit on the block+log rules.

### N8. §13 defers the highest value-per-hour item with no owner or trigger
*Reviewer: stage7-design*
**Lines:** 493–508, 496–503, 90–91.
The control-plane inbound allow-list protects a *measured* exposure (etcd `2381` unauthenticated on `0.0.0.0`, 90–91, with the host firewall off by design), is described as costing nothing to maintain, and is independent of every phase — then it is deferred with no owner, no phase and no trigger. Given Finding A explicitly allows that the IoT boundary may already exist (118–121), this may be the largest real security gain in the document.
**Fix:** promote it to a numbered phase (1c) or a Phase 0 action with an owner; it is one alias plus one rule and depends on no VLAN work.

### N9. "the rack" is used both as a location and as a device
*Reviewer: stage7-style (finding 2)*
**Lines:** 200, 203 ("rack switch"), 207 ("rack switch"), 263 ("scan the rack").
Line 263's "scan the rack" is a test-relevant target and names no address.
**Fix:** "rack switch" for the device everywhere; line 263 → "cannot scan the server subnet `192.168.0.0/24`".

### N10. The two switches are named four different ways
*Reviewer: stage7-style (finding 3)*
**Lines:** 66 ("rack switch (model unknown)"), 68 ("8-port managed switch"), 159 ("the office switch"), 198–200 ("8-port switch", "rack switch").
Line 159 "Buy the office switch with B in mind" is ambiguous: the office rack switch is the unknown one (Phase 0.2), but "office switch" reads as the living-room 8-port unit to a first-time reader.
**Fix:** freeze two names — `living-room switch (8-port)` and `office rack switch` — and apply them at 66, 68, 159, 198, 200, 203.

### N11. The alias table's `Source` column holds a value, not a source
*Reviewers: stage7-style (finding 5), stage7-structural (finding 18)*
**Lines:** 231 (`| HA_SERVER | *Phase 0* | unknown today |`), 232.
The Value cell holds a phase, the Source cell holds a status; 231 is italic while 232 is plain in the same column.
**Fix:** `Value = unknown until Phase 0.3`, `Source = Phase 0.3`.

### N12. "No inbound hole, ever" / "no inbound, ever"
*Reviewer: stage7-style (finding 13)*
**Lines:** 174, 241. "ever" is unbounded; a per-interface rule can be deleted by a later edit.
**Fix:** "no inbound rule is permitted on this interface; rule 4 is terminal and nothing above it allows inbound."

### N13. "Chosen to avoid every range this fleet already owns: … and the common consumer-router defaults"
*Reviewer: stage7-style (finding 14)*
**Lines:** 180–183. Consumer-router defaults are not ranges the fleet owns; the sentence mislabels its own list.
**Fix:** "Chosen to avoid three sets: the ranges this fleet owns (`10.42.0.0/16`, `10.43.0.0/16`, `172.17.0.0/16`, the `172.16/12` compose pools, `192.168.133.0/24`), the common consumer-router defaults (`192.168.0/24`, `192.168.1/24`, `10.0.0/24`, `10.10/16`), and the classic OpenVPN defaults `10.8/8` and `10.9/8`."

### N14. "Rejected on physics"
*Reviewer: stage7-style (finding 15)*
**Lines:** 150. "Physics" is rhetorical for "L2 switching does not traverse the router", which the sentence then states anyway.
**Fix:** "**Rejected.** Two hosts on the same switch never traverse the router, so intra-LAN traffic cannot be filtered without a VLAN boundary."

### N15. "a permanent maintenance tax for a threat this homelab does not have. Explicitly rejected."
*Reviewer: stage7-style (finding 16)*
**Lines:** 49. "maintenance tax" is a metaphor, "permanent" is unbounded, and "Explicitly rejected" is redundant inside a section titled Non-goals.
**Fix:** "each new workload would need its node-to-node rules reviewed, and no in-cluster workload is untrusted here. Rejected."

### N16. "YAGNI."
*Reviewer: stage7-style (finding 17)*
**Lines:** 56. An acronym used as the argument.
**Fix:** "Not built: no current need, and each one adds a maintenance surface."

### N17. "Documented as an additive seam"
*Reviewer: stage7-style (finding 18)*
**Lines:** 53. Jargon.
**Fix:** "Listed under Deferred seams as a later addition".

### N18. "Out of scope and actively undesirable"
*Reviewer: stage7-style (finding 19)*
**Lines:** 57. "actively" is decorative.
**Fix:** "Out of scope; see [IPv6 policy]".

### N19. "Rules 7 and 8 are the design's spine, and the order is load-bearing"
*Reviewer: stage7-style (finding 20)*
**Lines:** 259. Two metaphors in one sentence, and "spine" adds no constraint.
**Fix:** "Rule order is load-bearing: the allow from `HA_SERVER` must precede the block."

### N20. "one rule kills LAN, IoT, mesh, and every future private range"
*Reviewer: stage7-style (finding 21)*
**Lines:** 239. "kills" is slang in a rule justification.
**Fix:** "one rule covers LAN, IoT and mesh, and any private range added later".

### N21. "the choice is recorded so it is a decision, not an accident"
*Reviewer: stage7-style (finding 22)*
**Lines:** 185. Aphorism.
**Fix:** "Recorded here so a later editor changes it only with a reason."

### N22. "which is a live problem for WireGuard roadwarriors"
*Reviewer: stage7-style (finding 26)*
**Lines:** 30. "live problem" is colloquial and unquantified.
**Fix:** "which breaks the local network of any roadwarrior whose own LAN uses that range."

### N23. "The re-address is the expensive, cluster-risky step"
*Reviewer: stage7-style (finding 27)*
**Lines:** 151. "expensive" is unquantified here although Phase 3 carries the actual cost list.
**Fix:** "The re-address touches all 13 hosts plus the live etcd member URLs (see Phase 3)."

### N24. "OPNsense `LAN` NIC → 8-port switch port 1"
*Reviewer: stage7-style (finding 28)*
**Lines:** 198. Unclear whether port 1 is a fact about the current wiring or a proposal.
**Fix:** "connect the OPNsense `LAN` NIC to a chosen uplink port on the living-room switch (port 1 in this document; record the actual port in Phase 0.1)".

### N25. "In Phase 2 the desktop ports become untagged 50"
*Reviewer: stage7-style (finding 30)*
**Lines:** 203–204. "become" hides that someone edits the office rack switch.
**Fix:** "In Phase 2, set the desktop ports on the office rack switch to untagged 50."

### N26. "Nothing tagged `[unverified]` should be acted on before Phase 0 resolves it"
*Reviewer: stage7-style (finding 31)*
**Lines:** 22. Passive, and about the document rather than the reader.
**Fix:** "Do not act on a `[unverified]` claim until Phase 0 confirms it."

### N27. "actually" as an intensifier
*Reviewer: stage7-style (finding 32)*
**Lines:** 105, 305, 322 (and 411, 425 beyond the reviewed range).
**Fix:** delete at 105 ("and what enforces the current IoT/Guest boundary"); rewrite 305 as "Confirm that console access to OPNsense works (monitor and keyboard, or serial) — confirmed working, not assumed"; rewrite 322 as "whether mDNS is in use today".

### N28. "deliberately" carries no information in four places
*Reviewer: stage7-style (finding 33)*
**Lines:** 176 ("Only if iSCSI is deliberately routed"), 178 ("Deliberately unused"), 243 ("Rule 2 is deliberately `RFC1918`"), 334 ("Guest first, deliberately").
**Fix:** 176 → "Only if iSCSI is routed across a router."; 178 → "Unused by design. See the mesh landmine."; 243 → "Rule 2 uses `RFC1918` rather than `LAN_NET`."; 334 → "Guest first: nothing on it needs to be reachable…".

### N29. "trivially visible, trivially reversible"
*Reviewer: stage7-style (finding 34)*
**Lines:** 335. Rhetorical doubling.
**Fix:** "which is visible and reversible".

### N30. "Tag every VLAN on the inter-room trunk from day one. One cable, all VLANs, always."
*Reviewer: stage7-style (finding 35)*
**Lines:** 159. "from day one" and "always" are the same instruction, and "day one" is inconsistent with the phase vocabulary used everywhere else.
**Fix:** "Tag every VLAN on the inter-room trunk in Phase 1. One cable, all VLANs."

### N31. Chiasmus that restates one fact twice
*Reviewer: stage7-style (finding 36)*
**Lines:** 151–152: "doing it first means the cluster risk lands before any security benefit. Doing it last means Phase 1 delivers value before any risk is taken."
**Fix:** "Do the re-address last: Phase 1 delivers the boundary before the cluster-risky step is taken."

### N32. The OPNsense default allow-all warning appears twice in range
*Reviewer: stage7-style (finding 39)*
**Lines:** 220 (an instruction: replace it) and the landmine text adjacent to 310.
**Fix:** keep 220 as the instruction and drop the cautionary restatement.

### N33. "Cheap, and it is the half of …" duplicated
*Reviewer: stage7-style (finding 40)*
**Lines:** 148 and again at 368 (out of range, same wording). "Cheap" is unquantified and "the half of breach containment" is an unclear metaphor.
**Fix at 148:** "Adopted as Phase 2. Changes only the desktop ports on the office rack switch; no NixOS host config changes. It protects the operator's machines from a cluster compromise." **Fix at 368:** delete and cross-reference row B-lite.

### N34. "MQTT traffic stays on HA's docker bridge and never crosses the VLAN"
*Reviewer: stage7-style (finding 42)*
**Lines:** 267. Add-ons run in containers on a Home Assistant container network; "HA's docker bridge" is imprecise and the behaviour depends on add-on configuration that is not marked as checked.
**Fix:** "…are both Home Assistant add-ons, so MQTT stays inside Home Assistant's container network and does not cross the VLAN — `[unverified]`, confirm in Phase 0.3."

### N35. "a listening socket on the z2m port means HA dials out"
*Reviewer: stage7-style (finding 43)*
**Lines:** 273. A certainty drawn from one signal.
**Fix:** "a listening socket on the z2m port indicates Home Assistant is the TCP client; if nothing is listening, treat the coordinator as the client and keep rule 5."

### N36. Success criterion 1 overstates its own scope
*Reviewer: stage7-style (finding 44)*
**Lines:** 37–38 versus 275.
**Fix:** "An IoT device on the IoT SSID cannot reach any host on the legacy segment over a routed path. Same-VLAN traffic is out of scope of the firewall (§7.3)." Also drop "at all" at 38 — "any" already carries it.

### N37. Success criterion 3 is a list of nouns, not a pass condition
*Reviewer: stage7-style (finding 45)*
**Lines:** 40–41: "internet and nothing else — no LAN, no IoT, no cluster, no mesh."
**Fix:** "A guest client gets a `10.60.20.x` lease and internet, and cannot reach any address in `10.0.0.0/8`, `172.16.0.0/12` or `192.168.0.0/16`."

### N38. The Finding B consequence block carries no marker
*Reviewer: stage7-style (finding 47)*
**Lines:** 129–135. The mechanism ("may fall back to untagged") is an inference from `[vendor-doc]` and `[community]` evidence cited two lines above, but it is presented in a bold blockquote with no tag.
**Fix:** append `[unverified]` to the blockquote's last line and let Phase 0.1/0.2 close it, or state explicitly that it is an inference from the two tagged sentences above.

### N39. "Since nixpkgs 26.05 the module parses addresses at eval time"
*Reviewer: stage7-style (finding 48)*
**Lines:** 96. Tagged `[measured]` at the section level (79) but no file or nixpkgs source is named, unlike the neighbouring bullets which name files.
**Fix:** add the module path or the nixpkgs commit the claim was read from.

### N40. Word-level trims (batch)
*Reviewer: stage7-style (section I)*
| Line | Text | Fix |
|---|---|---|
| 25 | "from *apparent* isolation to a real L2/L3 boundary" | "to an L2/L3 boundary enforced by" — "real" is a loaded adjective; "enforced" already does the work |
| 43 | "Every boundary is *tested from a client*, not inferred from a config screen." | Fine; keep. Listed only because it is restated at 139–140 and 275 |
| 116 | "with IPv6 being the part that resists ACLs entirely" | "and IPv6 is the part ACLs do not cover" |
| 146 | "Delivers the stated goal, touches zero NixOS hosts, rules written once." | "No NixOS host changes; the ruleset is written once." |
| 147 | "Deferred to Phase 2/3, and reduced — see B-lite." | "Deferred to Phase 2/3 in reduced form (B-lite)." |
| 149 | "Folded into Phase 1a/1b staging rather than chosen as an endpoint." | "Not chosen; the staging in Phase 1a/1b already sequences Guest first." |
| 208 | "That is a hardware purchase, not a redesign." | Keep — it is a concrete consequence, not filler |
| 306 | "Not "should work" — confirmed." | Merge into line 305 (see N27) |

### N41. Structural weight carried by bold pseudo-headings, invisible to the outline
*Reviewer: stage7-structural (finding 15)*
**Lines:** 35, 153, 180, 187, 234, 246, 275. L139 cross-references "Acceptance criterion 5" by number into a list that lives under the pseudo-heading at 35, so any renumbering is silent.
**Fix:** promote 35 to `### 1.1 Success criteria` (and retitle 139 to cite `§1.1 item 5`); leave the "Why …" pseudo-headings as prose.

### N42. Asymmetric wording on the two parallel rule tables
*Reviewer: stage7-structural (finding 16)*
**Lines:** 234 (`**Interface \`GUEST\` (VLAN 20), evaluated top to bottom:**`) versus 246 (`**Interface \`IOT\` (VLAN 10):**`). Rule order is load-bearing for IOT too (asserted at 259).
**Fix:** use the same "evaluated top to bottom" suffix on both.

### N43. Empty table cells where the column contract expects a value
*Reviewer: stage7-structural (finding 17)*
**Lines:** 230 (`RFC1918` Source cell empty), 250 (IOT rule 1 Why cell empty), 253 (rule 4 Why cell empty).
**Fix:** fill, or use `—` consistently; the document already uses `—` at 178.

### N44. Prose pointer that matches no heading
*Reviewer: stage7-structural (finding 19)*
**Lines:** 178 "See the mesh landmine." — the §9 lead-in text is "The management VLAN breaks mesh" (430) and is not a heading. Same root cause as B3.
**Fix:** promote 430 to `### 9.1` and cite `§9.1`.

### N45. §7.6 title does not match its content
*Reviewer: stage7-structural (finding 20)*
**Lines:** 300 `### 7.6 Break-glass`. Four of five lines are a pre-change checklist; only 307–308 (never remove untagged native-1) is an actual break-glass path.
**Fix:** `### 7.6 Pre-change safety checklist and break-glass path`.

### N46. Deictic table reference
*Reviewer: stage7-structural (finding 21)*
**Lines:** 213 "with the addresses from the table, `/24`" — the table is two sections up.
**Fix:** "from the §6 table".

### N47. Three cross-reference conventions in one document
*Reviewer: stage7-structural (finding 22)*
**Lines:** markdown anchors (9, 51, 54, 58), bare section signs (322 `Finding B, §7.1`, 327 `§7.6`), and prose names (139, 178). The sibling spec uses `§N` throughout.
**Fix:** pick `§N` for body text and reserve markdown anchors for the front matter.

### N48. §3.1 diagram has three broken structural joins
*Reviewer: stage7-structural (finding 23)*
**Lines:** fenced block 64–77.
- The OFFICE tree has no drawn root: `rack switch (model unknown)` (66) is a column header, yet its children (67–72) hang from `├─` with an empty parent column.
- The inter-room link is drawn at 69 (`└─────────├─`) but labelled one line below at 70 (`[inter-room cable]`), so the label is detached from the line it names.
- The living-room branch closes at 68 (`└─ LAN …`), so `EAP610 (wired)` at 69 hangs off an already-closed branch.
- `[unverified]` at 69 is inert inside a code fence and cannot be grepped as a marker.

**Fix:** give the OFFICE tree a root line (`rack switch (model unknown)` with `├─` beneath), move the `[inter-room cable]` label onto the drawing line, add a `│` continuation column, and move the `.6 [unverified]` marker into §3.3's unknown list.

### N49. §7.5 table's SSID column holds a description
*Reviewer: stage7-structural (finding 24)*
**Lines:** 293 `| existing trusted | 1 (untagged) | all | unchanged |`. The trusted SSID's actual name appears nowhere in the document and is not listed among §3.3's unknowns (101–106).
**Fix:** `| <trusted SSID name — Phase 0> |` and add it to §3.3.

### N50. §11 Likelihood column has no defined scale
*Reviewer: stage7-structural (finding 25)*
**Lines:** 469–478; `certain` (478) is not on the same scale as `medium`/`low`, and no scale is defined anywhere.
**Fix:** add a one-line scale key (`low = <20%`, `medium`, `high`, `certain = observed`) or change 478's Likelihood to `—` with "accepted risk" in Mitigation.

### N51. One §10 row bundles three independent pass conditions
*Reviewer: stage7-structural (finding 26)*
**Lines:** 465 (roadwarrior reaches `6443` **and** reaches the rack **and** gains no route to `10.60.10.0/24`/`10.60.20.0/24`).
**Fix:** split into three rows so each has one observable outcome.

### N52. §5 Verdict column mixes verdict types and forward-references a lower row
*Reviewer: stage7-structural (finding 27)*
**Lines:** 146–151: `Adopted`, `Deferred … see B-lite` (147 pointing at 148), `Folded into`, `Rejected on physics`, `Rejected as an order`.
**Fix:** split into `Verdict` (adopted / rejected / deferred) and `Rationale`, and move B-lite above B or reorder so verdicts never point downward.

### N53. No table of contents, and §12–§14 have no ordering principle
*Reviewer: stage7-structural (finding 28)*
**Lines:** whole document — 513 lines, 14 H2 + 17 H3, with the reader shuttling between §7 and §8 on every rule. §12 (config as code), §13 (deferred seams) and §14 (out of scope) sit after §11 in an order that follows neither execution nor dependency.
**Fix:** add a TOC after the markers block and group as scope (§2, §14) → design (§5–§7) → execution (§8, §10) → risk (§9, §11) → deferred (§12, §13).

### N54. Marker/value style inconsistency inside the alias table
*Reviewer: stage7-structural (finding 18)*
**Lines:** 231 `*Phase 0*` (italic) versus 232 `Phase 0` (plain) in the same Source column; 231's Value cell holds a phase reference rather than a value, unlike every other row.
**Fix:** `Value = unknown until Phase 0.3`, `Source = Phase 0.3`.
