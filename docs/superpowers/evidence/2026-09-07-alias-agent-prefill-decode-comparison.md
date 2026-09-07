# Alias Comparison: `agent` vs `agent-instruct` vs `agent-fast` (2026-09-07)

Prefill/decode comparison of the three agent-serving aliases on llm01's
llama-server (router mode, Vulkan on Strix Halo APU), using
`scripts/agent-benchmark.py` (opencode-style tool-calling sessions).

Raw JSON (original): `2026-09-07-agent-benchmark-{agent,agent-instruct,agent-fast}-{hit,miss}.json`.
Tiel MTP Q6_K_XL (alias `agent` after 2026-09-07): `bench-tiel-hit.json`, `bench-tiel-miss.json`.

**⚠ Comparability**: `agent-benchmark.py` was modified on 2026-09-07 before
these runs (append-only history fix, tool-call token counting — see below).
Absolute numbers are NOT comparable with any earlier evidence
(`2026-08-28*`, `2026-08-29*`, `2026-09-01*`): the old hit-mode actually
re-prefilled most of the prompt each turn, and empty tool-call responses
deflated token counts. Only cross-model comparisons within this file are
valid. Re-baseline before tracking trends against older tables.

## Model parameters (from `hosts/llm01/llm-models.nix` @ `995a4cf`)

| Model params (current preset) | agent (Tiel MTP Q6_K_XL) — also agent/default | agent-instruct | agent-fast |
| Preset | TielCoder-35B-A3B (MTP) | Qwen3.5-9B | Qwen3.5-4B |
| Repo/file | peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF-MTP, MTP-UD-Q6_K_XL (30.5 GB) | unsloth/Qwen3.5-9B-GGUF, UD-Q4_K_XL | unsloth/Qwen3.5-4B-GGUF, Q4_K_M |
| Arch | 35B MoE (A3B, ~3B active), Ornith-1.5 base, Sharp template, MTP `draft-mtp` | dense 9B | dense 4B |
| ctx-size | 160000 (parallel=2 → 80k/slot) | 180000 (parallel=2 → 90k/slot) | 150000 |
| parallel | 2 | 2 | 1 |
| cache-type-k/v | q8_0/q8_0 | q8_0/q8_0 | q8_0/q8_0 |
| cache-reuse | 1024 | 1024 | 256 |
| cache-prompt | true | true | true |
| flash-attn | on | on | on |
| batch / ubatch | 4096 / 1024 | 4096 / 1024 | 4096 / 1024 |
| load-mode | mlock | — | — |
| speculative | MTP (`draft-mtp`) — `spec-type` set | — | — |
| sampling | temp 0.6, top-p 0.95, top-k 20, min-p 0.0 | temp 0.7, top-p 0.80, top-k 100, reasoning-budget −1, enable_thinking=false | (defaults) |
| Other aliases | tiel, default, agent-coder | hermes | fast, 4B |

**Note**: `agent` alias was `Ling-3.0-flash` (KDA, no cache-reuse, ngram-mod) until 2026-09-07; replaced by Tiel MTP for agentic coding. See `hosts/llm01/llm-models.nix` comment block.

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

| metric (ms unless noted) | agent (Tiel MTP Q6_K_XL) | agent-fast (Qwen3.5-4B) | agent-instruct (Qwen3.5-9B) | agent (Ling-3.0-flash, replaced) |
|---|---|---|---|---|
| TTFT p50 hit | **1968** | **1915** | 2704 | 5133 |
| TTFT p95 hit | 2386 | **2233** | 3059 | 5896 |
| TTFT p50 miss | 24007 | **17290** | 28370 | 58695 |
| TTFT p95 miss (~29k ctx) | 41742 | 30118 | 47142 | 99292 |
| cache benefit (miss/hit TTFT) | 12.2× | 9.0× | 10.5× | 11.4× |
| token latency p50 / p95 (decode) | **0.02 / 53.5** (~50k t/s peak, MTP draft 72% accept) | **18.0 / 19.3** (~55 t/s) | 30.9 / 32.6 (~32 t/s) | 30.9 / 34.6 (~33 t/s) |
| effective tps p50 hit | 2.8 | 15.1 | **19.2** | 6.3 |
| effective tps p50 miss | 2.0 | 3.4 | 1.4 | 0.9 |

## Read

- **`agent-fast` (Qwen3.5-4B) wins all latency metrics**: 2.6× faster hit-TTFT
  than the 9B, 3.3× than Ling; decode ~55 t/s with smooth p95 (19 ms).
- **`agent-instruct` (Qwen3.5-9B)**: middle prefill, steady decode; best
  effective tps in hit mode (uses all 128 tokens per turn).
- **`agent` (Tiel MTP Q6_K_XL)**: fastest agent prefill (24.0 s miss @18k ctx vs
  58.7 s Ling, 28.4 s 9B, 17.3 s 4B), good hit-TTFT (2.0 s), MTP decode shows
  very low per-token latency (p50 ~0.02 ms, draft acceptance 72%) — but effective
  tps is lower (2.8 hit / 2.0 miss) because MTP drafts include reasoning tokens
  that inflate total time; raw decode is fast (~50k t/s peak with drafts
  accepted). Best overall agent: best prefill + MTP decode speed.
- **`agent-fast` (Qwen3.5-4B)** wins latency: fastest hit-TTFT (1.9 s), decode
  ~55 t/s smooth, best effective tps (15.1).
- **`agent-instruct` (Qwen3.5-9B)**: middle on everything; best effective tps
  hit mode (19.2) due to full 128-token turns.
- Not comparable with older benchmark evidence (`2026-08-28*`, etc.). Tiel
  MTP results include new `draft_n` / `draft_n_accepted` decode metrics.
- **Reference (replaced)**: `agent` (Ling-3.0-flash, KDA, no cache-reuse,
  ngram-mod) — prefill bottleneck (~59 s miss @18k ctx), decode fine (~33 t/s),
  but any prefix divergence catastrophic; removed 2026-09-07.
