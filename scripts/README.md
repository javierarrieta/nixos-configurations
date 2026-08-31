# Agent Benchmark

Script: `agent-benchmark.py`

Simulates opencode-style agent sessions: multi-message conversations (system +
user/assistant/tool-result history) whose context grows monotonically to a
target size (default 80k tokens), then measures TTFT, per-turn latency,
effective tps, and per-token latency consistency.

## Arguments

- `--model` (required): Model identifier (`llama.cpp`, `ollama://name`, `openai://name`)
- `--base-url`: API base URL (e.g. `http://llm01:8080` for llama.cpp, `http://localhost:11434` for Ollama)
- `--model-name`: Override model name sent to API
- `--rounds`: Number of agent sessions (default 5). Each session resets context.
- `--turns-per-round`: Turns per session (default 8). Context grows each turn.
- `--provider`: Provider selection (`auto`, `ollama`, `llamacpp`, `openai`)
- `--api-key`: API key for cloud providers
- `--context-size`: Target context tokens the session grows to (default 80000)
- `--cache-mode`: `hit` (append-only prefix — KV cache reuse, like real opencode) or `miss` (unique prefix per turn — full re-prefill floor)
- `--json`: Output results as JSON

## How context growth works

Per session:

1. System prompt (~313 tok, opencode-like: role, tools, workspace)
2. Each turn appends: user task + assistant reply + fake tool result
3. Tool-result budget per turn = `(context-size - system - tasks) / turns-per-round` (~10.2k/turn at defaults)
4. Final turn's request is ~72k tok; final accumulated context ~82k ≈ target

## Cache modes

- `hit`: identical system + append-only history → exercises the server's KV/prefix
  cache. TTFT after turn 1 should drop sharply on llama.cpp. This is what real
  opencode sessions experience.
- `miss`: injects a per-turn nonce into the system prompt → every request is a
  full re-prefill. Run both modes: the TTFT gap between them IS the prefix-cache
  benefit at that context size.

Example:

```bash
python3 scripts/agent-benchmark.py --model llama.cpp --base-url http://llm01:8080 --cache-mode hit --json
python3 scripts/agent-benchmark.py --model llama.cpp --base-url http://llm01:8080 --cache-mode miss --json
```

## Output

Without `--json`, prints a per-round table: round, turns, final prompt tokens,
final accumulated tokens, TTFT (ms), per-turn latency (min/avg/max ms), effective
TPS, and per-token latency std (consistency). With `--json`, prints one JSON
object per round for parsing.

## Interpreting results

- **TTFT in hit mode**: real opencode path. If it stays high across turns, the
  server is not reusing the KV/prefix cache (likely `--no-cache-kv` / no flash-
  attention in the llama.cpp server).
- **hit vs miss gap**: the TTFT difference is the prefix-cache benefit at that
  context size. A large gap = cache is working; a flat gap = cache is disabled.
- **Per-token latency std**: low variance = steady streaming; spikes mark KV-cache
  misses or re-prefills (common in miss mode).
- **Effective TPS**: tokens/sec after TTFT; drops as context grows without cache.
