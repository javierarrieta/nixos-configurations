# LLM Benchmark History

## Model Configurations

| Model | Params | Quant | ctx | cache-type-k/v | cache-reuse | mmproj | ubatch | Config Commit |
|-------|--------|-------|-----|----------------|-------------|--------|--------|---------------|
| Ling-3.0-flash | 124B (5.1B active MoE) | IQ4_XS | 80000 | q8_0/q8_0 | — (KDA) | no | 1024 | `5aca294` |
| Ornith-1.5-35B | 35B (3B active MoE) | Q6_K | 80000 | q8_0/q8_0 | 1024 | yes (BF16) | 1024 | `c8a0313` |
| Ornith-1.5-35B-Text | 35B (3B active MoE) | Q6_K | 80000 | q8_0/q8_0 | 1024 | no | 1024 | `c8a0313` |
| Qwen3.8-27B | 27B dense | Q4_K_M | 80000 | q8_0/q8_0 | 1024 | no | 1024 | `c8a0313` |
| Qwen3.8-27B | 27B dense | Q6_K | 80000 | q8_0/q8_0 | 1024 | no | 1024 | `a40dcf1` |
| Qwen3.5-4B | 4B | Q4_K_M | 80000 | q8_0/q8_0 | 256 | no | 1024 | `c8a0313` |

## Cache Benchmark Results (2-turn, 8k target tokens)

| Date | Model | Config Commit | Prefill tok/s | Cache Speedup | TTFT Speedup | Cache Retained |
|------|-------|---------------|---------------|---------------|--------------|----------------|
| 2026-08-28 | Ling-3.0-flash | `01c0177` | 348 | 0x | 0x | no (KDA) |
| 2026-08-28 | Ornith-1.5-35B | `01c0177` | 889 | 28.5x | 27.3x | yes |
| 2026-08-30 | Qwen3.8-27B Q6_K | `a40dcf1` | 166 | 15.4x | 15.6x | yes |
| 2026-09-01 | Ornith-1.5-35B (mmproj) | `c8a0313` | 376 | 2.0x | 2.0x | no |
| 2026-09-01 | Ornith-1.5-35B-Text | `c8a0313` | 905 | 28.9x | 27.2x | yes |
| 2026-09-01 | Qwen3.8-27B Q4_K_M | `c8a0313` | 155 | 26.1x | 25.8x | yes |

## Agent Benchmark Results (8 turns, ~7k system prompt, cache-hit mode)

| Date | Model | Config Commit | TTFT p50 | TTFT p95 | Eff Tps p50 | Token Lat p50 |
|------|-------|---------------|----------|----------|-------------|---------------|
| 2026-08-28 | Ling-3.0-flash | `01c0177` | 11.8s | 14.5s | 4.1 | 24.4ms |
| 2026-08-28 | Ornith-1.5-35B | `01c0177` | 12.0s | 15.2s | 4.1 | 24.4ms |
| 2026-08-30 | Qwen3.8-27B Q6_K | `a40dcf1` | 60.0s | 79.4s | 0.8 | 108.6ms |
| 2026-09-01 | Ornith-1.5-35B (mmproj) | `c8a0313` | 14.0s | 18.9s | 3.1 | 19.7ms |
| 2026-09-01 | Ornith-1.5-35B-Text | `c8a0313` | 14.7s | 18.4s | 4.3 | 19.7ms |
| 2026-09-01 | Qwen3.8-27B Q4_K_M | `c8a0313` | 65.2s | 85.9s | 0.7 | 82.6ms |

## Key Findings

1. **Ling-3.0-flash KDA architecture**: `cache_reuse` fundamentally incompatible (`llama_memory_can_shift` returns false). Context checkpoints (`--ctx-checkpoints`) don't help — TTFT scales linearly with message count.

2. **Ornith with mmproj**: multimodal projector disables cache_reuse at server level (`server-context.cpp:1179`). Use `Ornith-1.5-35B-Text` (no mmproj) for text agents.

3. **Qwen3.8-27B**: 4-5x slower than Ornith across all metrics regardless of quantization (Q6_K vs Q4_K_M). Dense 27B architecture bottlenecked by memory bandwidth.

4. **ubatch-size 1024 vs 4096**: 4096 caused 3-7% TTFT regression and 13% prefill regression on this APU. Reverted to 1024.

5. **Agent benchmark TTFT scales linearly** because it varies task content each turn, invalidating prefix cache. Real agent use with stable system prompt prefix gets the full cache benefit.
