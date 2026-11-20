## Paraphrase of the design (FeatureRange)

The document proposes replacing today's *apparent* IoT/Guest isolation with a real boundary: two new 802.1Q VLANs — IoT (VLAN 10, `10.60.10.0/24`) and Guest (VLAN 20, `10.60.20.0/24`) — created as interfaces on the OPNsense router, which becomes the only routed path in or out of those segments, with an explicit per-interface firewall ruleset replacing OPNsense's default allow-all (Guest: DNS/DHCP to the firewall only, block everything inside RFC1918, allow internet, never accept inbound; IoT: block the LAN, the WireGuard mesh and Guest, allow internet, and allow exactly one trusted initiator, Home Assistant, to start connections into IoT). The trusted LAN stays untagged on native VLAN 1 at `192.168.0.0/24` so that no NixOS host changes address in Phase 1, while the final VLAN IDs and subnets for future segments (servers 30, storage 40, users 50) are reserved now and every VLAN is tagged on the single inter-room trunk from day one, so later phases never re-do earlier ones. Two findings shape the whole shape: the existing Omada "guest isolation" may only isolate clients on the same access point, and an Omada AP that cannot tag a VLAN may emit those frames untagged onto the native VLAN — i.e. onto the trusted LAN — so the IoT and Guest SSIDs are enabled only on the two wired APs, a management VLAN is rejected outright, and every phase ends with a test performed from a client rather than a screenshot. Desktops move to VLAN 50 in Phase 2; moving the legacy LAN off `192.168.0.0/24` is deliberately last, in Phase 3, because that is the step that touches etcd, k3s certificates and every hardcoded address in the fleet.

## Paraphrase of the plan (DetailedRange)

Phase 0 changes nothing and produces the missing facts: the two switch models and whether they do 802.1Q, Home Assistant's IP, the Zigbee coordinator's socket direction, an authoritative static-IP map, and a client-side proof of what actually enforces the current boundary today. Phase 1a does Guest first because nothing on it needs to be reachable: create VLAN 20 with its interface, address, DHCP and DNS on OPNsense, install the Guest ruleset before the SSID exists, tag VLAN 20 on the inter-room trunk at both ends, create `home-guest` on the two wired APs only, test from a client at each AP location, and only then retire the old guest SSID; rollback is "disable the new SSID, re-enable the old one". Phase 1b does the same for IoT with three extra steps: reserve the Zigbee coordinator's address below the DHCP pool, repoint zigbee2mqtt's `serial.port` at it, and migrate devices in batches while re-checking Home Assistant control after each batch. Phase 2 moves the desktops to VLAN 50 and adds users↔LAN rules. Phase 3 moves the fleet off `192.168.0.0/24`, lists the repo-wide blast radius, offers a live etcd IP migration versus a rebuild-from-backup, refuses to be scheduled until an etcd snapshot and a Longhorn backup have actually been restored, and §8.1 says it must become its own spec. The rest of the range is landmines, an acceptance table, a risk table, an admission that OPNsense and Omada config has no repo and therefore no diff or rollback, deferred seams, and an out-of-scope list.

---

## Findings

### 1. Firewall rule 5 is shadowed by rule 2 — the document's own evaluation order kills it
**Severity:** Blocker
**Affected Scope:** §7.3 IOT table, lines 246–255; the order claim at 259–260; the note at 264–266.
**Discrepancy:** The GUEST table is labelled "evaluated top to bottom" (line 236) and line 260 states "the order is load-bearing", so the reader applies top-to-bottom evaluation to the IOT table too. Rule 2 blocks `IOT → LAN_NET` (line 251). `HA_SERVER` is on the legacy LAN (§3.1 line 70, §3.3 line 104), so rule 5's flow `ZIGBEE_COORD → HA_SERVER:<port>` (line 254) matches rule 2 first and is **never reached**. The note at 264–266 compares rule 5 only to rule 7 ("narrower than rule 7 in both directions"), which is the wrong neighbour and actively misdirects the reader. **Fix:** move rule 5 above rule 2, renumber, and add one sentence: "Rule 5 must precede the `IOT → LAN_NET` block, because a block rule that matches the same source and destination shadows it."

### 2. The Phase 0.4 diagnostic is stated backwards
**Severity:** Blocker
**Affected Scope:** line 273 ("a listening socket on the z2m port means HA dials out"), with Phase 0.4 at line 323.
**Discrepancy:** If Home Assistant has a *listening* socket on the z2m port, then the coordinator is the party that connects to HA — i.e. the coordinator is the TCP client and rule 5 **is** needed. A listening socket on HA means HA is being dialed, not dialing out. As written, an implementer who runs the check gets the correct observation and then draws the opposite conclusion, producing exactly the silent Zigbee failure that line 452–453 warns about. **Fix:** replace with "a listening socket on the z2m port **on HA** means the coordinator connects to HA, so rule 5 is required; no listening socket on HA plus an established connection from HA to the coordinator's address means HA dials out and rule 5 is not needed."

### 3. `GUEST_NET` is used in a firewall rule and never defined
**Severity:** Blocker
**Affected Scope:** alias table lines 226–232; rule 4 at line 253.
**Discrepancy:** The alias table defines `LAN_NET`, `MESH_NET`, `RFC1918`, `HA_SERVER`, `ZIGBEE_COORD`. Rule 4 references `GUEST_NET`, which appears nowhere else in the document. The reader must guess that it means `10.60.20.0/24`. **Fix:** add `| GUEST_NET | 10.60.20.0/24 | §6 |` to the alias table.

### 4. `<z2m port>` is never given a number
**Severity:** Blocker
**Affected Scope:** lines 254, 271, 323.
**Discrepancy:** Rule 5 is specified as `HA_SERVER:<z2m port>` three times and the port is never named, so the rule cannot be written. The document elsewhere insists on concrete values (`.100`–`.200`, `:8123`, `:9000`, `:3260`). **Fix:** state the port (zigbee2mqtt's default socket port) or state explicitly "Phase 0.4 records the port; the rule uses that value" and add the port to Phase 0.4's "Resolves" column.

### 5. The scope line asserts two managed switches; §3.3, §7.1, Phase 0 and §11 say that is unknown
**Severity:** Blocker
**Affected Scope:** lines 5–6 vs lines 103, 207–208, 320–321, 471.
**Discrepancy:** Line 5 says "Scope: OPNsense, two managed switches". Line 103 lists "the two switch models and their 802.1Q support" as unknown, line 207 says "If the rack switch turns out to be unmanaged", line 321 asks whether the 8-port switch even supports 802.1Q, and line 471 rates "Rack switch is unmanaged" as medium likelihood. The diagram at line 69 also labels the living-room device "8-port managed switch" while Phase 0.1 questions it. A first-time reader cannot tell whether the plan's premise is established. **Fix:** change line 5 to "two switches (management capability unconfirmed — see Phase 0.1/0.2)" and change the diagram label to "8-port switch (managed?)".

### 6. Success criterion 1 contradicts rule 5
**Severity:** Blocker
**Affected Scope:** lines 37–38 vs lines 254, 270–272.
**Discrepancy:** Criterion 1 says an IoT device "cannot initiate any connection to the LAN at all". Rule 5, in the fallback case, is precisely an IoT-initiated connection to a LAN host. The two statements cannot both be true and the document never reconciles them. **Fix:** qualify criterion 1: "…cannot initiate any connection to the LAN at all, except the single Phase 0.4-determined coordinator flow in rule 5, if that flow is required."

### 7. No `[vendor-doc]` or `[community]` claim has a citation
**Severity:** Major
**Affected Scope:** marker table lines 15–21; claims at 110–121, 127–128, 277, 284, 430–434, 442.
**Discrepancy:** The marker table promises provenance ("TP-Link / Omada official documentation", "TP-Link community forum or Reddit report"), but not one of those claims carries a title, URL or even a rough date. The two load-bearing claims — that mesh EAPs inherit uplink VLAN settings (line 127) and that mesh adoption fails under a management VLAN (line 128–129) — decide the rejection of a management VLAN (§2 line 49–51, §9 line 430–436) and cannot be checked. **Fix:** add a short "Sources" list at the end and link each `[vendor-doc]`/`[community]` claim to it, or downgrade the marker to "recalled, source not recorded" so the reader knows it is not checkable.

### 8. There is no glossary, and project-specific systems are named as if known
**Severity:** Major
**Affected Scope:** lines 27, 47, 82–100, 219, 266–268, 324, 392–397, 403, 407, 465, 483–487, 497.
**Discrepancy:** The following are used with no definition, no inline gloss and no link: `comin` and the "comin health gate" (98, 444, 465, 483) — what it is, where it runs, and what "rolls the host back" concretely does; `SOPS` (82); `Longhorn` (27, 47, 407, 416); `titan` (91, 395, 512) — a host that does not appear in the §3.1 diagram at all; `k8s-casa` (7, 396) — a second repo with no link; `DNS2` (93) and "the registry" (219, 324) — neither is explained; "the coder helper" (95) and `coderHost` / `pi.baseUrl` (97); "the skew rule already in `AGENTS.md`" (403) — an unlinked repo file whose content the reader must already know; `Flux` (407); "bind zone `casa.arrieta` resolution" (397) — why a rollout script resolves a DNS zone is never stated; `split-horizon` (392); `configd` and the "terraform-provider path" (487); `z2m` used at 254 before zigbee2mqtt is named at 266; "CEP wireless bridge" (76) — never expanded, and the difference between CEP bridging and mesh backhaul is exactly why the garage AP is excluded, so it is not a detail. **Fix:** add a 10-line glossary table (term → one sentence → owner doc/path) covering the project-specific names, and add the missing link for `AGENTS.md` and `k8s-casa`.

### 9. General networking vocabulary is used with no gloss for a non-networking reader
**Severity:** Major
**Affected Scope:** 802.1Q (26, 103, 162, 320); trunk (159, 198–202, 308, 340, 357); native VLAN (133, 172, 437, 442); SNAT (91, 395); stateful firewall (260); SLAAC and router advertisement (284, 507); iSCSI (94, 98, 176, 391, 416); VXLAN and kubelet (47); etcd peer URL vs client URL (389, 402); certificate SAN (390); PoE (162, 321); VIP (87); CIDR (395); captive portal (56, 511); jumbo frames (416); YAGNI (56); SSDP (51, 497); Avahi (497); DHCP reservation (216, 232); prefix delegation implied by "delegate an IPv6 prefix" (282).
**Discrepancy:** None of these is defined or linked, and several are load-bearing rather than decorative: the whole "fails open" argument depends on the reader knowing what *native VLAN* and *untagged* mean (133); the Phase 2 aside at 373–374 depends on the reader knowing what `forwardToLan` SNAT does and what "the mesh advertises `LAN_NET` only" costs a roadwarrior; the Phase 3 recommendation at 414–418 depends on knowing what jumbo frames are and why routing removes them. **Fix:** the same glossary table, one line per term, plus one sentence at 373–374 spelling out the consequence ("roadwarriors would no longer reach desktops on VLAN 50 unless the tunnel advertises it").

### 10. Port numbers appear without saying which service they belong to
**Severity:** Major
**Affected Scope:** lines 325, 461 ("a node's `9100`", "`HA:8123`"), lines 500–502 (`6443`, `10250`, `2379`, `2380`, `2381`).
**Discrepancy:** §13's port list is unlabelled, so a reader who does not already know that 10250 is the kubelet and 2379/2380 are etcd client/peer cannot evaluate the proposed allow-list or notice that 2381 was already discussed at line 89–90. **Fix:** annotate each port inline: `6443 (k3s API)`, `10250 (kubelet)`, `2379/2380 (etcd client/peer)`, `2381 (etcd metrics)`, and `9100 (node_exporter)` at 325/461.

### 11. VLAN 1 is "Retired in Phase 3" but is also the break-glass path and where the NAS stays
**Severity:** Major
**Affected Scope:** line 172 vs lines 308, 414–416.
**Discrepancy:** The VLAN table says VLAN 1 is "Retired in Phase 3". §7.6 says never remove untagged native-1 membership because it is the path back into OPNsense, and the Phase 3 recommended scope leaves the NAS "on the flat segment it is on". So native VLAN 1 survives Phase 3. **Fix:** change the note at 172 to "Re-addressed in Phase 3; remains the untagged native VLAN and the break-glass path (§7.6)."

### 12. §14's titan scope contradicts the Phase 3 table
**Severity:** Major
**Affected Scope:** lines 510–512 vs line 395.
**Discrepancy:** Out of scope says "any change to `titan` beyond the `wireguard.lanSubnet` value in Phase 3", but line 395 lists `wireguard.forwardToLan` SNAT, `modules/nixos/public-host.nix` LAN allow-list and `hosts/titan/configuration.nix` as Phase 3 items — and §3.2 line 33–34 already flags `forwardToLan = true` on titan as the cause of the roadwarrior problem. **Fix:** either widen line 512 to "the WireGuard LAN/CIDR settings on titan" or drop the extra titan rows from line 395.

### 13. §10 tests only Phases 1a and 1b, while criterion 5 promises every boundary is tested
**Severity:** Major
**Affected Scope:** line 41 vs table at 457–467.
**Discrepancy:** There is no acceptance row for Phase 2 (desktops on VLAN 50) or Phase 3, and Phase 2 introduces a new boundary in both directions (line 372–374). Criterion 5 says "Every boundary is *tested from a client*". **Fix:** add a Phase 2 row (`users` client gets `10.60.50.x`, reaches node SSH and the cluster API, is unreachable from `LAN_NET` inbound) or state explicitly that Phase 2's acceptance lives in its own future spec.

### 14. Phase 1b step 5 breaks Zigbee before the coordinator has moved
**Severity:** Major
**Affected Scope:** lines 356–361 (steps 1–7), rollback claim at 364.
**Discrepancy:** Step 5 repoints z2m's `serial.port` at the reserved VLAN 10 address, but the coordinator itself only moves when devices are moved in step 7. Between step 5 and the coordinator's move, z2m points at an address the coordinator is not using, so Zigbee is down for the whole migration window — which contradicts success criterion 2 (line 39) and the rollback claim at 364 that this is "one field". **Fix:** reorder so that step 5 happens immediately after the coordinator itself is moved onto VLAN 10, and say so: "move the coordinator, then repoint z2m, in the same window."

### 15. Trunk tagging: "all VLANs from day one" versus one VLAN per phase
**Severity:** Major
**Affected Scope:** lines 159–161, 200–201 vs lines 340, 357; risk at 441–444.
**Discrepancy:** Forward-compatibility rule 2 and §7.1 both say tag the whole set `{10,20,30,40,50}` on the inter-room trunk from day one. Phase 1a step 3 tags only VLAN 20 and Phase 1b step 4 tags "VLAN 10 on the trunks" — two separate live-trunk edits, and §9 line 441–444 says each such edit is an outage on the only inter-room link. The plan as written does the risky operation twice and contradicts the rule that was written to avoid exactly that. **Fix:** make Phase 1a step 3 "apply the full tag set `{10,20,30,40,50}` to the inter-room trunk at both ends, in one scheduled change", and delete Phase 1b step 4 or reduce it to a verification.

### 16. "Each phase is independently valuable and independently reversible" is not true of Phase 3
**Severity:** Major
**Affected Scope:** line 314 vs lines 378–426.
**Discrepancy:** Phases 1a, 1b and 2 each carry a **Rollback:** line (347, 364, 376). Phase 3 has none, its rebuild option is explicitly a one-way door with "a real outage window" (408), and §8.1 defers it to a separate spec that has not been costed. The blanket claim at 314 reads as a promise the document then does not keep. **Fix:** scope line 314 to "Phases 0–2 are independently valuable and independently reversible; Phase 3 is a cluster migration and is not reversible without a restore (§8.1)."

### 17. The Omada controller is an unstated prerequisite for Phase 1
**Severity:** Major
**Affected Scope:** lines 341–343, 359 (SSID creation), 328 (Phase 0.8), 430–436, 511.
**Discrepancy:** Phases 1a step 4 and 1b step 6 create SSIDs, which requires a reachable Omada controller — yet Phase 0.8 says the document does not know where the controller runs (hardware, software or cloud), and §9's landmine is about controller adoption behaviour. A reader who does not know that SSIDs are pushed by a controller has no idea who performs step 4, and the rollback at 347 ("re-enable the old one") also depends on that controller being available. **Fix:** add one sentence to Phase 1a: "Steps 4–6 are performed in the Omada controller UI; Phase 0.8 must establish where it runs and that it is reachable before Phase 1 starts."

### 18. "The old guest SSID" and "the old SSID" are never named or confirmed to exist
**Severity:** Major
**Affected Scope:** lines 345, 347, 364; §7.5 table 291–295.
**Discrepancy:** §7.5 lists three SSIDs: "existing trusted", `home-iot`, `home-guest`. Phase 1a step 6 says "disable the old guest SSID" and Phase 1b's rollback says "move devices back to the old SSID", but no current IoT or Guest SSID name appears anywhere, and Finding A explicitly says it is unknown what the current boundary is. **Fix:** add the current SSID names to §3.3 and Phase 0 (a "list every SSID currently broadcast, per AP" item), and reference them by name in the rollback lines.

### 19. Phase 2's ruleset is not a decision
**Severity:** Major
**Affected Scope:** lines 372–374.
**Discrepancy:** "`users → LAN_NET` allow only what is needed (SSH to nodes, the cluster API)" leaves the actual ports, and whether "the cluster API" means the k3s API on the nodes or the API server endpoint, to the implementer. The document is otherwise exact about ports. **Fix:** write the concrete rules, e.g. `users → LAN_NET:22` and `users → 192.168.0.11:6443`, and state what is deliberately not allowed.

### 20. Claims that need an evidence marker have none
**Severity:** Major
**Affected Scope:** lines 187–188 ("They are never advertised into the WireGuard tunnel"), 260 ("The firewall is stateful"), 266–268 ("MQTT traffic … never crosses the VLAN"), 373–374 ("the mesh advertises `LAN_NET` only"), 416–417 ("Routing Longhorn's iSCSI across a router removes jumbo frames and adds latency"), 442 ("On some switches, changing the native VLAN … drops everything crossing it"), 31–34 (the `[measured]` tag covers two config values, but the stated *consequence* — roadwarriors lose their own local network — is an inference).
**Discrepancy:** The marker convention at 11–14 says every non-trivial claim is tagged; these are non-trivial, load-bearing and untagged, so a reader cannot tell which are read from the repo, which are OPNsense behaviour, and which are recollection. The MQTT claim at 266–268 is the one that removes the need for a wider hole and is stated as fact while §3.3 line 104 admits the Zigbee setup is unknown. **Fix:** tag each — `[measured]` for the WireGuard advertisement and mesh-advertisement claims (cite the option and file), `[vendor-doc]` for OPNsense keep-state and the native-VLAN trunk behaviour, `[unverified]` for the MQTT/docker-bridge claim so Phase 0 can close it.

### 21. The mDNS "deferred seam" is not as additive as claimed
**Severity:** Major
**Affected Scope:** lines 51–55 and 496–498 vs rule 8 at line 258.
**Discrepancy:** Both places say mDNS reflection can be turned on later "without touching a single VLAN assignment". That is true of VLAN assignment, but an Avahi reflector on OPNsense originates new traffic *into* IoT, which IOT rule 8 (`any → IOT` block + log) will drop, and reflection into the trusted LAN would need the trusted side to accept it too. A reader who takes "additive" at face value will add the reflector and then debug a firewall block. **Fix:** say what must change: "requires one firewall exception from the OPNsense firewall into each reflected VLAN; no VLAN assignment changes."

### 22. The acceptance row for mesh APs permits the outcome Finding B forbids
**Severity:** Major
**Affected Scope:** line 463 vs lines 135–139, 435–439.
**Discrepancy:** The pass condition is "IoT and Guest SSIDs not broadcast there, **or proven tagged**". Finding B's conclusion is that IoT/Guest must not be enabled on those APs at all until individually tested, because tags may not survive a mesh backhaul. "Proven tagged" reintroduces the exact unprovable assumption. **Fix:** delete "or proven tagged"; the pass condition is "not broadcast on kitchen, entrance or garage".

### 23. Three of the four internal links do not resolve
**Severity:** Major
**Affected Scope:** lines 9, 51, 58 (and 54, which does resolve).
**Discrepancy:** `#12-config-as-code-an-open-gap` does not match the heading "## 12. Config as code — an open gap" (line 480, whose slug contains a double hyphen at the em dash); `#landmine-the-management-vlan-breaks-mesh` points at a bold sentence (line 430), not a heading, so there is no target at all; `#ipv6-policy` does not match "### 7.4 IPv6 policy" (line 281, slug `74-ipv6-policy`). Each broken link is a reader being sent to a definition they then cannot reach. **Fix:** make line 430 a real heading (e.g. `### 9.1 The management VLAN breaks mesh`) and point line 51 at it; correct the other two slugs. (Overlaps the structural lane; reported here because the consequence is a missing definition.)

### 24. Sections that need a later section to be understood the first time
**Severity:** Nit
**Affected Scope:** lines 27 and 47 (Longhorn, etcd, kubelet, flannel VXLAN used before §3.2 describes the cluster and storage); line 51 (points at the mesh landmine, argued in §4 and §9); line 147 ("an etcd and k3s certificate event", explained only at 389–390); line 172 ("Retired in Phase 3") and line 176 ("Only if iSCSI is deliberately routed"), both explained only at 414–418; line 254 ("see note", the note is at 264–273); line 104 ("socket mode") defined only at 269–273; line 216 ("the Zigbee coordinator above all") with the coordinator's role unexplained until 266–273.
**Discrepancy:** Each is a forward reference a fresh reader must carry unresolved. **Fix:** add short "(see §…)" pointers at each site; for line 47 add a half-sentence naming what each component is ("etcd (cluster database), kubelet (node agent), flannel VXLAN (pod overlay), Longhorn (block storage)").

### 25. Terminology drift that forces the reader to infer an equation
**Severity:** Nit
**Affected Scope:** "trusted LAN" (29, 37, 133, 146, 286, 298, 347, 438), "legacy LAN" (168, 172, 190), "native 1" (172, 199, 205, 308), `LAN_NET` (228, 251, 372), "existing trusted" SSID (293); also "rack switch" (66, 200, 205, 321, 443) vs "office switch" (162, 207) vs "8-port switch"/"8-port managed switch" (69, 198, 320); "socket direction" (323) vs "socket mode" (104); "inbound" meaning "into a VLAN" at 240/258 but "from IoT toward the LAN" at 475.
**Discrepancy:** The document never states that trusted LAN = legacy LAN = native VLAN 1 = `LAN_NET` = the "existing trusted" SSID's network, and never states that rack switch and office switch are the same device. A fresh reader must infer both equations and can plausibly infer wrongly. **Fix:** one sentence in §6: "Trusted LAN, legacy LAN and `LAN_NET` all mean untagged VLAN 1 on `192.168.0.0/24`; 'rack switch' and 'office switch' are the same device."

### 26. Small ambiguities that cost a reader time
**Severity:** Nit
**Affected Scope:** line 212 "`opt10` → `IOT`" (which is the auto-assigned name and which is the description is not stated); line 213 "the addresses from the table" (say "§6"); lines 180–186 shorthand `192.168.0/24`, `10.0.0/24`, `10.10/16` is malformed CIDR, and `172.17.0.0/16` is listed separately although it is inside `172.16.0.0/12`; line 137 "Acceptance criterion 5" refers to §1's list while §10 is the section titled "Testing and acceptance"; line 388 "all 13 hosts" cannot be reconciled with the §3.1 diagram; line 323 `ss -ltnp` vs line 272 `sockstat`/`ss` (`sockstat` is the FreeBSD tool; say which applies to the HA install); line 340 step 2 claims rules before the SSID means "there is never an unfiltered window" although §9 line 445–446 says a new interface passes everything from creation — the window exists between steps 1 and 2 and is harmless only because no client can join yet, which is the actual reason; line 175 "Only if the control plane moves" gives no reason why it would; line 146 "rules written once" vs Phase 2 line 372 "Add to the ruleset"; lines 74–75 "wireless mesh off a wired parent" does not say *which* wired AP is the parent, which matters for §9 line 434; line 84 "the module parses addresses at eval time" does not name the module or say why it matters here; line 91 "hub on `titan`" names a host absent from the §3.1 diagram.
**Fix:** mechanical edits as sketched above.