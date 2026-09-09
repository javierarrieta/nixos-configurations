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

## Diagnosis

1. **Rejected:** "MTP never fires / zero acceptance". Acceptance holds at
   53–74 % across every data window; ~2+ tokens out per verify step.
2. **Confirmed:** steady decode = the memory-bandwidth floor in *every* measured
   window (isolated smoke test, bench hit-mode at 7–10 k ctx, and the owner's
   live-session report of ~13 t/s all coincide). If MTP's ~2× tokens/step were
   converting to wall-clock time, decode would run near 25–30 t/s. It does not:
   on this Vulkan iGPU, a verification pass carrying the extra draft positions
   costs roughly as much as the tokens it buys back ⇒ **MTP net gain ≈ 0** for
   a dense 27B model at this context range. The bottleneck is weight-read
   bandwidth (Q6_K 27B), and MTP's compute-side verify overhead cancels its
   token-side win.
3. **Unverified by clean run:** high-context KV/GTT collapse. `n_tokens_max`
   reached **51,043** today on an external session while decode stayed at the
   same floor (~13 t/s per owner report) — weak evidence *against* a sub-~60 k
   context-collapse regime, but a controlled high-ctx probe is blocked because
   llm01 was under active concurrent load (firing one would both contaminate
   numbers and starve the live user of a slot for ~5 min).

## Data-quality notes

- `/metrics` counters are lifetime-cumulative and shared with other users'
  traffic on Qwen3.8-27B; per-window deltas are approximate. Bench runs are
  isolated in their own JSONs.
- One client-side-killed probe (abandoned at 30 s) left a partial server-side
  request; excluded from analysis, but visible as the `n_tokens_max` jump to
   ~51 k is partially attributable to it plus real external traffic.
- Bench JSONs contain summary percentiles only (no per-turn rows).

## Open items / levers (owner decisions)

1. [ ] Clean high-context probe (~50 k): snapshot spec counters before/after,
       measure TTFT + steady decode at long ctx on a quiet box — closes the GTT
       question definitively. ~5 min of GPU time.
2. [IN PROGRESS] MTP A/B: `spec-type`/`spec-draft-n-max` removed from the
   Qwen3.8-27B preset in `hosts/llm01/llm-models.nix` (staged locally as an
   uncommitted diff, `nix eval` of llm01 toplevel passes). After owner pushes to
   `main` and llm01 converges: re-run smoke + both bench modes, compare vs the
   JSONs above, then restore MTP and push again. (Owner decision to hold the
   line past that point goes here.)
3. Bigger levers if more t/s is wanted on this hardware, in rough order of impact:
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
