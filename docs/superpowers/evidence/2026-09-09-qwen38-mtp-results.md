# Qwen3.8-27B + MTP on llm01 — performance results (2026-09-09)

## Question

Qwen3.8-27B decodes at only ~13 tok/s in live agent sessions despite MTP
speculative decoding being enabled. Is the loss "MTP broken / zero acceptance",
"verify overhead eats the gain on this iGPU", or GTT/KV-cache pressure?

## Setup under test

| item | value |
|---|---|
| backend | Vulkan, AMD Strix Halo APU iGPU (threads=8, `GGML_VK_DISABLE_COOPMAT=1`, `RADV_PERFTEST=nogttspill`) |
| model | Qwen3.8-27B-MTP GGUF **Q6_K** (~19 GB weights), source `Jackrong/Qwen3.8-27B-MTP-GGUF` |
| KV cache | f16, ctx 160k × parallel 2 (≈ ~80 GB at full occupancy) |
| speculation | `--spec-type draft-mtp max 2` |
| sampling/reasoning | repeat-penalty 1.1, reasoning-budget -1, effort medium |
| llama.cpp | b10649, rev `2bb9bddafad44ecbb50889644ca47537ec11841b` (pinned in flake.lock) |
| preset location | `hosts/llm01/llm-models.nix`, re-enabled by commits `de4d630` + `42cf2a2` |

## Evidence

### 1. Smoke test (isolated, clean)

64 generated tokens in **4.69 s wall** ≈ **~13–14 t/s**, right at the pure
weight-streaming bandwidth floor: ~19 GB of Q6_K weights per token pass against
the APU's ~250+ GB/s memory bandwidth ⇒ ceiling ≈ 13 t/s. MTP on, small context.

### 2. Agent benchmark — prefix-cache HIT (5 rounds × 5 turns)

`docs/superpowers/evidence/2026-09-09-agent-benchmark-qwen3.8-27b-mtp-hit.json`

| metric | p50 | mean | p95 |
|---|---|---|---|
| TTFT (ms) | 7,039 | 13,255 | 38,777 |
| total turn (ms) | 13,689 | 18,699 | 42,273 |
| effective tps (TTFT-inclusive, per turn) | 4.18 | 3.80 | 5.94 |
| token latency (ms) | ~0 (streaming batch artifact) | — | 135.6 |

Context: mean 8,500 / max 10,464 tokens per session. Observed pattern from the
run itself: round-1 turn TTFT ≈ 39–42 s (full prefill of a fresh ~7–10 k ctx),
turns 2–5 TTFT ≈ 6.5–7 s (prefix cache hit). Steady decode at 7–10 k ctx sits on
the same bandwidth floor as the smoke test — no uplift from MTP visible.

### 3. Agent benchmark — cache MISS (3 rounds × 3 turns)

`docs/superpowers/evidence/2026-09-09-agent-benchmark-qwen3.8-27b-mtp-miss.json`

| metric | p50 | mean | p95 |
|---|---|---|---|
| TTFT (ms) | 45,248 | 45,177 | 51,614 |
| total turn (ms) | 51,857 | 51,112 | 58,149 |
| effective tps | 0.98 | 0.98 | 1.19 |

Context: mean 7,543 / max 8,522 tokens. TTFT scales linearly with context at a
prefill rate of **~166 t/s**; effective throughput collapses to ~1 tps because
every turn pays full re-prefill. (This is the "agent restarts loop / no cache"
mode — expensive by design, not an MTP issue.)

### 4. Spec-decode acceptance via `/metrics?model=Qwen3.8-27B`

| window | verify steps | draft tokens | accepted | accept rate | output tok/step (incl. bonus) |
|---|---|---|---|---|---|
| initial scrape (my bench runs + earlier traffic) | 3,042 | 6,077 | 4,487 | **73.8 %** | ~2.5 |
| later lifetime totals (mixed external load) | 12,015 | 24,023 | 13,951 | 58.1 % | — |
| delta window between scrapes | +8,973 | +17,946 | +9,464 | **52.7 %** | ~2.1 |

MTP is unambiguously firing and the draft head accepts well (~2.0–2.5 output
tokens per verification step depending on window/workload).

## Diagnosis (corrected by A/B control — see §5)

1. **Rejected:** "MTP never fires / zero acceptance". Acceptance holds at
   53–74 % across every data window; ~2+ tokens out per verify step.
2. **Rejected (was the working theory, falsified by control):** "verify
   overhead cancels the gain, net ≈ 0". The spec-off A/B shows MTP ON winning
   ~1.5× wall-clock at agent context sizes. Per-forward fixed costs dominate on
   the iGPU; draft positions ride nearly free inside a bandwidth-bound pass, so
   ~2–2.5 tok/step converts to real throughput.
3. **Confirmed:** without speculation the true floor is ~9 t/s (uniform ~110 ms
   per token), not the 13 t/s seen with MTP on. 13–14 t/s ≈ MTP-assisted rate
   approaching the pure weight-streaming ceiling.
4. **Unverified by clean run:** high-context KV/GTT collapse. `n_tokens_max`
   reached **51,043** today on an external session while decode stayed at the
   MTP-assisted floor — weak evidence *against* a sub-~60 k collapse regime,
   but a controlled high-ctx probe is still open (box was busy; now free but
   the A/B windows took priority).

## Data-quality notes

- `/metrics` counters are lifetime-cumulative and shared with other users'
  traffic on Qwen3.8-27B; per-window deltas are approximate. Bench runs are
  isolated in their own JSONs.
- One client-side-killed probe (abandoned at 30 s) left a partial server-side
  request; excluded from analysis, but visible as the `n_tokens_max` jump to
   ~51 k is partially attributable to it plus real external traffic.
- Bench JSONs contain summary percentiles only (no per-turn rows).

## 5. A/B control: MTP off (same day, same box)

Deployed `b1061d5` (spec lines removed from preset), verified live `/models`
args contained no `--spec-*`, re-ran smoke + hit 5×5 + miss 3×3 with identical
flags. Contexts matched almost exactly (hit 8512/10536 vs 8500/10464; miss
7575/8595 vs 7543/8522), so the comparison is clean.

| metric | MTP on | MTP off | read |
|---|---|---|---|
| smoke effective t/s | ~13.6 (64 tok / 4.7 s) | ~7.4 wall / ~8.9 decode-only (49 tok / 6.6 s, TTFT 1.2 s) | **~1.5×** |
| hit total/turn p50 | 13.7 s | 20.8 s | **~1.5×** |
| hit effective tps p50 / mean | 4.18 / 3.80 | 2.56 / 2.24 | **~1.6×** |
| hit token latency | p50 ~0 ms (draft bursts), p95 135.6 ms | p50/p95 ~110 ms flat | bursty vs uniform |
| miss total/turn p50 | 51.9 s | 61.9 s | decode portion ~2× (output lengths differ — temp 1.0 sampling noise) |
| miss TTFT p50 | 45.2 s | 47.9 s | prefill unaffected ✓ (as expected) |

Latency profile note: MTP-on delivery is bursty (accepted drafts arrive
together, then verify gaps — worse p95 tail, 136 vs 111 ms), but bulk
throughput wins ~1.5×. Turn-level agent latency is dominated by bulk decode,
so MTP on is the right call.

**Verdict: keep MTP on.** Restored via `ba60d7a` (config byte-identical to
pre-A/B state). ⚠️ Restore deploy had NOT landed 20 min after push at time of
writing — comin on llm01 appears stalled (see open item 3).

## 6. High-context probe (~41 k tokens, MTP on)

Single prompt of 201,000 chars (≈41.4 k tokens; `n_tokens_max` 41587),
`max_tokens` 256, idle box, spec counters snapshotted before/after.

| metric | value |
|---|---|
| TTFT (full 41 k prefill) | 472.7 s ⇒ prefill ≈ **88 t/s** (vs ~166 t/s at 8 k ctx — ~2× slower, attention cost showing, still linear-ish) |
| decode window | 173 predicted tokens in 9.6 s ⇒ **~18 t/s** (short window; consistent with the 13–14 range — **no collapse**) |
| spec acceptance in-run | 69 verify steps, 137 draft tok, 102 accepted ⇒ **74.5 %**, ~2.5 tok/step (same as low-ctx windows) |
| server health | clean completion, `requests_processing` 0 after |

**No KV/GTT collapse at 41 k.** MTP acceptance and decode rate hold at long
context; only prefill slows (expected, attention-bound).

Caveat: an earlier oversized attempt (368 k chars ≈ 92 k tokens) failed before
emitting any token and the server restarted afterwards (counters zeroed) —
cause undiagnosed from here (llm01 journal needed). A single-prompt ceiling
exists somewhere between ~41 k and ~92 k on current settings. Agent sessions
(prefix-cached, rarely single-prefilling anywhere near that) are unaffected,
but do not fire >~50 k single prompts at this preset without watching the box.

## Open items / levers (owner decisions)

1. [x] High-context probe — done (§6). Residual: single-prompt ceiling between
       ~41 k and ~92 k unexplained; bisect only with owner consent (a repeat
       may crash the server again) + llm01 journal from the failed attempt.
2. [x] MTP A/B — done, ~1.5× win for MTP on. No further action except confirming
       the restore deploy (item 3).
3. [x] **Restore deploy skip — root-caused and resolved.** `ba60d7a` restored
       `llm-models.nix` byte-identical to pre-A/B, so the toplevel evaluated to
       the same out path comin had deployed before the experiment → comin
       logged `skipping deployment ... has already been deployed` and never
       re-ran activation (comin dedups on seen-before out paths, not on
       current-system state). Fix: manual `nixos-rebuild switch --flake
       /var/lib/comin/repository#llm01` on llm01, which switches away from the
       spec-off generation and re-runs activation. Verified live: `--spec-type
       draft-mtp` back in `/models` args, spec counters incrementing (18
       verify steps, 28/36 accepted on first smoke). Lesson: byte-identical
       reverts never deploy via comin — touch the config (even a comment) if a
       revert must go through the GitOps path.
4. Bigger levers if more t/s is wanted on this hardware, in rough order of impact:
       - **Q4_K instead of Q6_K** → ~2× decode (bandwidth halved) at a quality cost;
         MTP-quantized GGUFs may not exist for Qwen3.8 — check source repo first.
       - **KV q8_0 instead of f16** → long-context GTT pressure drops (~80 GB → ~53
         GB); no effect on short-ctx decode speed, but buys headroom vs the 118 GB
         GTT budget (same class of thrash documented for llm01 in AGENTS.md).
       - Smaller ctx/parallel if combined occupancy must stay resident.

## Files

- `docs/superpowers/evidence/2026-09-09-agent-benchmark-qwen3.8-27b-mtp-hit.json`
- `docs/superpowers/evidence/2026-09-09-agent-benchmark-qwen3.8-27b-mtp-miss.json`
- `docs/superpowers/evidence/2026-09-01-benchmark-history.md` (prior baselines)
