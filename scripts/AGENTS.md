# Scripts Agent Guidelines

- `agent-benchmark.py`: Benchmark agent interactions with opencode-style
  multi-message sessions and growing context.
- Key args: `--context-size` (session grows monotonically to this, default
  80000 tok) and `--cache-mode hit|miss` (prefix-cache reuse vs full re-prefill).
- Context growth: each turn appends user task + assistant reply + fake tool
  result; per-turn budget ≈ `(context-size - system - tasks) / turns-per-round`.
- Prompt tokens come from server usage chunks (`prompt_eval_count` /
  `prompt_tokens`); fallback is a chars/4 estimate.
- Ollama uses `/api/chat` (messages-based); llama.cpp and OpenAI use
  `/v1/chat/completions` with `stream_options.include_usage`.
- Keep tool-result text varied (TOOL_RESULT_TEMPLATES) — `.format()` does not
  support expressions like `{n % 4}`; precompute such values in the format call.
- `--cache-mode hit` requires append-only history (system prompt constant).
  Never mutate earlier messages in hit mode or the KV cache is invalidated.
