# Halogen-Flash (Qwen3.8-Flash-Next) on llm01 — Agent Benchmark Results (2026-09-14)

## Setup

| Item | Value |
|------|-------|
| Backend | `halogen-flash-server` (dedicated Strix Halo inference engine, **not** llama.cpp) |
| Image | `ghcr.io/peonist-ai/halogen-flash-server:0.6.3` |
| Model | `halogen-qwen3.8-flash-next` (served as `Qwen3.8-Flash-Next`) |
| API | OpenAI-compatible, `http://host.containers.internal:8731/v1` (uvicorn) |
| Hardware | AMD Strix Halo APU iGPU (126 GiB GTT, `amd_iommu=off`, `cwsr_enable=0`) |
| Quant / KV / ctx | **not exposed by the server** — halogen ships native weights, no GGUF preset knobs |
| Benchmark | `scripts/agent-benchmark.py` (post-2026-09-07 fixes, incl. `reasoning_content` counting) |

**Note on model knobs**: unlike the llama.cpp presets in `hosts/llm01/llm-models.nix`,
halogen exposes no `ctx-size`, `cache-type-k/v`, `cache-reuse`, or `ubatch-size`.
Those columns are `—` in the history table deliberately.

## Agent Benchmark — Prefix Cache HIT (5 rounds × 5 turns)

**File**: `2026-09-14-agent-benchmark-halogen-hit.json`

| Metric | p50 | mean | p95 |
|--------|-----|------|-----|
| TTFT (ms) | 1,855 | 1,760 | 1,972 |
| Total turn (ms) | 4,620 | 4,645 | 5,301 |
| Effective tps (TTFT-inclusive) | 25.5 | 26.6 | 39.3 |
| Token latency (ms) | 36.3 | — | 41.1 |

Context: mean 8,668 / max 10,752 tokens.

**Observed pattern**:
- Round 1 turn 1: cold prefill ~6.3 s (fresh ~6.6k ctx)
- Turns 2–5: TTFT ~1.8–2.0 s (prefix cache hit)
- Rounds 2–5 turn 1: **TTFT ~70 ms** — prefix cache retained across sessions

## Agent Benchmark — Cache MISS (3 rounds × 3 turns)

**File**: `2026-09-14-agent-benchmark-halogen-miss.json`

| Metric | p50 | mean | p95 |
|--------|-----|------|-----|
| TTFT (ms) | 7,320 | 7,205 | 8,074 |
| Total turn (ms) | 10,259 | 10,284 | 11,242 |
| Effective tps | 12.1 | 12.0 | 13.1 |
| Token latency (ms) | 36.3 | — | 40.9 |

Context: mean 7,647 / max 8,690 tokens.

TTFT scales with context: 6.6k→6.2 s, 7.6k→7.3 s, 8.7k→8.1 s ⇒ cold prefill
**~1,000–1,100 tok/s** (derived from client-side TTFT, not server timings).

## Hit vs Miss (same run family)

| Metric | Hit | Miss | Ratio |
|--------|-----|------|-------|
| TTFT p50 | 1,855 ms | 7,320 ms | **~3.9×** |
| Total p50 | 4,620 ms | 10,259 ms | **~2.2×** |
| Eff tps p50 | 25.5 | 12.1 | **~2.1×** |

## Comparison — fixed-script baselines only

⚠️ Rows from `2026-08-28*`/`08-29*`/`09-01*` in the history table are **not
comparable** (pre-fix hit mode re-prefilled most of the prompt). Compared here
are only runs made with the fixed `agent-benchmark.py`:

| Model | Backend | TTFT p50 hit | Eff tps p50 hit | TTFT p50 miss | ctx reached |
|-------|---------|--------------|-----------------|---------------|-------------|
| **Halogen-Flash** | halogen-flash-server | **1.86 s** | **25.5** | **7.3 s** | ~8.7k mean |
| Qwen3.8-27B MTP (09-09) | llama.cpp | 7.04 s | 4.18 | 45.2 s | ~8.5k mean |
| agent-instruct Qwen3.5-9B (09-07) | llama.cpp | 2.70 s | 19.2 | 28.4 s | ~18k mean |
| agent-fast Qwen3.5-4B (09-07) | llama.cpp | 1.92 s | 15.1 | 17.3 s | ~18k mean |
| agent Tiel MTP Q6_K_XL (09-07) | llama.cpp | 1.97 s | 2.8 | 24.0 s | ~18k mean |

Caveats: the 09-07 runs used 2×24 turns @60k target (mean ~18k ctx) vs my 5×5
@80k target (mean ~8.7k ctx) — hit-mode TTFT is context-dependent, so treat
cross-row hit comparisons as indicative. The **miss** comparison against
Qwen3.8-27B is near-context-matched (~7.5k both): halogen 7.3 s vs 45.2 s ≈
**6.2× faster cold prefill** on the same APU.

## Key Findings

1. **Halogen-Flash is the fastest agent path on this APU** among fixed-script
   measurements: best hit-TTFT (1.86 s) and by far the best effective tps
   (25.5), beating Qwen3.5-9B (19.2) and Qwen3.5-4B (15.1).

2. **Cold prefill ~1,000–1,100 tok/s** vs Qwen3.8-27B's ~166 tok/s at matched
   ~7.5k context — a ~6× prefill advantage on identical silicon.

3. **Prefix cache works and persists across sessions** (round-1 cold 6.3 s →
   round-2+ warm 70 ms), even though the server does not report `cache_n`.

4. **Decode is smooth**: token latency p50 36.3 ms / p95 41.1 ms — a tight
   distribution, unlike MTP-assisted llama.cpp models whose p95 tail spikes
   (Qwen3.8-27B p95 135.6 ms; Tiel p95 53.5 ms).

5. **Measurement caveat**: halogen streams thinking in `delta.reasoning_content`
   with an empty `content` field. Without the `reasoning_content` counting fix in
   `agent-benchmark.py`, every turn reports **0 output tokens** and tps is
   meaningless. That fix is included in this commit.

6. **Cache-table limitation**: `benchmark-agentic-cache.py` cannot populate the
   history file's Cache Benchmark table for halogen — it depends on llama.cpp
   `timings.prompt_ms` / `cache_n`, which halogen's `usage` block omits.

## Files

- `2026-09-14-agent-benchmark-halogen-hit.json`
- `2026-09-14-agent-benchmark-halogen-miss.json`
- `2026-09-14-halogen-cache-bench.json` (cache script — shows the missing-timings limitation)
- Updated: `2026-09-01-benchmark-history.md`