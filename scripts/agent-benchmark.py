#!/usr/bin/env python3
"""
Agent Interaction Benchmark

Measures what actually matters for agent perceived speed:
- Time-to-first-token (TTFT)
- Per-turn total time (including agent-style overhead)
- Effective tps under growing context
- Consistency (p50/p95 token latency)

Usage:
  python3 agent-benchmark.py --model llama.cpp --base-url http://llm01:8080 --rounds 10
  python3 agent-benchmark.py --model llama.cpp --base-url http://llm01:8080 --model-name ornith-1.5 --rounds 20
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


@dataclass
class TurnResult:
    turn: int
    ttft_ms: float
    total_ms: float
    tokens: int
    effective_tps: float
    token_latencies_ms: List[float] = field(default_factory=list)


@dataclass
class BenchmarkResults:
    model: str
    rounds: int
    turns_per_round: int
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
    def all_token_latencies(self) -> List[float]:
        latencies = []
        for r in self.results:
            latencies.extend(r.token_latencies_ms)
        return latencies

    def summary(self) -> dict:
        return {
            "model": self.model,
            "rounds": self.rounds,
            "turns_per_round": self.turns_per_round,
            "ttft_p50_ms": statistics.median(self.all_ttft) if self.all_ttft else 0,
            "ttft_p95_ms": sorted(self.all_ttft)[int(len(self.all_ttft) * 0.95)] if len(self.all_ttft) > 1 else 0,
            "ttft_mean_ms": statistics.mean(self.all_ttft) if self.all_ttft else 0,
            "total_p50_ms": statistics.median(self.all_total_ms) if self.all_total_ms else 0,
            "total_p95_ms": sorted(self.all_total_ms)[int(len(self.all_total_ms) * 0.95)] if len(self.all_total_ms) > 1 else 0,
            "total_mean_ms": statistics.mean(self.all_total_ms) if self.all_total_ms else 0,
            "effective_tps_p50": statistics.median(self.all_effective_tps) if self.all_effective_tps else 0,
            "effective_tps_p95": sorted(self.all_effective_tps)[int(len(self.all_effective_tps) * 0.95)] if len(self.all_effective_tps) > 1 else 0,
            "effective_tps_mean": statistics.mean(self.all_effective_tps) if self.all_effective_tps else 0,
            "token_latency_p50_ms": statistics.median(self.all_token_latencies) if self.all_token_latencies else 0,
            "token_latency_p95_ms": sorted(self.all_token_latencies)[int(len(self.all_token_latencies) * 0.95)] if len(self.all_token_latencies) > 1 else 0,
        }


def build_turn_prompt(turn: int, context_size_tokens: int) -> str:
    """Simulate an agent turn with growing context and tool-call overhead."""
    tool_calls = [
        f'{{"name": "bash", "arguments": {{"command": "echo turn_{turn}"}}}}',
        f'{{"name": "read", "arguments": {{"file": "/tmp/agent_state_{turn}.json"}}}}',
    ]

    context_lines = []
    for i in range(min(turn, context_size_tokens // 50)):
        context_lines.append(f"[Turn {i}] User: What is the status of task {i}?")
        context_lines.append(f"[Turn {i}] Assistant: Task {i} is complete. Results: ...")

    prompt = f"""You are an agent. Here is the conversation history and current task.

{chr(10).join(context_lines)}

[Current Turn {turn}]
User: Run the following steps and report results:
1. Execute: echo "step1_turn_{turn}"
2. Read: cat /tmp/agent_output_{turn}.txt
3. Summarize findings

Available tools:
- bash(command: str) -> str
- read(file: str) -> str

Please use the tools to complete this task.
"""
    return prompt


async def measure_turn_ollama(
    model: str,
    prompt: str,
    session: "aiohttp.ClientSession",
    url: str,
) -> TurnResult:
    """Measure a single turn against an Ollama-compatible local model."""
    import aiohttp

    payload = {
        "model": model,
        "prompt": prompt,
        "stream": True,
        "options": {
            "num_predict": 512,
            "temperature": 0.1,
        },
    }

    start = time.monotonic()
    first_token_time = None
    token_count = 0
    token_latencies = []
    last_token_time = start

    async with session.post(f"{url}/api/generate", json=payload) as resp:
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

            if "response" in data and data["response"]:
                token_count += len(data["response"])
                token_latencies.append((now - last_token_time) * 1000)
                last_token_time = now

            if data.get("done", False):
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
        token_latencies_ms=token_latencies,
    )


async def measure_turn_openai(
    model: str,
    prompt: str,
    session: "aiohttp.ClientSession",
    api_key: str,
    base_url: str = "https://api.openai.com/v1",
) -> TurnResult:
    """Measure a single turn against OpenAI-compatible cloud API."""
    import aiohttp

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": 512,
        "temperature": 0.1,
    }

    start = time.monotonic()
    first_token_time = None
    token_count = 0
    token_latencies = []
    last_token_time = start

    async with session.post(
        f"{base_url}/chat/completions",
        headers=headers,
        json=payload,
    ) as resp:
        async for line in resp.content:
            if not line.strip():
                continue
            text = line.decode("utf-8")
            if text.startswith("data: "):
                data_str = text[6:]
                if data_str == "[DONE]":
                    break
                try:
                    data = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                now = time.monotonic()
                if first_token_time is None:
                    first_token_time = now

                delta = data.get("choices", [{}])[0].get("delta", {}).get("content", "")
                if delta:
                    token_count += len(delta)
                    token_latencies.append((now - last_token_time) * 1000)
                    last_token_time = now

    total_ms = (time.monotonic() - start) * 1000
    ttft_ms = (first_token_time - start) * 1000 if first_token_time else total_ms

    effective_tps = (token_count / (total_ms / 1000)) if total_ms > 0 else 0

    return TurnResult(
        turn=0,
        ttft_ms=ttft_ms,
        total_ms=total_ms,
        tokens=token_count,
        effective_tps=effective_tps,
        token_latencies_ms=token_latencies,
    )


async def measure_turn_llamacpp(
    model_name: str,
    prompt: str,
    session: "aiohttp.ClientSession",
    base_url: str,
) -> TurnResult:
    """Measure a single turn against llama.cpp OpenAI-compatible endpoint."""
    import aiohttp

    headers = {
        "Content-Type": "application/json",
    }

    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": 512,
        "temperature": 0.1,
    }

    start = time.monotonic()
    first_token_time = None
    token_count = 0
    token_latencies = []
    last_token_time = start

    async with session.post(
        f"{base_url}/v1/chat/completions",
        headers=headers,
        json=payload,
    ) as resp:
        async for line in resp.content:
            if not line.strip():
                continue
            text = line.decode("utf-8")
            if text.startswith("data: "):
                data_str = text[6:]
                if data_str == "[DONE]":
                    break
                try:
                    data = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                now = time.monotonic()
                if first_token_time is None:
                    first_token_time = now

                delta = data.get("choices", [{}])[0].get("delta", {}).get("content", "")
                if delta:
                    token_count += len(delta)
                    token_latencies.append((now - last_token_time) * 1000)
                    last_token_time = now

    total_ms = (time.monotonic() - start) * 1000
    ttft_ms = (first_token_time - start) * 1000 if first_token_time else total_ms

    effective_tps = (token_count / (total_ms / 1000)) if total_ms > 0 else 0

    return TurnResult(
        turn=0,
        ttft_ms=ttft_ms,
        total_ms=total_ms,
        tokens=token_count,
        effective_tps=effective_tps,
        token_latencies_ms=token_latencies,
    )


async def run_benchmark(
    model: str,
    rounds: int,
    turns_per_round: int,
    provider: str = "auto",
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
    model_name: Optional[str] = None,
) -> BenchmarkResults:
    import aiohttp

    results = BenchmarkResults(model=model, rounds=rounds, turns_per_round=turns_per_round)

    if provider == "ollama" or (provider == "auto" and model.startswith("ollama://")):
        model_name = model_name or model.replace("ollama://", "")
        base_url = base_url or "http://localhost:11434"
        async with aiohttp.ClientSession() as session:
            for round_num in range(rounds):
                for turn in range(turns_per_round):
                    context_tokens = turn * 50
                    prompt = build_turn_prompt(turn, context_tokens)
                    result = await measure_turn_ollama(model_name, prompt, session, base_url)
                    result.turn = turn
                    results.results.append(result)
                    print(
                        f"  Round {round_num+1}/{rounds} Turn {turn+1}/{turns_per_round} | "
                        f"TTFT: {result.ttft_ms:.0f}ms | Total: {result.total_ms:.0f}ms | "
                        f"Tokens: {result.tokens} | Eff.tps: {result.effective_tps:.1f}",
                        flush=True,
                    )

    elif provider == "llamacpp" or (provider == "auto" and model.startswith("llama.cpp")):
        model_name = model_name or model.replace("llama.cpp://", "").replace("llama.cpp", "")
        base_url = base_url or "http://localhost:8080"
        async with aiohttp.ClientSession() as session:
            for round_num in range(rounds):
                for turn in range(turns_per_round):
                    context_tokens = turn * 50
                    prompt = build_turn_prompt(turn, context_tokens)
                    result = await measure_turn_llamacpp(model_name, prompt, session, base_url)
                    result.turn = turn
                    results.results.append(result)
                    print(
                        f"  Round {round_num+1}/{rounds} Turn {turn+1}/{turns_per_round} | "
                        f"TTFT: {result.ttft_ms:.0f}ms | Total: {result.total_ms:.0f}ms | "
                        f"Tokens: {result.tokens} | Eff.tps: {result.effective_tps:.1f}",
                        flush=True,
                    )

    elif provider == "openai" or (provider == "auto" and model.startswith("openai://")):
        model_name = model_name or model.replace("openai://", "")
        api_key = api_key or ""
        base_url = base_url or "https://api.openai.com/v1"
        async with aiohttp.ClientSession() as session:
            for round_num in range(rounds):
                for turn in range(turns_per_round):
                    context_tokens = turn * 50
                    prompt = build_turn_prompt(turn, context_tokens)
                    result = await measure_turn_openai(model_name, prompt, session, api_key, base_url)
                    result.turn = turn
                    results.results.append(result)
                    print(
                        f"  Round {round_num+1}/{rounds} Turn {turn+1}/{turns_per_round} | "
                        f"TTFT: {result.ttft_ms:.0f}ms | Total: {result.total_ms:.0f}ms | "
                        f"Tokens: {result.tokens} | Eff.tps: {result.effective_tps:.1f}",
                        flush=True,
                    )

    else:
        print(f"Unknown provider for model: {model}", file=sys.stderr)
        sys.exit(1)

    return results


def print_summary(results: BenchmarkResults):
    s = results.summary()
    print("\n" + "=" * 70)
    print(f"BENCHMARK RESULTS: {s['model']}")
    print(f"Rounds: {s['rounds']} x Turns/round: {s['turns_per_round']}")
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
    if s["ttft_p50_ms"] > 500:
        print("  HIGH TTFT is likely the bottleneck — model takes >500ms to start generating.")
        print("  This is what makes fast-tps models FEEL slow in agent interactions.")
    if s["token_latency_p95_ms"] > 100:
        print("  HIGH per-token latency variance — tokens arrive in bursts, not smoothly.")
        print("  This causes the 'stuttering' perception that makes agents feel unresponsive.")
    if s["effective_tps_p50"] < 30:
        print("  Effective tps under load is LOW despite high raw tps — context growth or")
        print("  overhead is eating the throughput advantage.")


def main():
    parser = argparse.ArgumentParser(description="Agent Interaction Benchmark")
    parser.add_argument("--model", required=True, help="Model identifier: llama.cpp, ollama://name, openai://name")
    parser.add_argument("--base-url", default=None, help="Base URL for the API (e.g. http://llm01:8080 for llama.cpp, http://localhost:11434 for Ollama)")
    parser.add_argument("--model-name", default=None, help="Model name to send to the API (overrides auto-detection)")
    parser.add_argument("--rounds", type=int, default=10, help="Number of full rounds")
    parser.add_argument("--turns-per-round", type=int, default=5, help="Turns per round (simulates multi-step agent task)")
    parser.add_argument("--provider", default="auto", choices=["auto", "ollama", "llamacpp", "openai"])
    parser.add_argument("--api-key", default=None, help="API key for cloud providers")
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
    ))

    if args.json:
        print(json.dumps(results.summary(), indent=2))
    else:
        print_summary(results)


if __name__ == "__main__":
    main()