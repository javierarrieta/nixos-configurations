# Low-Latency Local Model Serving for Agent Workflows — Design

**Date:** 2026-08-28
**Host:** llm01 (AMD gfx1151 "Strix Halo", Vulkan backend)
**Status:** Approved (design discussed in session; corrections from owner incorporated)

## Problem

Local models (Ling-3.0-flash 127B, Ornith-1.5-35B) have faster input-context
processing and faster output-token generation than cloud models used via
opencode/hermes, yet the *end-to-end* agent latency is worse: a 20–30 tps cloud
model feels faster than a 50–60 tps local model.

### Root cause

Per-request serving overhead dominates over raw throughput. Cloud APIs run
purpose-built serving stacks (pre-allocated KV cache, continuous batching,
persistent connections, optimized prompt pipelines). llama.cpp's built-in
server, as currently configured, pays a higher fixed cost per request: prompt
build/tokenize, cache state management, and (historically) cold context
allocation. Agent workflows amplify this because they are many small turns
with growing context, not one long generation — the fixed per-turn cost is
paid dozens of times per task.

Three levers, in order of measurable impact on TTFT and per-turn time:

1. **Serving-stack tuning** — reduce the fixed per-request cost (Layer 1).
2. **Context management** — reduce the variable cost by sending less prompt
   per turn (Layer 2).
3. **Model routing** — stop paying 35B/127B prices for turns that don't need
   them (Layer 3).

## Goals

- Lower p50/p95 TTFT and per-turn total time for agent workloads on
  Ling-3.0-flash and Ornith-1.5-35B (measured with
  `scripts/agent-benchmark.py`).
- Instrument llama.cpp cache behavior so cache-reuse effectiveness is
  observable (Prometheus metrics).
- Encode the pattern as a **reusable NixOS module** so any host can adopt it.

## Non-Goals

- No separate proxy service (FastAPI/llama-cpp-python router) — deferred to a
  future iteration.
- No vLLM/TGI — CUDA-only, incompatible with the AMD/Vulkan backend.
- No speculative decoding for Ornith-1.5 (owner-observed regression; stays
  disabled). Ling-3.0-flash keeps `draft-mtp` (`spec-draft-n-max 2`, the only
  depth that won on b10649).
- No automatic (server-side) prompt-complexity routing — the client selects
  the model via the `model` parameter; llama.cpp multi-model + aliases is the
  routing mechanism.

## Architecture

Single endpoint, llama.cpp `--models-preset` multi-model serving (already in
place on llm01), wrapped in a reusable module that also emits an agent-side
context policy.

### Layer 1 — Serving Stack Tuning (llama.cpp flags)

Keep (already proven on this host):

- `--load-mode mlock` (owner: already in use — do **not** add `--no-mmap`)
- `--cache-reuse 256` at server level (owner: plenty of VRAM, keep it)
- `--cont-batching`, `--flash-attn on`, `--fit on`, `-ngl 99`
  (`--threads 8` is replaced by `--threads 1` / `--threads-batch 1` — see
  "Add" below)
- `GGML_VK_DISABLE_COOPMAT=1` (gfx1151 coopmat FA path is buggy/slow)
- Per-model `batch-size 4096` / `ubatch-size 1024` on the large models

Add:

- `--ctx-cache-retention` — retain per-slot context caches across requests so
  an agent session's prompt cache survives between turns, cutting TTFT on
  every turn after the first. **Verify the flag exists on the pinned llama.cpp
  (b10649) before enabling** (`llama-server --help`); if absent, skip and
  record that in the plan evidence.
- **Context size 102400 (100k) for the large models** (Ornith-1.5-35B,
  Ling-3.0-flash; 131072 today). 100k still covers agent sessions
  comfortably; smaller KV cache = faster allocation + faster prompt scans.
  With `parallel = 2` each slot gets ~50k — ample for agent turns.
- `parallel = 2` on the large models — two continuous-batching slots so a
  second request never queues behind a long generation.
- Per-model `cont-batching = true` and `ctx-shift = true` on the large
  models — continuous execution scheduling plus smart context shifting that
  evicts oldest tokens without destroying the session history the prompt
  cache relies on.
- Server-side `--threads 1` / `--threads-batch 1` — Vulkan does the math on
  the APU; extra CPU threads only add sync stalls.
- Environment: `GGML_VK_VISIBLE_DEVICES=0` (binds to the 8060S APU
  explicitly) and `RADV_PERFTEST=nogttspill` (keeps KV cache inside the GTT
  partition instead of spilling). Keep `GGML_VK_DISABLE_COOPMAT=1`.

Instrument:

- llama-server `--metrics` (already enabled) is scraped every 60s into the
  node_exporter textfile collector dir (`/var/lib/node-exporter/textfiles/`)
  so cluster Prometheus picks it up like the existing `comin.prom` metric.
  Cache-related series (prompt-cache hits/reuse) become visible in Grafana;
  exact series names are discovered from `curl localhost:8001/metrics` and
  recorded in evidence.

### Layer 2 — Agent-Aware Context Policy (Option C: one module ties both sides)

`modules/nixos/llama-cpp-agent.nix` exposes a `contextPolicy` option and
writes `/etc/llm-agent/context-policy.json`. The policy is the contract
between the serving layer and any agent frontend (opencode, hermes):

```json
{
  "maxHistoryTurns": 20,
  "summarizeAfterTurns": 10,
  "systemPromptCache": true,
  "batchToolCalls": true
}
```

- **Sliding window** — never re-inject more than `maxHistoryTurns` of raw
  history; older turns are summarized to a single block.
- **Summarization threshold** — after `summarizeAfterTurns` raw turns, the
  client compacts them.
- **System prompt cache** — the agent role definition is sent identically
  every turn (byte-for-byte) so llama.cpp's prompt cache can reuse it.
- **Batch tool calls** — when a model emits multiple independent tool calls,
  the client executes and returns them in one round-trip.

v1 scope: the module generates and publishes the policy file plus a
`llm-agent-policy` helper binary that prints it. Wiring opencode/hermes to
*consume* the policy is a follow-up (the JSON contract is stable now so
consumers can be built against it).

### Layer 3 — Model Routing (built-in multi-model + aliases)

Routing decision is made **client-side** by picking the `model` value;
llama.cpp routes via per-model `alias` properties (already supported by the
INI preset). Tier taxonomy and aliases:

| Tier | Alias | Models | Use case |
|------|-------|--------|----------|
| Fast/Small | `agent-fast` | Qwen3.5-4B | tool calls, file reads, quick commands, short prompts |

**Constraint:** llama.cpp requires alias values to be unique across all
presets — one alias maps to exactly one model. Each small model keeps its own
name alias (`Qwen-3.5-2B`, `Qwen-3.5-4B`, `mellum`); the tier alias
`agent-fast` points at Qwen3.5-4B (strongest of the three, 140k ctx).
| Fast/Large | `agent` | Ling-3.0-flash (127B, IQ4_XS, draft-mtp) | default agent brain — complex reasoning at speed |
| Accurate/Large | `agent-quality` | Ornith-1.5-35B (Q5_K_M), candidate: Qwen3.8-27B | quality-critical: architecture, deep debugging |

Aliases are additive: existing aliases (`default`, `opencode`, `hermes`,
`multimodal`, …) stay untouched so nothing currently pointed at a model name
breaks.

**Qwen3.8-27B decision gate:** the commented-out Qwen3.8-27B entry may replace
Ornith-1.5-35B in the `agent-quality` tier *if* it reaches acceptable speed.
Decision procedure: enable it, benchmark, compare p50 TTFT / effective tps
against Ornith from the same baseline run; owner makes the final call.

### Reusable module

`modules/nixos/llama-cpp-agent.nix`
exposes:

- `services.llamaCppAgent.enable`
- `services.llamaCppAgent.package` (default: the flake's `llamaPkgs.vulkan`)
- `services.llamaCppAgent.listen` (`{ host, port }`)
- `services.llamaCppAgent.serverArgs` (typed list; Layer-1 defaults provided,
  host can append/override)
- `services.llamaCppAgent.models` (attrset, same schema as
  `hosts/llm01/llm-models.nix`: `modelId`, `filename`, `mmproj`,
  `modelDraft`, `modelDraftModelId`, `extraProperties`)
- `services.llamaCppAgent.metrics.enable` + textfile directory
- `services.llamaCppAgent.contextPolicy` (Layer-2 JSON fields)

The module owns the four systemd units currently inlined in
`hosts/llm01/configuration.nix` (`llama-cpp-server`,
`llama-cpp-config`, `llama-cpp-download-models`, `llama-cpp-config-watch`)
and the `/opt/llm` tmpfiles rules. The host config becomes imports + option
assignments only. Port stays 8001 so the comin health gate and Traefik/firewall
rules are untouched.

## Testing & Verification

- Every module change must keep `nix eval
  .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace`
  green and `nixfmt` clean.
- Behavior measured with `scripts/agent-benchmark.py` against
  `http://localhost:8001` (`--model-name "Ling-3.0-flash"`,
  `--model-name "Ornith-1.5-35B"`), before and after. Baseline and post-change
  JSON go to `docs/superpowers/evidence/`.
- Live-host verification (metric series names, `--ctx-cache-retention`
  support) is a **user action**: no SSH access from the repo environment;
  user runs commands on llm01 and pastes output.
- llm01 is a canary host (auto-deploys on push to main); the comin health gate
  checks the llama-cpp service with a 50-minute warmup — if the new flags
  break startup, the gate rolls back automatically.

## Risks

- `--ctx-cache-retention` may not exist on b10649 → verified before use;
  absence is not fatal (Layer 2/3 still land).
- Large models use `cache-prompt = false` ("prevents cache fragmentation
  locks") — this *coexists* with server-level `--cache-prompt`; do not change
  per-model values as part of this work; revisit only with benchmark evidence.
- `parallel = 2` splits the per-model context across slots (100k/2 = ~50k per
  slot). The llm-models comments warn about aggressive `parallel` values
  shrinking slots below tool limits — 50k is safe, but if a tool rejects the
  context, revert `parallel` to `1` and re-benchmark.
- Enabling retention/alias changes restarts llama-server; on llm01 that is a
  canary deploy — schedule during a low-activity window.
