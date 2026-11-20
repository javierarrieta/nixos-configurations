# Consolidated Review Report

**Target:** `docs/superpowers/specs/2026-11-17-lan-vlan-segregation-design.md` (513 lines)
**Inputs merged:** `critic_report.md` (stage 7: design, structural, style), `implementation_readiness_report.md` (stage 9: impl, codebase, style), `zoom_out_report.md`, `comprehension_report.md`, `intermediate_zoom_out_report.md` (stage 8: fix-set audit).
**Consolidated counts:** 22 Blockers, 78 Majors, 53 Nits.

The document is an implementation plan for replacing Omada's apparent IoT/Guest isolation with two 802.1Q VLANs (IoT 10 / `10.60.10.0/24`, Guest 20 / `10.60.20.0/24`) terminated on OPNsense, staged as Phase 0 inventory, Phase 1a Guest, Phase 1b IoT, Phase 2 desktops, Phase 3 fleet re-address. The design core — two VLANs, two DHCP scopes, twelve firewall rules, no new code — survives every reviewer, but the document is not executable as written: the IOT ruleset is wrong in two independent ways that both fail silently, the Phase 3 blast-radius table is factually wrong against the repository in at least nine rows, and most Phase 0/1 steps name a pass condition without naming the command or screen that produces it. The correct response is to fix the blockers and then cut: naive application of all five reviews would grow the document from 513 lines to roughly 700.

Reviewer short names used below: `s7-design`, `s7-struct`, `s7-style`, `s9-impl`, `s9-code`, `s9-style`, `zoom`, `compre`, `s8-audit`.

---

## Blockers

Ordered so that items which make the design silently wrong come first, then items that make the plan unexecutable, then items that make it untrustworthy as a reference.

### B-01. IOT rule 5 is shadowed by rule 2, and rule 5 contradicts success criterion 1
**Lines:** 246–257 (IOT table), 251, 254, 259–263; 37–38; also 234, 256, 257.
**Problem.** The GUEST table is labelled "evaluated top to bottom" (234) and 259–260 says the order is load-bearing, so an implementer enters the IOT rules in printed order. Rule 2 blocks `IOT → LAN_NET` (251); `HA_SERVER` is inside `LAN_NET`, so rule 5 (`ZIGBEE_COORD → HA_SERVER:<port>`, 254) never matches. The case rule 5 exists for is the case that silently fails. Independently, if rule 5 does pass, an IoT-initiated connection into the trusted LAN exists, which falsifies criterion 1 ("cannot initiate any connection to the LAN at all", 37–38) and falsifies the spine paragraph (261–262). Rule 5's note compares it only to rule 7 (265–266) — the wrong neighbour. Rule 7/8 wording ("the one trusted initiator", 256; "nothing else may initiate", 257) ignores rule 5.
**Fix.** (a) Add "evaluated top to bottom" above the IOT table. (b) Renumber so the conditional allow sits above the block: 1 firewall DNS/DHCP, 2 `ZIGBEE_COORD → HA_SERVER:<port>` allow (conditional), 3 `IOT → LAN_NET` block+log, 4 `IOT → MESH_NET`, 5 `IOT → GUEST_NET`, 6 `IOT → any`, 7 `HA_SERVER → IOT`, 8 `any → IOT`. (c) Reword criterion 1 to "cannot initiate a connection to any trusted-LAN host, except the single documented Zigbee flow if Phase 0.4 requires it". (d) Rule 7 Why → "the only trusted initiator from the LAN"; rule 8 Why → "no other source may open a session into IoT (rule 5 is the only exception)". See disagreement D-1 for the alternative fix (delete rule 5).
**Sources:** s7-design B1; s7-style M31, N36; compre #1, #6; zoom Blocker 1 (partial).

### B-02. IOT rule 2 uses `LAN_NET`, so IoT reaches every private range Phase 2 and Phase 3 create
**Lines:** 250/251 (IOT rule 2), 240 and 243–245 (GUEST rationale), 254/255 (rule 6 `IOT → any`).
**Problem.** The document justifies `RFC1918` for Guest with the argument that it "cannot go stale when Phase 2 and 3 create new ranges" (244–245) and does not apply that argument to IoT. Once Phase 2 puts desktops on `10.60.50.0/24` and Phase 3 creates VLAN 30/40, IoT can reach all of them, because rule 6 allows `IOT → any`. Phase 2's stated purpose — protect the operator's machines from a cluster compromise (370) — is defeated by a Phase 1 rule nobody will remember to edit. The Phase 3 change list has no firewall row, so nothing prompts the edit.
**Fix.** Change IOT rule 2 to `IOT → RFC1918 block + log`, with the HA exception placed above it (mirroring GUEST's structure). Add a Phase 3 row: "firewall aliases and rules — `LAN_NET` value, IOT and GUEST rulesets re-verified against the new ranges".
**Sources:** zoom Blocker 1; s9-impl M25; s7-style M34 (rationale wording).

### B-03. The Phase 3 blast-radius table is wrong against the repository in at least nine rows
**Lines:** 387–397; also 81–84, 85–86, 93, 95–96, 324.
**Problem.** Verified against the repo:
- 387 "all 13 hosts" get their address from `secrets.yaml#<host>/network_env`. Only nine do. `titan`'s lives in `secrets/titan.yaml`. `k8s-pi01/02/03` and `k8s-node04` hold build-time literals in `vars.nix` (`modules/nixos/static-network.nix:8–12` skips the SOPS runtime layer when values are not `$`-prefixed). `llm01` is NetworkManager-managed and has no `network_env`. An implementer who re-keys `network_env` leaves four hosts on the old range with no error.
- 388 `k3s.serverAddr` is not one literal: `k8s-server01` and `k8s-server03` use `https://192.168.0.12:6443`; `k8s-server02` and the agents use `.11`. Grepping `.11` leaves two control-plane members stale. Same error at 85–86.
- 391 `common/etcd-snapshot-s3.nix` mentions `.6` only in a comment; the live flag is a hostname. Missing: `pkgs/coder-iscsi-helper/helper.py:45,72` (two hardcoded `.6` defaults).
- 392 `modules/nixos/mesh-dns.nix` holds only an `example`; the live split-horizon data is `hosts/titan/configuration.nix:433–436`, and the `casa.arrieta.` half is never named anywhere in the spec.
- 394 `modules/nixos/ssh.nix` holds only an `example`; the real `.29` sites are `home/hosts/coder-workspace-titan/userOptions.nix` and `modules/home-manager/dev-tools.nix:146` (a module-level default).
- 395 names `public-host.nix` instead of the live value at `hosts/titan/configuration.nix:329`, and never names the WireGuard OPNsense peer `allowedIPs` (`hosts/titan/configuration.nix:205`) — the one edit that actually moves the route.
- Missing entirely: `hosts/titan/configuration.nix:528` `networking.hosts` pin of `s3.l.arrieta.eu` to `192.168.0.42`; `AGENTS.md` (runbook examples, routewatch commands, and a k3s snippet at `:452` already stale in both option name and address).
**Fix.** Either correct every row per the above (split 387 into three rows: nine SOPS hosts, four build-time-literal hosts, `llm01`), or delete the table and replace it with the instruction to run a fresh `grep -rn '192\.168\.0\.'` at planning time. See disagreement D-2.
**Sources:** s9-code B3, B4, M2, M4, M5, M6, M7, M10; zoom Blocker 2.

### B-04. The comin `iscsi` gate cannot see Longhorn; the VLAN 40 recommendation rests on a check that does not exist
**Lines:** 97–98, 415–418.
**Problem.** `modules/nixos/comin-health-gate.nix:114–146` runs `iscsiadm -m node`, a read of the host's local node DB. It contacts no portal and performs no I/O; exit 21 is treated healthy; the module's own comment at `:102–107` states that Longhorn is invisible to this check. A routing change that breaks the path to the portal yields exit 0 or 21 and nothing rolls back. Scope is also wrong: the check runs only where `openiscsi.enable` and `iscsi` is in `healthGate.checks` — not on `titan`, not on `llm01` — so "on every deploy" is false on two hosts. The Phase 3 recommendation that VLAN 40 stays reserved is justified by this non-existent safety net. Separately, 416–418 states that routing "removes jumbo frames"; MTU is a path property, not something routing deletes.
**Fix.** Rewrite 97–98 to say the gate reads only the local node DB, treats an empty DB as healthy, cannot detect a degraded portal path, and does not run on `titan` or `llm01`. Restate the Phase 3 recommendation on its own merits: routing iSCSI requires MTU ≥ 9000 end to end or Longhorn fragments or drops, and nothing in the current toolchain would detect it — so Phase 3 must carry its own per-node Longhorn attach-and-IO verification step. Add `[unverified]` on whether OPNsense and both switches support MTU 9000 on a VLAN interface.
**Sources:** s9-code B1, M12 (partial), M26; s9-style B1(finding 36).

### B-05. etcd `2381/metrics` is not bound to `0.0.0.0`; the spec conflates it with the authenticated control-plane bind
**Lines:** 88–89, 501.
**Problem.** `hosts/k8s-server01/vars.nix:36` says the opposite in words: `--etcd-expose-metrics` publishes `2381` on the node address in addition to loopback. The `0.0.0.0` in that file is `controlPlaneMetricsBindAddress` (`:35`), which covers 10257/10259 and is labelled authenticated at `:32–34`. The spec merged the two. The consequence is not pedantic: §13's proposed allow-list is justified by a wildcard bind that is not there, and the repo already contains the purpose-built answer (`modules/nixos/etcd-metrics-proxy.nix`, which refuses a wildcard bind) that §13 does not mention.
**Fix.** Correct both lines to "published on the node address by `--etcd-expose-metrics`, unauthenticated, and readable from the LAN because the host firewall is off", note that 10257/10259 are the authenticated `0.0.0.0` bind, and add that `etcd-metrics-proxy.nix` already solves this on `titan` by binding one address and forwarding to loopback.
**Sources:** s9-code B2; zoom Major 8 (partial); s8-audit §7.1.

### B-06. §14 excludes a `titan` change that does not exist as a value, and contradicts the Phase 3 table
**Lines:** 510–512 versus 395.
**Problem.** No host sets `wireguard.lanSubnet`; the only three hits in the repo are the module declaration and its MASQUERADE consumer. So the one `titan` change §14 permits is a new override, not an edit. Meanwhile 395 lists four `titan`-side Phase 3 items that §14 then excludes. The real `titan` Phase 3 surface is at least `:110` (`forwardToLan`), `:205` (OPNsense peer `allowedIPs`), `:329` (`meshTCPPortExtraSources`), `:433–435` (`splitZones`), `:528` (`networking.hosts`), plus a new `lanSubnet` override.
**Fix.** Line 512 → "any change to `titan` in Phase 3 beyond the mesh LAN-CIDR items listed in the Phase 3 table (`lanSubnet` — currently unset, inherited from the module default — `forwardToLan`, the OPNsense peer's `allowedIPs`, `publicHost.meshTCPPortExtraSources`, `meshDns.splitZones`, `networking.hosts`)", and reconcile line 395 so the two lists agree.
**Sources:** s9-code B5; s9-style B(finding 62); compre #12.

### B-07. Phase 1b never moves the coordinator, and step 5 precedes the thing it depends on
**Lines:** 351–361, especially 357; also 364.
**Problem.** Step 5 points z2m's `serial.port` at the reserved address, but no step puts the coordinator on VLAN 10. As written, Zigbee breaks at step 5 and nothing restores it until step 7. The single most critical device move in the phase is implicit. The rollback claim ("z2m's `serial.port` is one field") is true only if the coordinator's own address is also reverted, which is not stated.
**Fix.** Split step 5. 5a: move the coordinator itself onto VLAN 10 (static address below the pool, or its switch port to untagged 10), verify reachability from OPNsense. 5b: edit `serial.port` to `socket://<reserved-ip>:<port>`, restart the add-on, verify the z2m log reaches "Connected" with no reconnect loop. State the expected downtime between 5a and 5b and that Zigbee devices do not need re-pairing for it. Add the same actions to the rollback.
**Sources:** s9-impl B8, N22; compre #14.

### B-08. Phase 1b step 1 asserts as settled the question Phase 0.3 exists to answer, and there is no branch if the answer is unfavourable
**Lines:** 352–354, 322, 51–53, 38–39, 210–221.
**Problem.** Phase 0.3 exists to discover whether HA addresses IoT by IP or by mDNS name; step 1 then states "No mDNS means HA addresses IoT devices by IP" as though settled, and §2 asserts reflection is "not needed today". If any HA integration, Matter/Thread border router or voice assistant resolves an IoT device by mDNS/SSDP name, moving those devices to VLAN 10 removes them from HA's multicast domain and criterion 2 fails — and the only fix is the Avahi reflector §2 explicitly refuses. Multicast is also unaddressed as a mechanism: no rule mentions `224.0.0.0/4` or `255.255.255.255`, so intra-VLAN multicast falls to the catch-all and cross-VLAN discovery is simply absent.
**Fix.** Make §2 conditional: "not needed today unless Phase 0.3 finds mDNS names in use; if it does, the reflection seam becomes a Phase 1b prerequisite, not a deferral." Delete the assertion in step 1 and reference 0.3. Extend 0.3 to ask whether any IoT device resolves a LAN hostname (firmware/OTA URL, MQTT broker name) now that DNS moves to OPNsense, and whether any control path is UDP with long idle gaps. Add a gate line after 0.3 rather than a second remediation mechanism. See disagreement D-1/D-9 on whether to pre-write both branches.
**Sources:** s7-design M2; s9-style B(finding 14); zoom Major 7; compre #7 (partial).

### B-09. The Phase 0.4 socket-direction diagnostic is stated backwards
**Lines:** 273, 323; also 216 and 265–273 versus 357.
**Problem.** The document says "a listening socket on the z2m port means HA dials out". If HA holds a listening socket on the z2m port, then the peer connects *to* HA — the coordinator is the TCP client and rule 5 **is** required. An implementer who runs the check gets the correct observation and draws the opposite conclusion, producing exactly the silent Zigbee failure 452–453 warns about. Separately, 216 and 265–273 treat the direction as unknown while step 5 (357) assumes the coordinator-listens case.
**Fix.** Replace 273 with: "a listening socket on the z2m port **on HA** means the coordinator connects to HA, so rule 5 is required; no listening socket on HA plus an established connection from HA to the coordinator's address means HA dials out and rule 5 is not needed." Make step 5 conditional on the measured result. See disagreement D-6 — one reviewer repeats the document's direction.
**Sources:** compre #2; s7-style M40, N35.

### B-10. `<z2m port>` is never given a value, so rule 5 cannot be written
**Lines:** 254, 271, 323.
**Problem.** Rule 5 is specified as `HA_SERVER:<z2m port>` three times and the port is never named. The document elsewhere insists on concrete values (`.100`–`.200`, `:8123`, `:3260`). No Phase 0 item resolves it.
**Fix.** Either state the port, or state "Phase 0.4 records the port and the rule uses that value" and add the port to Phase 0.4's `Resolves` column. (Deleting rule 5 per D-1 also removes this.)
**Sources:** compre #4.

### B-11. `GUEST_NET` is used in a firewall rule and never defined
**Lines:** 253 versus the alias table 226–232.
**Problem.** The alias table is introduced as the authoritative glossary ("Aliases first, so the rules read as intent", 224) and defines only `LAN_NET`, `MESH_NET`, `RFC1918`, `HA_SERVER`, `ZIGBEE_COORD`. A rule referencing an undefined alias is a hole in the ruleset's own contract. It is also the only alias reference not wrapped in backticks. Phase 1b step 3 omits alias creation entirely.
**Fix.** Add `| \`GUEST_NET\` | \`10.60.20.0/24\` | §6 |` after 231, backtick 253, and add "create aliases" as a sub-step in both Phase 1a step 2 and Phase 1b step 3.
**Sources:** compre #3 (Blocker); s7-struct M15, s7-style M15 (Major); s9-impl M55. Severity disagreement — see D-15.

### B-12. Phase 0 produces eight facts and no artifact, format, or exit gate
**Lines:** 316–330; consumers at 351, 355, 370, 424.
**Problem.** Every later gate reads a Phase 0 answer, but there is no file, no format and no exit condition. "Record what answers" (325) records nothing durable, so no downstream gate can be evaluated.
**Fix.** Add a Phase 0 exit artifact — `docs/superpowers/specs/2026-11-17-lan-vlan-phase0-findings.md`, one section per 0.x holding the answer, the exact command or screen used, and the date — plus the OPNsense XML export stored off-router at a named path. Make "artifact complete" the gate for entering Phase 1a.
**Sources:** s9-impl B6.

### B-13. The guest coverage regression is unhandled and the two possible resolutions contradict
**Lines:** 341–342, 345, 294, 137–138.
**Problem.** The kitchen, entrance and garage APs are the mesh/bridge units — the APs most likely broadcasting today's guest SSID. Disabling the old SSID removes guest Wi-Fi from three rooms. Leaving it running keeps an unfiltered guest network on the flat LAN, which is the hole the project exists to close. The plan picks neither, so the implementer picks at 11pm.
**Fix.** After the SSID inventory, make step 6 an explicit either/or: (a) retire the old SSID everywhere and accept no guest coverage in those rooms until the cables in §13 are pulled; or (b) keep the old SSID on the mesh APs, leave per-AP Omada isolation on, and record the residual hole as accepted in §11. Record the choice in the Phase 0 artifact.
**Sources:** s9-impl B7.

### B-14. "The old guest SSID" / "the old SSID" is never named and its existence is never established
**Lines:** 345, 347, 364; §7.5 table 291–295.
**Problem.** Step 6 and both rollbacks depend on an existing IoT SSID and Guest SSID. §7.5 lists exactly one pre-existing SSID, "existing trusted". If there is no current guest SSID, step 6 and the 1a rollback are unexecutable; if there is one, its name is never given, so the executor will disable the wrong object in the Omada UI.
**Fix.** Add a Phase 0 row recording the exact SSID names, VLAN/untagged status, security mode and per-AP broadcast set of every SSID in use, then reference those recorded names literally in step 6 and both rollback lines. If no guest SSID exists, delete step 6 and rewrite the rollback.
**Sources:** s9-style B(finding 12); compre #18; s9-impl M4 (partial).

### B-15. Interface creation is compressed into one line, the router address appears nowhere, and two mandatory screens are missing
**Lines:** 338 (1a step 1), 355 (1b step 2), 214; §6 table 174–176.
**Problem.** Step 1 compresses VLAN creation, interface assignment, address, DHCP and DNS into one line. §7.2 (214) says only "with the addresses from the table, `/24`" and the §6 table gives a subnet, not a host address, so the literal `10.60.20.1/24` appears nowhere in the document. 1b step 2 drops "address" that 1a step 1 lists, so the parallel steps do not match. Two mandatory screens are omitted: the interface's "block private networks / block RFC1918" checkboxes (one of them silently kills rule 3's internet path and makes the step 5 test fail for the wrong reason) and the Unbound client-access list for the new subnet (if the new range is not permitted, guests resolve nothing and the failure looks like a firewall bug).
**Fix.** Split into numbered substeps with the screen and the literal value, identical in shape for both phases: VLAN creation → assignment and rename → IPv4 address → DHCP scope (range, gateway, DNS, lease time) → resolver listening set and client access list → firewall rules and removal of the default allow-all. Record the block-private checkboxes as an explicit observation.
**Sources:** s9-style B(finding 8); s9-impl B8, N5.

### B-16. Phase 2 is a paragraph sitting between two plans, and its ruleset is not a decision
**Lines:** 366–376, especially 372–374; §10 457–467 has no Phase 2 row.
**Problem.** There are no steps: no VLAN 50 interface, address, DHCP scope, DNS, alias or rules; no list of which rack-switch ports change; no verification; no rollback verification. "Allow only what is needed (SSH to nodes, the cluster API)" is the phase's entire security content and is the vaguest sentence in the plan — the executor will get it wrong in the permissive direction. Line 369 asserts "Nothing in this repo changes" while the phase requires a firewall ruleset that lives in no repo (§12). See disagreement D-3: two reviewers want it written to plan standard, two want it deleted.
**Fix.** Either write Phase 2 to the same standard as 1a/1b (numbered steps, literal values, §10 rows) with the rules in §7.3 table form and the node list named, or mark it explicitly "not yet planned — own spec after Phase 1b signs off", the way §8.1 handles Phase 3. Do not leave prose between two executed phases.
**Sources:** s9-impl B9, M15; s9-style B(finding 22); compre #19; zoom Major 4.

### B-17. Phase 3 never names the destination addressing, and VLAN 1 is "retired" while also being the break-glass path and the NAS destination
**Lines:** 378–397, 167, 172, 176, 308, 415–416.
**Problem.** VLAN 30 and 50 have ranges; the legacy segment's replacement subnet, gateway and prefix length exist nowhere in the document. Every Phase 3 row says "change the IP" without saying to what — a deferral hiding an uncosted decision, contradicting §6's claim (167) that "the final scheme is chosen now so no segment is migrated twice". 172 says VLAN 1 is "Retired in Phase 3", but 308 makes untagged native-1 membership the documented path back into OPNsense and 415–416 leaves the NAS "on the flat segment it is on" — i.e. on the segment this phase deletes. That is the most consequential open question in Phase 3 (the Longhorn iSCSI endpoint) expressed as a vague noun phrase.
**Fix.** Either add the post-Phase-3 row for VLAN 1 to the §6 table now, or state in §8.1 that selecting the new CIDR is the first deliverable of the Phase 3 spec and soften 167. Change 172 to "Re-addressed in Phase 3; remains the untagged native VLAN and the break-glass path (§7.6)". Name the NAS destination explicitly. Require Phase 3 to define its replacement break-glass path before retiring native VLAN 1.
**Sources:** s9-impl B10; s9-style M(finding 35); compre #11.

### B-18. "Each phase is independently valuable and independently reversible" is false for Phase 3
**Lines:** 314 versus 347, 364, 376 and 415.
**Problem.** Phases 1a, 1b and 2 each carry a `**Rollback:**` line. Phase 3 has none, its rebuild option is explicitly a one-way door with an outage window (408), and 415 makes it dependent on Phase 2 ("desktops already on 50"). The blanket claim reads as a promise the document then does not keep.
**Fix.** "Phases 0–2 are independently valuable and independently reversible; each has a rollback line. Phase 3 is a cluster migration and is not reversible without a restore." Then either add a Phase 3 rollback line or state "no rollback: the rebuild strategy is the rollback".
**Sources:** s9-style B(finding 1); compre #16.

### B-19. §10 pass conditions name no command, no observation point and no positive control
**Lines:** 459–467, especially 461–467; also 37–41.
**Problem.** Every row states a predicate and none states how to observe it. Several rows are satisfied by an unrelated failure: "unreachable" is also what you get when the target service is down, when the client has no route, or when the wrong SSID is joined. Without a positive control, a broken test and a working boundary look identical — the exact failure §9 (436–439) warns about and criterion 5 promises against. Specifics: placeholder lease values (`10.60.10.x`), shorthand targets (`.6`, "a node", "the rack"), "all RFC1918 unreachable" is unbounded, `kubectl get nodes` needs the invocation host and kubeconfig context, "no comin rollback in `/var/log/comin-health-gate.log`" needs the grep pattern, the roadwarrior row needs a named peer and the client-side route command, and the `comin-approve.sh` row may have no dry-run mode — a fact the row should state either way. Success criterion 3 (40–41) is a list of nouns, not a pass condition.
**Fix.** Add a fourth column `Observed with` holding a literal command to every row. Add one positive-control row: the same probes run from a trusted-LAN client return OPEN for `HA:8123`, `.6:9000`, node `9100`, proving the probes can detect an open port at all. Replace "all RFC1918 unreachable" with one named target per blocked range plus "and the block appears in OPNsense Firewall > Live View filtered on the GUEST interface" — a log line distinguishes "blocked" from "host down" in a way a timeout cannot. Rewrite criterion 3 as an observable predicate.
**Sources:** s9-style B(finding 45), M42; s9-impl M41; s7-style N37 (criterion 3).

### B-20. The scope line asserts two managed switches; four other places say that is unknown
**Lines:** 5–6 versus 103, 207–208, 320–321, 471; diagram 68.
**Problem.** Line 5 states "two managed switches" as established fact. Line 103 lists the switch models and 802.1Q support as unknown, 207 says "if the rack switch turns out to be unmanaged", 320–321 question both, and 471 rates "rack switch is unmanaged" as medium likelihood. A first-time reader cannot tell whether the plan's premise is established.
**Fix.** Line 5 → "two switches (management capability unconfirmed — see Phase 0.1/0.2)"; diagram label → "8-port switch (managed?)".
**Sources:** compre #5.

### B-21. Three of four internal anchor links do not resolve
**Lines:** 9, 51, 58 (only 54 resolves); also 178.
**Problem.** `#12-config-as-code-an-open-gap` is one hyphen short of the slug GitHub generates from "## 12. Config as code — an open gap". `#landmine-the-management-vlan-breaks-mesh` points at a bold lead-in inside §9 (430), which generates no anchor at all — and this is the link carrying the evidence for a §2 non-goal. `#ipv6-policy` does not match the slug `#74-ipv6-policy`. The prose pointer "See the mesh landmine" (178) matches no heading for the same reason.
**Fix.** Change 9 to `#12-config-as-code--an-open-gap` (or retitle 480), promote 430 to `### 9.1 The management VLAN breaks mesh` and point 51 and 178 at `#91-the-management-vlan-breaks-mesh`, change 58 to `#74-ipv6-policy`.
**Sources:** s7-struct B1, N44; compre #23. Severity disagreement — see D-15.

### B-22. The spine paragraph's two assurances are falsified by rule 6
**Lines:** 259–263 versus 255 (rule 6 `IOT → any allow`) and 275.
**Problem.** "An owned bulb still cannot phone home or scan the rack" (262–263) and "IoT can never start a connection to HA or anything else on the LAN" (261–262) are false as written. Every vendor-cloud beacon, OTA poll, telemetry upload and exfiltration channel from an owned bulb is an IoT-initiated outbound connection to a public address, and rule 6 permits it on all protocols and ports. Only IoT→private-space is constrained.
**Fix.** Replace 262–263 with: "Home Assistant keeps working; an owned bulb cannot reach the rack or any trusted-LAN host, and can still reach the public internet. That egress is deliberate (vendor cloud, OTA) and is listed as an open item in §13." Fix 260–262 to say IoT cannot open a session to any LAN address but can open sessions to the internet under rule 6, and that same-VLAN traffic never reaches the firewall (275). Add the matching §13 seam: an egress allow-list for VLAN 10, added when a specific device is retired from its vendor cloud.
**Sources:** s7-design B2; s7-style finding 7.

---

## Major

Ordered: boundary correctness, then single points of failure, then Phase 0/1 executability, then Phase 2/3, then structure and reference integrity, then wording batches, then fix-set scope.

### M-01. There are no IPv6-family rules; §7.4 closes its hole by intention, not by rule
**Lines:** 236–241, 248–257, 281–287.
Every rule in both tables has an IPv4-only destination, and OPNsense rules are per address family — a rule whose destination is an IPv4 alias does not match IPv6. §7.4 says do not delegate an IPv6 prefix to IoT or Guest (283) but never says to disable the DHCPv6 server or router advertisements on `opt10`/`opt20`, and never adds an `inet6` deny. The trusted LAN keeps IPv6 (286), so a prefix exists on the box. This is the SLAAC-defeats-guest-isolation failure §7.4 cites, reintroduced by omission.
**Fix.** Add to §7.2 "explicitly disable the DHCPv6 server and router advertisements on `opt10` and `opt20`". Add rule 0 to both tables: `any → any, family inet6, block`, above every IPv4 rule, plus a note that each listed rule is created with family `inet4`. Add a §10 row: from an IoT client and a guest client, `radvdump` shows no RA and any outbound IPv6 connection fails.
**Sources:** s7-design M3; s8-audit §9 (authorised addition).

### M-02. Statefulness is not what protects the LAN, and the claim hides a UDP / long-session failure mode
**Lines:** 259–263.
The LAN boundary is rule 2 — a stateless destination block evaluated before any allow — not statefulness. Presenting statefulness as the reason "IoT can never start a connection" invites a reader to conclude that removing rule 2 is safe. Separately, the design leans on HA-initiated state for the only permitted cross-boundary flows: UDP-based IoT control (CoAP, MQTT-SN, RTP) with idle gaps drops out of the state table and cannot re-establish, because the device cannot initiate.
**Fix.** Rewrite the paragraph to name rule 2 as the boundary and statefulness as the return-traffic mechanism only. Add: "IoT control protocols that are UDP with long idle gaps will not survive state expiry; Phase 0.3 must list any device whose control path is UDP, and those devices either need a per-flow keepalive or a dedicated pinhole."
**Sources:** s7-design M1.

### M-03. Rules 7/8 assume Home Assistant is the only legitimate initiator, and there is no extension path; wired IoT and printers have no segment
**Lines:** 230, 256, 257, 259–263; related 94–96, 324, 204–206.
Rule 8 blocks every inbound-initiated flow into IoT except one host. Real inbound dependencies that will silently die: Frigate or go2rtc pulling RTSP from IP cameras, Node-RED/n8n polling Tasmota/ESPHome devices, Prometheus or blackbox exporters, ESPHome OTA from a machine other than HA, a local LLM or voice pipeline an IoT device must call (the fleet has `llm01`, 94–96), and printers — which Phase 0.5 lists as static-IP LAN hosts (324). Each becomes a hand-edited OPNsense rule with no diff and no review (§12). Separately, all wired ports stay untagged native 1, so a wired smart hub, an ethernet camera or a networked printer stays unsegmented; criterion 1 is technically consistent ("an IoT device on the IoT SSID") but a reader finishes the document believing IoT is segmented.
**Fix.** Replace `HA_SERVER` with an `IOT_INITIATORS` alias (member today: HA) and write rule 7 against the alias. Add a short "adding a cross-boundary flow" procedure naming the alias to edit, the insertion position and the mandatory XML re-export. Add one Non-goals line: "wired IoT-class devices remain on VLAN 1 in Phase 1; segmenting them is a separate decision requiring per-port work."
**Sources:** s7-design M4; zoom Nit 15.

### M-04. Rule 1 is bypassable by design, and the boundary's own resolver can leak the internal map
**Lines:** 218–219, 238, 250, 255.
(a) Rule 1 restricts DNS to the firewall, but rule 6 allows `IOT → any` on every port, so DoT on 853 and DoH on 443 reach any external resolver; DNS-tunnelled exfiltration is unrestricted and nothing acknowledges this. (b) "Serve DNS from OPNsense on both" (218) has no resolver scoping. If Unbound holds or forwards the split-horizon zones referenced at 92–93 and 391–396 (`casa.arrieta`, `l.arrieta.eu`), IoT and guest clients can resolve internal names from the boundary interface and enumerate the LAN map — blocking `.41` (219) does not help when the boundary itself answers.
**Fix.** State that the resolver listening on `opt10`/`opt20` must not serve or forward private or forward zones (separate listener or access list restricted to LAN and mesh). Add one plain sentence: "DNS is not a trust boundary on these VLANs: DoH over 443 is reachable and is not mitigated." See disagreement D-11 on whether to add an 853 block.
**Sources:** s7-design M5; s8-audit §4.5.

### M-05. The admitted guest-to-guest hole skips the free mitigations, and PSK makes it worse than stated
**Lines:** 275–279, 297, 478.
(a) Per-AP Omada isolation is described as insufficient (277) but the design never says it will be *enabled* on the new SSIDs. Since IoT and Guest exist on only two APs (289–295), most guest pairs are on the same AP, so the free per-AP feature covers the common case at zero cost. (b) WPA2/WPA3-PSK with a shared per-SSID passphrase (297) means any client holding the passphrase can capture and decrypt other clients' airtime traffic; "guests can reach each other" (478) understates that. (c) The §11 mitigation cell (478) reads "accepted and documented, not hidden" — a decision, not a mitigation, and it is the only certain-likelihood risk in the table with no action attached.
**Fix.** In §7.5 add "enable Omada client isolation on `home-guest` and `home-iot` (per-AP, free, covers the same-AP majority)". Record the PSK decryption consequence in one clause at 275–279 rather than migrating every guest device to WPA3/OWE. In §11 replace the mitigation cell with the partial mitigations actually applied plus the residual, or move the row to §7.3 and leave §11 to uncertain items.
**Sources:** s7-design M6; s9-style M43(finding 53); s8-audit §4.6.

### M-06. OPNsense becomes a new single point of failure for home automation; not in the risk table, no reboot test
**Lines:** 196–209, 210–221, 469–479; only mention of a reboot is 353–354.
Today HA reaches IoT on one L2 segment and local automation survives a router outage. After Phase 1b every HA↔IoT flow traverses OPNsense, and IoT DNS and DHCP live there too. An OPNsense failure, upgrade or bad edit now takes down Zigbee and every IoT device — a new dependency, in the opposite direction from the document's framing. A reboot also flushes all stateful states, so long-lived HA→IoT sessions do not return without client-initiated reconnects. §11 has no row; §10 has no reboot test; §1 does not admit the trade.
**Fix.** Add one §11 row: "OPNsense down or mid-upgrade → HA loses all routed IoT control; today it does not", likelihood low, mitigation `accepted — the same failure already costs the internet`. Add a §10 row: reboot OPNsense with one Zigbee and one Wi-Fi IoT device active; both rejoin unattended; z2m log shows one reconnect, not a loop. Add one sentence to §1 admitting the trade. Do not mitigate it with a HA-on-both-VLANs hack or a redundant router.
**Sources:** s7-design M7; zoom Major 5; s8-audit §8 (collapse to one row).

### M-07. Steady-state single points of failure: the inter-room cable and the living-room switch
**Lines:** 62–78, 155–160, 199–201, 441–449, 469–479.
§5 rule 2 (157–160) and §7.1 (199–201) deliberately consolidate every VLAN onto one cable. §9 treats only the *act of reconfiguring* that trunk as a risk. The steady-state consequence is unstated: one cut cable or one failed living-room switch now removes the entire office — all four rack nodes, TrueNAS, HA, the office AP and both new VLANs in the office — because the office path is OPNsense → 8-port switch → inter-room → rack switch (70–74). The living-room switch is an unmodelled SPOF for the whole office and its model is unknown (Phase 0.1).
**Fix.** Add one §11 row covering both, with either an honest `accepted — no mitigation planned` or a named mitigation (second cable or LAG if the rack switch supports it). Add one sentence to §7.1: consolidating VLANs on one cable also consolidates its failure domain.
**Sources:** s7-design M9; s8-audit §8.

### M-08. A DHCP reservation is the wrong primitive for the coordinator
**Lines:** 215–217, 231, 352–355; related 306.
The firewall alias points at a DHCP-assigned address (231) and the only requirement is a reservation (352–355). If the reservation is lost — an older XML restore, which §7.6 prescribes at 306, or an OPNsense rebuild — the coordinator gets a different address, the alias silently points at nothing and Zigbee is down behind a rule that looks correct. A reservation also does not outlive a router outage longer than the lease.
**Fix.** Require a statically configured address on the coordinator itself, below `.100` and outside the pool, with the DHCP reservation kept only as documentation. Add to §10: after any config restore, re-apply and re-test Zigbee.
**Sources:** s7-design M8; s8-audit §6 (accepted).

### M-09. The Omada controller is now part of the boundary and has no stated role; both rollbacks depend on it
**Lines:** 289–299, 326, 341–343, 348, 364; related 130–136.
The SSID→VLAN binding *is* the boundary and it lives in the Omada controller. Phase 0.8 asks where the controller runs (326) and nothing downstream uses the answer. Unstated dependencies: whether an AP retains SSID/VLAN config across a reboot or re-adoption while the controller is offline; whether a factory-reset AP comes up with the controller's template or with a default config that emits the SSIDs untagged (the Finding B fail-open mode, 130–136); and that both rollbacks (348, 364) are controller actions, so rollback requires the controller to be up. A reader who does not know SSIDs are pushed by a controller has no idea who performs step 4.
**Fix.** Extend Phase 0.8 with: does a wired AP keep SSID/VLAN config with the controller stopped and after re-adoption (answered from TP-Link docs or a bench unit, not from the production office), and where is the controller's restorable backup. Add to §7.6: take an Omada controller backup and a per-AP config export before Phase 1a. Add one sentence to Phase 1a: "Steps 4–6 are performed in the Omada controller UI; Phase 0.8 must establish where it runs and that it is reachable before Phase 1 starts." See disagreement D-12 on the proposed controller-stop test.
**Sources:** s7-design M10; compre #17; s8-audit §4.4.

### M-10. Phase 1b never retires the old IoT SSID, but its rollback assumes it still exists
**Lines:** 350–364 contrasted with 346; acceptance row 461.
Phase 1a has an explicit "only then disable the old guest SSID" step (346). Phase 1b has no equivalent, so every IoT device that fails to rejoin stays on the old SSID, fully on the trusted LAN, with no boundary, and nothing in §10 detects it. The acceptance row at 461 tests a client that *is* on the new VLAN and never tests that nothing remains on the old one. Parallel phases with a missing step read as an omission rather than a decision, yet the 1b rollback assumes the old IoT SSID is still there.
**Fix.** Add a Phase 1b step "disable the old IoT SSID, or move it to VLAN 10 under the same ruleset, once the client list is empty", and a §10 row "no client remains on the legacy IoT/Guest SSID", observed by diffing the Omada client list and the DHCP lease file before and after. If the old IoT SSID is deliberately kept, say so in one line.
**Sources:** s7-design M11; s9-style M(finding 21).

### M-11. The inter-room trunk edit interrupts iSCSI to TrueNAS, not just comin
**Lines:** 441–449, 70–71, 98–99, 42.
TrueNAS/MinIO `.6` sits on the rack switch and Longhorn runs iSCSI across the inter-room cable. §9 frames the trunk change purely as "do not do it while comin is mid-switch on a fleet host" (447–449). The larger exposure is that a live tag/native change drops in-flight iSCSI for every Longhorn volume crossing the link at once — filesystem errors on live pods, worse than a rolled-back deploy. Criterion 4 (42) promises the cluster stays up through every Phase 1 step; this step is the most likely to break that promise.
**Fix.** State the iSCSI consequence in §9 and require, before the trunk edit: confirm no comin deploy, and confirm Longhorn reports all volumes healthy afterwards. Extend the §10 "Cluster untouched" row with `kubectl get volumes.longhorn.io -A` before and after, not only `kubectl get nodes`. See disagreement D-14 on whether a full drain runbook is warranted.
**Sources:** s7-design M12; s8-audit §4.3.

### M-12. Trunk tagging happens twice, contradicting the rule written to prevent exactly that
**Lines:** 159–161 and 200–201 versus 340 and 357; risk at 441–444.
Forward-compatibility rule 2 and §7.1 both say tag the whole set `{10,20,30,40,50}` on the inter-room trunk from day one. Phase 1a step 3 tags only VLAN 20 and Phase 1b step 4 tags VLAN 10 — two separate live-trunk edits, and §9 says each such edit is an outage on the only inter-room link.
**Fix.** Make Phase 1a step 3 apply the full tag set to the inter-room trunk at both ends in one scheduled change, and reduce Phase 1b step 4 to a verification. Make that single edit the first action of Phase 1a, before any SSID or client exists, on a link carrying only storage and cluster traffic.
**Sources:** compre #15; s8-audit §4.3.

### M-13. The trunk step is the only step with a real outage and has no procedure, duration or rollback; the consequence is stated 100 lines away
**Lines:** 340 versus 441–445 and risk row 475.
**Fix.** Name the two ports from the Phase 0 port map; state the order (which switch first) and the vendor caveat that some switches drop the link when the tag set changes on a live trunk; state the expected blip in seconds or say "duration unmeasured; treat as a full link outage until measured on your switch model"; require the no-deploy check; give the rollback (remove the tag on both ends, then re-verify the inter-room link by reaching a rack host by IP). Append the consequence to step 3 itself rather than leaving it in a section the executor has no reason to re-read mid-step.
**Sources:** s9-impl M6; s9-style M(finding 9), M(finding 42).

### M-14. The per-change cost is never stated, and "rules written once" is wrong
**Lines:** 147, 210–221, 222–257, 480–491.
A new IoT device is free only if it needs no inbound poll, no mDNS name and no local service; otherwise it is one hand-edited OPNsense rule plus a re-export, with no diff and no review. A new VLAN is at least eight edits across four systems. A new cross-boundary service is one alias edit and one rule inserted at a specific position in a UI with no undo. So §5's "rules written once" (147) is not true over the life of the system.
**Fix.** Add a three-row per-change checklist to §7 — new IoT device, new VLAN, new cross-boundary service — naming the **systems** to edit, and require an OPNsense XML export committed after every manual change. State that the tables in this document are descriptive, not authoritative (do not add "this document's own tables" to the checklist). Delete or qualify "rules written once" at 147.
**Sources:** s7-design M13; s8-audit §5.4.

### M-15. The alternatives table is staged to make A win, and omits the cheapest rivals
**Lines:** 142–153, with 64, 116, 118–121, 130–136, 277–278.
(a) Option D is rejected "on physics" using the weakest possible form; the realistic no-new-VLAN competitors are the ones the document names elsewhere — OPNsense rules on an already-routed WLAN interface (118–121), Omada EAP ACLs and guest policy (116), switch-level private-VLAN on the existing 8-port switch (277–278). (b) §3.1 advertises "4 NICs: WAN, LAN, 2 free" and §5 never asks why IoT/Guest are not terminated on a free NIC instead of trunked through two switches and one shared cable; the real answer is short (the office EAP610 and the rack are reachable only through the single inter-room cable, so a physically separate network needs a new cable run plus a second office switch). (c) Option B's row never says that *native VLAN unused* is the only property that structurally eliminates Finding B — the design's self-declared most dangerous item is precisely what the rejected option cures. (d) The Verdict column mixes adopted, deferred, folded and "rejected as an order", so rows are not comparable. See disagreement D-8 on how many rows to add.
**Fix.** Add two rows: one real no-new-VLAN rival naming the three mechanisms in its rationale cell, and one for narrowing roadwarrior client `AllowedIPs` instead of re-IPing the fleet. Add to B's cell: "an unused native VLAN is the only structural cure for Finding B." Split `Verdict` from `Rationale` and reorder so verdicts never point downward.
**Sources:** s7-design M14; zoom Major 9; s7-struct N52; s8-audit §5.2.

### M-16. §1's `[measured]` roadwarrior claim cites options that install no route
**Lines:** 30–32.
`wireguard.lanSubnet` and `forwardToLan = true` do not put a route into a roadwarrior's tunnel. `lanSubnet` is referenced only in the hub-side MASQUERADE scope (`modules/nixos/wireguard.nix:85–90`); `forwardToLan` sets `ip_forward` and appends SNAT rules (`:271–280`). The route a roadwarrior gets comes from its own client-side `AllowedIPs`, which is not in this repo; titan's roadwarrior peer entries are `/32` only. `hosts/titan/README.md:614` states the point outright.
**Fix.** Drop the `[measured]` citation from that sentence and cite the real measured source: `hosts/titan/README.md:592–635`, which records the collision (measured on macbookair 2026-10-18), the `/32` mitigation, and that a blanket `/24` "takes the venue's gateway and any captive portal down with it". Retag the consequence `[unverified]` if the client configs are not read.
**Sources:** s9-code M1; zoom Major 3.

### M-17. "The firewall is off on k3s hosts" is false for `titan`, which is a k3s host
**Lines:** 87–88 and 500.
`modules/nixos/k3s.nix:171` and `modules/nixos/k8s-network.nix:24` set `networking.firewall.enable = lib.mkDefault false`, but `modules/nixos/public-host.nix` assigns a hard `true`, which outranks `mkDefault`, and `hosts/titan/configuration.nix:315` enables `publicHost`. §13's seam is written as though the whole control plane is unguarded; on the hub it is already guarded by per-source rules matched `-i wg0`.
**Fix.** Line 87–88 → "`networking.firewall.enable` is `mkDefault false` on the casa k3s hosts, so nothing on the LAN is fenced from that control plane. `titan` is the exception: `public-host.nix` sets the firewall to `true` and answers mesh ports per-source." Same distinction at 500.
**Sources:** s9-code M3.

### M-18. Phase 0.6 — the item the document calls decisive — is not executable, and its outcome changes nothing
**Lines:** 325, 329–330, 119–121.
No probe tool, no named client, no named node for "a node's `9100`", no recording format, and no requirement to repeat it per AP location — while Finding B makes per-AP behaviour the thing under test. "Reach `192.168.0.1`" via ICMP is not a boundary test; a router can refuse ICMP for unrelated reasons and produce a false "boundary exists". "Record what answers" has no expected value, so a fully-open and a fully-closed boundary both produce a valid record. And 329–330 says 0.6 decides "hardening or fix" while the plan is byte-identical in both branches. No Phase 0 item captures the current IoT/Guest SSID names and passphrases, which the test client needs.
**Fix.** Replace with an explicit probe list to run from a laptop joined to the current IoT SSID and again on the current Guest SSID, at each AP location: `nc -vz -w3 192.168.0.1 443`, `nc -vz -w3 <HA> 8123`, `nc -vz -w3 192.168.0.6 9000`, `nc -vz -w3 192.168.0.11 9100`, `nc -vz -w3 1.1.1.1 443`. Record one line per target as OPEN / TIMEOUT, expecting only `1.1.1.1` OPEN; any other OPEN line is the hole Finding A predicts. Then see disagreement D-4 on whether the result becomes a stop condition or the claim gets dropped.
**Sources:** s9-impl M2, M54; s9-style M2, M54; s7-design N2; s8-audit §7.2.

### M-19. Five of eight Phase 0 items name no command and no screen; the `Item` column is noun phrases with no verb
**Lines:** 320, 321, 322, 324, 327.
Only 0.4 and 0.6 name a command, so the table has two registers in one column and an executor cannot tell what "done" looks like for 0.1, 0.2, 0.3, 0.5, 0.8. 0.1's "whether all ports trunk" is not an answerable question — §7.1 (205) says the server ports are untagged access ports.
**Fix.** Start every `Item` cell with an imperative verb and add a fourth column `Observed with` holding one named command or screen. Per item: 0.1/0.2 — read the label and management URL, check `arp -a` and OPNsense Diagnostics → ARP Table, record managed/unmanaged, model, firmware, PoE budget, port count and which ports support 802.1Q; replace "whether all ports trunk" with "which ports support tagging, and how many are free". 0.3 — DHCPv4 leases screen; if HA is absent it is static, so `nmap -sn 192.168.0.0/24` and diff against leases; for IP-vs-name, the z2m add-on Configuration tab showing `serial.port`. 0.5 — diff `nmap -sn` plus leases and reservations against the static list in `secrets.yaml#*/network_env`; anything answering with no lease is a static candidate. 0.8 — controller type, version, login, and whether it re-applies SSID config after an AP reboot.
**Sources:** s9-impl M1, N20; s9-style M(finding 2).

### M-20. Phase 0 is missing the items Phase 1 cannot run without
**Lines:** 316–330; consumers at 340, 345, 351, 253, 452, 475.
Missing: a physical port map (which 8-port switch port carries the OPNsense uplink and which carries the inter-room cable, and the equivalent on the rack switch — without it, "tag VLAN 20 on the inter-room trunk, both ends" is not executable because nobody knows which port is the trunk); the existing SSID inventory; per-AP model, firmware and whether per-SSID VLAN tagging is supported (Finding B is about APs, and 0.1/0.2 only cover switches); the coordinator MAC and whether it is USB-attached at all (if it is, Phase 1b steps 1 and 5 are no-ops and rule 5 does not exist); the z2m port number; and a named check that no comin deploy is running, which 452 and risk row 475 both require with no command.
**Fix.** Add these as numbered Phase 0 items with an `Observed with` value each. See also M-76 for the merged Phase 0 growth plan.
**Sources:** s9-impl M4.

### M-21. Phase 0.7 "confirm console access" has no pass condition
**Lines:** 326, 302–306.
"Confirm" is the word that lets an implementer skip it.
**Fix.** "Attach monitor+keyboard (or serial) and log in at the console menu — record which console works; then Diagnostics → Backup & Restore → Download, open the XML, confirm it contains the config version, store it off-router." Consider merging 0.7 into §7.6 as step 0 of Phase 1a, since it is a preflight, not inventory.
**Sources:** s9-impl M3; zoom Nit 12.

### M-22. "There is never an unfiltered window" is asserted without the mechanism, and two related OPNsense behaviours are unstated
**Lines:** 339, 220, 237, 448.
The plan never names the action (add the explicit rules and delete the auto-generated allow-all in the same screen visit), never states that the anti-lockout rule must not be touched, and never states the ordering consequence: once the allow-all is gone, rule 1 must already be present or DNS and DHCP break at that instant. Rule 1 as written (`GUEST → firewall`) also does not match a pre-bind DHCP client whose source is `0.0.0.0`; the plan does not say whether it relies on OPNsense's automatic DHCP pass rule or adds an explicit `0.0.0.0/32:68 → 255.255.255.255:67` allow.
**Fix.** Name the action, the anti-lockout constraint, the ordering consequence and the pre-bind DHCP decision in step 2.
**Sources:** s9-impl M5, N21; compre #26 (partial).

### M-23. Step 4 does not describe how Omada applies an SSID to a mesh fleet, and "mesh and garage" is a false partition
**Lines:** 341–342; §7.5 293–295; §3.1 line 76.
An SSID created in the Omada controller is applied controller-wide and then enabled per AP or per AP group, and mesh children inherit the parent's radio/SSID configuration — which is exactly Finding B. "Create the SSID on the two wired APs" is not a thing you can do. Separately, the garage unit is a CEP wireless bridge, not a mesh child (76), so "mesh and garage" mislabels the disabled set.
**Fix.** Write it as: create the controller Network object bound to VLAN 20; create the SSID bound to that network; enable it in the SSID's per-AP / AP-group settings on the living-room EAP225 and office EAP610 only; then **verify** in the controller that kitchen, entrance and garage show the SSID disabled after apply, and record the apply time and where apply status is visible. Name the devices: "leave it disabled on kitchen EAP225, entrance EAP225 and garage EAP225". Use the same wording in §11 row 2.
**Sources:** s9-impl M7; s9-style M(finding 10), N(finding 55).

### M-24. Phase 1a step 5 states pass conditions but no commands and no observation point
**Lines:** 343–344; §10 row 462.
`10.60.20.x` with a literal `x` is a placeholder where a range exists (`.100`–`.200`), and "any node" is 13 hosts. The lease check — which is the Finding B fail-open detector, present in §10 but absent from the step — and a DNS check are both missing, as is the requirement to run it at both AP locations.
**Fix.** "From a wifi client at each of the two AP locations: `ip a` shows a `10.60.20.100`–`.200` lease; `nc -vz -w3 1.1.1.1 443` succeeds; `dig +short` resolves; `nc -vz -w3` to `192.168.0.1 443`, `HA 8123`, `192.168.0.6 9000`, `192.168.0.11 9100` all time out."
**Sources:** s9-impl M8; s9-style M(finding 11).

### M-25. The Phase 1a rollback is executable only for steps 4 and 6, and its closing claim is false
**Lines:** 347–348.
Steps 1–2 require reverse dependency order (OPNsense refuses other orders while the DHCP server and rules reference the interface); step 3 requires a tag removal on both switches; step 6 requires re-enabling the old SSID and stating that clients already joined to `home-guest` must be rejoined or left there deliberately. "Nothing on the trusted LAN moved, so nothing else can break" is absolute and not true — this phase added a VLAN and a tag set to two switch trunks and a new interface plus ruleset to OPNsense.
**Fix.** Give a per-step rollback. State what is intentionally left in place (VLAN 20, interface, rules — inert with no SSID, and re-creating them is the riskier edit). Replace the closing claim with "the trusted LAN's addressing, native VLAN and existing SSIDs are unchanged".
**Sources:** s9-impl M9; s9-style M(finding 13).

### M-26. No abort criterion anywhere in Phase 1a
**Lines:** 332–348.
**Fix.** Add one line: "If step 5 shows the client reaching `192.168.0.1` or any RFC1918 host, stop. Do not proceed to step 6. Roll back step 4 first, then diagnose."
**Sources:** s9-impl M10.

### M-27. Phase 1b step 1 needs data no Phase 0 item captures, contradicts §7.2, and never names the reserved address
**Lines:** 351; §7.2 216/218; step 5 at 357/358.
A reservation needs the coordinator's MAC, which no Phase 0 item captures. §7.2 puts reservations *below* `.100`, outside the pool, while step 1 says "reserve … in the VLAN 10 DHCP scope". §7.2 gives the rule but no literal value, and step 5 then points z2m at "the reserved coordinator address" — a value the executor chose themselves and which is therefore recorded nowhere.
**Fix.** "Services → DHCPv4 → Edit (IOT) → Address Reservations: MAC from Phase 0.4 → `10.60.10.10`", using §7.2's wording ("below the dynamic pool") in both places. Then step 5 reads `serial.port: socket://10.60.10.10:<port>`. Add the third branch: if Phase 0.4 finds a USB-attached coordinator, steps 1 and 5 are no-ops and rule 5 does not exist.
**Sources:** s9-impl M11; s9-style M(finding 15).

### M-28. Phase 1b step 4 "the trunks" is three distinct configurations
**Lines:** 357; §7.1 198–204; compare 1a step 3 (340), which names exactly one.
**Fix.** "Add VLAN 10 to the tagged set on: the OPNsense LAN port on the 8-port switch, the inter-room trunk on both switches, and the EAP225/EAP610 ports. Expect a brief inter-room link drop (§9)." Better still, fold it into the single full-tag-set change per M-12.
**Sources:** s9-style M(finding 18).

### M-29. Phase 1b step 7 is the largest manual task in the plan and is one line
**Lines:** 359–360; success criterion 2 at 38; Phase 0.5 at 324.
"Move IoT devices over in batches, verifying HA control" does not say which devices, how many, what a batch is, what the per-device action is, or what "verifying" means. Zigbee/Z-Wave devices do not move at all — they join the coordinator's network, not a Wi-Fi SSID — so only Wi-Fi IoT devices need credential changes, each through its own app or a re-pair. Phase 0 inventories static IPs but never counts the devices that will join VLAN 10, so the phase has no effort number.
**Fix.** Add the device inventory to Phase 0 with per-device class (Wi-Fi / Zigbee / cloud-only), current SSID, and which need a reservation. Then define a batch ("one room, ≤5 Wi-Fi devices"), the per-device action (app Wi-Fi-change flow vs factory + re-pair), the verification (the HA entity changes state within N seconds; the integration shows no error; the z2m log shows no reconnect loop), and the abort rule.
**Sources:** s9-impl M13; s9-style M(finding 19); zoom Nit 13.

### M-30. The Phase 1b rollback understates the cost by an order of magnitude and omits actions and artifacts
**Lines:** 364.
"Move devices back to the old SSID" after step 7 means re-running every device's setup flow, one at a time, through its own vendor app. "z2m's `serial.port` is one field" is an argument, not an action — it never says to change it back, where, or that the add-on must restart. The rollback also omits two artifacts this phase created: rule 5 (if added) and the DHCP reservation.
**Fix.** "**Rollback:** per-batch; move devices back to `<recorded old IoT SSID>` (~N minutes per Wi-Fi device via its setup flow — the old SSID and passphrase must remain untouched until Phase 1b is signed off, which is why Phase 1a step 6 is sequenced last); set z2m `serial.port` back to its previous value in the add-on config and restart the add-on, confirm 'Connected'; revert the coordinator's address; if rule 5 was added, disable it. The DHCP reservation can stay."
**Sources:** s9-impl M14; s9-style M(finding 20).

### M-31. Phase 2 identifies a roadwarrior break and gives no fix; Phase 0.5 omits desktops
**Lines:** 374–375; 324.
The tunnel advertises `LAN_NET` only, so moving desktops to VLAN 50 silently removes VPN access to the operator's own machines — the machines the phase exists to protect. "Note this also" is filler and "what a roadwarrior sees" does not name the consequence or the decision. Separately, desktops moving to DHCP on VLAN 50 changes their IPs, so Phase 0.5 must include desktops and printers; it currently lists TrueNAS, DNS, HA, printers and the controller, not desktops.
**Fix.** Name the change and the file (add the VLAN 50 CIDR to the WireGuard advertised routes in `hosts/titan/configuration.nix`) and state that every roadwarrior peer config must be re-imported. Relocate the decision into the phase: "Consequence: mesh/roadwarrior clients lose access to VLAN 50 because `wireguard.lanSubnet` advertises `LAN_NET` only. Decide now whether to add VLAN 50 to the advertised routes or accept the loss." Add desktops to the Phase 0.5 scan scope.
**Sources:** s9-impl M16, N19; s9-style M(finding 24).

### M-32. Phase 2's hard gate is buried as a sentence fragment
**Lines:** 368–370.
"Cheap" is a one-word evaluative fragment with no cost attached, and the second clause restates §5 row B-lite almost word for word. "Requires the rack switch to be managed" is a hard gate buried at the end of a prose paragraph — an executor reading top-to-bottom reaches the switch before noticing it was conditional.
**Fix.** Drop the first sentence or replace it with the cost ("one switch reconfiguration of N desktop access ports; no change in this repo"). Promote the gate: "**Precondition:** Phase 0.2 confirmed the rack switch is managed. If not, Phase 2 is blocked on a hardware purchase."
**Sources:** s9-style M(finding 23).

### M-33. Phase 2's rollback omits its own side effects
**Lines:** 376.
"Set the desktop ports back to untagged 1" is silent on the rules added at 372, leaves stale `10.60.50.x` leases, and drops every desktop's connections without warning.
**Fix.** "Set the desktop ports back to untagged 1 and remove the VLAN 50 ruleset; each desktop must release/renew or reboot, and warn that the change drops every desktop's connections."
**Sources:** s9-style M(finding 25); s9-impl M23.

### M-34. The Phase 3 table is tagged `[measured]` but contains an `[unverified]` row and cannot measure the items that are not repo files
**Lines:** 383, 390, 387–397.
At least four required changes are outside this repo and therefore not `[measured]`: Home Assistant's own static network config (its IP is still unknown), TrueNAS/MinIO's own network config plus the iSCSI target addresses already recorded per Longhorn volume, printers/scanners and any client pinned to an IP, and OPNsense itself (DHCP reservations, the `LAN_NET` alias value, Outbound NAT and reflection for the new range). A table-level marker contradicted by a row marker destroys the convention the Confidence markers block sets up, and the row in question (certificate SANs) is one an implementer would otherwise trust.
**Fix.** Add a second table "Not in this repo" with those rows and scope the `[measured]` tag to the rows actually read from the repo; or drop the table-level tag, tag each row, and move the SAN caveat into a separate `Verify before planning` line.
**Sources:** s9-impl M18; s9-style M(finding 27).

### M-35. The Phase 3 `Where` column holds an explanation, not a location
**Lines:** 389 — "live etcd cluster — members are IP-pinned". An implementer cannot open "live etcd cluster".
**Fix.** "`Where`: `etcdctl member list -w table` on any control-plane node (record the output). Action: `etcdctl member update` per member."
**Sources:** s9-style M(finding 28).

### M-36. The Phase 3 table contains an open-ended catch-all
**Lines:** 396 — "anything with a hardcoded node IP". Inside a blast-radius table whose entire purpose is completeness, a catch-all converts a known-unknown into a hidden unknown.
**Fix.** Replace with the command that produces the list — "grep `192.168.0.` in `k8s-casa`; record output count and file list in Phase 0.5" — and drop the catch-all.
**Sources:** s9-style M(finding 29).

### M-37. The Phase 3 rollout row is unreadable, and the file it names needs no edit
**Lines:** 397 — "| Rollout | `scripts/comin-approve.sh` bind zone `casa.arrieta` resolution |".
Three nouns in a row with no relation stated; this is the sentence most likely to be misread at 11pm. `scripts/comin-approve.sh:39` is `DOMAIN="${COMIN_DOMAIN:-casa.arrieta}"` — an env-overridable default, so no edit is required for a re-IP unless the bind zone itself is renamed. What the script actually contributes to Phase 3 is the fleet accept order and canary ring (`:6–9`, `:36`), and `AGENTS.md` documents `COMIN_ORDER=servers-first|risk` — which is also the answer to the Phase 1a/1b "no deploy running" precondition.
**Fix.** "| Rollout ordering | `scripts/comin-approve.sh` — `COMIN_DOMAIN` defaults to `casa.arrieta` and is env-overridable, so no edit is needed for a re-IP; confirm no `casa.arrieta` record points at `192.168.0.0/24`; the reusable parts are `COMIN_ORDER` and the canary ring |".
**Sources:** s9-style M(finding 30); s9-code M15.

### M-38. Phase 3 has no ordering, no rollback, no verification, and no owner or deadline for the strategy choice
**Lines:** 399–413, 420–426; also 399.
The two bullets are options, not steps, and nothing says who picks, on what input, by when. Deferring the spec is legitimate; deferring the decision without naming its input is not. Line 399's "the etcd risk" is a pointer rather than content.
**Fix.** Name the decision owner; name the deciding input as a prerequisite task with a pass condition ("etcd snapshot restored into a scratch cluster and `etcdctl endpoint status` healthy; Longhorn backup restored to a scratch volume and the workload attached"); state that the Phase 3 spec must contain ordering, per-step rollback and per-step verification before it is schedulable. Replace 399 with "Two strategies. Choose only after the restore gate below has been satisfied."
**Sources:** s9-impl M22; s9-style M(finding 31).

### M-39. The restore gate is tagged `[unverified]` when it is a precondition, and the repo already has continuous restore evidence
**Lines:** 411–413.
A sentence beginning with a confidence marker and a lowercase verb reads as a hedge rather than a gate. `modules/nixos/k3s-snapshot-monitor.nix:236–240` defines `verify.enable`, which downloads the newest snapshot and verifies it with `etcdutl snapshot status`, publishing restoreability, revision and key count; it is enabled on the casa servers and titan. Line 412–413 gates Phase 3 as though nothing exists.
**Fix.** Convert to an explicit gate: "**Gate:** do not schedule Phase 3 until an etcd snapshot restore and a Longhorn backup restore have each completed successfully at least once. Record the date, host and duration in this section." Name the existing metric as standing evidence and define the one additional step that closes the gap — a restore into a scratch etcd and a `kubectl get` against it — with a date.
**Sources:** s9-style M(finding 34); s9-code M12.

### M-40. Phase 3's risk list omits the documented route-loss failure that a re-IP will trigger on every host
**Lines:** Phase 3 table and landmines (no row exists).
`modules/nixos/static-network.nix:159–179` exists because fresh worker switches drop the default route: a persistent `network-route-watch` unit re-issues `ip route replace default` every 10s, and `staticNetwork.routeFlags` is the documented knob for gateways that are not on-link. Phase 3 changes every host's address, gateway and prefix — the exact trigger — and never mentions it. The watchdog is skipped entirely on the Pi hosts, so they have no self-heal during the migration.
**Fix.** Add a Phase 3 landmine naming the watchdog, the `routeFlags` knob, and that the Pi hosts have no self-heal — budget a console or a physical visit for them.
**Sources:** s9-code M14.

### M-41. §6's avoided-range list omits titan's pod and service CIDRs
**Lines:** 180–184.
`hosts/titan/vars.nix:72–73` sets `clusterCidr = "10.62.0.0/16"` and `serviceCidr = "10.63.0.0/16"` precisely because titan reaches the home LAN over WireGuard. `10.60.0.0/16` still clears them, so the choice is safe, but the justification is unverifiable as written and a reader who trusts the list rather than the code would not catch a future collision.
**Fix.** Insert "`10.62.0.0/16` and `10.63.0.0/16` (`titan`'s pod and service ranges, `hosts/titan/vars.nix:72–73`)" into the list at 181.
**Sources:** s9-code M8.

### M-42. Phase 0.5's IP map omits the MetalLB LoadBalancer pool, and `.41` may be a VIP rather than a host
**Lines:** 92, 324.
`k3s-network-debug.md:160` records "MetalLB provides LoadBalancer IPs on 192.168.0.41-44 range", and `common/etcd-snapshot-s3.nix:49` independently warns that pinning `:9000` "hits a VIP and hangs until `--etcd-s3-timeout`". Both 92 and 324 treat `.41` as a plain host. If `.41` is inside the pool, Phase 3's blast radius for it is a k8s-casa pool change, not a NixOS host change — a completely different work item.
**Fix.** Add to 324: "…and whether the MetalLB LoadBalancer pool (recorded as `192.168.0.41-44` in `k3s-network-debug.md:160`) overlaps `.41`/`.42` — if it does, those are pool addresses, not host addresses, and Phase 3 moves them in k8s-casa rather than in this repo."
**Sources:** s9-code M9.

### M-43. `hosts/titan/README.md` already contains the roadwarrior finding and the re-IP inventory; the spec does not cite it
**Lines:** §1 29–33, Phase 3 378–397.
`hosts/titan/README.md:592–635` documents the roadwarrior collision with a dated measurement, the `/32` fix, and the renumber cost in words ("21 `.nix` files here plus SOPS `network_env` on every host, OPNsense and the cluster scrape list encode it"). A grep of `*.nix` for `192.168.0.` returns 22 files — the README's count is right and the spec's Phase 3 table is a subset of it. §1 and Phase 3 reinvent this and understate it.
**Fix.** Cite `hosts/titan/README.md:592–635` in §1 and in Phase 3, and state that the README's inventory is broader than the table — the table is the *named* subset, not the full count.
**Sources:** s9-code M11.

### M-44. §13's "one-way rule" already exists as a declarative pattern on titan, and the seam does not say where the rule would live
**Lines:** 499–504; §3.2 88–90.
`modules/nixos/public-host.nix` implements `meshTCPPorts` (matched `-i wg0`), `meshTCPPortExtraSources` and `meshTCPPortRules`, and `hosts/titan/configuration.nix:329, 333, 343–349` shows the pattern in use, including a deliberate refusal to widen a shared multiport rule. §13 reads as greenfield. Both placement answers are also weak: on the k3s hosts it means reversing a documented deliberate `mkDefault false`; on OPNsense it protects nothing, because a device already on the trusted LAN is exactly what the rule must survive and IoT/Guest are already fenced by §7.3. The repo already has a purpose-built answer for the cited exposure in `modules/nixos/etcd-metrics-proxy.nix`. See disagreement D-5.
**Fix.** Add to the §13 bullet that `public-host.nix` already expresses this shape on the hub, and that the seam is whether the casa servers adopt a host-side equivalent or the rule lives in OPNsense — decide the location before writing the rule. Delete the port list.
**Sources:** s9-code M13; zoom Major 8; s8-audit §7.1.

### M-45. Phase dependencies are prose, not gates
**Lines:** 314, 370, §10 rows.
**Fix.** Add two lines to each phase — `Entry:` (named Phase 0 items recorded in the artifact; named prior-phase §10 rows passing) and `Exit:` (named §10 rows, with their output pasted into the artifact).
**Sources:** s9-impl M40.

### M-46. §10 delivers acceptance for only two of the five phases and is not tied to §1's criteria
**Lines:** 457–467 versus 314 and 35–44; criterion 4 at 40 and the nearest row at 464.
Every row is scoped `1a`/`1b`; there is no row for Phase 0, Phase 2 or Phase 3, although 314 claims each phase is independently valuable. Success criterion 4 ("No NixOS host changes IP in Phase 1") has no corresponding test — the nearest row checks node Ready status, not addresses. Criterion 5 promises every boundary is tested from a client, and Phase 2 introduces a new boundary in both directions.
**Fix.** Add a `Criterion` column mapping each row to §1's numbers 1–5, and add rows for Phase 0 (boundary proof recorded), Phase 2 (desktops on 50, roadwarrior visibility) and Phase 3 entry gate (restore tested) — or state explicitly that Phase 2 and 3 acceptance lives in their own future specs.
**Sources:** s7-struct M19; compre #13.

### M-47. Three §11 mitigations are not actions
**Lines:** 473, 475, 478.
473 is a pointer plus a noun phrase with no decision rule or purchase criterion. 475's second half describes a rule's shape, not what anyone does. 478 is not a mitigation, and "not hidden" is self-congratulation about the document.
**Fix.** 473 → "Run Phase 0.2 before Phase 1a. If unmanaged: order a managed PoE switch (≥ 8 GbE ports, ≥ 15.4 W PoE per AP port) and block Phase 1a until it arrives." 475 → "Phase 0.4 measures the socket direction. If the coordinator is a TCP client, add rule 5 before moving the coordinator's device, and keep it to one source, one destination, one port." 478 → "Accepted. No mitigation in Phase 1; see §7.3 and §13. Revisit if the guest SSID is ever used by people you do not know."
**Sources:** s9-style M(finding 53).

### M-48. §12's central claim is contradicted by the same document
**Lines:** 482–484.
"No rollback" is false within this document: 347, 364 and 376 each describe a rollback that does not involve an XML restore. The accurate claim is that there is no *automated, diffable, reviewed* rollback.
**Fix.** "…is the one part with no diff, no review, and no automated rollback — the only scripted recovery path is a restored XML export, and the manual rollbacks in §8 depend on remembering what was changed."
**Sources:** s9-style M(finding 57).

### M-49. §13 contains three absolutes and an undefined goal term in one bullet
**Lines:** 499–504.
"Costs nothing to maintain", "it never needs editing for new workloads" and "the cheap half of the containment goal" are absolutes; "the containment goal" is not one of §1's five success criteria and is defined nowhere. Line 500 asserts intent ("the firewall is off on k3s hosts by design") where §3.2 records only the mechanism.
**Fix.** "Today the control plane is reachable from anywhere on the LAN: `networking.firewall.enable` is `mkDefault false` on k3s hosts (§3.2) and etcd `2381/metrics` is unauthenticated on the node address (see B-05's correction). A one-way allow-list needs no edits for new workloads. Independent of every phase here; open it as its own spec."
**Sources:** s9-style M(finding 59).

### M-50. Three sections say "not doing this", and §9 and §11 duplicate each other
**Lines:** §2 45–58 versus §13 493–508 versus §14 509–513; §9 428–456 versus §11 469–478.
Cluster-internal segmentation appears at 46 and 510; captive portal at 56 and 511; mDNS at 53 and 497; IPv6 at 57 and 507; guest intra-VLAN at 277–280, 478 and 506. A reader cannot tell which list is authoritative and every new exclusion must be written twice. §9 and §11 duplicate five items (rack switch, VLAN fallback, coordinator, trunk outage, Phase 3 etcd), and the OPNsense default allow-all warning appears twice (220 and near 310/445).
**Fix.** Merge §13 and §14 into one "Not in this plan" section with one row per exclusion holding the reason and the re-entry condition; reduce §2 to a bare list pointing at it. Keep §9 as prose-only "why" narrative and §11 as the only tabular risk register, with §9 items referenced by `§9.n` from the Mitigation column instead of restated.
**Sources:** s9-style M(finding 61); zoom Nit 10; s7-struct M20; s7-style M20(findings 37, 38, 39).

### M-51. §9 landmines: headings that assert more than their evidence, duplicates, and stale entries
**Lines:** 430, 436–439, 441, 446–447, 449–451, 453–455.
430 states as a law what the body hedges at 433–434, and a heading is the one line guaranteed to be read out of context. 436–439 restates Finding B with the same failure chain and opens with self-reference. 441's heading is certain while the body is conditional ("On some switches"), and "brief" is unquantified — the operator needs to know whether this is 2 seconds or 2 minutes. 446–447 is the third copy of "create the rules before the SSID". 449–451 restates a decision §7.2 already fixed, in the weak "can be / should live" register. 453–455 is a landmine already defused by Phase 0.4 earlier in the same plan, which dilutes the two that are not.
**Fix.** 430 → "**Mesh adoption fails when the wired parent uses a management VLAN.** `[community]`" and drop "the textbook". 436–439 → a pointer to Finding B plus the new content only ("every phase ends with a client-side test at each AP location, not a config screenshot"). 441 → "**Tagging a live trunk can drop the inter-room link**" with the duration stated or explicitly marked unmeasured. Delete 446–447, 449–451 and 453–455. Keep only the mesh/management landmine and the trunk outage.
**Sources:** s9-style M(findings 39–44); zoom Nit 11; s7-struct M21.

### M-52. §8.1 duplicates the restore gate and drifts its referent
**Lines:** 424–426 versus 411–413.
The restore-test prerequisite appears twice in near-identical wording, and 426 says "Do not fold it into the Phase 1 plan" after 421 established the unit as "Phases 0 through 2" — two names for one thing.
**Fix.** State the gate once (keep the 411–413 version as the Gate line) and reduce §8.1 to: "Phase 3 is a cluster migration and gets its own spec, written after Phase 0.5 and after the Gate above is satisfied. Phases 0–2 remain one implementation plan."
**Sources:** s9-style M(finding 38).

### M-53. Finding B is stated three times and the management-VLAN finding four times
**Lines:** 131–134, 137–140, 436–439, 474; and 48–52, 123–141, 178, 428–434.
A restated hazard is a hazard whose canonical wording drifts.
**Fix.** Keep 131–134 canonical. Replace 436–439 with a pointer plus new content only. §11 row 2 keeps the mitigation and cites `§4 Finding B`. Replace 139–140 with "Mitigation: §7.5 SSID scoping and acceptance criterion 5". Non-goals keeps one line plus the anchor; the VLAN-99 row keeps only the anchor.
**Sources:** s7-struct M21; s7-style M22.

### M-54. Ordering does not serve a reader who must execute Phase 0 first
**Lines:** Phase 0 at 316, first referenced at 101, then 110–121, 254, 262–273.
A reader meets "Phase 0" as an undefined token 215 lines before it is defined, and must read all 311 lines of design before learning that the first executable action is an inventory.
**Fix.** Add a short `## 0.1 Reading and execution order` immediately after the markers block stating: §3.3 unknowns → §8 Phase 0 → §7 → §8 Phase 1a → 1b; or move §8 to directly after §6 so the plan precedes §9–§14 commentary.
**Sources:** s7-struct M23.

### M-55. §12 is an open gap with no owner, no phase and no discoverable entry point
**Lines:** 480–491, linked from front matter 9 but absent from §2 and §14.
A reader who scans the scope sections never learns the gap exists; a reader who follows 9 finds "Not in scope to fix here" with no decision owner, deadline or follow-up item.
**Fix.** Add a §2 bullet pointing at §12, and end §12 with an explicit "Deferred decision: … owner: operator, gate: before Phase 2 begins."
**Sources:** s7-struct M24.

### M-56. The marker contract stated at line 13 is not honoured
**Lines:** 13 versus untagged claims at 150, 180–186, 441–444, 207–209.
**Fix.** Tag each (150 needs no tag if it is a switching fact; 180–186 is repo-measurable so `[measured]`; 441–444 needs `[community]` or `[vendor-doc]`), or narrow 13 to "Every claim about a device or file not read directly in this repo is tagged."
**Sources:** s7-struct M25.

### M-57. No `[vendor-doc]` or `[community]` claim has a citation
**Lines:** marker table 15–21; claims at 110–121, 127–128, 277, 284, 430–434, 442.
The marker table promises provenance, but not one of those claims carries a title, URL or rough date. The two load-bearing claims — that mesh EAPs inherit uplink VLAN settings (127) and that mesh adoption fails under a management VLAN (128–129) — decide the rejection of a management VLAN and cannot be checked.
**Fix.** Add a short "Sources" list at the end and link each `[vendor-doc]`/`[community]` claim to it, or downgrade the marker to "recalled, source not recorded" so the reader knows it is not checkable.
**Sources:** compre #7.

### M-58. Load-bearing claims carry no marker at all
**Lines:** 187–188, 260, 266–268, 373–374, 416–417, 442, 31–34, 129–135, 96.
The MQTT/docker-bridge claim at 266–268 is the one that removes the need for a wider hole and is stated as fact while §3.3 admits the Zigbee setup is unknown; the phrasing "HA's docker bridge" is also imprecise, since add-on behaviour depends on configuration that is not marked as checked. The Finding B consequence block (129–135) is an inference from two tagged sentences above it and carries no tag. The nixpkgs 26.05 claim at 96 is tagged only at section level and names no module or commit, unlike neighbouring bullets that name files.
**Fix.** Tag each: `[measured]` for the WireGuard and mesh-advertisement claims (cite the option and file), `[vendor-doc]` for OPNsense keep-state and native-VLAN trunk behaviour, `[unverified]` for the MQTT container-network claim (with the corrected wording "both are Home Assistant add-ons, so MQTT stays inside Home Assistant's container network — confirm in Phase 0.3"). Append `[unverified]` to the Finding B blockquote's last line or state that it is an inference. Add the module path or nixpkgs commit at 96.
**Sources:** compre #20; s7-style N34, N38, N39.

### M-59. The mDNS "deferred seam" is not additive — rule 8 will drop the reflected traffic
**Lines:** 51–55 and 496–498 versus rule 8 at 258.
Both places say reflection can be turned on later "without touching a single VLAN assignment". That is true of VLAN assignment, but an Avahi reflector on OPNsense originates new traffic *into* IoT, which IOT rule 8 (`any → IOT` block + log) will drop, and reflection into the trusted LAN needs the trusted side to accept it too.
**Fix.** Say what must change: "requires one firewall exception from the OPNsense firewall into each reflected VLAN; no VLAN assignment changes."
**Sources:** compre #21.

### M-60. The §10 mesh row permits the outcome Finding B forbids
**Lines:** 463 versus 135–139, 435–439.
The pass condition is "IoT and Guest SSIDs not broadcast there, **or proven tagged**". Finding B's conclusion is that IoT/Guest must not be enabled on those APs at all until individually tested, because tags may not survive a mesh backhaul. The alternative condition reopens the exact hole the row exists to close.
**Fix.** Delete "or proven tagged". The pass condition is "not broadcast on kitchen, entrance or garage", verified by a wifi scan at each location.
**Sources:** compre #22; s9-style M42(finding 48).

### M-61. Remote and mesh access to IoT disappears, and the document treats it as an unqualified win
**Lines:** 40–41, 186–192, 252; §10 row 466.
Today a mesh client can reach any IoT device because everything is on `192.168.0.0/24`. After Phase 1b, IoT is on `10.60.10.0/24`, never advertised into the tunnel and blocked from the mesh side by rule 3, so remote access to a camera, a printer or any device not exposed through HA silently stops working. Line 187 presents the addressing choice purely as a benefit and 466 makes "gains no route to `10.60.10.0/24`" a **pass condition** — an unmeasured assumption encoded as success.
**Fix.** Add Phase 0 item 0.9: "Does the operator reach any IoT or Guest device from the mesh or from outside today? Name the device and the client." If yes, decide now whether a mesh→IoT allow is required — a deliberate narrow hole designed on purpose — rather than a regression found in the dark. State the regression next to the "never advertised into the tunnel" argument.
**Sources:** zoom Major 6; s7-design N5.

### M-62. There is no glossary, and project-specific systems are named as if known
**Lines:** 27, 47, 82–100, 219, 266–268, 324, 392–397, 403, 407, 465, 483–487, 497.
Used with no definition, gloss or link: `comin` and the "comin health gate" (what it is, where it runs, what "rolls the host back" concretely does), SOPS, Longhorn, `titan` (a host absent from the §3.1 diagram), `k8s-casa` (a second repo with no link), `DNS2` and "the registry", "the coder helper" and `coderHost`/`pi.baseUrl`, "the skew rule already in `AGENTS.md`" (unlinked), Flux, "bind zone `casa.arrieta` resolution", split-horizon, `configd`, `z2m` used at 254 before zigbee2mqtt is named at 266, and "CEP wireless bridge" (76) — the CEP-vs-mesh distinction is exactly why the garage AP is excluded, so it is not a detail.
**Fix.** Add a ~10-line glossary table (term → one sentence → owner doc/path) covering the project-specific names, and add the missing links for `AGENTS.md` and `k8s-casa`.
**Sources:** compre #8.

### M-63. General networking vocabulary is used with no gloss
**Lines:** 802.1Q (26, 103, 162, 320), trunk (159, 198–202, 308, 340, 357), native VLAN (133, 172, 437, 442), SNAT, stateful (260), SLAAC and RA (284, 507), iSCSI, VXLAN and kubelet (47), etcd peer vs client URL (389, 402), certificate SAN (390), PoE, VIP, CIDR, captive portal, jumbo frames (416), YAGNI (56), SSDP, Avahi, DHCP reservation.
The whole "fails open" argument depends on the reader knowing what *native VLAN* and *untagged* mean, and the Phase 3 recommendation depends on knowing what jumbo frames are.
**Fix.** See disagreement D-7: the comprehension reviewer asks for a ~30-term glossary; the stage 8 audit authorises only a one-clause gloss at first use of native/untagged (near 131 and at 199) and of trunk/tagged, and refuses the rest. Both positions are recorded; the decision is the caller's.
**Sources:** compre #9; s8-audit §5.1.

### M-64. Port numbers appear without saying which service they belong to
**Lines:** 325, 461 ("a node's `9100`", "`HA:8123`"), 500–502.
A reader who does not already know that 10250 is the kubelet and 2379/2380 are etcd client/peer cannot evaluate the proposed allow-list or notice that 2381 was already discussed at 89–90.
**Fix.** Annotate inline: `6443 (k3s API)`, `10250 (kubelet)`, `2379/2380 (etcd client/peer)`, `2381 (etcd metrics)`, `9100 (node_exporter)`.
**Sources:** compre #10.

### M-65. "Trusted LAN", "legacy LAN", "native VLAN", `LAN_NET` and "flat LAN" are not one thing
**Lines:** 25, 29, 37, 116, 133, 146, 151, 168, 172, 190, 203, 205, 243, 287; also 240/258 versus 475 for "inbound".
The document uses these interchangeably for three distinct referents: untagged VLAN ID 1, the `192.168.0.0/24` range, and the set of devices currently on both. They come apart in Phase 2 — desktops move to VLAN 50 but keep `192.168.0.0/24` — so after Phase 2 "trusted LAN" ≠ VLAN 1 ≠ `LAN_NET`, and rule 2's justification silently changes meaning mid-document. The document never states that rack switch and office switch are the same device either.
**Fix.** Add a definitions block after 22 with exactly three terms and use them exclusively: `legacy segment` (untagged VLAN 1 + `192.168.0.0/24`), `LAN_NET` (the firewall alias, used only in rule tables), `VLAN 1 untagged` (L2 fact only). Delete "trusted LAN", "flat LAN" and "native LAN" as synonyms.
**Sources:** s7-style M29; compre #25.

### M-66. The two switches and the APs are named several different ways in the execution path
**Lines:** 66, 68, 70, 159, 160, 198, 200, 203, 205, 207, 320, 321, 341, 342, 370, 431, 441, 443.
"Rack switch" is also "office switch"; the living-room device is "8-port managed switch" and "8-port switch"; APs are "the two wired APs", "wired parent", "mesh and garage APs". Line 159 "Buy the office switch with B in mind" is ambiguous: the office rack switch is the unknown one, but "office switch" reads as the living-room 8-port unit to a first-time reader. In an execution document, one device with two names is an instruction defect: at 11pm the operator logs into the wrong switch.
**Fix.** Freeze names in §3.1 — `LIVINGROOM-SW`, `OFFICE-SW`, `EAP-LR`, `EAP-OFFICE`, `EAP-KITCHEN`, `EAP-ENTRANCE`, `EAP-GARAGE` — and use them throughout §5–§10.
**Sources:** s9-style M(finding 63); s7-style N10.

### M-67. Register inconsistency between the plan tables
**Lines:** Phase 0 `Item` column 320–324 (noun phrases), Phase 1a/1b 338–362 (imperatives), §10 `Test` column 461–467 (noun phrases).
Three registers in one execution path means the reader has to re-infer, for each table, whether it is telling them to do something or describing something.
**Fix.** Imperative + object in every actionable cell across Phase 0, Phase 1a/1b and §10.
**Sources:** s9-style M(finding 64).

### M-68. Phase 1b step 3 omits alias creation
**Lines:** 355, 338, 226–232, 253.
**Fix.** Add "create aliases" as a sub-step in both 1a step 2 and 1b step 3, and add `GUEST_NET` to the alias table (see B-11).
**Sources:** s9-impl M55.

### M-69. Heading and numbering conventions are broken in three ways
**Lines:** 11 (unnumbered `## Confidence markers` inside a numbered sequence), 62/79/101 versus 110/123 versus 316/332/350/366/378 versus 420 (three mutually incompatible H3 conventions, with `8.1` appearing after `Phase 3`), 79 (confidence marker inside a heading).
The unnumbered H2 breaks the template the sibling spec `2026-10-01-ovh-single-node-k3s-design.md:10` already establishes with a `## 0.` section. `8.1` appears 200+ lines after the `8.x` namespace would be expected, so the reader cannot tell whether it precedes or follows `Phase 3`. A marker in a heading pollutes the anchor slug and is invisible to a marker grep.
**Fix.** Retitle 11 as `## 0. Confidence markers`. Either renumber §8's children `### 8.1 Phase 0 …` through `### 8.5 Phase 3 gets its own spec`, or keep phase names and retitle 420 as `### Phase 3 needs its own spec` placed immediately after the §8 intro (314) with a one-line pointer from Phase 3. Heading 79 → `### 3.2 Logical`, with `[measured]` as the first token of 81.
**Sources:** s7-struct M26, M27, M28.

### M-70. Unbounded absolutes and superlatives that the document itself contradicts
**Lines:** 130, 174, 241, 243–244, 191–192, 39, 110, 151, 380–381, 403–404, 498, 502.
"The single most dangerous item in the whole project" (130) is a superlative with no comparison set, no likelihood and no marker. "It cannot go stale" (243) is unearned — a later edit can narrow it — and the second clause asserts a future human failure with no evidence; the real, stronger reason is unstated: every planned range already falls inside `10.0.0.0/16`. "A cosmetic cost in OPNsense and nothing else" (191–192) is contradicted inside the document, since two coexisting ranges appear in the acceptance expectations. "With no regression" (39) is unbounded with no device inventory. Finding A's heading (110) states a hedged verdict the `[community]` marker and 118–121 do not support. "Preserves everything" (403) is an absolute the same bullet undercuts. "This is the expensive one" (380) is relative to nothing.
**Fix.** 130 → "Consequence:" and let the blockquote stand, or move the ranking to the risk table with likelihood and impact filled. 243–244 → "All Phase 2 and 3 ranges fall inside `10.0.0.0/16`, hence inside `10.0.0.0/8`, so this rule needs no edit when they appear." 191–192 → "The cost is two addressing schemes in OPNsense until Phase 3, and two address ranges in the acceptance expectations." 39 → "Every device listed as available in Home Assistant before Phase 1b remains available after its batch move, checked per batch." 110 → "Finding A — the current boundary is unproven `[community]`". 174/241 → "no inbound rule is permitted on this interface; rule 4 is terminal". 380–381 → state the actual change list and drop the sentence about editorial intent. 403 → "avoids re-provisioning nodes and re-encrypting Longhorn volumes", and state the skew rule in one clause.
**Sources:** s7-style M30, M32, M33, M34, M41; s7-style N12; s9-style M49, M50; s9-style N(finding 60).

### M-71. Dangling, deictic and mixed cross-references
**Lines:** 254 ("see note" with nothing labelled "note"), 213 ("the table", two sections up), 178 (prose pointer matching no heading), 9/51/54/58 versus 322/327 versus 139/178 (three cross-reference conventions in one document).
**Fix.** 254 → "see the note below the table" and label the paragraph `**Note on rule 5.**` at 265. 213 → "from the §6 table". Pick `§N` for body text and reserve markdown anchors for the front matter, as the sibling spec does.
**Sources:** s7-struct M16, N44, N46, N47.

### M-72. Table contract violations and a broken ASCII diagram
**Lines:** 230, 250, 253 (empty cells where the column contract expects a value), 231–232 (the `Source` column holds a value and a status; italic on one row, plain on the next), 35/153/180/187/234/246/275 (structural weight carried by bold pseudo-headings invisible to the outline, with 139 cross-referencing "Acceptance criterion 5" by number into a pseudo-headed list), 234 versus 246 (asymmetric wording on the two parallel rule tables), 293 (the §7.5 SSID column holds a description; the trusted SSID's actual name appears nowhere and is not in §3.3's unknowns), 64–77 (the §3.1 diagram has three broken joins: the OFFICE tree has no drawn root, the inter-room label is detached from the line it names, and `EAP610 (wired)` hangs off an already-closed branch; `[unverified]` inside a code fence cannot be grepped as a marker).
**Fix.** Fill empty cells or use `—` consistently (the document already uses `—` at 178). `HA_SERVER` → `Value = unknown until Phase 0.3`, `Source = Phase 0.3`. Promote 35 to `### 1.1 Success criteria` and retitle 139 to cite `§1.1 item 5`. Use the same "evaluated top to bottom" suffix on both rule tables. `| <trusted SSID name — Phase 0> |` and add it to §3.3. Give the OFFICE tree a root line, move the inter-room label onto the drawing line, add a continuation column, and move the `.6 [unverified]` marker into §3.3's unknown list.
**Sources:** s7-struct N41, N42, N43, N49, N54; s7-style N11.

### M-73. §6's VLAN table contradicts itself and disagrees with §8 Phase 3
**Lines:** 170–178, especially 172 and 175 versus 415; authority claim at 167.
172 says `Phase = 1 unchanged` while its Notes cell says `Retired in Phase 3`, and the `Phase` column mixes phase IDs with lifecycle states (`1 unchanged`, `3 reserved`, `never`), so it cannot be read as a schedule. 175 makes VLAN 30 conditional ("Only if the control plane moves") while 415 recommends servers to VLAN 30 — and 167 declares §6 the single source of truth, so the conditional in the table is the version a reader will act on.
**Fix.** Split into `| VLAN | Name | Subnet | Introduced | Status |`: VLAN 1 → Introduced `1`, Status `re-addressed in 3; remains untagged native and break-glass`; 30/40 → Introduced `3`, Status `reserved`; 99 → Introduced `—`, Status `never`. Make 175's Notes read "Recommended in Phase 3 scope (see §8 Phase 3); conditional on the control-plane move."
**Sources:** s7-struct M17, M18.

### M-74. Fix-set scope: the naive fix set grows the document ~37%, and deletions must land before additions
**Lines:** whole document; the aggregate of all five reviews.
Naive application adds roughly 190 lines (two glossaries ~45, a sources list ~12, Phase 2/3 acceptance rows and rules ~25, the design reviewer's additions ~75, the structural reviewer's ~35) to a 513-line document whose executable content is twelve firewall rules and two SSIDs — for an author who is also the only implementer, on a spec whose §12 already admits it has no diff, no review and no rollback.
**Fix.** Sequence the revision as (a) the deletions in M-75, (b) the four one-line factual corrections (rule order, `GUEST_NET`, the backwards Phase 0.4 diagnostic, the z2m port), (c) the authorised additions. Do not interleave: structural renumbering churns lines the deletions remove. Net target ≈ 430 lines — smaller than today and strictly better. If the cuts do not land first, the additions should not land at all.
**Sources:** s8-audit §1, §9.

### M-75. Cut outright rather than fix
**Lines:** 378–426 (Phase 3 body + §8.1 → four lines), 366–376 (Phase 2 → one §6 row), 509–513 (§14, duplicate of §2), 436–455 (§9's restatements, keeping only 430–435 and 441–444), 486–491 (§12's tooling menu), 265–273 (the rule-5 prose essay), 175–176 (VLAN 30/40 conditional prose and their presence in the day-one tag set), 463 (`or proven tagged`).
These cuts remove roughly 130 lines and retire a long list of dependent findings — including the §11 Phase 3 row, the §14/Phase 3 `titan` contradiction, the "Retired in Phase 3" self-contradiction, and the claim at 314 (which becomes true without hedging).
**Fix.** Execute the list. Then §1's criteria, §6, §10 and §11 each shrink to the scope the document actually executes. See disagreement D-2 and D-3 — three other reviewers want Phase 2 and Phase 3 corrected and expanded rather than cut.
**Sources:** s8-audit §2; zoom Blocker 2, Major 4, Nit 11, Nit 14.

### M-76. Phase 0 is the only section where additions are unambiguously good value
**Lines:** 316–330, 312–314.
Phase 0 changes nothing, costs an afternoon, and every item replaces a guess currently load-bearing in §7. Let it grow from 8 items to about 12, not 15, by collapsing demanded items into existing ones: 0.3 absorbs name-resolution questions, the LAN-hostname-dependency question, the UDP-control-path question and the z2m port number; 0.4 absorbs the coordinator's **static** address on the device itself (not a reservation) and the observed socket direction; 0.8 absorbs the controller backup location and the config-retention question; new 0.9 covers every SSID broadcast per AP with its VLAN/isolation setting plus a count of devices joining VLAN 10 and which need a reservation; new 0.10 asks whether the operator reaches IoT or Guest devices from the mesh today. Do **not** add a Phase 0 item for the WAN address family — widen the alias instead (N-01).
**Fix.** Apply the merges above and scope 312–314 to "Phases 0–2".
**Sources:** s8-audit §6.

### M-77. Add an honesty block: "What this boundary does not buy you"
**Lines:** §1 35–43, §2 45–58, §11 469–478.
Six reviewer findings are true and none of them should be *fixed* — each is unfixable without TLS inspection, already accepted, or outside the goal's scope. What is missing is not mitigation but a short list, so a future reader does not believe more was built than was.
**Fix.** Add one block of five to eight bullets under §2: IoT may still reach the whole public internet (vendor cloud, OTA, exfiltration); guests can reach and, on a shared passphrase, passively decrypt each other; DNS is not a boundary (DoH is reachable); wired IoT-class devices stay on VLAN 1; roadwarriors lose direct reachability to IoT; OPNsense becomes a new control-plane dependency for HA↔IoT and one inter-room cable carries every segment; the control plane remains reachable from anywhere on the trusted LAN. Then cap §11 at nine rows and allow `accepted — no mitigation` as a legal Mitigation cell value; forcing a mitigation into every cell is what manufactures mitigations worse than their risks.
**Sources:** s8-audit §8; s7-design B2/M6/M7/M9 (as the underlying facts).

### M-78. Demanded mitigations that are worse than the risk they address, and additions to refuse outright
**Lines:** §5 142–153; §11 469–478; §7.6 300–311; 218–220, 255; 297; 51–53, 322, 352–355.
The following demanded mitigations should not be added in the form proposed: the dead-native-VLAN "cheap partial" on the two AP trunk ports (it re-imports the rejected management-VLAN pattern onto the two mesh parents and contradicts the break-glass rule at 307–308 — record it as a §13 bench-test candidate, one line, no new phase); per-device static address plus local DNS record as the mDNS fallback (a permanent hand-edit on the one device §12 says has no diff — use a gate instead); a Longhorn drain runbook for one scheduled trunk edit (ordering beats procedure — see M-12); deliberately stopping the Omada controller and rebooting a production AP as a §10 test (a mitigation that can take out the office's wireless is an incident, not a test — take the cheap half: controller and per-AP config export in §7.6, plus the retention question answered from docs or a bench unit); an outbound 853 block while rule 6 leaves 443 wide open (theater — keep the resolver-scoping sentence and the "DNS is not a boundary" sentence); WPA3/OWE migration on the guest SSID (accept the free per-AP isolation checkbox, record the residual). Refuse outright: a general-vocabulary glossary (see D-7), a full §5 decision matrix (see D-8), an invented Likelihood scale for a six-row homelab risk table (replace the values with `observed / possible / speculative` or drop the column), and a per-change checklist that instructs the operator to also edit this document's own tables (that makes the spec a second source of truth for live config and guarantees drift).
**Fix.** Apply the refusals above; see disagreements D-7 to D-13.
**Sources:** s8-audit §4.1–4.6, §5.1–5.4.

---

## Nits

Ordered: technical nits first, then wording batches.

### N-01. `RFC1918` is not the whole non-routable space
**Lines:** 229, 239. The alias omits `100.64.0.0/10` (carrier NAT — frequently the actual WAN address on consumer ISPs, and the space Tailscale-class meshes use), `169.254.0.0/16` and `127.0.0.0/8`. If OPNsense's WAN is in `100.64/10`, guests can reach the WAN-side interface and anything else in that space, defeating the claim at 239.
**Fix.** Widen the alias (or add a `NON_ROUTABLE` alias) to include `100.64.0.0/10`. One cell, not a Phase 0 inventory item. **Sources:** s7-design N1; s8-audit §6.

### N-02. VLAN 30/40 tagged on every trunk with no scheduled use
**Lines:** 155–157, 174–176, 197–201, 415–418. VLANs 30 and 40 are reserved with subnets and tagged on every trunk and AP while §6 marks 40 "not recommended" and Phase 3 recommends leaving storage flat. Dead tags on every trunk forever is a permanent confusion cost with no benefit.
**Fix.** Tag only `{10,20}` on day one; add 30/40 when Phase 3 actually schedules them. The §6 table is where a reservation is recorded. **Sources:** s7-design N3.

### N-03. §6's collision argument ignores default-route tunnels
**Lines:** 186–192. The claim holds only for split-tunnel clients; on a default-route tunnel, a roadwarrior whose home LAN is `10.60.0.0/16` has that space captured by the tunnel regardless of what the tunnel advertises.
**Fix.** Add "for roadwarriors on a default-route tunnel any `/16` can collide with their own LAN; `10.60/16` is chosen as unlikely, not impossible." **Sources:** s7-design N4.

### N-04. §7.6 break-glass covers only OPNsense, and its own path is retired by Phase 3
**Lines:** 300–311, 308–309, 172. The switch management UI also lives on native VLAN 1, and changing a management port's tag set is exactly the edit being made — there is no switch backup step and no "do not touch the management port" rule. The Omada controller has no backup step either. 308 makes untagged native-1 membership the documented path back in, and 172 retires native 1 with no acknowledgement that Phase 3 must replace the path before removing it.
**Fix.** Add bullets for switch config backup plus "do not change the management port's native VLAN", and an Omada controller and per-AP export; add "Phase 3 must define its replacement break-glass path before retiring native VLAN 1." **Sources:** s7-design N6; s9-impl M4 (partial).

### N-05. Rule 1 is not implementable as written
**Lines:** 238, 250. "Allow DNS, DHCP" names neither protocol nor ports, and DHCP is UDP 67/68 from a client with no address. Whether NTP is allowed is unspecified, and some IoT devices fail setup without it. The block+log rules have no rate limit, so chatty blocked devices will flood the firewall log.
**Fix.** Write rule 1 as `proto UDP, src any, dst this firewall, dst ports 53,67,68 allow`, state the NTP decision, and note a log rate limit on the block+log rules. **Sources:** s7-design N7.

### N-06. §13 defers the highest value-per-hour item with no owner or trigger
**Lines:** 493–508, 90–91. The control-plane allow-list protects an exposure described as costing nothing to maintain and independent of every phase — then it is deferred with no owner, no phase and no trigger.
**Fix.** Give it an owner and a trigger. See disagreement D-5: one reviewer promotes it to a phase, two reduce it to a pointer at the existing `etcd-metrics-proxy` pattern. **Sources:** s7-design N8.

### N-07. "The rack" is used both as a location and as a device
**Lines:** 200, 203, 207, 263. Line 263's "scan the rack" is a test-relevant target and names no address.
**Fix.** "Rack switch" for the device everywhere; 263 → "cannot scan the server subnet `192.168.0.0/24`". **Sources:** s7-style N9.

### N-08. The alias table's `Source` column holds a value, not a source
**Lines:** 231, 232. The Value cell holds a phase, the Source cell holds a status, and 231 is italic while 232 is plain in the same column.
**Fix.** `Value = unknown until Phase 0.3`, `Source = Phase 0.3`. **Sources:** s7-style N11; s7-struct N54.

### N-09. "No inbound hole, ever" / "no inbound, ever"
**Lines:** 174, 241. "Ever" is unbounded; a per-interface rule can be deleted by a later edit.
**Fix.** "No inbound rule is permitted on this interface; rule 4 is terminal and nothing above it allows inbound." **Sources:** s7-style N12.

### N-10. §6's range list mislabels its own contents
**Lines:** 180–183. Consumer-router defaults are not "ranges this fleet already owns". The shorthand `192.168.0/24`, `10.0.0/24`, `10.10/16` is malformed CIDR, and `172.17.0.0/16` is listed separately although it is inside `172.16.0.0/12`.
**Fix.** "Chosen to avoid three sets: the ranges this fleet owns (…), the common consumer-router defaults (…), and the classic OpenVPN defaults `10.8/8` and `10.9/8`." **Sources:** s7-style N13; compre #26.

### N-11. Rhetorical phrasing, slang and metaphor in rule and verdict cells
**Lines:** 150 ("Rejected on physics"), 239 ("one rule kills"), 259 ("the design's spine", "load-bearing"), 49 ("maintenance tax … Explicitly rejected"), 56 ("YAGNI."), 53 ("Documented as an additive seam"), 57 ("actively undesirable"), 185 ("a decision, not an accident"), 151–152 (chiasmus restating one fact twice), 432 ("the textbook").
**Fix.** 150 → "**Rejected.** Two hosts on the same switch never traverse the router, so intra-LAN traffic cannot be filtered without a VLAN boundary." 239 → "one rule covers LAN, IoT and mesh, and any private range added later". 259 → "Rule order is load-bearing: the allow from `HA_SERVER` must precede the block." 49 → "each new workload would need its node-to-node rules reviewed, and no in-cluster workload is untrusted here. Rejected." 56 → "Not built: no current need, and each one adds a maintenance surface." 53 → "Listed under Deferred seams as a later addition". 57 → "Out of scope; see [IPv6 policy]". 185 → "Recorded here so a later editor changes it only with a reason." 151–152 → "Do the re-address last: Phase 1 delivers the boundary before the cluster-risky step is taken." **Sources:** s7-style N14–N21, N31; s9-style M(finding 39).

### N-12. Editorial asides and duplicated instructions inside configuration text
**Lines:** 215 ("Small pools" is noise once the numbers exist), 216 ("above all" is an aside inside an instruction, and it pre-commits the coordinator to VLAN 10 before Phase 0.4 decides its socket direction), 29 ("Long term" has no referent in a document with a named phase for exactly this), 335 ("trivially visible, trivially reversible"), 159 ("from day one" and "always" are the same instruction, and "day one" is inconsistent with the phase vocabulary), 148 and 368 ("Cheap, and it is the half of…" duplicated, unquantified, unclear metaphor).
**Fix.** 215 → "DHCP pool `.100`–`.200` (101 addresses) on each of VLAN 10 and VLAN 20; static reservations below `.100`." 216 → delete the parenthesis. 29 → "Phase 3 also moves the legacy segment off `192.168.0.0/24`." 335 → "which is visible and reversible". 159 → "Tag every VLAN on the inter-room trunk in Phase 1. One cable, all VLANs." 148 → "Adopted as Phase 2. Changes only the desktop ports on the office rack switch; no NixOS host config changes. It protects the operator's machines from a cluster compromise." 368 → delete and cross-reference row B-lite. **Sources:** s7-style N29, N30, N33, M36, M37, M38.

### N-13. Passive voice with no actor, and hidden actors
**Lines:** 103 ("Produced in Phase 0, not assumed here"), 22 ("Nothing tagged `[unverified]` should be acted on"), 203–204 ("the desktop ports become untagged 50" hides that someone edits the office rack switch).
**Fix.** 103 → "Phase 0 produces: the two switch models and their 802.1Q support, Home Assistant's IP, the Zigbee coordinator's model and socket mode, an authoritative map of every static IP on the segment, and what enforces the current IoT/Guest boundary." 22 → "Do not act on a `[unverified]` claim until Phase 0 confirms it." 203–204 → "In Phase 2, set the desktop ports on the office rack switch to untagged 50." **Sources:** s7-style N25, N26, M39.

### N-14. Intensifiers and filler
**Lines:** 105, 305, 322, 411, 425 ("actually"); 176, 178, 243, 334 ("deliberately"); 30 ("live problem"); 374 ("Note this also"); 354 ("This is a requirement, not a nicety."); 306 ("Not 'should work' — confirmed.").
**Fix.** Delete "actually" at 105; rewrite 305 as "Confirm that console access to OPNsense works (monitor and keyboard, or serial) — confirmed working, not assumed" and merge 306 into it; 322 → "whether mDNS is in use today". 176 → "Only if iSCSI is routed across a router."; 178 → "Unused by design. See the mesh landmine."; 243 → "Rule 2 uses `RFC1918` rather than `LAN_NET`."; 334 → "Guest first: nothing on it needs to be reachable…". 30 → "which breaks the local network of any roadwarrior whose own LAN uses that range." Drop 374's "Note this also", drop 354 entirely, drop "the textbook" at 432. **Sources:** s7-style N27, N28, N22; s9-style M(finding 16), M(finding 24), M(finding 39).

### N-15. Unbounded comparatives where the number exists or is knowable
**Lines:** 151 ("the expensive, cluster-risky step"), 490 ("far safer"), 502 ("costs nothing to maintain"), 407 ("Often *less* risky"), 408 ("a real outage window"), 441 ("a brief outage"), 329 ("costs ten minutes"), 380 ("the expensive one").
**Fix.** 151 → "The re-address touches all 13 hosts plus the live etcd member URLs (see Phase 3)." 490 → name the mechanism instead of the comparative. 407–409 → "Neither path has been tried here. Rebuild avoids live etcd surgery but requires a full restore rehearsal and an outage window long enough to restore etcd, Longhorn and Flux (measure it during the rehearsal; do not guess it now)." 441 → "duration unmeasured; treat as a full link outage until measured on your switch model." Drop 329's estimate or keep only "0.6 is the cheapest item in this table and it changes how §4 Finding A is read."
**Sources:** s7-style N23; s9-style M(finding 26), M(finding 33); s9-impl M54.

### N-16. "OPNsense `LAN` NIC → 8-port switch port 1" — fact or proposal?
**Lines:** 198. Unclear whether port 1 is a fact about the current wiring or a proposal.
**Fix.** "Connect the OPNsense `LAN` NIC to a chosen uplink port on the living-room switch (port 1 in this document; record the actual port in Phase 0.1)." **Sources:** s7-style N24.

### N-17. The OPNsense default allow-all warning appears twice
**Lines:** 220 (the instruction) and the landmine text adjacent to 310/445.
**Fix.** Keep 220 as the instruction and drop the cautionary restatement. **Sources:** s7-style N32; s7-style M20(finding 39).

### N-18. The Finding B consequence block carries no marker
**Lines:** 129–135. The mechanism ("may fall back to untagged") is an inference from `[vendor-doc]` and `[community]` evidence cited two lines above, but it is presented in a bold blockquote with no tag.
**Fix.** Append `[unverified]` to the blockquote's last line and let Phase 0.1/0.2 close it, or state explicitly that it is an inference from the two tagged sentences above. **Sources:** s7-style N38.

### N-19. The nixpkgs 26.05 claim names no module or commit
**Lines:** 96. Tagged `[measured]` at section level but no file or nixpkgs source is named, unlike the neighbouring bullets which name files.
**Fix.** Add the module path or the nixpkgs commit the claim was read from. **Sources:** s7-style N39.

### N-20. Word-level trims
| Line | Text | Fix |
|---|---|---|
| 25 | "from *apparent* isolation to a real L2/L3 boundary" | "to an L2/L3 boundary enforced by" — "real" is a loaded adjective |
| 43 | "Every boundary is *tested from a client*…" | Keep; it is restated at 139–140 and 275 |
| 116 | "with IPv6 being the part that resists ACLs entirely" | "and IPv6 is the part ACLs do not cover" |
| 146 | "Delivers the stated goal, touches zero NixOS hosts, rules written once." | "No NixOS host changes; the ruleset is written once." |
| 147 | "Deferred to Phase 2/3, and reduced — see B-lite." | "Deferred to Phase 2/3 in reduced form (B-lite)." |
| 149 | "Folded into Phase 1a/1b staging rather than chosen as an endpoint." | "Not chosen; the staging in Phase 1a/1b already sequences Guest first." |
| 208 | "That is a hardware purchase, not a redesign." | Keep — a concrete consequence, not filler |
**Sources:** s7-style N40.

### N-21. §7.6 title does not match its content
**Lines:** 300. Four of five lines are a pre-change checklist; only 307–308 is an actual break-glass path.
**Fix.** `### 7.6 Pre-change safety checklist and break-glass path`. **Sources:** s7-struct N45.

### N-22. §11's Likelihood column has no defined scale
**Lines:** 469–478. `certain` (478) is not on the same scale as `medium`/`low`, and no scale is defined anywhere. The "certain" row is a known limitation, not a risk, which makes the column unreadable.
**Fix.** See disagreement D-13: add a scale key, or replace the values with `observed / possible / speculative`, or drop the column and keep Impact plus Mitigation and move the 478 row to §7.3. Add a `Checked at` column naming the Phase 0 item or phase step so the table is not read once and forgotten. **Sources:** s7-struct N50; s9-style N9, N11; s8-audit §5.3.

### N-23. §10 row bundles three independent pass conditions
**Lines:** 465 (roadwarrior reaches `6443` **and** reaches the rack **and** gains no route to `10.60.10.0/24`/`10.60.20.0/24`).
**Fix.** Split into three rows so each has one observable outcome. Related row-level gaps: the z2m row names no log path (→ "HA > Settings > Add-ons > zigbee2mqtt > Log shows `Connected` and no reconnect within 10 minutes"), and the cluster row does not say when, by whom or from where (→ "Run `kubectl get nodes` from titan immediately before Phase 1 step 4 and after step 8; all 7 cluster nodes Ready in both runs"). **Sources:** s7-struct N51; s9-style N7, N8.

### N-24. §5's Verdict column mixes verdict types and forward-references a lower row
**Lines:** 146–151: `Adopted`, `Deferred … see B-lite` (147 pointing at 148), `Folded into`, `Rejected on physics`, `Rejected as an order`.
**Fix.** Split into `Verdict` (adopted / rejected / deferred) and `Rationale`, and move B-lite above B so verdicts never point downward. **Sources:** s7-struct N52.

### N-25. No table of contents, and §12–§14 have no ordering principle
**Lines:** whole document — 513 lines, 14 H2 + 17 H3, with the reader shuttling between §7 and §8 on every rule.
**Fix.** Add a TOC after the markers block and group as scope (§2, §14) → design (§5–§7) → execution (§8, §10) → risk (§9, §11) → deferred (§12, §13). **Sources:** s7-struct N53.

### N-26. Phase 0.3's `Resolves` cell quotes an undefined proposition
**Lines:** 322 — `whether "no mDNS" is actually true today`. The quoted phrase appears nowhere earlier as a defined proposition.
**Fix.** "Whether §7.3's assumption that HA addresses IoT devices by IP holds." **Sources:** s9-style N1.

### N-27. Phase 0.8's parenthetical is not a partition
**Lines:** 327 — "(hardware, software, cloud)". A container on a NixOS host is both. The `Resolves` cell says "rollback mechanics" without saying why.
**Fix.** "Confirm which Omada controller is in use: OC200/OC300 gateway box, self-hosted controller (record host and port), or TP-Link cloud. | Resolves: whether an SSID rollback can be done offline, or only through a cloud login." **Sources:** s9-style N2.

### N-28. "Including rule 5 only if Phase 0.4 requires it"
**Lines:** 356. Phase 0.4 is a measurement; it cannot require anything. The actual condition is stated 90 lines earlier at 271–275.
**Fix.** "Add rule 5 only if Phase 0.4 found no listening socket on the z2m port (coordinator is a TCP client)." **Sources:** s9-style N4.

### N-29. Phase 1b step 2 drops "address" from the list that Phase 1a step 1 has
**Lines:** 354 versus 338.
**Fix.** Make the two steps identical in shape so neither interface is created half-configured. **Sources:** s9-impl N5.

### N-30. "Unless there is a specific reason" is an open conditional with no criterion
**Lines:** 418. It invites exactly the reason-free change it is meant to prevent.
**Fix.** Drop the clause, or name the one acceptable reason. **Sources:** s9-style N6.

### N-31. §12 wording
**Lines:** 486–491. "Not in scope to fix here, but the options worth a decision later:" is throat-clearing; "a well-trodden `ansible`/terraform-provider path" uses an adjective where a name would do; "would make Phase 2 and 3 far safer" is an unmeasured comparative. The option menu is also speculative design for a decision the section explicitly defers.
**Fix.** "Out of scope here. Options for a later decision: OPNsense REST/`configd` API, an Ansible or terraform provider, and the Omada controller API. A minimal version — VLAN table, interface definitions and firewall ruleset rendered from a Nix module and diffed against the live device — would give Phase 2 and 3 a reviewable diff before apply instead of a hand edit on a live firewall." Or delete the menu entirely and keep the gap statement plus "the XML export is the only rollback". **Sources:** s9-style N12; zoom Nit 14.

### N-32. "Nothing about the VLAN plan changes" is an absolute about an undesigned change
**Lines:** 498.
**Fix.** "No VLAN reassignment is expected to change." **Sources:** s9-style N13.

### N-33. §13's IPv6 line is a fragment, and RA/SLAAC are never expanded
**Lines:** 507.
**Fix.** "Add IPv6 to IoT and Guest only after a plan exists for router-advertised prefix changes and SLAAC-based guest isolation (see §7.4 for why it is excluded now)." **Sources:** s9-style N14.

### N-34. Line 88 attributes the etcd documentation to one host
**Lines:** 88. The identical comment block is in `hosts/k8s-server02/vars.nix` and `hosts/k8s-server03/vars.nix`.
**Fix.** Say "every casa server's `vars.nix`". **Sources:** s9-code N1.

### N-35. Line 95–96 calls `coderHost.allowedApiSources` a `192.168.0.29` reference
**Lines:** 95–96. The live value is `hosts/llm01/configuration.nix:76`: `[ "192.168.0.0/24" ]` — a /24, not `.29`. It does need changing in Phase 3, but it is not a `.29` reference.
**Fix.** Reword to "…`coderHost.allowedApiSources` (the LAN `/24`, not the host)". **Sources:** s9-code N2.

### N-36. Line 393 understates the rsyslog fan-out
**Lines:** 393. `modules/nixos/rsyslog.nix:36` sets `default = "192.168.0.41"` and no host overrides `rsyslog.server`, while 11 hosts set `rsyslog.enable = true`. One edit changes 11 hosts at once — the only row in the table where a single change is atomic across the fleet rather than per-host.
**Fix.** Note the fan-out in the row. **Sources:** s9-code N3.

### N-37. Line 461's "node `9100`" is not what it looks like on the casa nodes
**Lines:** 461, 325. `prometheus.nix` node_exporter is enabled only on `titan` and `llm01`; on the casa nodes 9100 is the in-cluster node-exporter DaemonSet. The probe is still valid, but the two 9100s have different owners and failure modes.
**Fix.** Name which 9100 the row means. **Sources:** s9-code N4.

### N-38. Hedged wording where the answer is knowable
**Lines:** 353, 407, 418, 442, 450, 463, 490, 502. Each is a place where either Phase 0 will produce the answer or the author already decided it.
**Fix.** Tie each hedge to the item that resolves it, or state the decision. **Sources:** s9-style N23.

### N-39. Forward references that need pointers
**Lines:** 27 and 47 (Longhorn, etcd, kubelet, flannel VXLAN used before §3.2 describes the cluster), 51 (points at a landmine argued in §4 and §9), 147 ("an etcd and k3s certificate event", explained only at 389–390), 172 and 176 (explained only at 414–418), 254 ("see note", the note is at 264–273), 104 ("socket mode" defined only at 269–273), 216 (the coordinator's role unexplained until 266–273).
**Fix.** Add short "(see §…)" pointers at each site; at 47 add a half-sentence naming each component. **Sources:** compre #24.

### N-40. Small ambiguities that cost a reader time
**Lines:** 212 (`opt10` → `IOT` — which is the auto-assigned name and which the description), 137 ("Acceptance criterion 5" refers to §1's list while §10 is the section titled "Testing and acceptance"), 388 ("all 13 hosts" cannot be reconciled with the §3.1 diagram), 323 versus 272 (`ss -ltnp` versus `sockstat` — `sockstat` is the FreeBSD tool; say which applies to the HA install), 340 (step 2's "never an unfiltered window" is true only because no client can join yet — that is the actual reason), 175 ("Only if the control plane moves" gives no reason why it would), 146 ("rules written once" versus Phase 2's "Add to the ruleset"), 74–75 (does not say which wired AP is the mesh parent, which matters for §9 line 434), 84 ("the module parses addresses at eval time" does not name the module or say why it matters), 91 ("hub on `titan`" names a host absent from the §3.1 diagram).
**Fix.** Mechanical edits as sketched. **Sources:** compre #26.

### N-41. Phase 0.7 duplicates §7.6
**Lines:** 326 versus 300–310. Console confirmation and config export are a preflight for Phase 1, not inventory.
**Fix.** Delete 0.7 and make §7.6 step 0 of Phase 1a. **Sources:** zoom Nit 12.

### N-42. §11 "SSIDs disabled on mesh" repeats the false partition
**Lines:** 474. The garage AP is a CEP bridge, not a mesh child (96).
**Fix.** Use "disabled on kitchen, entrance and garage APs". **Sources:** s9-style N10.

### N-43. §10's mesh row alternative is a deletion, not a repair
**Lines:** 463. See M-60; recorded separately because the fix is a deletion rather than a rewrite.
**Fix.** Delete "or proven tagged". **Sources:** compre #22.

### N-44. Phase 1b step 5 must state expected z2m downtime and that Zigbee devices do not need re-pairing
**Lines:** 357–358.
**Fix.** State the expected downtime between moving the coordinator and repointing z2m, and state that Zigbee devices do not need re-pairing for it. **Sources:** s9-impl N22.

### N-45. Phase 0.1's "whether all ports trunk" is not an answerable question
**Lines:** 320 versus §7.1 line 205 (server ports are untagged access ports).
**Fix.** Replace with "which ports support tagging, and how many are free." **Sources:** s9-impl N20.

### N-46. Phase 0.5's scan scope omits desktops
**Lines:** 324. Phase 2 moves desktops to DHCP on VLAN 50, which changes their IPs.
**Fix.** Add desktops (and printers) to the Phase 0.5 scan scope. **Sources:** s9-impl N19.

### N-47. Phase 1a step 2 must state the anti-lockout rule and the ordering consequence
**Lines:** 339, 220, 237.
**Fix.** State that the anti-lockout rule must not be touched, and that once the allow-all is gone rule 1 must already be present or DNS and DHCP break at that instant. **Sources:** s9-impl N21.

### N-48. §11's "certain" row is a known limitation, not a risk
**Lines:** 478. It sits in a table whose other rows are probabilistic.
**Fix.** Move it out of §11 into §7.3 (where 277–280 already states it) and leave §11 to uncertain items. **Sources:** s9-style N9.

### N-49. §11 needs a "checked at" column
**Lines:** 469–478. The table is read once and forgotten.
**Fix.** Add a `Checked at` column naming the Phase 0 item or phase step. **Sources:** s9-style N11.

### N-50. §10's z2m row names no log path
**Lines:** 464.
**Fix.** "z2m add-on log (HA > Settings > Add-ons > zigbee2mqtt > Log) shows `Connected` and no reconnect within 10 minutes." **Sources:** s9-style N7.

### N-51. §10's cluster row does not say when, by whom, or from where
**Lines:** 465.
**Fix.** "Run `kubectl get nodes` from titan immediately before Phase 1 step 4 and after step 8; all 7 cluster nodes Ready in both runs." **Sources:** s9-style N8.

### N-52. §10's roadwarrior row states conditions without the commands that show them
**Lines:** 466. "The rack as before" is not a test; "gains no route" states a condition without the command.
**Fix.** "From a connected roadwarrior: `nc -vz -w3 192.168.0.11 6443` succeeds; `nc -vz -w3 <named rack host> <port>` succeeds; `ip route` inside the tunnel contains no `10.60.10.0/24` or `10.60.20.0/24`." **Sources:** s9-style M42(finding 51).

### N-53. §10's rollout row may not be executable without side effects
**Lines:** 467. A script name is not a test procedure; if `comin-approve.sh` has no dry-run or list mode, the row cannot be executed without touching a live fleet — a fact the row should state either way.
**Fix.** Name the invocation and expected output, e.g. "`scripts/comin-approve.sh --list` (or the read-only path) prints all 13 hostnames with reachable addresses; no host falls back to a `192.168.0.x` address that no longer answers." **Sources:** s9-style M42(finding 52).

---

## Where reviewers disagree

Both positions are recorded. Nothing below is averaged.

**D-1. Rule 5: repair it or delete it.**
`s7-design` B1, `compre` #1/#4/#6 and `zoom` Blocker 1 all repair it: renumber above the block, name the port, qualify criterion 1, add the UDP caveat. `s8-audit` §3 argues that is six repairs to keep a rule the document has already admitted it cannot write yet, and proposes replacing 254 + 265–273 with three lines: Phase 0.4 records the coordinator's address, port and listening end; Phase 1b then writes exactly one narrow allow in the measured direction, placed above the block; until Phase 0.4 reports, the rule does not exist. That deletion also retires B-10, the `ZIGBEE_COORD` alias, §11 row 475 and the criterion-1 contradiction. `s8-audit` also states an optional variant (allow `IOT → HA_SERVER` outright, deleting Phase 0.4) with its honest cost. **Unresolved; the caller picks.**

**D-2. Phase 3: correct the table or delete the section.**
`s9-code` B3/B4/M2–M10 correct the blast-radius table row by row, which presumes the table stays. `zoom` Blocker 2 and `s8-audit` §2 delete lines 378–426 down to four lines, arguing that a quarter of the document is about work this document will not execute and explicitly disowns, and that a hand-transcribed inventory is already wrong in three verifiable ways where a fresh `grep` at planning time would not be. **Unresolved.**

**D-3. Phase 2: write it to plan standard or cut it to one row.**
`s9-impl` B9/M15, `s9-style` B(finding 22) and `compre` #19 want it written to the same standard as 1a/1b, on the grounds that prose between two executed phases will be executed as if it were a plan. `zoom` Major 4 and `s8-audit` §2 want it reduced to one §6 row — "VLAN 50 is reserved for operator desktops; its ruleset and its switch dependency make it its own spec" — on the grounds that it is an undecided phase inside an executable plan and the only thing it needs from this document is the reserved ID. **Unresolved.**

**D-4. Phase 0.6's outcome: promote it or drop the claim.**
`s8-audit` §7.2 calls it the highest-leverage line in the document and promotes it to a stop condition in §1: "if Phase 0.6 shows an enforced boundary, this spec's Phase 1 is re-prioritised below the etcd-metrics fix before any switch or AP is touched." `s9-impl` M54 and `s9-style` M54 observe that the plan is byte-identical in both branches and recommend dropping the sentence, or stating concretely what changes. **Unresolved.**

**D-5. §13's control-plane allow-list: promote to a phase or reduce to a pointer.**
`s7-design` N8 promotes it to Phase 1c or a Phase 0 action, arguing it is the largest real security gain in the document, costs one alias plus one rule, and depends on no VLAN work. `zoom` Major 8 and `s8-audit` §7.1 disown it: the exposure is mis-stated (B-05), the repo already contains the bound-to-one-address pattern in `etcd-metrics-proxy.nix`, and the fix is a per-host flag change reusing an existing module — its own small spec, not a VLAN concern and not a new phase. **Unresolved.**

**D-6. The z2m listening-socket diagnostic.**
`compre` #2 rates this a Blocker and says the document is backwards: a listening socket on the z2m port on HA means the coordinator connects to HA, so rule 5 is required. `s7-style` N35 restates the document's own direction ("a listening socket on the z2m port indicates Home Assistant is the TCP client"), which is the opposite conclusion from the same observation. The two cannot both be right; `compre`'s reading is the one consistent with how `socket://` clients work, but the disagreement is recorded rather than resolved by fiat.

**D-7. Glossaries.**
`compre` #8 and #9 ask for two: a project-name glossary (~10 lines) and a general networking glossary (~30 terms, ~45 lines). `s8-audit` §5.1 accepts the project glossary and refuses the general one — "a homelab operations spec whose reader is the person who owns the router, the switches and the cluster" — authorising only a one-clause gloss at first use of native/untagged and trunk/tagged. `s8-audit` explicitly notes that refusing this leaves the document unreadable to anyone who is not the operator, and accepts that.

**D-8. The alternatives table.**
`s7-design` M14 splits option D into D1/D2/D3 and adds a costed dead-native-VLAN option, taking the table from 6 rows to 10–11. `zoom` Major 9 adds two rows (free-NIC termination, narrow roadwarrior `AllowedIPs`). `s8-audit` §5.2 caps it at 8 rows: one row naming the three real no-new-VLAN mechanisms in the rationale cell, one for the roadwarrior alternative, and one clause on row B — and explicitly refuses the D split as the single clearest bloat vector in the fix set.

**D-9. The mDNS fallback.**
`s7-design` M2 pre-writes two remediation branches (scoped Avahi reflector, or per-device static address plus local DNS record). `s8-audit` §4.2 refuses the pinning branch as a permanent hand-edit on the one device §12 says has no diff, review or rollback, and asks for a gate instead of a mechanism.

**D-10. The dead native VLAN.**
`s7-design` M14 proposes it as a cheap partial mitigation that structurally eliminates Finding B for two switch-port edits. `s8-audit` §4.1 refuses it: the two APs involved are the mesh parents, Omada EAPs are managed on their untagged native VLAN, so the mitigation re-imports the exact rejected management-VLAN pattern onto the APs whose failure costs roaming in two rooms, and it contradicts the break-glass rule at 307–308. `s8-audit` records it as a §13 bench-test candidate instead.

**D-11. The DoT block.**
`s7-design` M5 adds an outbound TCP/UDP 853 block for VLANs 10 and 20. `s8-audit` §4.5 calls it theater on a ruleset whose catch-all allows every port, and keeps only the resolver-scoping sentence plus "DNS is not a boundary".

**D-12. The controller-stop test.**
`s7-design` M10 adds a §10 row: stop the Omada controller, reboot one wired AP, confirm the new SSIDs return tagged. `s8-audit` §4.4 refuses it as disproportionate — a mitigation that can take out the office's wireless and both new VLANs is an incident, not a test — and keeps the cheap half (controller and per-AP config export in §7.6, retention question answered from docs or a bench unit).

**D-13. §11's Likelihood column.**
`s7-struct` N50 adds a defined scale key. `s8-audit` §5.3 refuses it as fake precision for a six-row homelab table and replaces the values with `observed / possible / speculative` or drops the column.

**D-14. The trunk edit.**
`s7-design` M12 requires a Longhorn procedure before the edit: identify the volumes crossing the link, pause or drain the workloads, confirm no deploy. `s8-audit` §4.3 says ordering beats procedure — once `compre` #15 is applied the edit happens exactly once, so make it the first action of Phase 1a before any client exists, add one line about the expected interruption, and extend the existing §10 cluster row with `kubectl get volumes.longhorn.io -A`.

**D-15. Severity disagreements on two shared findings.**
`GUEST_NET` undefined: `compre` #3 rates it Blocker (the ruleset cannot be written as specified), `s7-struct`/`s7-style` M15 rate it Major. Broken anchors: `s7-struct` B3 rates it Blocker, `compre` #23 rates it Major. Both are placed in Blockers here on the ground that a reader following a broken link or an undefined alias reaches an unusable result, not a suboptimal one.

---

## Traceability Matrix

Every raw finding in the five inputs appears exactly once. `→` gives the consolidated item.

### critic_report.md — stage 7

| Raw | Reviewer | Short title | → |
|---|---|---|---|
| B1 | s7-design | Rule 5 unreachable, contradicts criterion 1 | B-01 |
| B2 | s7-design + s7-style(7) | Spine assurances falsified by rule 6 | B-22 |
| B3 | s7-struct(1) | Three anchors do not resolve | B-21 |
| M1 | s7-design | Statefulness not the boundary; UDP expiry | M-02 |
| M2 | s7-design | mDNS is the load-bearing unknown | B-08 |
| M3 | s7-design | No IPv6-family rules | M-01 |
| M4 | s7-design | Rules 7/8 assume HA only; no extension path | M-03 |
| M5 | s7-design | Rule 1 bypassable; resolver leaks map | M-04 |
| M6 | s7-design | Guest intra-VLAN; PSK; §11 cell | M-05 |
| M7 | s7-design | OPNsense new SPOF | M-06 |
| M8 | s7-design | Reservation wrong primitive for coordinator | M-08 |
| M9 | s7-design | Cable and living-room switch SPOFs | M-07 |
| M10 | s7-design | Omada controller role unstated | M-09 |
| M11 | s7-design | Old IoT SSID never removed | M-10 |
| M12 | s7-design | Trunk edit drops iSCSI | M-11 |
| M13 | s7-design | Per-change cost unstated | M-14 |
| M14 | s7-design | Alternatives table staged | M-15 |
| M15 | s7-struct(5) + s7-style(4) | `GUEST_NET` undefined | B-11 |
| M16 | s7-struct(6) | Dangling "see note" | M-71 |
| M17 | s7-struct(7) | §6 row self-contradiction; Phase column | M-73 |
| M18 | s7-struct(8) | §6 vs Phase 3 on VLAN 30 | M-73 |
| M19 | s7-struct(9) | §10 covers 3 of 5 phases; not tied to §1 | M-46 |
| M20 | s7-struct(10) + s7-style(37,38,39) | Sections doing two jobs | M-50 |
| M21 | s7-struct(11) + s7-style(38) | Finding B stated three times | M-53 |
| M22 | s7-style(37) | Mesh landmine stated four times | M-53 |
| M23 | s7-struct(12) | Ordering vs Phase 0-first execution | M-54 |
| M24 | s7-struct(13) | §12 no owner, phase or entry point | M-55 |
| M25 | s7-struct(14) | Marker contract not honoured | M-56 |
| M26 | s7-struct(2) | Unnumbered H2 in numbered sequence | M-69 |
| M27 | s7-struct(3) | Three H3 conventions; orphaned 8.1 | M-69 |
| M28 | s7-struct(4) | Marker inside a heading | M-69 |
| M29 | s7-style(1) | trusted/legacy/native/`LAN_NET` drift | M-65 |
| M30 | s7-style(6) | "most dangerous item in the whole project" | M-70 |
| M31 | s7-style(8) | Rule 7/8 wording ignores rule 5 | B-01 |
| M32 | s7-style(9) | "with no regression" unverifiable | M-70 |
| M33 | s7-style(10) | "cosmetic cost … and nothing else" | M-70 |
| M34 | s7-style(11) | "cannot go stale" unearned | M-70 |
| M35 | s7-style(12) | "for no benefit" | N-11 |
| M36 | s7-style(23) | "Small pools, wireless-only" | N-12 |
| M37 | s7-style(24) | "the Zigbee coordinator above all" | N-12 |
| M38 | s7-style(25) | "Long term" has no referent | N-12 |
| M39 | s7-style(29) | Passive with no actor (103) | N-13 |
| M40 | s7-style(41) | Socket direction undecided/decided | B-09 |
| M41 | s7-style(46) | Finding A heading overstates | M-70 |
| N1 | s7-design | `RFC1918` alias gaps | N-01 |
| N2 | s7-design | No go/no-go gate after 0.6 | M-18 |
| N3 | s7-design | Permanently dead tags | N-02 |
| N4 | s7-design | Default-route tunnel collision | N-03 |
| N5 | s7-design | Roadwarrior IoT access lost | M-61 |
| N6 | s7-design | Break-glass covers only OPNsense | N-04 |
| N7 | s7-design | Rule 1 not implementable | N-05 |
| N8 | s7-design | §13 item has no owner or trigger | N-06 |
| N9 | s7-style(2) | "the rack" as location and device | N-07 |
| N10 | s7-style(3) | Switches named four ways | M-66 |
| N11 | s7-style(5) + s7-struct(18) | Alias `Source` column holds a value | N-08 |
| N12 | s7-style(13) | "no inbound, ever" | N-09 |
| N13 | s7-style(14) | §6 list mislabels its contents | N-10 |
| N14 | s7-style(15) | "Rejected on physics" | N-11 |
| N15 | s7-style(16) | "maintenance tax … Explicitly rejected" | N-11 |
| N16 | s7-style(17) | "YAGNI." | N-11 |
| N17 | s7-style(18) | "Documented as an additive seam" | N-11 |
| N18 | s7-style(19) | "actively undesirable" | N-11 |
| N19 | s7-style(20) | "design's spine" metaphor | N-11 |
| N20 | s7-style(21) | "one rule kills" | N-11 |
| N21 | s7-style(22) | "a decision, not an accident" | N-11 |
| N22 | s7-style(26) | "live problem" | N-14 |
| N23 | s7-style(27) | "expensive, cluster-risky step" | N-15 |
| N24 | s7-style(28) | Port 1 fact or proposal | N-16 |
| N25 | s7-style(30) | "desktop ports become untagged 50" | N-13 |
| N26 | s7-style(31) | Passive marker rule (22) | N-13 |
| N27 | s7-style(32) | "actually" as intensifier | N-14 |
| N28 | s7-style(33) | "deliberately" ×4 | N-14 |
| N29 | s7-style(34) | "trivially visible, trivially reversible" | N-12 |
| N30 | s7-style(35) | "from day one … always" | N-12 |
| N31 | s7-style(36) | Chiasmus at 151–152 | N-11 |
| N32 | s7-style(39) | Allow-all warning twice | N-17 |
| N33 | s7-style(40) | "Cheap, and it is the half of" | N-12 |
| N34 | s7-style(42) | "HA's docker bridge" imprecise, unmarked | M-58 |
| N35 | s7-style(43) | Listening-socket certainty | B-09 (see D-6) |
| N36 | s7-style(44) | Criterion 1 overstates scope | B-01 |
| N37 | s7-style(45) | Criterion 3 is nouns, not a pass condition | B-19 |
| N38 | s7-style(47) | Finding B block carries no marker | N-18 |
| N39 | s7-style(48) | nixpkgs claim names no source | N-19 |
| N40 | s7-style(I) | Word-level trims | N-20 |
| N41 | s7-struct(15) | Bold pseudo-headings carry structure | M-72 |
| N42 | s7-struct(16) | Asymmetric rule-table wording | M-72 |
| N43 | s7-struct(17) | Empty table cells | M-72 |
| N44 | s7-struct(19) | Prose pointer matches no heading | M-71 |
| N45 | s7-struct(20) | §7.6 title mismatch | N-21 |
| N46 | s7-struct(21) | Deictic "the table" | M-71 |
| N47 | s7-struct(22) | Three cross-reference conventions | M-71 |
| N48 | s7-struct(23) | §3.1 diagram broken joins | M-72 |
| N49 | s7-struct(24) | §7.5 SSID column holds a description | M-72 |
| N50 | s7-struct(25) | §11 Likelihood has no scale | N-22 |
| N51 | s7-struct(26) | §10 row bundles three conditions | N-23 |
| N52 | s7-struct(27) | §5 Verdict column mixed, points down | N-24 |
| N53 | s7-struct(28) | No TOC; §12–§14 unordered | N-25 |
| N54 | s7-struct(18) | Alias marker/value style | N-08 |

### implementation_readiness_report.md — stage 9

| Raw | Reviewer | Short title | → |
|---|---|---|---|
| B1 | s9-code(1) + s9-style(36) | `iscsi` gate cannot see Longhorn | B-04 |
| B2 | s9-code(2) | etcd `2381` bind mis-stated | B-05 |
| B3 | s9-code(3) | "all 13 hosts" `network_env` false | B-03 |
| B4 | s9-code(4) | Rows point at examples/comments | B-03 |
| B5 | s9-code(5) + s9-style(62) | §14 titan carve-out does not exist | B-06 |
| B6 | s9-impl(1) | Phase 0 has no artifact | B-12 |
| B7 | s9-impl(7) | Guest coverage regression unhandled | B-13 |
| B8 | s9-impl(15) | Coordinator never moved; step 5 misordered | B-07 |
| B9 | s9-impl(20) + s9-style(22) | Phase 2 is a paragraph | B-16 |
| B10 | s9-impl(24) | Phase 3 names no destination addressing | B-17 |
| B11 | s9-style(1) | "independently reversible" false for Phase 3 | B-18 |
| B12 | s9-style(8) + s9-impl(8) | Step 1 compressed; address missing | B-15 |
| B13 | s9-style(12) | "old SSID" undefined referent | B-14 |
| B14 | s9-style(14) | Step 1 asserts the unknown | B-08 |
| B15 | s9-style(45) | §10 has no observation column | B-19 |
| M1 | s9-impl(2) + s9-style(2) | Phase 0 items name no command | M-19 |
| M2 | s9-impl(3) + s9-style(3) | Phase 0.6 not executable | M-18 |
| M3 | s9-impl(4) | Phase 0.7 no pass condition | M-21 |
| M4 | s9-impl(5) | Phase 0 missing prerequisites | M-20 |
| M5 | s9-impl(9) | "never an unfiltered window" | M-22 |
| M6 | s9-impl(10) + s9-style(9) | Trunk step has no procedure | M-13 |
| M7 | s9-impl(11) + s9-style(10) | Step 4 Omada/mesh mechanics | M-23 |
| M8 | s9-impl(12) + s9-style(11) | Step 5 has no commands | M-24 |
| M9 | s9-impl(13) + s9-style(13) | 1a rollback partially executable | M-25 |
| M10 | s9-impl(14) | No abort criterion in 1a | M-26 |
| M11 | s9-impl(16) + s9-style(15) | 1b step 1 data/pool/address | M-27 |
| M12 | s9-style(18) | "the trunks" is three configs | M-28 |
| M13 | s9-impl(17) + s9-style(19) | 1b step 7 is one line | M-29 |
| M14 | s9-impl(18) + s9-style(20) | 1b rollback understates cost | M-30 |
| M15 | s9-impl(21) | Phase 2 ruleset not a decision | B-16 |
| M16 | s9-impl(22) + s9-style(24) | Phase 2 roadwarrior break | M-31 |
| M17 | s9-style(23) | Phase 2 gate buried | M-32 |
| M18 | s9-impl(25) + s9-style(27) | Phase 3 `[measured]` tag contradicted | M-34 |
| M19 | s9-style(28) | `Where` column holds an explanation | M-35 |
| M20 | s9-style(29) | Open-ended catch-all row | M-36 |
| M21 | s9-style(30) + s9-code(M15) | Rollout row unreadable | M-37 |
| M22 | s9-impl(26) + s9-style(31) | Phase 3 no ordering/owner | M-38 |
| M23 | s9-style(34) + s9-code(M12) | Restore gate mis-tagged | M-39 |
| M24 | s9-style(35) | Phase 3 scope vs §6; NAS unnamed | B-17 |
| M25 | s9-impl(27) | IOT ruleset stops covering new ranges | B-02 |
| M26 | s9-impl(28) | Phase 3 scope rests on unshown mechanism | B-04 |
| M27 | s9-code(M1) | Roadwarrior `[measured]` miscited | M-16 |
| M28 | s9-code(M2) | Two `k3s.serverAddr` literals | B-03 |
| M29 | s9-code(M3) | "firewall off" false for titan | M-17 |
| M30 | s9-code(M4) | WireGuard `allowedIPs` never named | B-03 |
| M31 | s9-code(M5) | `.42` pin absent | B-03 |
| M32 | s9-code(M6) | `helper.py` `.6` defaults | B-03 |
| M33 | s9-code(M7) | `dev-tools.nix` `.29` default | B-03 |
| M34 | s9-code(M8) | titan pod/service CIDRs omitted | M-41 |
| M35 | s9-code(M9) | MetalLB pool; `.41` may be VIP | M-42 |
| M36 | s9-code(M10) | `AGENTS.md` unlisted and stale | B-03 |
| M37 | s9-code(M11) | titan README uncited | M-43 |
| M38 | s9-code(M13) | §13 pattern already exists | M-44 |
| M39 | s9-code(M14) | Route-loss failure omitted | M-40 |
| M40 | s9-impl(29) | Phase dependencies are prose | M-45 |
| M41 | s9-impl(30) | §10 unobservable; phases never cite it | B-19 |
| M42 | s9-style(46,47,48,51,52) | §10 row-level untestable | B-19, N-52, N-53 |
| M43 | s9-style(53) | §11 mitigations not actions | M-47 |
| M44 | s9-style(57) | §12 "no rollback" contradicted | M-48 |
| M45 | s9-style(59) | §13 absolutes; undefined goal | M-49 |
| M46 | s9-style(61) | §2/§13/§14 three exclusion lists | M-50 |
| M47 | s9-style(39–44) | §9 landmine defects | M-51 |
| M48 | s9-style(38) | §8.1 duplicates restore gate | M-52 |
| M49 | s9-style(26) | Phase 3 header superlative | M-70 |
| M50 | s9-style(32) | "Preserves everything" | M-70 |
| M51 | s9-style(33) | "Often less risky"; no duration | N-15 |
| M52 | s9-style(63) | Device-name drift | M-66 |
| M53 | s9-style(64) | Register inconsistency | M-67 |
| M54 | s9-impl(6) + s9-style(4) | 0.6 consequence inert; "ten minutes" | M-18 |
| M55 | s9-impl(19) | 1b step 3 omits alias creation | M-68 |
| M56 | s9-style(25) + s9-impl(23) | Phase 2 rollback omits side effects | M-33 |
| M57 | s9-style(21) | 1b never retires old IoT SSID | M-10 |
| N1 | s9-style(5) | 0.3 quotes undefined proposition | N-26 |
| N2 | s9-style(6) | 0.8 parenthetical not a partition | N-27 |
| N3 | s9-style(16) | "requirement, not a nicety" | N-14 |
| N4 | s9-style(17) | "only if Phase 0.4 requires it" | N-28 |
| N5 | s9-impl(31) | 1b step 2 drops "address" | N-29 |
| N6 | s9-style(37) | "unless there is a specific reason" | N-30 |
| N7 | s9-style(49) | §10 z2m row names no log path | N-50 |
| N8 | s9-style(50) | §10 cluster row lacks when/who/where | N-51 |
| N9 | s9-style(54) | "certain" row is a limitation | N-22, N-48 |
| N10 | s9-style(55) | §11 repeats false partition | N-42 |
| N11 | s9-style(56) | §11 has no "checked at" column | N-22, N-49 |
| N12 | s9-style(58) | §12 wording | N-31 |
| N13 | s9-style(60) | "nothing about the VLAN plan changes" | N-32 |
| N14 | s9-style(66) | §13 IPv6 fragment | N-33 |
| N1 | s9-code(N1) | Line 88 attributes to one host | N-34 |
| N2 | s9-code(N2) | `allowedApiSources` mislabelled | N-35 |
| N3 | s9-code(N3) | rsyslog fan-out understated | N-36 |
| N4 | s9-code(N4) | Which `9100` | N-37 |
| N19 | s9-impl(22b) | 0.5 omits desktops/printers | N-46 |
| N20 | s9-impl(2a) | "whether all ports trunk" | N-45 |
| N21 | s9-impl(9b) | Anti-lockout + ordering | N-47 |
| N22 | s9-impl(15b) | z2m downtime; no re-pairing | N-44 |
| N23 | s9-style(65) | Hedged wording, knowable answers | N-38 |

### zoom_out_report.md

| Raw | Lens | Short title | → |
|---|---|---|---|
| Blocker 1 | zoom | IoT rule staleness; rule 5 position | B-02, B-01 |
| Blocker 2 | zoom | Phase 3 deferred and drafted; table wrong | B-03, M-75 (see D-2) |
| Major 3 | zoom | Roadwarrior claim miscited; cheap alternative | M-16, M-15 |
| Major 4 | zoom | Phase 2 undecided phase in an executable plan | B-16 (see D-3) |
| Major 5 | zoom | New SPOF not recorded | M-06 |
| Major 6 | zoom | Remote/mesh IoT reachability lost | M-61 |
| Major 7 | zoom | mDNS asserted in §2, disowned by 0.3 | B-08 |
| Major 8 | zoom | §13 allow-list out of scope and re-solves | M-44, B-05 (see D-5) |
| Major 9 | zoom | Free-NIC alternative omitted from §5 | M-15 |
| Nit 10 | zoom | Three overlapping exclusion lists | M-50 |
| Nit 11 | zoom | §9 half restatement | M-51 |
| Nit 12 | zoom | Phase 0.7 duplicates §7.6 | N-41 |
| Nit 13 | zoom | Phase 1b labour unmeasured | M-29 |
| Nit 14 | zoom | §12 sketches a disowned project | N-31 |
| Nit 15 | zoom | Wired IoT neither in nor out | M-03 |
| Scope guard | zoom | Hold §7 firm; shrink around it | M-74 |

### comprehension_report.md

| Raw | Lens | Short title | → |
|---|---|---|---|
| 1 | compre | Rule 5 shadowed by rule 2 | B-01 |
| 2 | compre | Phase 0.4 diagnostic backwards | B-09 (see D-6) |
| 3 | compre | `GUEST_NET` undefined | B-11 |
| 4 | compre | `<z2m port>` never numbered | B-10 |
| 5 | compre | Scope line asserts managed switches | B-20 |
| 6 | compre | Criterion 1 contradicts rule 5 | B-01 |
| 7 | compre | No citation behind markers | M-57 |
| 8 | compre | No project glossary | M-62 |
| 9 | compre | General vocabulary unglossed | M-63 (see D-7) |
| 10 | compre | Ports unnamed | M-64 |
| 11 | compre | VLAN 1 retired vs break-glass vs NAS | B-17 |
| 12 | compre | §14 vs Phase 3 titan scope | B-06 |
| 13 | compre | §10 tests only 1a/1b | M-46 |
| 14 | compre | Step 5 breaks Zigbee before the move | B-07 |
| 15 | compre | Trunk tagging twice | M-12 |
| 16 | compre | "independently reversible" untrue | B-18 |
| 17 | compre | Omada controller unstated prerequisite | M-09 |
| 18 | compre | Old SSIDs never named | B-14 |
| 19 | compre | Phase 2 ruleset not a decision | B-16 |
| 20 | compre | Claims needing markers have none | M-58 |
| 21 | compre | mDNS seam not additive | M-59 |
| 22 | compre | §10 mesh row permits Finding B's outcome | M-60 |
| 23 | compre | Three anchors do not resolve | B-21 |
| 24 | compre | Forward references | N-39 |
| 25 | compre | Terminology drift | M-65 |
| 26 | compre | Small ambiguities | N-40 |

### intermediate_zoom_out_report.md — stage 8

| Raw | Lens | Short title | → |
|---|---|---|---|
| §1 | s8-audit | Fix-load arithmetic; cut first | M-74 |
| §2 | s8-audit | Cut outright rather than fix | M-75 |
| §3 | s8-audit | Delete rule 5's conditional apparatus | D-1, M-75 |
| §4.1 | s8-audit | Dead native VLAN re-imports mesh landmine | M-78 (see D-10) |
| §4.2 | s8-audit | Per-device DNS pinning worse than risk | M-78 (see D-9) |
| §4.3 | s8-audit | Longhorn drain runbook disproportionate | M-78, M-12 (see D-14) |
| §4.4 | s8-audit | Controller-stop test is an incident | M-78, M-09 (see D-12) |
| §4.5 | s8-audit | DoT block is theater | M-78, M-04 (see D-11) |
| §4.6 | s8-audit | WPA3/OWE migration refused; keep checkbox | M-78, M-05 |
| §5.1 | s8-audit | Refuse general glossary | M-78 (see D-7) |
| §5.2 | s8-audit | Refuse §5 decision matrix | M-78, M-15 (see D-8) |
| §5.3 | s8-audit | Refuse §11 likelihood scale | M-78, N-22 (see D-13) |
| §5.4 | s8-audit | Per-change checklist scope | M-78, M-14 |
| §6 | s8-audit | Add mass to Phase 0 only | M-76 |
| §7.1 | s8-audit | §13 allow-list resolution | D-5, M-44 |
| §7.2 | s8-audit | Phase 0.6 as stop condition | D-4, M-18 |
| §8 | s8-audit | Honesty list instead of mitigations | M-77 |
| §9 | s8-audit | Authorised addition budget | M-74 |
| §10 | s8-audit | Residual risks of cut-first | M-74, M-75 |
