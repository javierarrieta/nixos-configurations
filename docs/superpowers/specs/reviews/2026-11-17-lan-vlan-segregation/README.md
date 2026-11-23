# Review artifacts — LAN VLAN segregation design

Multi-agent review of `../../2026-11-17-lan-vlan-segregation-design.md`, run 2026-11-18
(the morning after the spec was committed at `27cb868`, 2026-11-17 21:04).

**Status: the findings are NOT applied.** The spec is still 513 lines, byte-identical to
what was reviewed. These files are kept so the review is not silently lost, not because
they are documentation.

**Update — all 22 blockers are now addressed**, each re-verified against `origin/main`
rather than taken on trust. Two of the review's own citations did not survive that check:

- B-03 said "only nine" hosts resolve their address from `network_env`. It is **seven**
  via `secrets.yaml`, plus `titan` from `secrets/titan.yaml`, four build-time literals
  (`k8s-node04`, `k8s-pi01/02/03`) and `llm01` on NetworkManager.
- B-03 cited `modules/home-manager/dev-tools.nix:146` for the `.29` default. That moved
  to `modules/home-manager/pi/default.nix` when #182 extracted the pi config — the
  review rotted in the four days between itself and this correction, which is the
  argument for re-deriving rather than archiving.

Four more of the review's fixes were applied with a change, because following them
literally would have introduced the very bug class they were reporting:

- **B-01 + B-02 together.** Making the IOT block `RFC1918` (B-02) puts `MESH_NET` and
  `GUEST_NET` inside it, so the separate block rules the review left in place become dead
  code behind it — the same shadowing B-01 was reporting. They were deleted, and the
  conditional Zigbee allow moved above the block.
- **B-11** asked for a `GUEST_NET` alias; added, plus alias creation as an explicit step,
  since a rule naming a missing alias matches nothing silently.
- **B-13** is not fixed — it is **converted into an explicit blocking decision (§8.2)**,
  because it is the operator's call, not a fact. It needs an answer before Phase 1a step 12.
- **B-16** was resolved by **deferral** ("not yet planned", mirroring §8.1) rather than by
  writing Phase 2 to plan standard. That is a judgement call and is reversible if the
  operator wants the phase written out.

All 78 majors remain unaddressed.

| file | what it is |
|---|---|
| `consolidated_review_report.md` | the one to read — **22 blockers, 78 majors**, deduplicated across the stages below |
| `critic_report.md` | stage 7: design, structural and style criticism |
| `implementation_readiness_report.md` | stage 9: could this be executed as written |
| `comprehension_report.md` | stage 6: independent paraphrase of the design, used to catch misreadings |
| `zoom_out_report.md` | skeptical-architect / minimalism pass over the whole file |
| `intermediate_zoom_out_report.md` | audits the fix set the other stages demand, and argues for deleting rather than repairing several sections |

## The blockers, in one line each

- **B-01** IOT rule 5 is shadowed by rule 2, and rule 5 contradicts success criterion 1
- **B-02** IOT rule 2 uses `LAN_NET`, so IoT reaches every private range Phase 2 and Phase 3 create
- **B-03** the Phase 3 blast-radius table is wrong against the repository in at least nine rows
- **B-04** the comin `iscsi` gate cannot see Longhorn; the VLAN 40 recommendation rests on a check that does not exist
- **B-05** etcd `2381/metrics` is not bound to `0.0.0.0`; the spec conflates it with the authenticated control-plane bind
- **B-06** §14 excludes a `titan` change that does not exist as a value, and contradicts the Phase 3 table
- **B-07** Phase 1b never moves the coordinator, and step 5 precedes the thing it depends on
- **B-08** Phase 1b step 1 asserts as settled the question Phase 0.3 exists to answer, and there is no branch if the answer is unfavourable
- **B-09** the Phase 0.4 socket-direction diagnostic is stated backwards
- **B-10** `<z2m port>` is never given a value, so rule 5 cannot be written
- **B-11** `GUEST_NET` is used in a firewall rule and never defined
- **B-12** Phase 0 produces eight facts and no artifact, format, or exit gate
- **B-13** the guest coverage regression is unhandled and the two possible resolutions contradict
- **B-14** "the old guest SSID" is never named and its existence is never established
- **B-15** interface creation is compressed into one line, the router address appears nowhere, and two mandatory screens are missing
- **B-16** Phase 2 is a paragraph sitting between two plans, and its ruleset is not a decision
- **B-17** Phase 3 never names the destination addressing, and VLAN 1 is "retired" while also being the break-glass path and the NAS destination
- **B-18** "each phase is independently valuable and independently reversible" is false for Phase 3
- **B-19** §10 pass conditions name no command, no observation point and no positive control
- **B-20** the scope line asserts two managed switches; four other places say that is unknown
- **B-21** three of four internal anchor links do not resolve
- **B-22** the spine paragraph's two assurances are falsified by rule 6

B-01 and B-02 are the ones with security weight: as written the IoT ruleset both fails to
enforce its own stated success criterion and lets IoT reach every private range the plan
later creates. B-04 and B-05 are the ones where the spec asserts something about this
repository that the repository does not do.

## Not included

`.review-raw/` (stage prompts, the workflow script, per-stage raw output) was left out —
it is regenerable tooling noise, not findings.

## What should happen to this directory

When the spec is revised, these should be deleted rather than kept in sync. Their value
expires the moment the findings land in the document.
