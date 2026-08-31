#!/usr/bin/env python3
"""
Agent Interaction Benchmark

Simulates opencode-style agent sessions:
- Multi-message conversations (system + user/assistant/tool-result history)
- Monotonically growing context up to --context-size (default 80k tokens)
- --cache-mode hit|miss to separate prefix-cache TTFT from full re-prefill

Measures what actually matters for agent perceived speed:
- Time-to-first-token (TTFT)
- Per-turn total time (including agent-style overhead)
- Effective tps under growing context
- Consistency (p50/p95 token latency)

Usage:
  python3 agent-benchmark.py --model llama.cpp --base-url http://llm01:8080 --rounds 5
  python3 agent-benchmark.py --model llama.cpp --cache-mode miss --rounds 3
  python3 agent-benchmark.py --model openai://gpt-4o --api-key $OPENAI_API_KEY --rounds 10
  python3 agent-benchmark.py --model ollama://llama3.1 --rounds 10
"""

import argparse
import asyncio
import json
import time
import statistics
import sys
from dataclasses import dataclass, field
from typing import List, Optional


def est_tokens(text: str) -> int:
    """Approximate token count (~4 chars per token)."""
    return max(1, len(text) // 4)


def _extract_error_message(body: str, status: int) -> str:
    """Pull a human-readable message from an error body (llama.cpp JSON, plain text)."""
    if not body:
        return "HTTP %s" % status
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return "HTTP %s: %s" % (status, body.strip()[:200])
    err = data.get("error")
    if isinstance(err, dict):
        msg = err.get("message") or err.get("type") or "error"
        code = err.get("code")
        return "%s (code=%s)" % (msg, code) if code else str(msg)
    if isinstance(err, str):
        return err
    return body.strip()[:200]


@dataclass
class TurnResult:
    turn: int
    ttft_ms: float
    total_ms: float
    tokens: int
    effective_tps: float
    context_tokens: int = 0
    token_latencies_ms: List[float] = field(default_factory=list)
    error: Optional[str] = None


@dataclass
class BenchmarkResults:
    model: str
    rounds: int
    turns_per_round: int
    cache_mode: str = "hit"
    context_size: int = 80000
    results: List[TurnResult] = field(default_factory=list)

    @property
    def all_ttft(self) -> List[float]:
        return [r.ttft_ms for r in self.results]

    @property
    def all_total_ms(self) -> List[float]:
        return [r.total_ms for r in self.results]

    @property
    def all_effective_tps(self) -> List[float]:
        return [r.effective_tps for r in self.results]

    @property
    def all_context_tokens(self) -> List[int]:
        return [r.context_tokens for r in self.results]

    @property
    def all_token_latencies(self) -> List[float]:
        latencies = []
        for r in self.results:
            latencies.extend(r.token_latencies_ms)
        return latencies

    def summary(self) -> dict:
        def pct(vals, q):
            return sorted(vals)[int(len(vals) * q)] if len(vals) > 1 else (vals[0] if vals else 0)

        return {
            "model": self.model,
            "rounds": self.rounds,
            "turns_per_round": self.turns_per_round,
            "cache_mode": self.cache_mode,
            "context_size_target": self.context_size,
            "context_tokens_mean": statistics.mean(self.all_context_tokens) if self.all_context_tokens else 0,
            "context_tokens_max": max(self.all_context_tokens) if self.all_context_tokens else 0,
            "ttft_p50_ms": statistics.median(self.all_ttft) if self.all_ttft else 0,
            "ttft_p95_ms": pct(self.all_ttft, 0.95),
            "ttft_mean_ms": statistics.mean(self.all_ttft) if self.all_ttft else 0,
            "total_p50_ms": statistics.median(self.all_total_ms) if self.all_total_ms else 0,
            "total_p95_ms": pct(self.all_total_ms, 0.95),
            "total_mean_ms": statistics.mean(self.all_total_ms) if self.all_total_ms else 0,
            "effective_tps_p50": statistics.median(self.all_effective_tps) if self.all_effective_tps else 0,
            "effective_tps_p95": pct(self.all_effective_tps, 0.95),
            "effective_tps_mean": statistics.mean(self.all_effective_tps) if self.all_effective_tps else 0,
            "token_latency_p50_ms": statistics.median(self.all_token_latencies) if self.all_token_latencies else 0,
            "token_latency_p95_ms": pct(self.all_token_latencies, 0.95),
        }


# ---------------------------------------------------------------------------
# Session content builders (opencode-style simulation)
# ---------------------------------------------------------------------------

TOOL_DOCS = [
    ("bash", "Execute a shell command and return stdout/stderr."),
    ("read", "Read a file from the workspace. Returns file contents with line numbers."),
    ("grep", "Search file contents using regular expressions. Returns matching lines."),
    ("glob", "Find files by name pattern. Returns matching file paths."),
    ("edit", "Perform exact string replacements in a file."),
    ("write", "Write content to a file, overwriting if it exists."),
]

WORKSPACE_LINES = [
    "modules/nixos/base.nix",
    "modules/nixos/k3s.nix",
    "modules/nixos/ssh.nix",
    "modules/nixos/static-network.nix",
    "hosts/k8s-server01/configuration.nix",
    "hosts/k8s-node01/configuration.nix",
    "hosts/llm01/configuration.nix",
    "flake.nix",
    "secrets.yaml",
    "vars.nix",
]


def build_system_prompt() -> str:
    """Large opencode-like system prompt: role, tools, workspace, instructions."""
    tools = "\n".join(f"- {name}({desc})" for name, desc in TOOL_DOCS)
    files = "\n".join(f"  - {f}" for f in WORKSPACE_LINES)
    return f"""You are opencode, an interactive CLI agent that helps with software engineering tasks.

# Environment
Working directory: /home/coder/nixos-configurations (git repo)
Platform: linux. You are powered by a GLM model trained by Z.ai.

# Tools
{tools}

# Workspace files
{files}

# Guidelines
- Understand the codebase before making changes. Search extensively in parallel.
- Follow existing conventions: formatting, naming, module patterns.
- Only use tools to complete tasks. Never guess URLs. Follow security best practices.
- Be concise. Answer directly. Avoid unnecessary preamble or explanation.
"""


def build_user_task(turn: int) -> str:
    return f"""[Task {turn}]
Investigate how the k3s module handles server vs agent roles, then:
1. Run: grep -rn "role" modules/nixos/k3s.nix | head -20
2. Read: modules/nixos/k3s.nix (first 100 lines)
3. Explain the role handling and report findings"""


TOOL_RESULT_TEMPLATES = [
    "{n:6d}  {{ role = \"{role}\"; address = \"192.168.0.{o}\"; gateway = \"192.168.0.1\"; }}",
    "{n:6d}    systemd.services.k3s = {{ enable = true; role = \"{role}\"; tokenFile = \"{path}\"; }}",
    "{n:6d}  def handler_{n}(request, context): return process(payload_{n}, retries={n} % 5)",
    "{n:6d}      const data_{n} = {{ value: compute(input_{n}), meta: 'chunk', index: {n} }};",
    "{n:6d}        - name: deploy-{n}\n          image: registry.l.arrieta.eu/app:v{n}.{n}\n          ports: [{n}]",
    "{n:6d}    boot.kernelParams = [ \"cgroup.no_restrict=1\" \"overlay.override_cgroup=1\" \"loglevel={n}\" ];",
    "{n:6d}  Aug {n} 12:0{n}:15 host k3s-node0{h}: systemd[1]: k3s.service: reload succeeded",
    "{n:6d}    if response.status == {n} {{ return error(\"upstream failed at stage {n}\") }}",
]


def generate_tool_result(target_tokens: int, seed: int) -> str:
    """Fake but varied tool output (file dump / grep results), ~target_tokens."""
    lines = []
    n = 0
    total = 0
    while total < target_tokens:
        template = TOOL_RESULT_TEMPLATES[(n + seed) % len(TOOL_RESULT_TEMPLATES)]
        h = (n % 4) + 1
        line = template.format(n=n, h=h, role="server" if n % 3 else "agent", o=(n % 200) + 10, path=f"/run/secrets/token_{n}")
        lines.append(line)
        total += est_tokens(line)
        n += 1
    header = f"[tool result] grep -rn \"role\" modules/ ({n} lines)"
    return header + "\n" + "\n".join(lines)


def build_turn_messages(
    system: str,
    history: List[dict],
    task: str,
) -> List[dict]:
    """Full message list for this turn: system + accumulated history + new task."""
    return [{"role": "system", "content": system}] + history + [{"role": "user", "content": task}]


def messages_prompt_tokens(messages: List[dict]) -> int:
    return est_tokens("\n".join(m["content"] for m in messages))


# ---------------------------------------------------------------------------
# Provider measurement (streaming, per-turn)
# ---------------------------------------------------------------------------

async def measure_turn_ollama(
    model_name: str,
    messages: List[dict],
    session,
    url: str,
) -> TurnResult:
    """Measure a single turn against an Ollama-compatible local model (/api/chat)."""
    import aiohttp

    payload = {
        "model": model_name,
        "messages": messages,
        "stream": True,
        "options": {"num_predict": 512, "temperature": 0.1},
    }

    start = time.monotonic()
    first_token_time = None
    token_count = 0
    response_parts = []
    prompt_tokens = 0
    token_latencies = []
    last_token_time = start

    async with session.post(f"{url}/api/chat", json=payload) as resp:
        async for line in resp.content:
            if not line.strip():
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue

            now = time.monotonic()
            if first_token_time is None:
                first_token_time = now

            content = data.get("message", {}).get("content", "")
            if content:
                token_count += 1
                response_parts.append(content)
                token_latencies.append((now - last_token_time) * 1000)
                last_token_time = now

            if data.get("done", False):
                prompt_tokens = data.get("prompt_eval_count", 0) or 0
                break

    total_ms = (time.monotonic() - start) * 1000
    ttft_ms = (first_token_time - start) * 1000 if first_token_time else total_ms
    effective_tps = (token_count / (total_ms / 1000)) if total_ms > 0 else 0

    return TurnResult(
        turn=0,
        ttft_ms=ttft_ms,
        total_ms=total_ms,
        tokens=token_count,
        effective_tps=effective_tps,
        context_tokens=prompt_tokens,
        token_latencies_ms=token_latencies,
    ), "".join(response_parts) or "(no output)"


# ---------------------------------------------------------------------------
# Provider measurement (streaming, per-turn)
# ---------------------------------------------------------------------------

async def measure_turn_ollama(
    model_name: str,
    messages: List[dict],
    session,
    url: str,
) -> TurnResult:
    """Measure a single turn against an Ollama-compatible local model (/api/chat)."""
    import aiohttp

    payload = {
        "model": model_name,
        "messages": messages,
        "stream": True,
        "options": {"num_predict": 512, "temperature": 0.1},
    }

    start = time.monotonic()
    first_token_time = None
    token_count = 0
    response_parts = []
    prompt_tokens = 0
    token_latencies = []
    last_token_time = start

    async with session.post(f"{url}/api/chat", json=payload) as resp:
        async for line in resp.content:
            if not line.strip():
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue

            now = time.monotonic()
            if first_token_time is None:
                first_token_time = now

            content = data.get("message", {}).get("content", "")
            if content:
                token_count += 1
                response_parts.append(content)
                token_latencies.append((now - last_token_time) * 1000)
                last_token_time = now

            if data.get("done", False):
                prompt_tokens = data.get("prompt_eval_count", 0) or 0
                break

    total_ms = (time.monotonic() - start) * 1000
    ttft_ms = (first_token_time - start) * 1000 if first_token_time else total_ms
    effective_tps = (token_count / (total_ms / 1000)) if total_ms > 0 else 0

    result = TurnResult(
        turn=0,
        ttft_ms=ttft_ms,
        total_ms=total_ms,
        tokens=token_count,
        effective_tps=effective_tps,
        context_tokens=prompt_tokens,
        token_latencies_ms=token_latencies,
    )
    return result, "".join(response_parts) or "(no output)"


async def measure_turn_openai_compat(
    model_name: str,
    messages: List[dict],
    session,
    base_url: str,
    api_key: Optional[str] = None,
) -> TurnResult:
    """Measure a single turn against an OpenAI-compatible endpoint (llama.cpp server, cloud)."""
    import aiohttp

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    payload = {
        "model": model_name,
        "messages": messages,
        "stream": True,
        "max_tokens": 512,
        "temperature": 0.1,
        "stream_options": {"include_usage": True},
    }

    start = time.monotonic()
    first_token_time = None
    token_count = 0
    response_parts = []
    prompt_tokens = 0
    token_latencies = []
    last_token_time = start
    error_body = []

    async with session.post(f"{base_url}/v1/chat/completions", headers=headers, json=payload) as resp:
        async for line in resp.content:
            if not line.strip():
                continue
            text = line.decode("utf-8", "replace")
            if resp.status >= 400:
                # Server rejected the request (e.g. context overflow); capture body.
                if not text.startswith("data: "):
                    error_body.append(text)
                continue
            if not text.startswith("data: "):
                continue
            data_str = text[6:].strip()
            if data_str == "[DONE]":
                break
            try:
                data = json.loads(data_str)
            except json.JSONDecodeError:
                continue

            now = time.monotonic()
            if first_token_time is None:
                first_token_time = now

            choices = data.get("choices") or [{}]
            delta = choices[0].get("delta", {}).get("content", "")
            if delta:
                token_count += 1
                response_parts.append(delta)
                token_latencies.append((now - last_token_time) * 1000)
                last_token_time = now

            usage = data.get("usage")
            if usage:
                prompt_tokens = usage.get("prompt_tokens", 0) or 0

    total_ms = (time.monotonic() - start) * 1000

    if resp.status >= 400:
        msg = _extract_error_message("".join(error_body), resp.status)
        return (
            TurnResult(
                turn=0,
                ttft_ms=total_ms,
                total_ms=total_ms,
                tokens=0,
                effective_tps=0,
                context_tokens=prompt_tokens,
                error=msg,
            ),
            "(error: %s)" % msg,
        )

    ttft_ms = (first_token_time - start) * 1000 if first_token_time else total_ms
    effective_tps = (token_count / (total_ms / 1000)) if total_ms > 0 else 0

    result = TurnResult(
        turn=0,
        ttft_ms=ttft_ms,
        total_ms=total_ms,
        tokens=token_count,
        effective_tps=effective_tps,
        context_tokens=prompt_tokens,
        token_latencies_ms=token_latencies,
    )
    return result, "".join(response_parts) or "(no output)"


# ---------------------------------------------------------------------------
# Benchmark loop (agent sessions)
# ---------------------------------------------------------------------------

async def run_benchmark(
    model: str,
    rounds: int,
    turns_per_round: int,
    provider: str = "auto",
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
    model_name: Optional[str] = None,
    context_size: int = 80000,
    cache_mode: str = "hit",
) -> BenchmarkResults:
    import aiohttp

    results = BenchmarkResults(
        model=model,
        rounds=rounds,
        turns_per_round=turns_per_round,
        cache_mode=cache_mode,
        context_size=context_size,
    )

    if provider == "ollama" or (provider == "auto" and model.startswith("ollama://")):
        model_name = model_name or model.replace("ollama://", "")
        base_url = base_url or "http://localhost:11434"
        measure = lambda msgs: measure_turn_ollama(model_name, msgs, session, base_url)
    elif provider == "llamacpp" or (provider == "auto" and model.startswith("llama.cpp")):
        model_name = model_name or model.replace("llama.cpp://", "").replace("llama.cpp", "")
        base_url = base_url or "http://llm01:8080"
        measure = lambda msgs: measure_turn_openai_compat(model_name, msgs, session, base_url)
    elif provider == "openai" or (provider == "auto" and model.startswith("openai://")):
        model_name = model_name or model.replace("openai://", "")
        base_url = base_url or "https://api.openai.com/v1"
        measure = lambda msgs: measure_turn_openai_compat(model_name, msgs, session, base_url, api_key)
    else:
        print(f"Unknown provider for model: {model}", file=sys.stderr)
        sys.exit(1)

    timeout = aiohttp.ClientTimeout(total=None, sock_read=600)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        # Unmetered warm-up for llama.cpp (not counted in results)
        if provider == "llamacpp" or (provider == "auto" and model.startswith("llama.cpp")):
            try:
                async with session.post(
                    f"{base_url}/v1/chat/completions",
                    json={"model": model_name, "messages": [{"role": "user", "content": "warmup"}], "max_tokens": 5, "stream": False},
                    timeout=aiohttp.ClientTimeout(total=180),
                ) as resp:
                    await resp.read()
                print("  Warm-up complete (unmetered).", flush=True, file=sys.stderr)
            except Exception as e:
                print(f"  Warm-up skipped: {e}", flush=True, file=sys.stderr)

        # Adaptive budget: grow context toward context_size using the server's
        # own prompt-token counts as ground truth. The chars/4 estimate is
        # unreliable for code/nix (they tokenize to far more tokens than /4), so
        # we calibrate a real/est ratio each turn and scale tool-result size to
        # it. Shrinking-room budgeting bounds any single overshoot.
        system = build_system_prompt()
        eff_target = max(1000, context_size - 2000)  # headroom under the model's n_ctx
        ratio = 1.3  # conservative floor (code/nix over-tokenize vs /4); EWMA-corrected
        mean_assist = 500.0

        for round_num in range(rounds):
            history: List[dict] = []
            for turn in range(turns_per_round):
                task = build_user_task(turn)
                turn_system = system
                if cache_mode == "miss":
                    # Unique prefix per turn -> full re-prefill every request
                    turn_system = f"<!-- session {round_num + 1} turn {turn + 1} nonce -->\n" + system

                messages = build_turn_messages(turn_system, history, task)
                est_prompt = messages_prompt_tokens(messages)

                result, response_text = await measure(messages)
                result.turn = turn
                results.results.append(result)

                if result.error:
                    print(
                        f"  Round {round_num+1}/{rounds} Turn {turn+1}/{turns_per_round} | "
                        f"ERROR: {result.error}",
                        flush=True,
                        file=sys.stderr,
                    )
                    return results  # stop the whole benchmark on a server rejection

                real_prompt = result.context_tokens or est_prompt
                if est_prompt > 0:
                    cur = real_prompt / est_prompt
                    ratio = max(0.3, min(ratio * 0.5 + cur * 0.5, 8.0))

                print(
                    f"  Round {round_num+1}/{rounds} Turn {turn+1}/{turns_per_round} | "
                    f"Ctx: {real_prompt} tok | "
                    f"TTFT: {result.ttft_ms:.0f}ms | Total: {result.total_ms:.0f}ms | "
                    f"Out tok: {result.tokens} | Eff.tps: {result.effective_tps:.1f} | ratio:{ratio:.2f}",
                    flush=True,
                    file=sys.stderr,
                )

                # Agent loop: append assistant reply, then a tool result that grows
                # context toward eff_target without overshooting n_ctx.
                history.append({"role": "assistant", "content": response_text[:2000]})
                assist_real = max(1, len(response_text[:2000]) // 4)
                mean_assist = mean_assist * 0.8 + assist_real * 0.2

                slots = turns_per_round - 1 - turn  # tool results still to add this round
                if slots <= 0:
                    tool_text = ""
                else:
                    room = eff_target - real_prompt
                    reserve = slots * mean_assist
                    per_tool_real = max(200, (room - reserve) / slots)
                    per_tool_est = max(100, int(per_tool_real / max(ratio, 0.5)))
                    tool_text = generate_tool_result(per_tool_est, seed=round_num * 100 + turn)
                history.append({"role": "user", "content": f"[tool result]\n{tool_text}"})

    return results


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_summary(results: BenchmarkResults):
    s = results.summary()
    print("\n" + "=" * 70)
    print(f"BENCHMARK RESULTS: {s['model']}  (cache_mode={s['cache_mode']})")
    print(f"Rounds: {s['rounds']} x Turns/round: {s['turns_per_round']}, context target: {s['context_size_target']} tok")
    print(f"Context reached: mean {s['context_tokens_mean']:.0f} tok, max {s['context_tokens_max']} tok")
    print("=" * 70)
    print(f"  TTFT (time to first token):")
    print(f"    Mean:  {s['ttft_mean_ms']:.0f} ms")
    print(f"    P50:   {s['ttft_p50_ms']:.0f} ms")
    print(f"    P95:   {s['ttft_p95_ms']:.0f} ms")
    print(f"  Per-turn total time:")
    print(f"    Mean:  {s['total_mean_ms']:.0f} ms")
    print(f"    P50:   {s['total_p50_ms']:.0f} ms")
    print(f"    P95:   {s['total_p95_ms']:.0f} ms")
    print(f"  Effective tps (under load):")
    print(f"    Mean:  {s['effective_tps_mean']:.1f}")
    print(f"    P50:   {s['effective_tps_p50']:.1f}")
    print(f"    P95:   {s['effective_tps_p95']:.1f}")
    print(f"  Per-token latency:")
    print(f"    P50:   {s['token_latency_p50_ms']:.1f} ms")
    print(f"    P95:   {s['token_latency_p95_ms']:.1f} ms")
    print("=" * 70)

    print("\nKEY INSIGHT:")
    if s["cache_mode"] == "hit" and s["ttft_p50_ms"] > 500:
        print("  HIGH TTFT even with an append-only prefix — the server is NOT reusing")
        print("  the KV cache between turns, or the cache was evicted. Real opencode")
        print("  sessions depend on this reuse: turn N should prefill only new tokens.")
    if s["cache_mode"] == "miss" and s["ttft_p50_ms"] > 500:
        print("  HIGH TTFT on full re-prefill is expected — this is the cache-cold floor.")
        print("  Compare with --cache-mode hit: the TTFT gap IS the prefix-cache benefit.")
    if s["token_latency_p95_ms"] > 100:
        print("  HIGH per-token latency variance — tokens arrive in bursts, not smoothly.")
        print("  This causes the 'stuttering' perception that makes agents feel unresponsive.")
    if s["effective_tps_p50"] < 30:
        print("  Effective tps under load is LOW despite high raw tps — large-context")
        print("  attention or overhead is eating the throughput advantage.")


def main():
    parser = argparse.ArgumentParser(description="Agent Interaction Benchmark")
    parser.add_argument("--model", required=True, help="Model identifier: llama.cpp, ollama://name, openai://name")
    parser.add_argument("--base-url", default=None, help="Base URL for the API (e.g. http://llm01:8080 for llama.cpp, http://localhost:11434 for Ollama)")
    parser.add_argument("--model-name", default=None, help="Model name to send to the API (overrides auto-detection)")
    parser.add_argument("--rounds", type=int, default=5, help="Number of agent sessions")
    parser.add_argument("--turns-per-round", type=int, default=8, help="Turns per session (context grows each turn)")
    parser.add_argument("--provider", default="auto", choices=["auto", "ollama", "llamacpp", "openai"])
    parser.add_argument("--api-key", default=None, help="API key for cloud providers")
    parser.add_argument("--context-size", type=int, default=80000, help="Target context tokens the session grows to (default 80k, opencode-style)")
    parser.add_argument("--cache-mode", default="hit", choices=["hit", "miss"], help="hit: append-only prefix (KV cache reuse, like real opencode); miss: unique prefix per turn (full re-prefill floor)")
    parser.add_argument("--json", action="store_true", help="Output results as JSON")
    args = parser.parse_args()

    results = asyncio.run(run_benchmark(
        model=args.model,
        rounds=args.rounds,
        turns_per_round=args.turns_per_round,
        provider=args.provider,
        base_url=args.base_url,
        api_key=args.api_key,
        model_name=args.model_name,
        context_size=args.context_size,
        cache_mode=args.cache_mode,
    ))

    if args.json:
        print(json.dumps(results.summary(), indent=2))
    else:
        print_summary(results)


if __name__ == "__main__":
    main()
