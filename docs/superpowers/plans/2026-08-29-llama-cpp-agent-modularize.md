# llama-cpp-agent Module Modularization Plan

> Status: planned (not started — need user confirm after Config A benchmark verified)

## Problem
`modules/nixos/llama-cpp-agent.nix` is 348 lines monolithic: model preset submodule, 4 systemd units (download/config/server/metrics+timer), tmpfiles, firewall, environment (hardcoded gfx1151/Strix Halo vars), serverArgs mix of layer-1 + layer-2 flags.

## Goal
Split into composable submodules; remove hardware lock-in; allow host-level flag override without editing module.

## File Split

| New File | Source Lines | Content |
|---|---|---|
| `modules/nixos/llama-cpp/model-preset.nix` | 9-40 + download/config services | `modelType` submodule + download + config + INI generation |
| `modules/nixos/llama-cpp/server.nix` | 351-383 (systemd service) + args/options | `llama-cpp-server` systemd + `serverArgs`, `listen`, `threads` |
| `modules/nixos/llama-cpp/metrics.nix` | 395-413 + timer | Scrape + timer + textfile collector; independent import possible |
| `modules/nixos/llama-cpp/agent.nix` | Option namespace + imports | Entry point importing above; keeps `services.llamaCppAgent` namespace |

## Changes to Host
- `hosts/llm01/configuration.nix`: replace single module import with imports + `services.llamaCppAgent` option assignments (already done; just adjust to new paths)
- Move `GGML_VK_DISABLE_COOPMAT`, `RADV_PERFTEST`, `GGML_VK_VISIBLE_DEVICES` from module `environment` default into `hosts/llm01/configuration.nix` or `vars.nix`

## Option Refactors
- Separate `baseServerArgs` (layer-1: `--offline`, `--fit`, `--load-mode mlock`) from `agentTuneArgs` (`--cache-reuse 256`, `--cache-prompt`) — allows A/B testing via host override only
- Make `environment` default `{}`; host passes Strix Halo vars explicitly

## Verification Criteria
- `nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace` green
- `nixfmt .` clean
- Benchmark Config A (`-c 65536 -np 1`) still yields `cache_n > 0` after split
- Module parse OK: `nix-instantiate --parse modules/nixos/llama-cpp/agent.nix`

## Dependencies / Order
1. Create submodule files (no dependency loop; download depends on preset, server depends on config)
2. Rewrite `agent.nix` to import in order: preset → download → config → server → metrics
3. Update `configure.nix` imports + move env vars
4. Format + eval + commit
