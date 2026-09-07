# Alias Comparison: `agent` vs `agent-instruct` vs `agent-fast` (2026-09-07)

Prefill/decode comparison of the three agent-serving aliases on llm01's
llama-server (router mode, Vulkan on Strix Halo APU), using
`scripts/agent-benchmark.py` (opencode-style tool-calling sessions).

Raw JSON: `2026-09-07-agent-benchmark-{agent,agent-instruct,agent-fast}-{hit,miss}.json`.

**⚠ Comparability**: `agent-benchmark.py` was modified on 2026-09-07 before
these runs (append-only history fix, tool-call token counting — see below).
Absolute numbers are NOT comparable with any earlier evidence
(`2026-08-28*`, `2026-08-29*`, `2026-09-01*`): the old hit-mode actually
re-prefilled most of the prompt each turn, and empty tool-call responses
deflated token counts. Only cross-model comparisons within this file are
valid. Re-baseline before tracking trends against older tables.

## Model parameters (from `hosts/llm01/llm-models.nix` @ `995a4cf`)

| | agent | agent-instruct | agent-fast |
|---|---|---|---|
| Preset | Ling-3.0-flash | Qwen3.5-9B | Qwen3.5-4B |
| Repo/file | bartowski/Ling-3.0-flash-GGUF, IQ4_XS, 2 shards | unsloth/Qwen3.5-9B-GGUF, UD-Q4_K_XL | unsloth/Qwen3.5-4B-GGUF, Q4_K_M |
| Arch | 124B MoE (5.1B active), KDA recurrent, bailingmoe3/KDA | dense 9B | dense 4B |
| ctx-size | 140000 | 180000 (parallel=2 → 90k/slot) | 150000 |
| parallel | 1 | 2 | 1 |
| cache-type-k/v | f16/f16 | q8_0/q8_0 | q8_0/q8_0 |
| cache-reuse | — (incompatible with KDA) | 1024 | 256 |
| cache-prompt | — | true | true |
| flash-attn | on | on | on |
| batch / ubatch | 4096 / 1024 | 4096 / 1024 | 4096 / 1024 |
| load-mode | mlock | — | — |
| speculative | ngram-mod (n-match 24, draft-n-max 4) | — | — |
| sampling | temp 0.6, top-p 0.95, top-k 20, min-p 0.05 | temp 0.7, top-p 0.80, top-k 100, reasoning-budget −1, enable_thinking=false | (defaults) |
| Other aliases | default, long-horizon | hermes | fast, 4B |

Server: `llama-server --models-preset` (router mode), port 8001, `-ngl 99`,
`--mlock --ctx-checkpoints 1 --fit on --cont-batching --metrics` (see
`modules/nixos/llama-cpp/agent.nix`).

## Methodology

`scripts/agent-benchmark.py` @ `995a4cf` + two fixes made same day (below).
- Base URL `http://host.containers.internal:8001`, aliases as model names
  (router mode; all three targets resident — no eviction observed).
- Params: hit = rounds 2 × turns 24; miss = rounds 1 × turns 24;
  `--context-size 60000` (growth-limited: reached mean ~18k, max ~29k ctx);
  max_tokens 128, streaming, temp 0.1.
- hit = append-only history (prefix cache reuse, like real opencode turn N);
  miss = unique nonce in system prompt each turn (full re-prefill floor).

### Script fixes (uncommitted, required for valid results)

1. `history.append` now re-adds the user task (agent-benchmark.py:~1228).
   Previously the task was only in the request, not history → every new prompt
   diverged from the cached prefix right after the system prompt → full
   re-prefill every turn, silently invalidating `--cache-mode hit`.
2. Tool-call deltas (`delta.tool_calls`) counted as tokens (agent-benchmark.py:~1074).
   Agent presets stream tool calls with empty content → Out tok 0, meaningless tps.

## Results

| metric (ms unless noted) | agent-fast (Qwen3.5-4B) | agent-instruct (Qwen3.5-9B) | agent (Ling-3.0-flash) |
|---|---|---|---|
| TTFT p50 hit | **1915** | 2704 | 5133 |
| TTFT p95 hit | **2233** | 3059 | 5896 |
| TTFT p50 miss | **17290** | 28370 | 58695 |
| TTFT p95 miss (~29k ctx) | 30118 | 47142 | 99292 |
| cache benefit (miss/hit TTFT) | 9.0× | 10.5× | 11.4× |
| token latency p50 / p95 (decode) | **18.0 / 19.3** (~55 t/s) | 30.9 / 32.6 (~32 t/s) | 30.9 / 34.6 (~33 t/s) |
| effective tps p50 hit | 15.1 | **19.2** | 6.3 |
| effective tps p50 miss | 3.4 | 1.4 | 0.9 |

## Read

- **`agent-fast` (Qwen3.5-4B) wins all latency metrics**: 2.6× faster hit-TTFT
  than the 9B, 3.3× than Ling; decode ~55 t/s with smooth p95 (19 ms).
- **`agent-instruct` (Qwen3.5-9B)**: middle prefill, steady decode; best
  effective tps in hit mode (uses all 128 tokens per turn).
- **`agent` (Ling-3.0-flash)**: decode fine (33 t/s, ngram-mod spec decode) but
  prefill is the bottleneck — 59 s full re-prefill at ~18k ctx, and even ~1k
  incremental tokens cost ~5 s (~190 t/s incremental, worst of the three).
  Any prefix divergence (tool result differing from the simulated one) is
  catastrophic in real sessions. Consistent with the KDA findings in
  `2026-09-01-benchmark-history.md` (cache_reuse/ctx-checkpoints don't help).
- Note vs 2026-09-01 history: Ling now runs f16 KV @140k ctx (was q8_0 @80k)
  plus ngram-mod speculative decoding.
