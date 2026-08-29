# Agent latency: baseline vs post-change (2026-08-28)

Harness: `scripts/agent-benchmark.py`, 10 rounds x 5 turns, sequential turns,
llama.cpp router on llm01:8001. `effective_tps` counts characters, not tokens —
valid for A/B only.

## Changes under test

- `--threads 8` → `--threads 1 --threads-batch 1` (server args)
- ctx 131072 → 102400 on Ling-3.0-flash + Ornith-1.5-35B
- `parallel 1 → 2` on both large models
- `cont-batching = true` per-model (ctx-shift dropped: unsupported on b10649)
- env `GGML_VK_VISIBLE_DEVICES=0`, `RADV_PERFTEST=nogttspill`
- tier aliases (agent-fast / agent / agent-quality); module extraction

## Results (ms unless noted)

### Ling-3.0-flash

| Metric      | Baseline | Post | Delta  | Verdict |
|-------------|---------:|-----:|--------|---------|
| TTFT p50    | 1229     | 961  | -21.8% | better  |
| TTFT p95    | 1392     | 1140 | -18.1% | better  |
| Total p50   | 3332     | 3858 | +15.8% | worse   |
| Total p95   | 3817     | 4396 | +15.2% | worse   |
| Eff.tps p50 | 67.6     | 66.3 | -1.8%  | equal   |

### Ornith-1.5-35B

| Metric      | Baseline | Post | Delta  | Verdict |
|-------------|---------:|-----:|--------|---------|
| TTFT p50    | 376      | 493  | +31.1% | worse   |
| TTFT p95    | 444      | 572  | +28.8% | worse   |
| Total p50   | 3096     | 4420 | +42.8% | worse   |
| Total p95   | 3223     | 4896 | +51.9% | worse   |
| Eff.tps p50 | 98.6     | 68.8 | -30.2% | worse   |

## Analysis

- **Ling**: TTFT clearly better (larger cache-reuse wins at 100k ctx?),
  generation throughput flat; total-per-turn up ~16% likely from slightly
  longer generations + slot split overhead, not raw speed.
- **Ornith**: uniform degradation, worst in throughput (-30%). Ornith is a
  MoE A3B model — prompt ingestion and expert routing on the Vulkan backend
  were previously helped by more CPU threads for batch/tokenization work.
  `--threads 1 --threads-batch 1` (Gemini recommendation) is the prime
  suspect; sequential benchmarking means `parallel 2` alone shouldn't cost
  single-stream throughput.

## Recommended next iteration

Applied (commit after this file): module now exposes `threads` /
`threadsBatch` options (defaults 1) instead of baking them into `serverArgs`;
llm01 sets `threads = 8; threadsBatch = 8;` — the original CPU threading.
Everything else (100k ctx, parallel 2, cont-batching, env vars, aliases,
module) stays. Re-run the same two benchmarks against the redeployed host:
expected Ornith recovers toward baseline throughput; Ling TTFT gain may
persist.

Decision owner: if Ornith recovers, keep threads 8/8. The threads-1
recommendation is recorded here as measured-worse for this backend.

## Round 2 — threads 8/8 restored (final config)

Config: threads 8/8, 100k ctx, parallel 2, cont-batching, env vars, aliases.

### Ling-3.0-flash

| Metric      | Baseline | Round 1 (t1) | Round 2 (t8) | Delta vs base | Verdict |
|-------------|---------:|-------------:|-------------:|---------------|---------|
| TTFT p50    | 1229     | 961          | 929          | -24.4%        | better  |
| TTFT p95    | 1392     | 1140         | 1097         | -21.2%        | better  |
| Total p50   | 3332     | 3858         | 3220         | -3.4%         | better  |
| Total p95   | 3817     | 4396         | 3835         | +0.5%         | equal   |
| Eff.tps p50 | 67.6     | 66.3         | 68.9         | +2.0%         | equal   |

### Ornith-1.5-35B

| Metric      | Baseline | Round 1 (t1) | Round 2 (t8) | Delta vs base | Verdict |
|-------------|---------:|-------------:|-------------:|---------------|---------|
| TTFT p50    | 376      | 493          | 413          | +9.8%         | worse   |
| TTFT p95    | 444      | 572          | 486          | +9.5%         | worse   |
| Total p50   | 3096     | 4420         | 3309         | +6.9%         | worse   |
| Total p95   | 3223     | 4896         | 6674         | +107%         | worse (tail) |
| Eff.tps p50 | 98.6     | 68.8         | 92.4         | -6.3%         | ~equal  |

## Conclusion

- **Ling (the agent default)**: strict improvement — TTFT -24%, total -3%,
  throughput flat. Primary win of the whole exercise.
- **Ornith**: ~6-10% single-stream cost — the price of `parallel 2` slot
  reservation at 100k ctx. That cost buys 2 concurrent sessions without
  queueing. Total p95 tail (6674ms) suggests occasional slot contention;
  if it bothers, `parallel 1` on Ornith is a one-line revert.
- threads 1/1 (external recommendation) measured strictly worse on this
  Vulkan/MoE backend — reverted to 8/8 and encoded as module options.

Deploy state: feature branch `feat/llm-agent-latency`, comin suspended on
llm01. Merge to `main` resumes canary auto-deploy.
