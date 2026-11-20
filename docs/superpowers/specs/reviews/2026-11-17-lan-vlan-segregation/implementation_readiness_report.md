# Implementation Readiness Report — Stage 9 (impl-readiness, codebase-details, style)

**Target:** `docs/superpowers/specs/2026-11-17-lan-vlan-segregation-design.md` (513 lines)
**Range audited:** lines 312–513 (the executable plan) for all three reviewers; the codebase reviewer additionally checked the `[measured]` claims in §1, §3.2, §6, §13 and §14 against the repository.
**Reviewers:** `stage9-impl` (implementation readiness), `stage9-codebase` (codebase details), `stage9-style` (copy edit of the plan). All three completed.

Merged, deduplicated, most severe first. Every line citation preserved.

Severity tally: 15 Blockers, 57 Majors, 23 Nits.

---

## Blockers

### B1. The `iscsi` health gate cannot see Longhorn and cannot see the network; the Phase 3 recommendation rests on a safety net that does not exist
*Reviewers: stage9-codebase (B1), stage9-style (finding 36, same lines)*
**Lines:** 97–98 ("The comin health gate runs an `iscsi` check on every deploy and **rolls the host back** if it breaks") and 415–418 ("the comin health gate's `iscsi` check will roll a host back if that degrades — so VLAN 40 stays reserved"). Style adds 416–418: "removes jumbo frames" is the wrong mechanism — MTU is a property of the path, not something routing deletes — and "adds latency" is an unquantified claim with no marker.

**Code:** `modules/nixos/comin-health-gate.nix:114–146`. The check is `iscsiadm -m node` — a read of the host's local node DB. It contacts no portal, opens no session, performs no I/O toward TrueNAS. Exit 21 is explicitly treated healthy (`:117–118`). The module's own comment at `:102–107` says it outright: *"Longhorn is INVISIBLE to this check: it logs into its own targets with the initiator bundled in its instance-manager pods and never writes to /etc/iscsi, so a node can carry dozens of healthy Longhorn engines with an empty host db (verified 2026-09-21 on k8s-server01: `-m node` -> 21, `-m session` -> 21, empty /etc/iscsi/nodes, 20 Longhorn pods running)."* The rollback therefore fires only when the local node DB is *unparseable* while no kernel sessions are live (`:126–133`, `:141–144`). A VLAN or routing change that breaks the path to the iSCSI portal yields exit 0 (DB still readable) or exit 21 (treated healthy). Nothing rolls back.

Scope is also wrong: the check is gated on `hasCheck "iscsi" && config.openiscsi.enable` (`:114`). `openiscsi.enable = true` on `k8s-node01..05`, `k8s-server01..03`, `k8s-pi01..03`; `llm01` sets `checks = ["current-system" "halogen-flash"]` (`hosts/llm01/configuration.nix:59–62`) and `titan` sets `checks` without `iscsi` and carries the comment "No iSCSI on titan (no Longhorn)" (`hosts/titan/configuration.nix:576–579`). So "on every deploy" is false on two hosts.

**Fix:** replace 97–98 with: "Longhorn uses iSCSI to TrueNAS over this LAN. The comin health gate has an `iscsi` check, but it reads only the host's local iSCSI node DB and treats an empty DB as healthy; per `modules/nixos/comin-health-gate.nix:102–107` Longhorn's sessions are invisible to it, so it will **not** detect a degraded path to the portal. It runs only where `openiscsi.enable` and `iscsi` is in `cominGitOps.healthGate.checks` (not `titan`, not `llm01`)." Then restate the Phase 3 recommendation on its own merits: "VLAN 40 stays reserved because routing iSCSI across a router drops jumbo frames and adds latency, and because nothing in the current toolchain would detect that degradation — Phase 3 must carry its own Longhorn attach-and-IO verification step per node." Add that step to the Phase 3 table and to §10. For the style defect at 416–418: "A routed iSCSI path must keep MTU ≥ 9000 end to end or Longhorn will fragment or drop; if MTU cannot be guaranteed across the router, latency and throughput degrade. `[unverified]` whether the OPNsense platform and both switches support MTU 9000 on a VLAN interface — confirm in Phase 0."

### B2. etcd `2381/metrics` is not bound to `0.0.0.0`; the spec conflates it with the authenticated control-plane metrics bind
*Reviewer: stage9-codebase (B2)*
**Lines:** 88–89 ("`hosts/k8s-server01/vars.nix` documents that etcd's `2381/metrics` is bound to `0.0.0.0` and is **unauthenticated**") and 501 ("etcd's `2381/metrics` is unauthenticated on `0.0.0.0`").

**Code:** `hosts/k8s-server01/vars.nix:36` says the opposite in words — "Expose etcd's metrics port **on the node address as well as loopback**, so Prometheus can scrape 192.168.0.11:2381." `modules/nixos/etcd-metrics-proxy.nix:9–27` quotes the k3s v1.35.8+k3s1 source (`pkg/etcd/etcd.go listenMetricsURLs`) proving `--etcd-expose-metrics` appends `http://<e.address>:2381` — the node address — and that module refuses a wildcard bind by design. The `0.0.0.0` in that vars.nix is `controlPlaneMetricsBindAddress` at `:35`, which covers **10257/10259** and which `:32–34` explicitly labels *authenticated*. The spec merged the two. Beyond pedantry: §13's proposed allow-list is justified by a wildcard bind that isn't there, and the repo already contains the purpose-built answer that §13 does not mention.

**Fix:** line 88–89 → "`hosts/k8s-server01/vars.nix:36–46` documents that `--etcd-expose-metrics` publishes etcd's `2381/metrics` on the **node address** in addition to loopback, and that it is unauthenticated and LAN-readable because the host firewall is off. (Separately, `controlPlaneMetricsBindAddress = "0.0.0.0"` covers 10257/10259, which are authenticated.)" Line 501 → same correction, plus: "`modules/nixos/etcd-metrics-proxy.nix` already solves this on `titan` by binding the tunnel address and forwarding to loopback rather than widening the bind; the seam should say whether the casa servers adopt that pattern or take the firewall rule."

### B3. "all 13 hosts" get their address from `secrets.yaml#<host>/network_env`. Only 9 do, one from a different file, and four hosts carry build-time literals
*Reviewer: stage9-codebase (B3)*
**Lines:** 387 (`| Per-host address, gateway, DNS | secrets.yaml#<host>/network_env, all 13 hosts |`), restating 81–84.

**Code:**
- `network_env` exists for `k8s-node01..05` and `k8s-server01..03` in `secrets.yaml`, and for `titan` — but in `secrets/titan.yaml`, not `secrets.yaml`. `hosts/titan/configuration.nix:439` states this in words: "It lives in secrets/titan.yaml, NOT secrets.yaml."
- `hosts/k8s-pi01/vars.nix:8–13` holds build-time literals: `ipAddress = "192.168.0.21"`, `defaultGateway = "192.168.0.1"`, `nameservers = ["1.1.1.1" "8.8.8.8"]`. Same shape in `k8s-pi02/vars.nix` and `k8s-pi03/vars.nix`. `modules/nixos/static-network.nix:8–12` derives `useRuntimeConfig` from whether those values start with `$`; with literals the SOPS env file, the activation script (`:149–156`) and the route watchdog (`:164–179`) are all skipped, so the Pi addresses are baked into the derivation.
- `hosts/k8s-node04/vars.nix:4` hardcodes `ipAddress = "192.168.0.17"` while using placeholder DNS — a mixed host. `static-network.nix:152` only emits `ip addr replace` when the address *is* a placeholder, so node04's address is build-time.
- `llm01` is NetworkManager-managed (`hosts/llm01/configuration.nix:146`) and has no `network_env`; its LAN address is not in this repo at all.

An implementer who re-keys `network_env` and stops leaves four hosts on the old range with no error.

**Fix:** replace 387 with three rows:
| Per-host address, gateway, DNS (9 hosts) | `secrets.yaml#<host>/network_env` for `k8s-node01..05`, `k8s-server01..03`; `secrets/titan.yaml` for `titan` |
| Build-time literals in `vars.nix` | `k8s-pi01/02/03` address + gateway + DNS, `k8s-node04` address. `modules/nixos/static-network.nix:8–12` skips the SOPS runtime layer entirely when the values are not `$`-prefixed, so these are baked into the derivation |
| `llm01` | NetworkManager-managed; LAN address not held in this repo |

And correct 81–84 to "hosts whose `vars.nix` still holds `$` placeholders …".

### B4. Four rows of the Phase 3 blast-radius table point at option `example`s, comments, or files that need no edit
*Reviewer: stage9-codebase (B4)*
**Lines:** 391, 392, 394, and part of 395.

**Code:**
- `modules/nixos/ssh.nix:48–54` — `ssh.listenAddresses` defaults to `[]` and `192.168.0.29` appears only inside `example`. No host sets `ssh.listenAddresses` anywhere in the repo (only the declaration at `:48` and its consumer at `:73–74`). Line 394 lists it as an "llm01 reference" to change; editing it changes nothing.
- `modules/nixos/mesh-dns.nix:76–79` — `default = { }` and `192.168.0.41` is an `example`. The live split-horizon data is `hosts/titan/configuration.nix:433–436`: `splitZones = { "l.arrieta.eu." = [ "192.168.0.41" ]; "casa.arrieta." = [ "192.168.0.41" ]; }`. Line 392 sends the implementer to the wrong file, and the `casa.arrieta.` half of the live value is never named anywhere in the spec.
- `common/etcd-snapshot-s3.nix:48` mentions `192.168.0.6` in a **comment**; the live flag at `:52` is `--etcd-s3-endpoint=s3.l.arrieta.eu`, a hostname, and `:49` explicitly warns that pinning an IP there "hits a VIP and hangs". Line 391 lists this file as a place holding `192.168.0.6`; it needs no edit for a re-IP.
- `modules/nixos/public-host.nix` — the LAN allow-list option (`meshTCPPortExtraSources`) appears there only as an `example`. The live value is `hosts/titan/configuration.nix:329`.

**Fix:** line 392 → "`hosts/titan/configuration.nix:433–436` `meshDns.splitZones` (both `l.arrieta.eu.` **and** `casa.arrieta.`)". Line 394 → drop `modules/nixos/ssh.nix`; the real `.29` sites are `home/hosts/coder-workspace-titan/userOptions.nix` and `modules/home-manager/dev-tools.nix:146`. Line 391 → drop `common/etcd-snapshot-s3.nix`, add `pkgs/coder-iscsi-helper/helper.py`. Line 395 → name `hosts/titan/configuration.nix:329` instead of `modules/nixos/public-host.nix`.

### B5. §14 excludes a `titan` change that does not exist as a value, and contradicts the Phase 3 table
*Reviewers: stage9-codebase (B5), stage9-style (finding 62)*
**Lines:** 510–512 versus 395.

**Code:** `grep lanSubnet --glob '*.nix'` returns exactly three hits, all in `modules/nixos/wireguard.nix` (`:88`, `:89` — the MASQUERADE scope — and `:143`, the option declaration defaulting to `192.168.0.0/24`). **No host sets `wireguard.lanSubnet`.** `hosts/titan/configuration.nix` sets `forwardToLan = true` at `:110` and nothing else LAN-CIDR-related. So the one titan change §14 permits is not an edit to an existing value; it is a new override. Meanwhile 395 lists four titan-side items (`forwardToAn` SNAT, the LAN allow-list, `hosts/titan/configuration.nix`), which §14 then excludes. Style's version of the same finding: an out-of-scope statement that contradicts the in-scope table will be used to justify not touching `public-host.nix`. The real titan-side Phase 3 surface is at least `:110` (`forwardToLan`), `:205` (the OPNsense peer's `allowedIPs` `"192.168.0.0/24"`), `:329` (`meshTCPPortExtraSources`), `:433–435` (`splitZones`), `:528` (`networking.hosts`), plus a new `lanSubnet` override.

**Fix (codebase):** line 512 → "…and any change to `titan` in Phase 3 beyond the mesh LAN-CIDR items listed in Phase 3 (`wireguard.lanSubnet` — currently unset, inherited from the module default — `forwardToLan`, the OPNsense peer's `allowedIPs`, `publicHost.meshTCPPortExtraSources`, `meshDns.splitZones`, `networking.hosts`)." Then reconcile line 395 so the two lists agree.
**Fix (style):** "any change to `titan` beyond the WireGuard LAN CIDR and its dependent allow-lists listed in the Phase 3 table."

### B6. Phase 0 produces eight facts and no artifact
*Reviewer: stage9-impl (finding 1)*
**Lines:** 316–330; downstream consumers at 355 ("only if Phase 0.4 requires it"), 351 (reservation), 370 (rack switch managed), 424 (Phase 3 gate on 0.5).

Every Phase 1/2/3 gate reads a Phase 0 answer, but there is no file, no format, and no exit condition. "Record what answers" (325) records nothing durable.

**Fix:** add a Phase 0 exit artifact — `docs/superpowers/specs/2026-11-17-lan-vlan-phase0-findings.md`, one section per 0.x holding the answer, the exact command or screen used, and the date — plus the OPNsense XML export stored off-router at a named path, and a repeat export after each phase. Make "artifact complete" the gate condition for entering Phase 1a.

### B7. The guest coverage regression is unhandled, and the two resolutions are contradictory
*Reviewer: stage9-impl (finding 7)*
**Lines:** 341–342 ("leave it disabled on the mesh and garage APs"), 345 ("only then disable the old guest SSID"), §7.5 line 294, Finding B line 138.

The kitchen, entrance and garage APs are the mesh units — i.e. the APs most likely broadcasting today's guest SSID. Disabling the old SSID removes guest Wi-Fi from three rooms. Leaving it running keeps an unfiltered guest network on the flat LAN, which is the hole the project exists to close. The plan picks neither, so the implementer picks at 11pm.

**Fix:** after the SSID inventory (B/M-list below), make step 6 an explicit either/or with named options: (a) retire the old SSID everywhere and accept no guest coverage in kitchen/entrance/garage until the cables in §13 (503) are pulled; or (b) keep the old SSID on the mesh APs only, leave Omada per-AP isolation on, and record the residual hole as accepted in §11. Record the choice in the Phase 0 artifact.

### B8. Phase 1b never moves the coordinator, and step 5 is ordered before the thing it depends on
*Reviewer: stage9-impl (finding 15)*
**Lines:** 351–361, especially 357.

Step 5 points z2m's `serial.port` at the reserved address, but no step puts the coordinator on VLAN 10. As written, z2m breaks at step 5 and nothing restores it. The single most critical device move in the phase is implicit.

**Fix:** split step 5. 5a: move the coordinator itself onto VLAN 10 (for a network-attached coordinator: its own static address on `10.60.10.x` below the pool, or its switch port to untagged 10), verify reachability from OPNsense (Diagnostics → Ping / `nc -vz <reserved-ip> <port>`). 5b: edit z2m's `serial.port` to `socket://<reserved-ip>:<port>` and restart the add-on; verify the z2m log reaches "Connected" with no reconnect loop (§10 line 463). State the expected z2m downtime between 5a and 5b, and state that Zigbee devices do not need re-pairing for it.

### B9. Phase 2 is a paragraph, not a plan, and it sits between two phases that are plans
*Reviewers: stage9-impl (finding 20), stage9-style (finding 22)*
**Lines:** 366–376; §10 lines 457–467 has no Phase 2 row. Style singles out 372–374.

There are no steps at all — no VLAN 50 interface, address, DHCP scope, DNS, alias, or rules; no list of which rack-switch ports change; no verification; no test row; no rollback verification. Line 369 asserts "Nothing in this repo changes" while the phase requires a firewall ruleset that lives in no repo (§12 lines 480–491). Style: "allow only what is needed (SSH to nodes, the cluster API)" is the phase's entire security content and the vaguest sentence in the plan; "allow only what is needed" is not a rule, and the executor will get it wrong in the permissive direction.

**Fix (impl):** either write Phase 2 to the same standard as 1a/1b (numbered steps with screens and values, plus §10 rows), or mark it explicitly "not yet planned — own spec after Phase 1b signs off", the way §8.1 handles Phase 3. Prose between two executed phases will be executed as if it were a plan.
**Fix (style):** write the rules in the same table form as §7.3, e.g. `| 1 | VLAN50 | nodes | TCP 22 | allow |`, `| 2 | VLAN50 | 192.168.0.11 | TCP 6443 | allow |`, `| 3 | LAN_NET | VLAN50 | * | block + log |`, with the node list named (`.11 .12 .13`, and whether `.14`–`.17` / Pis need SSH too).

### B10. Phase 3 never names the destination addressing, which contradicts §6
*Reviewer: stage9-impl (finding 24)*
**Lines:** 378–397, §6 line 167 ("the final scheme is chosen now so no segment is migrated twice"), table row for VLAN 1 at 169–176 ("Retired in Phase 3").

VLAN 30 and 50 have ranges; the legacy segment's replacement subnet, gateway and prefix length do not exist anywhere in the document. Every row of the Phase 3 table says "change the IP" without saying to what. This is a deferral hiding an uncosted *decision*, not just uncosted work.

**Fix:** either add the post-Phase-3 row for VLAN 1 to the §6 table now, or state in §8.1 that selecting the new CIDR is the first deliverable of the Phase 3 spec, and soften line 167's claim accordingly.

### B11. "Each phase is independently valuable and independently reversible" — two absolutes contradicted inside the same section
*Reviewer: stage9-style (finding 1)*
**Lines:** 314; Phases 1a/1b/2 have a `**Rollback:**` line at 347, 364, 376; Phase 3 has none; Phase 3's own scope at 415 says "desktops already on 50", i.e. it depends on Phase 2.

**Fix:** "Phases 0–2 are independently reversible; each has a rollback line. Phase 3 is not independently reversible — see §Phase 3." Then either add a `**Rollback:**` line to Phase 3 or state explicitly "no rollback: the rebuild strategy is the rollback."

### B12. Phase 1a step 1 and Phase 1b step 2 compress five UI actions into one line, and the literal router address appears nowhere
*Reviewers: stage9-style (finding 8), stage9-impl (finding 8)*
**Lines:** 338 (step 1), 355 (1b step 2); §7.2 line 214 says only "with the addresses from the table, `/24`", and the table at 174–176 gives a subnet, not a host address. 1b step 2 additionally drops "address" that 338 lists, so the two parallel steps do not match. Impl adds that step 1 omits two mandatory screens.

**Fix (style):** split into substeps with the screen and the literal value, and use the same substep list in both phases:
`1a.1 Interfaces > Other Types > Interfaces: VLAN 20 on LAN, priority 0.`
`1a.2 Interfaces > Assignments: opt10 -> IOT / opt20 -> GUEST.`
`1a.3 Set IPv4 10.60.20.1/24 (GUEST), 10.60.10.1/24 (IOT).`
`1a.4 Services > DHCPv4 > Settings: enable on GUEST, pool 10.60.20.100-200.`
`1a.5 Services > DNS Resolver: confirm it is listening on the new interface.`

**Fix (impl, additional mandatory screens and values):**
1. Interfaces → Other Types → VLANs: VLAN 20 on the LAN parent, priority 0, description `GUEST`.
2. Interfaces → Assignments → Interfaces: assign the new VLAN, rename `GUEST`, IPv4 Configuration Type Static IPv4, address `10.60.20.1/24`.
3. On the new interface, record the state of the "block private networks" / "block RFC1918" / "block bogous" checkboxes and leave them off — one of them silently kills rule 3's internet path and makes the step 5 test fail for the wrong reason.
4. Services → DHCPv4 → GUEST: enable, range `10.60.20.100`–`10.60.20.200`, gateway `10.60.20.1`, DNS `10.60.20.1`, lease time stated.
5. Services → Unbound DNS → Advanced: confirm `10.60.20.0/24` is permitted in the resolver's client access list and that the GUEST interface is in its listening set. If it is not, guests resolve nothing and the "reaches internet" test fails looking like a firewall bug.
6. Firewall → Rules → GUEST: create the aliases, then the §7.3 rules, then remove the default allow-all.

### B13. Undefined referent: "the old guest SSID" / "the old SSID"
*Reviewer: stage9-style (finding 12)*
**Lines:** 345, 347, 364; §7.5 table 291–295.

Step 6 "Only then disable the old guest SSID" and both rollbacks ("re-enable the old one", "move devices back to the old SSID") depend on an existing IoT SSID and Guest SSID. Nothing in the document establishes that they exist: §7.5's table lists exactly one pre-existing SSID, "existing trusted". If there is no current guest SSID, step 6 and the 1a rollback are unexecutable; if there is one, its name is never given, so the executor will disable the wrong object in the Omada UI.

**Fix:** add a Phase 0 row — "Record the exact SSID names, VLAN/untagged status and security mode of every SSID broadcast today (Omada > Settings > Wireless Networks)" — then reference those recorded names literally in step 6 and in both rollback lines. If no guest SSID exists today, delete step 6 and rewrite the rollback as "disable `home-guest`; there is no prior guest SSID to restore."

### B14. Phase 1b step 1 asserts as fact the item its own inventory marks unknown
*Reviewer: stage9-style (finding 14)*
**Lines:** 352–354 ("No mDNS means HA addresses IoT devices by IP, and a random lease means a router reboot silently breaks Zigbee"), against Phase 0.3 (322) whose `Resolves` cell admits "whether "no mDNS" is actually true today".

**Fix (calibrate):** "If Phase 0.3 found that HA addresses IoT devices by IP (no mDNS), reserve the coordinator's address before moving any device: a changed lease after a router reboot breaks Zigbee silently."

### B15. §10 pass conditions have no observation column and no positive control
*Reviewer: stage9-style (finding 45)*
**Lines:** 459–467.

Every row states a predicate and none states how to observe it. Several rows are satisfied by an unrelated failure: "unreachable" is also what you get when the target service is down, when the client has no route, or when the wrong SSID is joined. Without a positive control, a broken test and a working boundary look identical — precisely the failure mode §9 (436–439) warns about and §1 criterion 5 promises against. Impl states the same for 465–466: `kubectl get nodes` needs the invocation host and kubeconfig context; "no comin rollback in `/var/log/comin-health-gate.log`" needs the grep pattern that denotes a rollback; the roadwarrior row needs a named test peer and the client-side command.

**Fix:** add a fourth column `Observed with` to every row, and add one row: "**Positive control** | 1a, 1b | the same probes run from a trusted-LAN client return OPEN for `HA:8123`, `.6:9000`, node `9100` — proving the probes can detect an open port at all." For the comin row, name the grep pattern; for the roadwarrior row, name the peer and use `ip route` / `netstat -rn` inside the tunnel.

---

## Major

### M1. Five of eight Phase 0 items name no command and no screen; the `Item` column is noun phrases with no verb
*Reviewers: stage9-impl (finding 2), stage9-style (finding 2)*
**Lines:** 320, 321, 322, 324, 327 (impl); 320–324 (style). Only 0.4 (323) and 0.6 (325) name a command, so the table has two registers in one column. An executor cannot tell what "done" looks like for 0.1, 0.2, 0.3, 0.5, 0.8.

**Fix (impl), per item:**
- 0.1 / 0.2 (320–321): "read the label and the management URL; check `arp -a` and OPNsense → Diagnostics → ARP Table for a management IP; record managed/unmanaged, model, firmware, PoE budget, total port count, and which ports support 802.1Q tagging." Also, "whether all ports trunk" (320) is not a question anyone can answer — §7.1 line 205 says the server ports are untagged access ports. Replace with "which ports support tagging, and how many are free."
- 0.3 (322): "OPNsense → Services → DHCPv4 → Leases; if HA is absent it is static — run `nmap -sn 192.168.0.0/24` and diff against leases." For "IP vs mDNS": "HA UI → Settings → Devices & Services → zigbee2mqtt / MQTT, and the z2m add-on Configuration tab showing `serial.port`."
- 0.5 (324): "diff `nmap -sn 192.168.0.0/24` plus OPNsense leases and reservations against the static list in `secrets.yaml#*/network_env`; anything answering with no lease is a static candidate." Add desktops and printers to the scan scope.
- 0.8 (327): "record controller type, version, login, and whether it re-applies SSID config to APs after an AP reboot" — the Resolves column says "rollback mechanics" but nothing in the item captures mechanics.

**Fix (style):** start every `Item` cell with an imperative verb and add a fourth column `Observed with` holding one named command or one named screen. Example for 0.2: "Record the rack switch model, whether it has a management UI with 802.1Q, and its PoE budget | Observed with: label photo + switch admin page `System > Port Statistics`, or `curl` to its mgmt IP."

### M2. Phase 0.6 — the one item the document calls decisive — is not executable as written
*Reviewers: stage9-impl (finding 3), stage9-style (finding 3)*
**Lines:** 325, and the claim at 329–330.

Impl: no probe tool, no named client, no named node for "a node's `9100`", no recording format, and no requirement to repeat it per AP location — while Finding B (123–140) makes per-AP behaviour the thing under test. Also, "reach `192.168.0.1`" via ICMP is not a boundary test; a router can refuse ICMP for unrelated reasons and produce a false "boundary exists". Style: no tool, no timeout, "a node" leaves the executor to pick one at random, which makes the recorded result non-comparable across the two test rounds; "Record what answers" has no expected value, so a fully-open boundary and a fully-closed one both produce a valid record.

**Fix (impl):** replace with an explicit probe list to run from a laptop joined to the current IoT SSID and again on the current Guest SSID, at each AP location: `nc -vz -w3 192.168.0.1 443`, `nc -vz -w3 <HA> 8123`, `nc -vz -w3 192.168.0.6 9000`, `nc -vz -w3 192.168.0.11 9100`, `curl -s -m3 https://1.1.1.1`. Record TCP open / refused / timeout per line in the Phase 0 artifact. Prerequisite: no Phase 0 item captures the current IoT/Guest SSID names and passphrases, which the test client needs — add it.
**Fix (style):** "From a client on each of IoT and Guest run `nc -vz -w3 <target> <port>` against: `192.168.0.1:443`, `HA:8123`, `192.168.0.6:9000`, `192.168.0.11:9100`, `1.1.1.1:443`. Record one line per target as OPEN / TIMEOUT. Expect only `1.1.1.1` OPEN; any other OPEN line is the hole Finding A predicts."

### M3. Phase 0.7 "confirm console access" has no pass condition
*Reviewer: stage9-impl (finding 4)*
**Lines:** 326, §7.6 lines 302–306.

**Fix:** "attach monitor+keyboard (or serial) and log in at the console menu — record which console works; then Diagnostics → Backup & Restore → Download, open the XML, confirm it contains the config version, store it off-router." "Confirm" is the word that lets an implementer skip it.

### M4. Phase 0 is missing the items Phase 1 cannot run without
*Reviewer: stage9-impl (finding 5)*
**Lines:** 316–330; consumers at 340, 345, 351, 253, 452, 475.

Add as numbered items:
- **Physical port map**: which port on the 8-port switch carries the OPNsense uplink and which carries the inter-room cable, and the equivalent on the rack switch. Without this, Phase 1a step 3 (340, "tag VLAN 20 on the inter-room trunk, both ends") is not executable — nobody knows which port is the trunk.
- **Existing SSID inventory**: SSID name, VLAN/isolation setting, passphrase, which APs broadcast it, client count. Needed by 1a step 6 (345) and 1b step 7 (359).
- **Per-AP model and firmware, and whether per-SSID VLAN tagging is supported.** Finding B is about APs; 0.1/0.2 only cover switches.
- **Coordinator MAC address** (required for the reservation at 351) and **whether the coordinator is USB-attached at all** — if it is, steps 1 and 5 of Phase 1b are no-ops and rule 5 does not exist.
- **The z2m socket port number.** Rule 5 (253) uses `<z2m port>` as a placeholder that no Phase 0 item resolves.
- **A named check that no comin deploy is running.** Line 452 and risk row 475 both say "check no comin deploy is running" with no command; the gate is `modules/nixos/comin-health-gate.nix` logging to `/var/log/comin-health-gate.log`.

### M5. "there is never an unfiltered window" is asserted without the mechanism that creates or closes it
*Reviewer: stage9-impl (finding 9)*
**Lines:** 339, §7.2 line 220 ("Replace OPNsense's default per-interface pass all"), §9 line 448.

**Fix:** name the action — on the GUEST rules screen, add the explicit rules and delete the auto-generated allow-all rule in the same visit; state that the anti-lockout rule must not be touched. State the ordering consequence: once the allow-all is gone, rule 1 must already be present or DNS and DHCP break at that instant. Separately, rule 1 as written (`GUEST → firewall`, 237) does not match a pre-bind DHCP client whose source is `0.0.0.0`; state whether the plan relies on OPNsense's automatic DHCP pass rule or adds an explicit `0.0.0.0/32:68 → 255.255.255.255:67` allow.

### M6. The trunk step is the only step with a real outage and has no procedure, no expected duration, and no rollback; the consequence is stated 100 lines away
*Reviewers: stage9-impl (finding 10), stage9-style (finding 9)*
**Lines:** 340 versus §9 lines 441–445 and risk row 475. Style: the consequence — this can drop every frame crossing the only inter-room cable, including the path to the rack and to three nodes' uplinks — is stated at 441–444, in a section the executor has no reason to re-read mid-step.

**Fix (impl):** name the two ports from the Phase 0 port map; state the order (which switch first) and the vendor-specific caveat that some switches drop the link when the tag set changes on a live trunk; state the expected blip in seconds; require the "no deploy running" check; give the rollback (remove the tag on both ends, then re-verify the inter-room link with a named test such as reaching a rack host by IP).
**Fix (style, relocate):** append to step 3: "This can briefly drop the inter-room link (§9). Do it outside a deploy window; confirm no comin switch is in progress first."

### M7. Step 4 does not describe how Omada applies an SSID to a mesh fleet, and names no device
*Reviewers: stage9-impl (finding 11), stage9-style (finding 10)*
**Lines:** 341–342; §7.5 (293–295) names the enabled pair and the disabled trio explicitly. Style adds that "mesh and garage" is a false partition — the garage unit is a CEP wireless bridge, not a mesh child (§3.1 line 96).

Impl: an SSID created in the Omada controller is applied controller-wide and then enabled per AP or per AP group, and mesh children inherit the parent's radio/SSID configuration — which is exactly Finding B. "Create the SSID on the two wired APs" is not a thing you can do.

**Fix (impl):** write it as: create the controller Network object bound to VLAN 20; create the SSID bound to that network; then in the SSID's per-AP / AP-group settings enable it on the living-room EAP225 and office EAP610 only; then **verify** in the controller that kitchen, entrance and garage show the SSID disabled after apply, and record the apply time and where apply status is visible. That verification is §10 line 464's row, and it is not in the step.
**Fix (style):** "Create `home-guest` on EAP225 (living room) and EAP610 (office), VLAN 20. Leave it disabled on kitchen EAP225, entrance EAP225 and garage EAP225."

### M8. Step 5 states pass conditions but no commands and no observation point
*Reviewers: stage9-impl (finding 12), stage9-style (finding 11)*
**Lines:** 343–344; §10 line 462. Style adds that `10.60.20.x` with a literal `x` is a placeholder where a range exists (§7.2 line 216 says `.100`–`.200`), and that "any node" is 13 hosts.

**Fix (impl):** give the literal probe list, plus the lease check (client shows `10.60.20.x` — this is the Finding B fail-open detector, present in §10 line 462 but absent from the step), plus a DNS check (`dig +short`), and require it at both AP locations.
**Fix (style):** "From a wifi client at each of the two AP locations: `ip a` shows a `10.60.20.100`–`10.60.20.200` lease; `nc -vz -w3 1.1.1.1 443` succeeds; `nc -vz -w3` to `192.168.0.1 443`, `HA 8123`, `192.168.0.6 9000`, `192.168.0.11 9100` all time out."

### M9. The Phase 1a rollback is executable only for steps 4 and 6, and its closing claim is false
*Reviewers: stage9-impl (finding 13), stage9-style (finding 13)*
**Lines:** 347–348.

Impl: steps 1–2 require reverse dependency order; step 3 requires a tag removal; step 6 requires re-enabling the old SSID and stating that clients already joined to `home-guest` must be rejoined or left there deliberately; nothing states what is intentionally left in place. Style: "Nothing on the trusted LAN moved, so nothing else can break" is absolute and not true as written — this phase added a VLAN and a tag set to two switch trunks and a new interface plus ruleset to OPNsense, and any of those can misbehave after the SSID is disabled.

**Fix (impl):** per-step rollback. Steps 1–2: delete the rules, then the DHCP scope, then the interface assignment, then the VLAN — reverse dependency order, because OPNsense refuses other orders while the DHCP server and rules reference the interface. Step 3: remove the tag on both switches. Step 4: disable the SSID controller-wide. Step 6: re-enable the old SSID, and state that clients already joined to `home-guest` must be rejoined or left there deliberately. State what is intentionally left in place (VLAN 20, interface, rules — inert, and re-creating them is the riskier edit).
**Fix (style):** "Disable `home-guest` in Omada and re-enable `<recorded old guest SSID>`. The trusted LAN's addressing, native VLAN and existing SSIDs are unchanged. The VLAN 20 interface, DHCP scope and GUEST ruleset can be left in place (inert with no SSID) or removed in a second change."

### M10. No abort criterion anywhere in Phase 1a
*Reviewer: stage9-impl (finding 14)*
**Lines:** 332–348.

**Fix:** add one line: "If step 5 shows the client reaching `192.168.0.1` or any RFC1918 host, stop. Do not proceed to step 6. Roll back step 4 first, then diagnose."

### M11. Phase 1b step 1 is unexecutable without data, contradicts §7.2, and never names the reserved address
*Reviewers: stage9-impl (finding 16), stage9-style (finding 15)*
**Lines:** 351; §7.2 line 216/218; step 5 at 357/358.

Impl: a reservation needs the coordinator's MAC, which no Phase 0 item captures. And §7.2 line 216 puts reservations *below* `.100`, outside the pool, while step 1 says "reserve … in the VLAN 10 DHCP scope". Style: §7.2 gives the rule ("below `.100`") but no literal value, and step 5 then points z2m at "the reserved coordinator address" — a value the executor chose themselves and which is therefore not recorded anywhere.

**Fix (impl):** "Services → DHCPv4 → Edit (IOT) → Address Reservations: MAC from Phase 0.4 → `10.60.10.10`", and use §7.2's wording ("below the dynamic pool") in both places. Add the third branch explicitly: if Phase 0.4 finds a USB-attached coordinator, steps 1 and 5 are no-ops and rule 5 does not exist — say so, or the implementer invents a plan for a device that has no IP.
**Fix (style):** name it: "Reserve `10.60.10.10` for the coordinator (below the `.100` pool start)." Then step 5 reads `serial.port: socket://10.60.10.10:<port>`.

### M12. Phase 1b step 4 "the trunks" is three distinct configurations
*Reviewer: stage9-style (finding 18)*
**Lines:** 357; §7.1 (198–204) lists OPNsense↔8-port, 8-port↔rack, and each AP port. Compare 1a step 3 (340), which names exactly one of them. Same ambiguity as M6 regarding the inter-room outage.

**Fix:** "Add VLAN 10 to the tagged set on: OPNsense LAN port 1 on the 8-port switch, the inter-room trunk on both switches, and the EAP225/EAP610 ports. Expect a brief inter-room link drop (§9)."

### M13. Phase 1b step 7 is the largest manual task in the plan and is one line
*Reviewers: stage9-impl (finding 17), stage9-style (finding 19)*
**Lines:** 359–360; success criterion 2 at 38.

Impl: "move IoT devices over in batches, verifying HA control" does not say which devices, how many, what a batch is, what the per-device action is, or what "verifying" means. Zigbee/Z-Wave devices do not move at all (they join the coordinator's network, not a Wi-Fi SSID); only Wi-Fi IoT devices need their credentials changed, each through its own app or a re-pair. Style: batch size and the verification act are both undefined; "verifying HA control" is not an instruction.

**Fix (impl):** add the device inventory to Phase 0 with per-device class (Wi-Fi / Zigbee / cloud-only) and current SSID; then define a batch ("one room, ≤5 Wi-Fi devices"), the per-device action (app Wi-Fi-change flow vs factory + re-pair), the verification (the HA entity changes state within N seconds; the integration shows no error), and the abort rule.
**Fix (style):** "Move at most 5 devices at a time. After each batch, open HA > Developer Tools > States and confirm each moved entity changes state when the device is triggered; then check the z2m log for a reconnect loop before starting the next batch."

### M14. The Phase 1b rollback understates the cost by an order of magnitude and omits actions and artifacts
*Reviewers: stage9-impl (finding 18), stage9-style (finding 20)*
**Lines:** 364.

Impl: "move devices back to the old SSID" after step 7 means re-running every device's setup flow, one at a time, through its own vendor app. "z2m's `serial.port` is one field" is true only if the coordinator's own address is also reverted, which is not stated. Style: the second sentence is an argument, not an action — it never says to change it back, where, or that the add-on must restart; the rollback also omits two artifacts this phase created: rule 5 (if added) and the DHCP reservation.

**Fix (impl):** state the real cost and bound it — "per-batch rollback; ~N minutes per Wi-Fi device via its setup flow; the old SSID and passphrase must remain untouched until Phase 1b is signed off, which is why Phase 1a step 6 is sequenced last." Give the z2m rollback as a named action (revert `serial.port`, restart add-on, confirm "Connected") plus revert the coordinator's address.
**Fix (style):** "**Rollback:** move devices back to `<recorded old IoT SSID>`; set z2m `serial.port` back to its previous value in the add-on config and restart the add-on; if rule 5 was added, disable it. The DHCP reservation can stay."

### M15. Phase 2's ruleset delegates the actual design to whoever is at the keyboard
*Reviewer: stage9-impl (finding 21)*
**Lines:** 372–373.

**Fix:** enumerate with protocol/port/destination: `VLAN50 → LAN_NET:22`, `VLAN50 → LAN_NET:6443`, and decide the ones the plan has not considered — kubelet `10250` if `kubectl logs`/`kubectl top` runs from a desktop, Grafana/Prometheus ports, `8123` HA UI, SMB/NFS to TrueNAS, printer ports, and DNS to the firewall. State the `LAN_NET → VLAN50` inbound block and what it visibly breaks (anything on a desktop that expects to reach a device by old desktop IP).

### M16. Phase 2 identifies a roadwarrior break and gives no fix
*Reviewers: stage9-impl (finding 22), stage9-style (finding 24)*
**Lines:** 374–375; Phase 0.5 at 324.

The tunnel advertises `LAN_NET` only, so moving desktops to VLAN 50 silently removes VPN access to the operator's own machines — the machines the phase exists to protect. Style: "Note this also" is filler, and "what a roadwarrior sees" does not name the consequence or the decision.

**Fix (impl):** name the change and the file (add the VLAN 50 CIDR to the WireGuard advertised routes in `hosts/titan/configuration.nix`), and state that every roadwarrior peer config must be re-imported. Also: desktops moving to DHCP on VLAN 50 changes their IPs, so Phase 0.5 (324) must include desktops — it currently lists TrueNAS, DNS, HA, printers and the controller, not desktops.
**Fix (style, relocate the decision to where it is made):** "Consequence: mesh/roadwarrior clients lose access to VLAN 50, because `wireguard.lanSubnet` advertises `LAN_NET` only. Decide now whether to add VLAN 50 to the advertised routes or accept the loss."

### M17. Phase 2's hard gate is buried as a sentence fragment
*Reviewer: stage9-style (finding 23)*
**Lines:** 368–370. "Cheap" is a one-word evaluative fragment with no cost attached, and the second clause restates §5 row B-lite (152) almost word for word. "Requires the rack switch to be managed." (370) is a hard gate buried at the end of a prose paragraph — an executor reading top-to-bottom reaches the switch before noticing it was conditional.

**Fix:** DROP the first sentence (or replace with the cost: "one switch reconfiguration of N desktop access ports; no change in this repo"). Promote the gate: "**Precondition:** Phase 0.2 confirmed the rack switch is managed. If not, Phase 2 is blocked on a hardware purchase."

### M18. The Phase 3 table is tagged `[measured]` but contains an `[unverified]` row and cannot measure the items that are not repo files
*Reviewers: stage9-impl (finding 25), stage9-style (finding 27)*
**Lines:** 383 (tag), 390 (`[unverified]` inside the tagged table), rows 387–397.

Impl: at least four required changes are outside this repo and therefore not `[measured]`: Home Assistant's own static network config (its IP is still unknown, 324); TrueNAS/MinIO's own network config plus the iSCSI target addresses already recorded per Longhorn volume — moving the portal IP is not a single config value; printers/scanners and any client pinned to an IP; and OPNsense itself (DHCP reservations, the `LAN_NET` alias value, Outbound NAT and reflection for the new range). Style: a table-level marker contradicted by a row marker destroys the convention the Confidence markers block (13–19) sets up, and the row in question (certificate SANs) is one an implementer would otherwise trust.

**Fix (impl):** add a second table "Not in this repo" with those rows, and scope the `[measured]` tag to the rows actually read from the repo.
**Fix (style):** drop the table-level `[measured]`, tag each row, and move the SAN row's caveat into a separate `Verify before planning` line under the table.

### M19. The Phase 3 `Where` column holds an explanation, not a location
*Reviewer: stage9-style (finding 28)*
**Lines:** 389 — "etcd member peer and client URLs | live etcd cluster — members are IP-pinned". The column promises a place; the cell gives a reason. An implementer cannot open "live etcd cluster".

**Fix:** "`Where`: `etcdctl member list -w table` on any control-plane node (record the output). Action: `etcdctl member update` per member."

### M20. The Phase 3 table contains an open-ended catch-all
*Reviewer: stage9-style (finding 29)*
**Lines:** 396 — "Cluster side | `k8s-casa` Prometheus static scrape list, app DNS, anything with a hardcoded node IP". "anything with a hardcoded node IP" is an open-ended catch-all inside a blast-radius table whose entire purpose is completeness. It converts a known-unknown into a hidden unknown.

**Fix:** replace with the command that produces the list — "grep `192.168.0.` in `k8s-casa`; record output count and file list in Phase 0.5" — and drop the catch-all.

### M21. The Phase 3 rollout row is unreadable, and the file it names needs no edit
*Reviewers: stage9-style (finding 30), stage9-codebase (M15)*
**Lines:** 397 — "| Rollout | `scripts/comin-approve.sh` bind zone `casa.arrieta` resolution |". Style: three nouns in a row with no relation stated; this is the sentence most likely to be misread at 11pm. It is unclear whether the script resolves names, or whether the bind zone holds the IP-pinned records, or both. Codebase: `scripts/comin-approve.sh:39` is `DOMAIN="${COMIN_DOMAIN:-casa.arrieta}"` — an env-overridable default, so no edit is required for a re-IP unless the bind zone itself is renamed. What the script actually contributes to Phase 3 is the fleet accept order and canary ring (`:6–9`, `:36`), and `AGENTS.md` documents `COMIN_ORDER=servers-first|risk`. Phase 1's landmine at 441 ("do not do it while comin is mid-switch on a fleet host") has the same answer.

**Fix (style):** "`Rollout` | `scripts/comin-approve.sh` reaches hosts by name via the `casa.arrieta` zone. Confirm no `casa.arrieta` record points at `192.168.0.0/24`; if one does, it must change with the rest."
**Fix (codebase):** "| Rollout ordering | `scripts/comin-approve.sh` — `COMIN_DOMAIN` defaults to `casa.arrieta` and is env-overridable, so no edit is needed for a re-IP; the reusable parts are `COMIN_ORDER` and the canary ring, which is also the answer to the Phase 1a/1b 'no deploy running' precondition |".

### M22. Phase 3 has no ordering, no rollback, no verification, and no owner or deadline for the strategy choice
*Reviewers: stage9-impl (finding 26), stage9-style (finding 31)*
**Lines:** 399–413, §8.1 lines 420–426. Style adds line 399: "Two ways to do it, and the choice should be made with the etcd risk in view:" — "it" and "the etcd risk" are pointers rather than content; the risk is a row in §11 (477) and the gate is three paragraphs below at 411–413.

Impl: the two bullets are options, not steps, and nothing says who picks, on what input, by when. Deferring the spec is legitimate; deferring the decision without naming its input is not.

**Fix (impl):** name the decision owner; name the deciding input as a prerequisite task with a pass condition ("etcd snapshot restored into a scratch cluster and `etcdctl endpoint status` healthy; Longhorn backup restored to a scratch volume and the workload attached"); and state that the Phase 3 spec must contain ordering, per-step rollback and per-step verification before it is schedulable.
**Fix (style):** "Two strategies. Choose only after the restore gate below has been satisfied."

### M23. The restore gate is tagged `[unverified]` when it is a precondition, and the repo already has continuous restore evidence
*Reviewers: stage9-style (finding 34), stage9-codebase (M12)*
**Lines:** 411–413.

Style: a sentence beginning with a confidence marker and a lowercase verb. The marker is misapplied: this is not a claim awaiting verification, it is a precondition. As written it reads as a hedge rather than a gate. Codebase: `modules/nixos/k3s-snapshot-monitor.nix:236–240` defines `verify.enable`: "Download the newest snapshot and verify it with `etcdutl snapshot status`, publishing restoreability, revision and key count alongside the age" (`:100–104` is the implementation). It is enabled on the casa servers and titan. Line 412–413 gates Phase 3 on "an etcd snapshot … restored successfully at least once" as though nothing exists.

**Fix (style):** convert to an explicit gate: "**Gate:** do not schedule Phase 3 until an etcd snapshot restore and a Longhorn backup restore have each completed successfully at least once. Record the date, host and duration in this section."
**Fix (codebase):** line 411–413 → "…depends on the restore path actually being tested. `modules/nixos/k3s-snapshot-monitor.nix` `verify.enable` already proves every snapshot opens with `etcdutl snapshot status` on a timer; that is a necessary but not sufficient proof (it does not restore into a live etcd). Name the existing metric as the standing evidence and define the one additional step that closes the gap — a restore into a scratch etcd and a `kubectl get` against it — with a date."

### M24. The recommended Phase 3 scope contradicts §6 and leaves the NAS destination unnamed
*Reviewer: stage9-style (finding 35)*
**Lines:** 415–416 versus §6 line 176.

"**Recommended Phase 3 scope:** servers to VLAN 30, desktops already on 50, NAS left on the flat segment it is on." "The flat segment it is on" is VLAN 1 / `192.168.0.0/24`, which §6 line 176 says is "Retired in Phase 3". The sentence therefore says the NAS stays on a segment this phase deletes, and never says where it goes. This is the single most consequential open question in Phase 3 (Longhorn iSCSI endpoint) and it is expressed as a vague noun phrase.

**Fix:** name the destination explicitly, e.g. "NAS moves to the new untagged native VLAN that replaces VLAN 1 in this phase (define that VLAN and its subnet in the Phase 3 spec); iSCSI stays untagged on it."

### M25. The Phase 3 change list has no firewall row, and the IOT ruleset silently stops covering the new ranges
*Reviewer: stage9-impl (finding 27)*
**Lines:** rows 387–397; §7.3 rule 2 (249/251) versus rule 6 (254/255); contrast the GUEST rationale at 246–248.

IOT rule 2 blocks `IOT → LAN_NET` only, while rule 6 allows `IOT → any`. Once Phase 2 puts desktops on `10.60.50.0/24` and Phase 3 puts servers on `10.60.30.0/24`, IoT can reach both — precisely the staleness the document cites as the reason GUEST rule 2 uses `RFC1918`.

**Fix:** change IOT rule 2 to `IOT → RFC1918 block + log`, with the HA exception as an explicit allow before it (mirroring GUEST's structure), and add a Phase 3 row "firewall aliases and rules: `LAN_NET` value, IOT and GUEST rulesets re-verified against the new ranges".

### M26. The Phase 3 scope recommendation rests on an unshown mechanism
*Reviewer: stage9-impl (finding 28)*
**Lines:** 415–418.

**Fix:** cite the actual check in `modules/nixos/comin-health-gate.nix` and what it measures (does it measure latency, or only session establishment?), or tag the claim `[unverified]`. As written it reads as measured fact and it is load-bearing for keeping VLAN 40 unused. (See B1 — the check cannot see Longhorn at all.)

### M27. Line 30–32: the `[measured]` tag is attached to two true facts that do not produce the stated mechanism
*Reviewer: stage9-codebase (M1)*
**Lines:** 30–32.

Line 30–31 says roadwarriors "get `192.168.0.0/24` injected as a route into the tunnel and lose their own local network", and cites `wireguard.lanSubnet` + `forwardToLan = true` as the evidence. Neither option installs any route. `lanSubnet` is referenced only in the hub-side MASQUERADE scope (`wireguard.nix:85–90`); `forwardToLan` sets `net.ipv4.ip_forward` (`:271–273`) and appends those NAT rules (`:279–280`). The option description at `:166–171` says so: "enable IPv4 forwarding and SNAT mesh -> LAN traffic to the hub's tunnel address." The route a roadwarrior gets comes from its own client-side `AllowedIPs`, which is not in this repo. `hosts/titan/README.md:614` states the point outright: "**Listing `192.168.0.0/24` in `AllowedIPs` does not fix this.**"

**Fix:** drop the `[measured]` citation from that sentence and replace it with the real measured source: `hosts/titan/README.md:592–635`, which records the collision (measured on macbookair 2026-10-18), the `/32` mitigation, and the fact that a blanket `/24` "takes the venue's gateway and any captive portal down with it."

### M28. `k3s.serverAddr` is not a single literal across the control plane
*Reviewer: stage9-codebase (M2)*
**Lines:** 388, and 85–86.

`hosts/k8s-server01/vars.nix:25` and `hosts/k8s-server03/vars.nix:25` both hardcode `https://192.168.0.12:6443`; `hosts/k8s-server02/vars.nix:25` uses `.11`. So two of three control-plane members join via a *different* member's address. An implementer who greps `.11` and edits "every agent `vars.nix`" leaves server01 and server03 with a stale endpoint. Line 86 ("hardcoded in every agent's `vars.nix`. There is no VIP.") is true for agents but hides this.

**Fix:** line 388 → "`k3s.serverAddr` is a hardcoded literal in every member's `vars.nix`: `https://192.168.0.11:6443` on all agents and on `k8s-server02`, `https://192.168.0.12:6443` on `k8s-server01` and `k8s-server03`. No VIP, so both literals are live dependencies." Apply the same correction at 85–86.

### M29. "the firewall is off on k3s hosts" is false for `titan`, which is a k3s host
*Reviewer: stage9-codebase (M3)*
**Lines:** 87–88 and 500.

`modules/nixos/k3s.nix:171` and `modules/nixos/k8s-network.nix:24` set `networking.firewall.enable = lib.mkDefault false`, but `modules/nixos/public-host.nix` assigns a hard `true`, which outranks `mkDefault`, and `hosts/titan/configuration.nix:315` enables `publicHost`. titan runs k3s (`hosts/k8s-server01/vars.nix` — `hosts/titan/vars.nix`). §13's seam is written as though the whole control plane is unguarded; on the hub it is already guarded, by per-source rules matched `-i wg0`.

**Fix:** line 87–88 → "`networking.firewall.enable` is `mkDefault false` on the casa k3s hosts, so nothing on the LAN is fenced from that control plane. `titan` is the exception: `public-host.nix` sets the firewall to `true` and answers mesh ports per-source." Line 500 → same distinction.

### M30. The Phase 3 table never names the WireGuard peer `allowedIPs` — the one edit that actually moves the route
*Reviewer: stage9-codebase (M4)*
**Lines:** 395.

`hosts/titan/configuration.nix:201–206` gives the OPNsense peer `allowedIPs = [ "192.168.133.2/32" "192.168.0.0/24" ]`. The comment at `:162–164` states the consequence: "AllowedIPs become routes the moment the generation is deployed, whether or not the peer ever handshakes." The mirror requirement is hand-maintained on the OPNsense box and on the retired VPS hub (`:283–284` region). Line 395 lists `lanSubnet`, `forwardToLan` SNAT and the allow-list — none of which is the route.

**Fix:** add a row: "| WireGuard route advertisement | `hosts/titan/configuration.nix:205` OPNsense peer `allowedIPs` `"192.168.0.0/24"`, and the mirrored advertisement on the OPNsense peer itself (out of repo) — these are the routes; `lanSubnet` only scopes the hub's SNAT |".

### M31. `192.168.0.42` appears nowhere in the spec but is a live hardcoded pin on titan
*Reviewer: stage9-codebase (M5)*
**Lines:** 324 (Phase 0.5 list), 391.

`hosts/titan/configuration.nix:527–529`: `networking.hosts = { "192.168.0.42" = [ "s3.l.arrieta.eu" ]; };` — deliberately pinned so etcd snapshots and restic do not depend on split-horizon DNS. Also `:166` (`nix-cache.home.arrieta.eu -> 192.168.0.42`, in `extra-substituters`) and `:203–204` ("MinIO for backups, and the Attic cache, both at 192.168.0.42"). Phase 0.5 (324) lists `.6` and `.41` and omits `.42` entirely.

**Fix:** add `.42` to the Phase 0.5 list and add a Phase 3 row "`hosts/titan/configuration.nix:528` `networking.hosts` pin of `s3.l.arrieta.eu`".

### M32. Two more hardcoded copies of `192.168.0.6` in `pkgs/coder-iscsi-helper/helper.py`, absent from the table
*Reviewer: stage9-codebase (M6)*
**Lines:** 391, 93.

`pkgs/coder-iscsi-helper/helper.py:45` defaults `CODER_HELPER_TRUENAS_URL` to `https://192.168.0.6` and `:72` defaults `CODER_HELPER_TARGET_PORTAL` to `192.168.0.6:3260`. `modules/nixos/coder-host.nix:174` sets the second one explicitly, but the TrueNAS **API** URL is only ever a default in the Python file — so it survives silently if the NixOS env is ever trimmed. Note also that `.6` serves the TrueNAS API on 443, not just `:9000`/`:3260` as line 93 implies.

**Fix:** add `pkgs/coder-iscsi-helper/helper.py:45,72` to line 391's row, and mention the TrueNAS API endpoint in line 93.

### M33. `modules/home-manager/dev-tools.nix:146` carries `192.168.0.29` as a module-level default
*Reviewer: stage9-codebase (M7)*
**Lines:** 394.

`baseUrl = piCfg.baseUrl or "http://192.168.0.29:8731/v1";` — a fallback that silently reappears if the per-host override in `home/hosts/coder-workspace-titan/userOptions.nix` is removed or renamed. Line 394 lists only `home/hosts/coder-workspace-titan`.

**Fix:** add `modules/home-manager/dev-tools.nix:146` to line 394's row and note it is a default, not an assignment.

### M34. Line 180–184: "avoid every range this fleet already owns" omits titan's pod and service CIDRs
*Reviewer: stage9-codebase (M8)*
**Lines:** 180–184.

`hosts/titan/vars.nix:72–73` sets `clusterCidr = "10.62.0.0/16"` and `serviceCidr = "10.63.0.0/16"` precisely because "titan reaches the home LAN over WireGuard, so the defaults would collide." The list at 181–183 names `10.42/16`, `10.43/16`, `172.17/16`, `172.16/12`, `192.168.133.0/24` and consumer defaults — but not `10.62/16` or `10.63/16`. `10.60.0.0/16` still clears them, so the choice is safe; the justification is simply unverifiable as written, and a reader who trusts the list rather than the code would not catch a future `10.62` collision.

**Fix:** insert "`10.62.0.0/16` and `10.63.0.0/16` (`titan`'s pod and service ranges, `hosts/titan/vars.nix:72–73`)" into the list at line 181.

### M35. Phase 0.5's IP map omits the MetalLB LoadBalancer pool, and `.41` may be a VIP rather than a host
*Reviewer: stage9-codebase (M9)*
**Lines:** 92 and 324.

`k3s-network-debug.md:160`: "MetalLB provides LoadBalancer IPs on 192.168.0.41-44 range." `common/etcd-snapshot-s3.nix:49` independently warns that "pinning :9000 hits a VIP and hangs until `--etcd-s3-timeout`". Line 92 and line 324 both treat `.41` as a plain host ("DNS2, the rsyslog target"). If `.41` is inside the MetalLB pool, Phase 3's blast radius for it is a k8s-casa pool change, not a NixOS host change — a completely different work item.

**Fix:** add to line 324: "…the Omada controller, and whether the MetalLB LoadBalancer pool (recorded as `192.168.0.41-44` in `k3s-network-debug.md:160`) overlaps `.41`/`.42` — if it does, those are pool addresses, not host addresses, and Phase 3 moves them in k8s-casa rather than in this repo."

### M36. `AGENTS.md` is an unlisted bearer of the legacy LAN, and is already stale
*Reviewer: stage9-codebase (M10)*
**Lines:** Phase 3 table (no row exists).

The operator runbook hardcodes the range in documented commands and examples: the `network_env` worked example at `AGENTS.md:1189–1192` and `:139–141` (`DNS2=192.168.0.41`), the routewatch commands, and — already wrong today — the k3s snippet at `AGENTS.md:452` showing `serverUrl = "https://192.168.0.10:6443"`, which is both a stale option name (the module option is `serverAddr`) and a fourth IP that matches no node. After Phase 3 every one of those commands is a trap.

**Fix:** add a Phase 3 row: "| Operator runbook | `AGENTS.md` — `network_env` examples, routewatch commands, and the k3s snippet at `:452` (already stale: option name `serverUrl` and endpoint `.10` match nothing in the repo) |". Fixing `:452` is a Phase 0-sized correction, not a Phase 3 one.

### M37. `hosts/titan/README.md` already contains the roadwarrior finding and the re-IP inventory; the spec does not cite it
*Reviewer: stage9-codebase (M11)*
**Lines:** §1 (29–33) and Phase 3 (378–397).

`hosts/titan/README.md:592–635` already documents the roadwarrior collision with a dated measurement, the `/32` fix, and the renumber cost in words: "the durable fix is renumbering the home LAN off `192.168.0.0/24` (tracked as an issue; 21 `.nix` files here plus SOPS `network_env` on every host, OPNsense and the cluster scrape list encode it)". A grep of `*.nix` for `192.168.0.` returns 22 files — the README's count is right and the spec's Phase 3 table is a subset of it. §1 and Phase 3 reinvent this and understate it.

**Fix:** cite `hosts/titan/README.md:592–635` in §1 and in Phase 3, and state that the README's own inventory (22 `.nix` files) is broader than the table below it — the table is the *named* subset, not the full count.

### M38. §13's "one-way rule" already exists as a declarative pattern on titan
*Reviewer: stage9-codebase (M13)*
**Lines:** 499–504.

`modules/nixos/public-host.nix` implements `meshTCPPorts` (matched `-i wg0`), `meshTCPPortExtraSources` and `meshTCPPortRules` (per-source port lists), and `hosts/titan/configuration.nix:329, 333, 343–349` shows the pattern in use, including the deliberate refusal to widen a shared multiport rule to avoid exposing unauthenticated metrics. §13 reads as greenfield.

**Fix:** add to the §13 bullet: "`modules/nixos/public-host.nix` already expresses exactly this shape on the hub (`meshTCPPorts` matched `-i wg0`, plus `meshTCPPortExtraSources` and per-source `meshTCPPortRules`); the seam is whether the casa servers adopt a host-side equivalent or the rule lives in OPNsense. Decide the location before writing the rule."

### M39. Phase 3's risk list omits the documented route-loss failure that a re-IP will trigger on every host
*Reviewer: stage9-codebase (M14)*

`modules/nixos/static-network.nix:159–179` exists because "fresh worker switches drop the default route": a persistent `network-route-watch` unit re-issues `ip route replace default` every 10s, and `staticNetwork.routeFlags` (`:51–58`, example `["onlink"]`) is the documented knob for gateways that are not on-link. `AGENTS.md` documents the same failure and its workaround. Phase 3 changes every host's address, gateway and prefix — the exact trigger — and never mentions it. Note also that the watchdog is skipped entirely on the Pi hosts (B3), so they have no self-heal during the migration.

**Fix:** add a Phase 3 landmine: "Re-addressing a host can drop the default route mid-switch, which is why `modules/nixos/static-network.nix:164–179` runs a route watchdog and `staticNetwork.routeFlags` exists for non-on-link gateways. The watchdog is only created when the address is a `$` placeholder, so the Pi hosts have no self-heal — budget a console or a physical visit for them."

### M40. Phase dependencies are prose, not gates
*Reviewer: stage9-impl (finding 29)*
**Lines:** 314 ("each phase is independently valuable and independently reversible"), 370 (the only gate, in prose), §10 rows.

**Fix:** add two lines to each phase — `Entry:` (named Phase 0 items recorded in the artifact; named prior-phase §10 rows passing) and `Exit:` (named §10 rows, with their output pasted into the artifact).

### M41. §10 is the only verification content for Phases 1a/1b, the phases never reference it, and three rows are not observable as written
*Reviewer: stage9-impl (finding 30)*
**Lines:** 457–467, especially 465–466.

**Fix:** add a "how to observe" column with literal commands. `kubectl get nodes` needs the invocation host and kubeconfig context. "No comin rollback in `/var/log/comin-health-gate.log`" needs the grep pattern that denotes a rollback. "Roadwarrior reaches `192.168.0.11:6443` and gains no route to `10.60.10.0/24`" needs a named test peer and the client-side command (`route get 10.60.10.1` / `netstat -rn` inside the tunnel). And add the missing Phase 2 rows once Phase 2 exists.

### M42. §10 row-level untestable conditions
*Reviewer: stage9-style (findings 46, 47, 48, 51, 52)*
**Lines:** 461, 462, 463, 466, 467.

- 461: "`10.60.10.x` lease; `192.168.0.1`, `HA:8123`, `.6:9000`, node `9100` all unreachable; internet up" — placeholder lease value, shorthand `.6`, unnamed node, no command. **Fix:** "`ip a` shows `10.60.10.100`–`.200`; `nc -vz -w3` times out for `192.168.0.1:443`, `<HA>:8123`, `192.168.0.6:9000`, `192.168.0.11:9100`; `nc -vz -w3 1.1.1.1 443` succeeds."
- 462: "all RFC1918 unreachable" is unbounded and untestable — nobody probes `10.0.0.0/8`. **Fix:** name one target per range the rule blocks: `192.168.0.1`, `10.60.10.1`, `10.60.50.1`, `192.168.133.1`. Add the real observation for a firewall block: "and the block appears in OPNsense Firewall > Live View filtered on the GUEST interface" — a log line distinguishes "blocked" from "host down" in a way a timeout cannot.
- 463: "IoT and Guest SSIDs not broadcast there, or proven tagged" — two pass conditions, and the second is the thing Finding B (123–131) says cannot be relied on over a mesh backhaul. The alternative condition reopens the exact hole the row exists to close. **Fix:** single condition — "`home-iot` and `home-guest` are not broadcast from kitchen, entrance or garage APs (verified by a wifi scan at each location)."
- 466: "roadwarrior reaches `192.168.0.11:6443` and the rack as before, and gains no route to `10.60.10.0/24` or `10.60.20.0/24`" — "the rack as before" is not a test; "gains no route" states a condition without the command that shows it. **Fix:** "From a connected roadwarrior: `nc -vz -w3 192.168.0.11 6443` succeeds; `nc -vz -w3 <named rack host> <port>` succeeds; `ip route` inside the tunnel contains no `10.60.10.0/24` or `10.60.20.0/24`."
- 467: "`scripts/comin-approve.sh` still resolves and reaches every host" — a script name is not a test procedure. If the script has no dry-run or list mode, this row cannot be executed without side effects on a live fleet — which is a fact the row should state either way. **Fix:** name the invocation and expected output, e.g. "`scripts/comin-approve.sh --list` (or the read-only path) prints all 13 hostnames with reachable addresses; no host falls back to a `192.168.0.x` address that no longer answers."

### M43. §11 mitigations that are not actions
*Reviewer: stage9-style (finding 53)*
**Lines:** 473, 475, 478.

- 473: "Phase 0.2; hardware purchase, not redesign" — a pointer plus a noun phrase. No decision rule, no criterion for what to buy.
- 475: "Phase 0.4 measures it; rule 5 is narrow and IP-pinned" — the second half describes the rule's shape, not what anyone does.
- 478: "accepted and documented, not hidden" — not a mitigation, and "not hidden" is self-congratulation about the document rather than information for the operator.

**Fix:**
- 473 → "Run Phase 0.2 before Phase 1a. If unmanaged: order a managed PoE switch (≥ 8 GbE ports, ≥ 15.4 W PoE per AP port) and block Phase 1a until it arrives."
- 475 → "Phase 0.4 measures the socket direction. If the coordinator is a TCP client, add rule 5 before moving the coordinator's device, and keep it to one source, one destination, one port."
- 478 → "Accepted. No mitigation in Phase 1; see §7.3 and §13. Revisit if the guest SSID is ever used by people you do not know."

### M44. §12's central claim is contradicted by the same document
*Reviewer: stage9-style (finding 57)*
**Lines:** 482–484 — "this spec's network boundary is the one part with no diff, no review, and no rollback other than a restored XML export."

"No rollback" is false within this document: 347, 364 and 376 each describe a rollback that does not involve an XML restore. The accurate claim is that there is no *automated, diffable, reviewed* rollback.

**Fix:** "…is the one part with no diff, no review, and no automated rollback — the only scripted recovery path is a restored XML export, and the manual rollbacks in §8 depend on remembering what was changed."

### M45. §13 contains three absolutes and an undefined goal term in one bullet
*Reviewer: stage9-style (finding 59)*
**Lines:** 499–504 — "costs nothing to maintain", "it never needs editing for new workloads", "This is the cheap half of the containment goal". "The containment goal" is not one of §1's five success criteria and is not defined anywhere; the reader cannot tell which goal is the cheap half of. "the firewall is off on k3s hosts by design" (500) asserts intent — §3.2 line 89 records the mechanism (`mkDefault false`) but not why.

**Fix:** "Today the control plane is reachable from anywhere on the LAN: `networking.firewall.enable` is `mkDefault false` on k3s hosts (§3.2) and etcd `2381/metrics` is unauthenticated on `0.0.0.0`. A one-way allow-list — only the rack and the mesh reach `6443`, `10250`, `2379`, `2380`, `2381` — needs no edits for new workloads. Independent of every phase here; open it as its own spec." (Note: the `0.0.0.0` claim itself is corrected by B2.)

### M46. §2, §13 and §14 are three sections saying "not doing this"
*Reviewer: stage9-style (finding 61)*
**Lines:** mDNS reflection (48–51, 497–498), guest intra-VLAN isolation (277–280, 478, 506), IPv6 on IoT/Guest (56–58, 281–287, 507), cluster-internal segmentation (45–47, 510). §13 and §14 differ only in that §13 adds a reason.

**Fix:** merge §13 and §14 into one "Not in this plan" section with one line per item holding both the reason and any re-entry condition; reduce §2 to a bare list pointing at it.

### M47. §9 landmines: headings that assert more than their evidence, duplicates, and stale entries
*Reviewer: stage9-style (findings 39, 40, 41, 42, 43, 44)*
**Lines:** 430, 436–439, 441, 446–447, 449–451, 453–455.

- 430 "**The management VLAN breaks mesh.**" is stated as a law; the body's own evidence is `[community]` plus one vendor sentence, and the body hedges at 433–434 ("If it is ever revisited, it needs a bench test"). A heading is the one line guaranteed to be read out of context. **Fix:** "**Mesh adoption fails when the wired parent uses a management VLAN.** `[community]`". Also DROP "the textbook" at 432.
- 436–439 restates Finding B (132–138) with the same failure chain and conclusion, and opens with self-reference: "Restating Finding B because it is the one that bites". Two copies of a load-bearing warning means two copies to keep in sync. **Fix:** replace with a pointer: "**A half-working VLAN fails open.** See Finding B. Operational consequence: every phase ends with a client-side test at each AP location, not a config screenshot."
- 441 heading is certain, body conditional: "**Tagging the trunk is a brief outage on the inter-room link.**" versus "On some switches". "brief" is unquantified — the operator needs to know whether this is 2 seconds or 2 minutes, because it decides whether a deploy can be in flight. **Fix:** "**Tagging a live trunk can drop the inter-room link.**" and either state the observed duration after Phase 0.1/0.2 or say "duration unmeasured; treat as a full link outage until measured on your switch model."
- 446–447 "Create the rules before the SSID" is the third copy of an instruction already at §7.2 line 220 and Phase 1a step 2 line 339. **Fix:** DROP the landmine entry; keep the instruction where it is executed (339).
- 449–451 "**DHCP scope exhaustion or overlap** … Wireless-only scopes can be small and static reservations should live outside the dynamic pool." §7.2 (216–219) already fixed the pools at `.100`–`.200` and already required reservations below `.100`. This is a decision restated as advice in the weak "can be / should live" register. **Fix:** delete. If a check is wanted, make it a §10 verification row: "Confirm in the DHCP settings screen that the coordinator reservation `10.60.10.10` is outside the `100`–`200` pool."
- 453–455 "**The Zigbee coordinator's socket direction is a guess until measured.**" By the time anyone reaches Phase 1b, Phase 0.4 has measured it. The entry also duplicates §7.3's note (265–275) and Phase 0.4 (323). A landmine defused by a step earlier in the same plan dilutes the two landmines that are not. **Fix:** delete; the condition already lives in step 3 (356) and §7.3.

### M48. §8.1 duplicates the restore gate and drifts its referent
*Reviewer: stage9-style (finding 38)*
**Lines:** 424–426 versus 411–413. The restore-test prerequisite appears twice in near-identical wording. Line 426 then says "Do not fold it into the Phase 1 plan" after line 421 established the unit as "Phases 0 through 2". Two names for one thing.

**Fix:** state the gate once (keep the version at 411–413 as the Gate line) and reduce §8.1 to: "Phase 3 is a cluster migration and gets its own spec, written after Phase 0.5 and after the Gate above is satisfied. Phases 0–2 remain one implementation plan."

### M49. Phase 3's header is a floating superlative plus meta-commentary
*Reviewer: stage9-style (finding 26)*
**Lines:** 380–381 — "This is the expensive one and it is a **cluster event**, not a network change. It is listed with its real cost so it can be scheduled knowingly rather than discovered." "The expensive one" is expensive relative to what — the table below it, or Phases 0–2? The second sentence is the document describing its own editorial intent.

**Fix:** "This phase changes 13 hosts' network secrets, the k3s API endpoint, live etcd member URLs and serving certificates. Treat it as a cluster migration, not a network change." DROP the second sentence.

### M50. "Preserves everything" is an absolute the same bullet undercuts, and the skew rule is undefined here
*Reviewer: stage9-style (finding 32)*
**Lines:** 403–404.

**Fix:** state the rule in one clause ("control-plane nodes before workers, per the version-skew rule in `AGENTS.md`") and replace "Preserves everything" with "avoids re-provisioning nodes and re-encrypting Longhorn volumes".

### M51. "Often *less* risky" is a hedged comparative with no evidence, and "a real outage window" gives no duration
*Reviewer: stage9-style (finding 33)*
**Lines:** 407–409. The author has not run either path, and line 411 says so. Duration is the only number that matters for scheduling.

**Fix:** "Neither path has been tried here. Rebuild avoids live etcd surgery but requires a full restore rehearsal and an outage window long enough to restore etcd, Longhorn and Flux (measure it during the rehearsal; do not guess it now)."

### M52. Terminology drift for the same three devices in the execution path
*Reviewer: stage9-style (finding 63)*
**Lines:** rack switch is "rack switch" (321, 370, 441) and "office switch" (160); living-room switch is "8-port managed switch" (70), "8-port switch" (198, 320); APs are "the two wired APs" (341), "wired parent" (127, 431), "mesh and garage APs" (342). In an execution document, one device with two names is an instruction defect: at 11pm the operator logs into the wrong switch.

**Fix:** pick one name per device in §3.1 — `LIVINGROOM-SW`, `OFFICE-SW`, `EAP-LR`, `EAP-OFFICE`, `EAP-KITCHEN`, `EAP-ENTRANCE`, `EAP-GARAGE` — and use those throughout §7–§10.

### M53. Register inconsistency between the plan tables
*Reviewer: stage9-style (finding 64)*
**Lines:** Phase 0's `Item` column is noun phrases (320–324); Phase 1a/1b are imperatives (338–362); §10's `Test` column is noun phrases again (461–467). Three registers in one execution path means the reader has to re-infer, for each table, whether it is telling them to do something or describing something.

**Fix:** imperative + object in every actionable cell across Phase 0, Phase 1a/1b and §10.

### M54. Phase 0.6's stated consequence is inert, and "costs ten minutes" is an unverified estimate
*Reviewers: stage9-impl (finding 6), stage9-style (finding 4)*
**Lines:** 329–330; also 119–121.

Impl: lines 329–330 say 0.6 decides "hardening or fix", but the plan is byte-identical in both branches. Style: the decision is already stated at 119–121, and "costs ten minutes" is an unverified estimate presented as fact.

**Fix (impl):** either state what changes (e.g. "if there is no boundary today, the old guest SSID may not be left running — see Phase 1a step 6") or drop the claim.
**Fix (style):** DROP the sentence. If the effort estimate is wanted, keep only "0.6 is the cheapest item in this table and it changes how §4 Finding A is read."

### M55. Phase 1b step 3 omits alias creation
*Reviewer: stage9-impl (finding 19)*
**Lines:** 355 (1b step 3), 338 (1a step 2), alias table 226–232, IOT rule 4 at 253.

**Fix:** add "create aliases" as a sub-step in both 1a step 2 and 1b step 3, and add `GUEST_NET = 10.60.20.0/24` to the alias table — IOT rule 4 (253) references `GUEST_NET`, which is never defined.

### M56. Phase 2's rollback omits its own side effects
*Reviewers: stage9-style (finding 25), stage9-impl (finding 23)*
**Lines:** 376.

Style: "set the desktop ports back to untagged 1" is actionable but silent on the rules added at 372. Impl: it also leaves stale `10.60.50.x` leases; each desktop needs a release/renew or reboot, and the change drops every desktop's connections without warning.

**Fix:** "set the desktop ports back to untagged 1 and remove the VLAN 50 ruleset; each desktop must release/renew or reboot, and warn that the change drops every desktop's connections."

### M57. Phase 1b never retires the old IoT SSID, but its rollback assumes it still exists
*Reviewer: stage9-style (finding 21)*
**Lines:** 345 versus 350–362. 1a ends by retiring the old SSID (step 6); 1b never does, yet its rollback assumes the old IoT SSID still exists. Parallel phases with a missing step read as an omission rather than a decision.

**Fix:** either add "9. Once two weeks of clean operation have passed, retire the old IoT SSID" or state in one line why the old IoT SSID is kept.

---

## Nit

### N1. Phase 0.3's `Resolves` cell quotes an undefined proposition
*Reviewer: stage9-style (finding 5)*
**Lines:** 322 — `whether "no mDNS" is actually true today`. "no mDNS" is a quoted phrase that appears nowhere earlier as a defined proposition; the reader has to find §7.3's assumption at 265–268.
**Fix:** "whether §7.3's assumption that HA addresses IoT devices by IP holds".

### N2. Phase 0.8's parenthetical is not a partition
*Reviewer: stage9-style (finding 6)*
**Lines:** 327 — "Confirm where the Omada controller runs (hardware, software, cloud)." A container on a NixOS host is both. The `Resolves` cell says "rollback mechanics" without saying why.
**Fix:** "Confirm which Omada controller is in use: OC200/OC300 gateway box, self-hosted controller (record host and port), or TP-Link cloud. | Resolves: whether an SSID rollback can be done offline, or only through a cloud login."

### N3. "This is a requirement, not a nicety."
*Reviewer: stage9-style (finding 16)*
**Lines:** 354. Rhetorical emphasis; it adds no instruction. DROP.

### N4. "including rule 5 only if Phase 0.4 requires it"
*Reviewer: stage9-style (finding 17)*
**Lines:** 356. Phase 0.4 is a measurement; it cannot require anything. The actual condition is stated 90 lines earlier at 271–275.
**Fix:** "add rule 5 only if Phase 0.4 found no listening socket on the z2m port (coordinator is a TCP client)."

### N5. Phase 1b step 2 drops "address" from the list that Phase 1a step 1 has
*Reviewer: stage9-impl (finding 31)*
**Lines:** 354 versus 338.
**Fix:** make the two steps identical in shape so neither interface is created half-configured.

### N6. "unless there is a specific reason" is an open conditional with no criterion
*Reviewer: stage9-style (finding 37)*
**Lines:** 418 — "so VLAN 40 stays reserved and unused unless there is a specific reason." It invites exactly the reason-free change it is meant to prevent.
**Fix:** DROP "unless there is a specific reason", or name the one acceptable reason.

### N7. §10 z2m row names no log path
*Reviewer: stage9-style (finding 49)*
**Lines:** 464 — "no reconnect loop in the z2m log".
**Fix:** "z2m add-on log (HA > Settings > Add-ons > zigbee2mqtt > Log) shows `Connected` and no reconnect within 10 minutes."

### N8. §10 cluster row does not say when, by whom, or from where
*Reviewer: stage9-style (finding 50)*
**Lines:** 465 — "`kubectl get nodes` all Ready before and after".
**Fix:** "Run `kubectl get nodes` from titan immediately before Phase 1 step 4 and after step 8; all 7 cluster nodes Ready in both runs."

### N9. §11 row with likelihood "certain" is a known limitation, not a risk
*Reviewer: stage9-style (finding 54)*
**Lines:** 478. It sits in a table whose other rows are probabilistic, which makes the column unreadable.
**Fix:** move it out of §11 into §7.3 (where 277–280 already states it) and leave §11 to uncertain items.

### N10. §11 "SSIDs disabled on mesh" repeats the false partition
*Reviewer: stage9-style (finding 55)*
**Lines:** 474. The garage AP is a CEP bridge, not a mesh child (96).
**Fix:** use "disabled on kitchen, entrance and garage APs".

### N11. §11 has no row saying when the risk is checked
*Reviewer: stage9-style (finding 56)*
**Lines:** whole table (469–478). The table is read once and forgotten.
**Fix:** add a `Checked at` column naming the Phase 0 item or phase step.

### N12. §12 wording
*Reviewer: stage9-style (finding 58)*
**Lines:** 486–491. "Not in scope to fix here, but the options worth a decision later:" is wordy throat-clearing; "a well-trodden `ansible`/terraform-provider path" uses "well-trodden" where a name would do; "would make Phase 2 and 3 far safer" is an unmeasured comparative.
**Fix:** "Out of scope here. Options for a later decision: OPNsense REST/`configd` API, an Ansible or terraform provider, and the Omada controller API. A minimal version — VLAN table, interface definitions and firewall ruleset rendered from a Nix module and diffed against the live device — would give Phase 2 and 3 a reviewable diff before apply instead of a hand edit on a live firewall."

### N13. "nothing about the VLAN plan changes" is an absolute about an undesigned change
*Reviewer: stage9-style (finding 60)*
**Lines:** 498.
**Fix:** "no VLAN reassignment is expected to change."

### N14. §13's IPv6 line is a fragment, and RA/SLAAC are never expanded
*Reviewer: stage9-style (finding 66)*
**Lines:** 507 — "Only with a plan for RA-based SLAAC and prefix changes."
**Fix:** "Add IPv6 to IoT and Guest only after a plan exists for router-advertised prefix changes and SLAAC-based guest isolation (see §7.4 for why it is excluded now)."

### N15. Line 88 attributes the etcd documentation to one host
*Reviewer: stage9-codebase (N1)*
**Lines:** 88. The identical comment block is in `hosts/k8s-server02/vars.nix` and `hosts/k8s-server03/vars.nix`.
**Fix:** say "every casa server's `vars.nix`".

### N16. Line 95–96 calls `coderHost.allowedApiSources` a `192.168.0.29` reference
*Reviewer: stage9-codebase (N2)*
**Lines:** 95–96. The live value is `hosts/llm01/configuration.nix:76`: `coderHost.allowedApiSources = [ "192.168.0.0/24" ];` — a /24, not `.29`. It does need changing in Phase 3, but it is not a `.29` reference.
**Fix:** reword to "…`coderHost.allowedApiSources` (the LAN `/24`, not the host)".

### N17. Line 393 understates the rsyslog fan-out
*Reviewer: stage9-codebase (N3)*
**Lines:** 393. `modules/nixos/rsyslog.nix:36` sets `default = "192.168.0.41"` and no host overrides `rsyslog.server`, while 11 hosts set `rsyslog.enable = true`. One edit changes 11 hosts at once. Worth saying, because it is the only row in the table where a single change is atomic across the fleet rather than per-host.
**Fix:** note the fan-out in the row.

### N18. Line 461's "node `9100`" probe target is not what it looks like on the k3s nodes
*Reviewer: stage9-codebase (N4)*
**Lines:** 461 (and 325). `modules/nixos/prometheus.nix` (node_exporter) is enabled only on `titan` (`hosts/titan/configuration.nix:522`) and `llm01`; on the casa nodes 9100 is the in-cluster node-exporter DaemonSet. The Phase 0.6 probe is still valid, but the row should say which 9100 it means, since the two have different owners and different failure modes.
**Fix:** name which 9100 the row means.

### N19. Phase 0.5 scan scope omits desktops and printers
*Reviewer: stage9-impl (finding 22, second half)*
**Lines:** 324. Phase 0.5 lists TrueNAS, DNS, HA, printers and the controller, not desktops; but Phase 2 moves desktops to DHCP on VLAN 50, which changes their IPs.
**Fix:** add desktops (and printers) to the Phase 0.5 scan scope.

### N20. Phase 0.1's "whether all ports trunk" is not an answerable question
*Reviewer: stage9-impl (finding 2, part)*
**Lines:** 320 versus §7.1 line 205 (server ports are untagged access ports).
**Fix:** replace with "which ports support tagging, and how many are free."

### N21. Phase 1a step 2 must state the anti-lockout rule and the ordering consequence
*Reviewer: stage9-impl (finding 9, second half)*
**Lines:** 339, 220, 237.
**Fix:** state that the anti-lockout rule must not be touched, and that once the allow-all is gone rule 1 must already be present or DNS and DHCP break at that instant.

### N22. Phase 1b step 5 must state expected z2m downtime and that Zigbee devices do not need re-pairing
*Reviewer: stage9-impl (finding 15, second half)*
**Lines:** 357–358.
**Fix:** state the expected downtime between moving the coordinator and repointing z2m, and state that Zigbee devices do not need re-pairing for it.

### N23. Hedged wording where the answer is knowable
*Reviewer: stage9-style (finding 65)*
**Lines:** 353 ("No mDNS means…"), 407 ("Often *less* risky"), 418 ("unless there is a specific reason"), 442 ("On some switches"), 450 ("can be small"), 463 ("or proven tagged"), 490 ("far safer"), 502 ("costs nothing to maintain"). Each is a place where either Phase 0 will produce the answer or the author already decided it.
**Fix:** tie each hedge to the item that resolves it, or state the decision.
