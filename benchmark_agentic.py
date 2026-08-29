#!/usr/bin/env python3
"""
Agentic Multi-Turn Latency & Prefix Cache Benchmark for llama-server.

Measures:
- Wall-clock time (Total ms and TTFT ms)
- Prompt processing / prefill speed (prompt_n, prompt_ms, prompt_per_second)
- Prefix cache retention (cache_n on Turn 2 vs Turn 1)
- Generation speed (predicted_n, predicted_ms, predicted_per_second)

Usage:
  python3 benchmark_agentic.py --base-url http://localhost:8080 --model default
  python3 benchmark_agentic.py --base-url http://localhost:8001 --model Ling-3.0-flash --stream
  python3 benchmark_agentic.py --base-url http://localhost:8080 --model Qwen3.8-27B --target-tokens 3000 --json
"""

import argparse
import json
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

# Prefer httpx/requests if installed; fallback seamlessly to standard urllib
try:
    import httpx

    HTTP_CLIENT = "httpx"
except ImportError:
    try:
        import requests

        HTTP_CLIENT = "requests"
    except ImportError:
        import urllib.error
        import urllib.request

        HTTP_CLIENT = "urllib"


def generate_agent_system_prompt(target_tokens: int = 3000) -> str:
    """
    Generate realistic agentic system prompt with structured tool definitions
    to simulate ~2k-4k tokens of system prompt context.
    """
    tools = [
        {
            "name": "bash",
            "description": "Run bash commands in a persistent shell session with sandboxing and execution timeout.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The exact shell command to execute"},
                    "timeout_sec": {"type": "integer", "description": "Max execution time in seconds", "default": 60},
                    "working_dir": {"type": "string", "description": "Absolute path to working directory", "default": "/workspace"}
                },
                "required": ["command"]
            }
        },
        {
            "name": "read_file",
            "description": "Read file contents from local filesystem with line offset, limit and encoding detection.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Absolute path to file"},
                    "offset": {"type": "integer", "description": "1-based line number to start reading from", "default": 1},
                    "limit": {"type": "integer", "description": "Maximum number of lines to return", "default": 2000}
                },
                "required": ["file_path"]
            }
        },
        {
            "name": "edit_file",
            "description": "Perform precise exact-string replacements in an existing file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Absolute path to file"},
                    "old_string": {"type": "string", "description": "Exact text to find and replace"},
                    "new_string": {"type": "string", "description": "Replacement text"},
                    "replace_all": {"type": "boolean", "description": "Replace all occurrences", "default": False}
                },
                "required": ["file_path", "old_string", "new_string"]
            }
        },
        {
            "name": "grep_search",
            "description": "Fast regex search over repository file contents using ripgrep semantics.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Regex pattern to match"},
                    "path": {"type": "string", "description": "Root path to search", "default": "."},
                    "include": {"type": "string", "description": "Glob pattern for included files (e.g. *.py, *.nix)"}
                },
                "required": ["pattern"]
            }
        },
        {
            "name": "glob_find",
            "description": "Match file paths using glob wildcards across deep directory trees.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Glob pattern (e.g. **/*.conf)"},
                    "path": {"type": "string", "description": "Root path to evaluate", "default": "."}
                },
                "required": ["pattern"]
            }
        },
        {
            "name": "git_status_diff",
            "description": "Inspect git working tree status, unstaged diffs, and staged commits.",
            "parameters": {
                "type": "object",
                "properties": {
                    "repo_path": {"type": "string", "description": "Git repository path", "default": "."},
                    "staged": {"type": "boolean", "description": "Show staged diff instead of working tree", "default": False}
                }
            }
        },
        {
            "name": "query_metrics",
            "description": "Query Prometheus timeseries database via PromQL endpoint.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "PromQL expression"},
                    "time_range": {"type": "string", "description": "Duration string (e.g. 5m, 1h)", "default": "15m"}
                },
                "required": ["query"]
            }
        },
        {
            "name": "manage_service",
            "description": "Control systemd units and monitor runtime daemon lifecycle.",
            "parameters": {
                "type": "object",
                "properties": {
                    "unit": {"type": "string", "description": "Name of systemd unit"},
                    "action": {"type": "string", "enum": ["status", "start", "stop", "restart", "reload"]}
                },
                "required": ["unit", "action"]
            }
        }
    ]

    base_prompt = (
        "You are an expert autonomous software engineering and systems administration agent.\n"
        "Your mission is to analyze codebase structures, diagnose latency bottlenecks, execute terminal operations,\n"
        "and modify system configurations safely and idiomatically.\n\n"
        "## OPERATING GUIDELINES & PROTOCOLS\n"
        "1. Strictly verify file contents and system state before executing destructive modifications.\n"
        "2. Minimize unnecessary roundtrips by formulating coherent, structured execution steps.\n"
        "3. Provide precise technical reasoning without conversational filler.\n"
        "4. Always monitor resource consumption (GPU VRAM, unified NVRAM bandwidth, CPU threads).\n\n"
        "## AVAILABLE TOOL SPECIFICATIONS\n"
        f"{json.dumps(tools, indent=2)}\n\n"
        "## SYSTEM CONTEXT & HARDWARE TOPOLOGY\n"
        "- Architecture: AMD Strix Halo APU (Unified LPDDR5X NVRAM 128GB, gfx1151 RDNA3.5 compute units)\n"
        "- Subsystem: Vulkan / ROCm compute backend with continuous batching and prompt caching enabled.\n"
        "- Target Host: llm01 (NixOS / K3s control & agent tier node)\n"
    )

    # Pad system prompt with detailed domain policies if target token length is higher
    padding_block = (
        "\n### EXTENDED DOMAIN SPECIFICATION & POLICY DEFINITION\n"
        "- Policy Rule S-101: All network sockets must bind explicitly to configured IP interfaces.\n"
        "- Policy Rule S-102: Systemd units must include timeout boundaries and RestartSec throttling.\n"
        "- Policy Rule S-103: Cache reuse thresholds must be preserved across multi-turn conversational trees.\n"
        "- Policy Rule S-104: Quantized KV buffers (q8_0 / q4_0) must retain alignment on 256-token boundaries.\n"
        "- Policy Rule S-105: Memory lock limits (mlock) must be set to infinity for real-time inference slots.\n"
        "- Policy Rule S-106: Prompt prefix caching relies on deterministic tokenization and byte-identical prefixes.\n"
    )

    prompt = base_prompt
    # Approximate 1 token ~= 3.8 characters
    while len(prompt) < target_tokens * 3.8:
        prompt += padding_block

    return prompt


def send_chat_completion(
    url: str,
    payload: Dict[str, Any],
    stream: bool = False,
    timeout: float = 120.0,
) -> Tuple[str, Optional[float], float, Dict[str, Any], Dict[str, Any]]:
    """
    Send request to OpenAI-compatible /v1/chat/completions endpoint.
    Returns: (content, ttft_ms, total_wall_ms, timings_dict, usage_dict)
    """
    payload["stream"] = stream
    t0 = time.monotonic()
    content = ""
    ttft_ms = None
    timings = {}
    usage = {}

    if HTTP_CLIENT == "httpx":
        if stream:
            with httpx.Client(timeout=timeout) as client:
                with client.stream("POST", url, json=payload) as resp:
                    resp.raise_for_status()
                    for line in resp.iter_lines():
                        if not line:
                            continue
                        if line.startswith("data: "):
                            data_str = line[6:].strip()
                            if data_str == "[DONE]":
                                break
                            try:
                                data = json.loads(data_str)
                                if ttft_ms is None:
                                    ttft_ms = (time.monotonic() - t0) * 1000
                                choices = data.get("choices", [])
                                if choices:
                                    delta = choices[0].get("delta", {})
                                    delta_content = delta.get("content")
                                    if delta_content:
                                        content += delta_content
                                if "timings" in data:
                                    timings.update(data["timings"])
                                if "usage" in data:
                                    usage.update(data["usage"])
                            except json.JSONDecodeError:
                                pass
        else:
            with httpx.Client(timeout=timeout) as client:
                resp = client.post(url, json=payload)
                resp.raise_for_status()
                data = resp.json()
                choices = data.get("choices", [])
                if choices:
                    content = choices[0].get("message", {}).get("content", "")
                timings = data.get("timings", {})
                usage = data.get("usage", {})

    elif HTTP_CLIENT == "requests":
        if stream:
            with requests.post(url, json=payload, stream=True, timeout=timeout) as resp:
                resp.raise_for_status()
                for raw_line in resp.iter_lines():
                    if not raw_line:
                        continue
                    line = raw_line.decode("utf-8")
                    if line.startswith("data: "):
                        data_str = line[6:].strip()
                        if data_str == "[DONE]":
                            break
                        try:
                            data = json.loads(data_str)
                            if ttft_ms is None:
                                ttft_ms = (time.monotonic() - t0) * 1000
                            choices = data.get("choices", [])
                            if choices:
                                delta = choices[0].get("delta", {})
                                delta_content = delta.get("content")
                                if delta_content:
                                    content += delta_content
                            if "timings" in data:
                                timings.update(data["timings"])
                            if "usage" in data:
                                usage.update(data["usage"])
                        except json.JSONDecodeError:
                            pass
        else:
            resp = requests.post(url, json=payload, timeout=timeout)
            resp.raise_for_status()
            data = resp.json()
            choices = data.get("choices", [])
            if choices:
                content = choices[0].get("message", {}).get("content", "")
            timings = data.get("timings", {})
            usage = data.get("usage", {})

    else:  # urllib fallback
        req_data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=req_data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        if stream:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                while True:
                    raw_line = resp.readline()
                    if not raw_line:
                        break
                    line = raw_line.decode("utf-8").strip()
                    if not line:
                        continue
                    if line.startswith("data: "):
                        data_str = line[6:].strip()
                        if data_str == "[DONE]":
                            break
                        try:
                            data = json.loads(data_str)
                            if ttft_ms is None:
                                ttft_ms = (time.monotonic() - t0) * 1000
                            choices = data.get("choices", [])
                            if choices:
                                delta = choices[0].get("delta", {})
                                delta_content = delta.get("content")
                                if delta_content:
                                    content += delta_content
                            if "timings" in data:
                                timings.update(data["timings"])
                            if "usage" in data:
                                usage.update(data["usage"])
                        except json.JSONDecodeError:
                            pass
        else:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                choices = data.get("choices", [])
                if choices:
                    content = choices[0].get("message", {}).get("content", "")
                timings = data.get("timings", {})
                usage = data.get("usage", {})

    total_wall_ms = (time.monotonic() - t0) * 1000
    if ttft_ms is None:
        ttft_ms = timings.get("prompt_ms", total_wall_ms)

    return content, ttft_ms, total_wall_ms, timings, usage


def extract_metrics(
    timings: Dict[str, Any], usage: Dict[str, Any], total_wall_ms: float, ttft_ms: Optional[float]
) -> Dict[str, Any]:
    """Normalize timing and token metrics from server payload."""
    prompt_n = timings.get("prompt_n", usage.get("prompt_tokens", 0))
    prompt_ms = timings.get("prompt_ms", 0.0)
    prompt_per_sec = timings.get("prompt_per_second", 0.0)

    predicted_n = timings.get("predicted_n", usage.get("completion_tokens", 0))
    predicted_ms = timings.get("predicted_ms", 0.0)
    predicted_per_sec = timings.get("predicted_per_second", 0.0)

    # cache_n can appear in timings or usage prompt_tokens_details
    cache_n = timings.get("cache_n")
    if cache_n is None:
        prompt_details = usage.get("prompt_tokens_details", {})
        cache_n = prompt_details.get("cached_tokens", 0)

    if prompt_per_sec == 0.0 and prompt_ms > 0 and prompt_n > 0:
        prompt_per_sec = prompt_n / (prompt_ms / 1000.0)

    if predicted_per_sec == 0.0 and predicted_ms > 0 and predicted_n > 0:
        predicted_per_sec = predicted_n / (predicted_ms / 1000.0)

    return {
        "wall_total_ms": round(total_wall_ms, 2),
        "wall_ttft_ms": round(ttft_ms, 2) if ttft_ms else round(prompt_ms, 2),
        "prompt_n": prompt_n,
        "prompt_ms": round(prompt_ms, 2),
        "prompt_per_second": round(prompt_per_sec, 2),
        "cache_n": cache_n,
        "predicted_n": predicted_n,
        "predicted_ms": round(predicted_ms, 2),
        "predicted_per_second": round(predicted_per_sec, 2),
    }


def run_agentic_benchmark(
    base_url: str,
    model: str,
    target_tokens: int = 3000,
    max_tokens: int = 256,
    temperature: float = 0.0,
    stream: bool = True,
    rounds: int = 1,
) -> Dict[str, Any]:
    """
    Execute 2-turn agentic benchmark verifying prompt caching & latency.
    """
    endpoint = base_url.rstrip("/")
    if not endpoint.endswith("/v1/chat/completions"):
        endpoint = f"{endpoint}/v1/chat/completions"

    system_prompt = generate_agent_system_prompt(target_tokens=target_tokens)
    user_turn_1 = "Analyze system disk usage, evaluate Longhorn iSCSI target health, and report any storage alerts."
    user_turn_2 = "Filter down the output to non-zero error counters and run the recommended cleanup commands."

    benchmark_rounds = []

    for r in range(1, rounds + 1):
        # -------------------------------------------------------------
        # Turn 1: System prompt + User Turn 1
        # -------------------------------------------------------------
        messages_turn_1 = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_turn_1},
        ]

        payload_1 = {
            "model": model,
            "messages": messages_turn_1,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        resp1_content, ttft1, wall1, timings1, usage1 = send_chat_completion(
            endpoint, payload_1, stream=stream
        )
        metrics_turn_1 = extract_metrics(timings1, usage1, wall1, ttft1)

        # -------------------------------------------------------------
        # Turn 2: Exact System prompt + User 1 + Assistant 1 + User 2
        # (Byte-for-byte identical prefix to guarantee cache hit eligibility)
        # -------------------------------------------------------------
        messages_turn_2 = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_turn_1},
            {"role": "assistant", "content": resp1_content},
            {"role": "user", "content": user_turn_2},
        ]

        payload_2 = {
            "model": model,
            "messages": messages_turn_2,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        resp2_content, ttft2, wall2, timings2, usage2 = send_chat_completion(
            endpoint, payload_2, stream=stream
        )
        metrics_turn_2 = extract_metrics(timings2, usage2, wall2, ttft2)

        cache_retained = metrics_turn_2["cache_n"] > 0
        speedup_prefill = (
            (metrics_turn_1["prompt_ms"] / metrics_turn_2["prompt_ms"])
            if metrics_turn_2["prompt_ms"] > 0
            else 0.0
        )
        speedup_ttft = (
            (metrics_turn_1["wall_ttft_ms"] / metrics_turn_2["wall_ttft_ms"])
            if metrics_turn_2["wall_ttft_ms"] > 0
            else 0.0
        )

        total_e2e_ms = metrics_turn_1["wall_total_ms"] + metrics_turn_2["wall_total_ms"]
        benchmark_rounds.append(
            {
                "round": r,
                "turn_1": metrics_turn_1,
                "turn_2": metrics_turn_2,
                "total_e2e_ms": round(total_e2e_ms, 2),
                "cache_retained": cache_retained,
                "prefill_speedup": round(speedup_prefill, 2),
                "ttft_speedup": round(speedup_ttft, 2),
            }
        )

    return {
        "model": model,
        "endpoint": endpoint,
        "http_client": HTTP_CLIENT,
        "stream": stream,
        "target_system_tokens": target_tokens,
        "rounds": benchmark_rounds,
    }


def print_formatted_report(results: Dict[str, Any]) -> None:
    print("\n" + "=" * 80)
    print(f" AGENTIC MULTI-TURN BENCHMARK REPORT: {results['model']}")
    print(f" Endpoint: {results['endpoint']} (client: {results['http_client']}, stream: {results['stream']})")
    print("=" * 80)

    for r_data in results["rounds"]:
        r = r_data["round"]
        t1 = r_data["turn_1"]
        t2 = r_data["turn_2"]
        cache_ok = r_data["cache_retained"]

        print(f"\n--- ROUND {r} ---")
        print(f"{'Metric':<25} | {'Turn 1 (Initial)':<22} | {'Turn 2 (Follow-up)':<22}")
        print("-" * 75)
        print(f"{'Wall Total Time':<25} | {t1['wall_total_ms']:>10.2f} ms         | {t2['wall_total_ms']:>10.2f} ms")
        print(f"{'Wall TTFT':<25} | {t1['wall_ttft_ms']:>10.2f} ms         | {t2['wall_ttft_ms']:>10.2f} ms")
        print(f"{'Prompt Evaluated (n)':<25} | {t1['prompt_n']:>10} tokens     | {t2['prompt_n']:>10} tokens")
        print(f"{'Prompt Cache Hit (cache_n)':<25} | {t1['cache_n']:>10} tokens     | {t2['cache_n']:>10} tokens")
        print(f"{'Prompt Time (prompt_ms)':<25} | {t1['prompt_ms']:>10.2f} ms         | {t2['prompt_ms']:>10.2f} ms")
        print(f"{'Prompt Speed (tok/s)':<25} | {t1['prompt_per_second']:>10.2f} tok/s      | {t2['prompt_per_second']:>10.2f} tok/s")
        print(f"{'Tokens Predicted (n)':<25} | {t1['predicted_n']:>10} tokens     | {t2['predicted_n']:>10} tokens")
        print(f"{'Generation Speed (tok/s)':<25} | {t1['predicted_per_second']:>10.2f} tok/s      | {t2['predicted_per_second']:>10.2f} tok/s")
        print("-" * 75)

        status_str = "SUCCESS (Retained)" if cache_ok else "FAILED / BROKEN (cache_n == 0)"
        print(f" Prefix Cache Status : [{status_str}]")
        print(f" TTFT Ratio (T1 / T2): {r_data['ttft_speedup']:.2f}x speedup on Turn 2")
        print(f" Prefill Time Ratio  : {r_data['prefill_speedup']:.2f}x speedup on Turn 2")
        print(f" Total E2E (Turn1+Turn2): {r_data['total_e2e_ms']:.2f} ms")

    print("\n" + "=" * 80)
    final_round = results["rounds"][-1]
    if final_round["cache_retained"]:
        print(" VERIFICATION: Prefix caching active and functional (cache_n > 0).")
    else:
        print(" ALERT: Prefix caching NOT functional (cache_n == 0).")
        print(" Root cause indicators:")
        print(" 1. Ensure server launched with `--cache-prompt` and `--cache-reuse 256`.")
        print(" 2. Ensure slot context is sufficiently sized (`-c 32768` or greater).")
        print(" 3. Verify single client contention or set `-np 1` / slot allocation.")
    print("=" * 80 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Agentic Multi-Turn Latency & Prefix Cache Benchmark"
    )
    parser.add_argument(
        "--base-url",
        default="http://localhost:8080",
        help="Base URL of llama-server (default: http://localhost:8080)",
    )
    parser.add_argument(
        "--model",
        default="default",
        help="Model name / alias (default: default)",
    )
    parser.add_argument(
        "--target-tokens",
        type=int,
        default=8000,
        help="Approximate token count for system prompt tools (default: 8000 for 60k+ context)",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=128,
        help="Max generation tokens per turn (default: 128)",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.0,
        help="Sampling temperature (default: 0.0 for deterministic evaluation)",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        default=True,
        help="Use streaming mode to capture TTFT accurately (default: True)",
    )
    parser.add_argument(
        "--no-stream",
        dest="stream",
        action="store_false",
        help="Disable streaming mode",
    )
    parser.add_argument(
        "--rounds",
        type=int,
        default=1,
        help="Number of sequential 2-turn rounds to run (default: 1)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON to stdout",
    )

    args = parser.parse_args()

    results = run_agentic_benchmark(
        base_url=args.base_url,
        model=args.model,
        target_tokens=args.target_tokens,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        stream=args.stream,
        rounds=args.rounds,
    )

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print_formatted_report(results)


if __name__ == "__main__":
    main()
