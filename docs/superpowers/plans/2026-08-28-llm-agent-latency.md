# LLM Agent Latency — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut end-to-end agent latency on llm01's local models (Ling-3.0-flash, Ornith-1.5-35B) by reducing per-request serving overhead, publishing an agent context policy, and formalizing model routing tiers — all encoded in a reusable NixOS module.

**Architecture:** Extract llm01's four inlined llama.cpp systemd units into `modules/nixos/llama-cpp-agent.nix` with typed options for serving flags, metrics collection, context policy, and multi-model routing via llama.cpp aliases. Baseline and post-change behavior is measured with `scripts/agent-benchmark.py` (TTFT, per-turn time, effective tps).

**Tech Stack:** NixOS modules (systemd units, tmpfiles, timers), llama.cpp `--models-preset` INI, Prometheus node_exporter textfile collector, `scripts/agent-benchmark.py`.

**Spec:** `docs/superpowers/specs/2026-08-28-llm-agent-latency-design.md`

## Global Constraints

- Port stays **8001**; service name stays `llama-cpp-server` (comin health gate + firewall depend on it).
- Keep `--cache-reuse 256` and `--load-mode mlock`. Never add `--no-mmap`.
- No speculative decoding for Ornith-1.5 (`modelDraft`/`spec-*` stay commented out for it). Ling-3.0-flash keeps `spec-type = draft-mtp`, `spec-draft-n-max = 2`.
- Alias changes are **additive only** — existing aliases (`default`, `opencode`, `hermes`, `multimodal`, `fast`, `4B`, …) must not change meaning.
- Per-model `extraProperties` values (including `cache-prompt = "false"` on large models) are untouched in this plan.
- Every task: `nixfmt .` clean and `nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace` green.
- `git add` new files **before** evaluating (untracked paths break flake eval).
- llm01 is a **canary host**: pushing to `main` auto-deploys. Commit locally on a branch; only the owner pushes/merges.
- No SSH from this environment. Steps marked **USER ACTION** run on llm01; the user runs them and pastes output.
- Working directory for all commands: repo root `/home/coder/nixos-configurations`.

---

### Task 1: Capture baseline benchmarks (evidence)

**Files:**
- Create: `docs/superpowers/evidence/2026-08-28-baseline-ling30flash.json`
- Create: `docs/superpowers/evidence/2026-08-28-baseline-ornith15.json`

**Interfaces:**
- Consumes: `scripts/agent-benchmark.py`, llama.cpp server on port 8001.
- Produces: two baseline JSON files every later task compares against.

- [ ] **Step 1: Install benchmark dependency**

```bash
pip3 install aiohttp
```

- [ ] **Step 2: Verify the llama.cpp endpoint is reachable**

```bash
curl -fsS --max-time 5 http://localhost:8001/health && echo OK
```

Expected: `{"status":"ok"}` or similar. **If this fails, this workspace is not llm01 — hand Steps 3–5 to the owner as a USER ACTION with the exact commands below and have them paste the JSON output back to save as the evidence files.**

- [ ] **Step 3: Run baseline for Ling-3.0-flash**

```bash
python3 scripts/agent-benchmark.py \
  --model llama.cpp --base-url http://localhost:8001 \
  --model-name "Ling-3.0-flash" --rounds 10 --turns-per-round 5 --json \
  > docs/superpowers/evidence/2026-08-28-baseline-ling30flash.json
```

- [ ] **Step 4: Run baseline for Ornith-1.5-35B**

```bash
python3 scripts/agent-benchmark.py \
  --model llama.cpp --base-url http://localhost:8001 \
  --model-name "Ornith-1.5-35B" --rounds 10 --turns-per-round 5 \
  --json > docs/superpowers/evidence/2026-08-28-baseline-ornith15.json
```

- [ ] **Step 5: Sanity-check the JSON has the key metrics**

```bash
jq '{ttft_p50_ms, total_p50_ms, effective_tps_p50}' docs/superpowers/evidence/2026-08-28-baseline-ling30flash.json
```

Expected: three numeric fields, TTFT > 0. Note in the evidence file (add a top-level `"caveat"` key) that `effective_tps` counts characters, not tokens — valid for A/B comparison, not absolute.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/evidence/2026-08-28-baseline-*.json
git commit -m "chore: baseline agent-latency benchmarks for Ling-3.0-flash and Ornith-1.5-35B"
```

---

### Task 2: Create the `llama-cpp-agent` module

**Files:**
- Create: `modules/nixos/llama-cpp-agent.nix`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - Option namespace `services.llamaCppAgent` with `enable`, `package` (types.package, **required**, no default), `listen.{host,port}`, `stateDir`, `user`, `group`, `environment` (attrsOf str), `serverArgs` (listOf str, Layer-1 defaults), `models` (attrsOf submodule with fields `modelId`, `filename`, `mmproj`, `mmprojModelId`, `modelDraft`, `modelDraftModelId` (all nullable str) and `extraProperties` (attrsOf str)), `metrics.enable`, `metrics.textfileDir`, `contextPolicy.{maxHistoryTurns,summarizeAfterTurns,systemPromptCache,batchToolCalls}`.
  - systemd units `llama-cpp-server.service`, `llama-cpp-config.service`, `llama-cpp-download-models.service`, `llama-cpp-metrics.service` + `llama-cpp-metrics.timer`, `llama-cpp-config-watch.path`.
  - `/etc/llm-agent/context-policy.json` and helper binary `llm-agent-policy`.
  - Firewall port opened for `listen.port`.

- [ ] **Step 1: Write the module**

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llamaCppAgent;
  modelType = {
    options = {
      modelId = lib.mkOption {
        type = lib.types.str;
        description = "HuggingFace repo id";
      };
      filename = lib.mkOption {
        type = lib.types.str;
        description = "GGUF filename (or first shard of a split model)";
      };
      mmproj = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      mmprojModelId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      modelDraft = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      modelDraftModelId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      extraProperties = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };
  };
in
{
  options.services.llamaCppAgent = {
    enable = lib.mkEnableOption "llama.cpp agent serving stack (server, model download, config generation, metrics)";

    package = lib.mkOption {
      type = lib.types.package;
      description = "llama.cpp package to run (host passes e.g. llamaPkgs.vulkan)";
    };

    listen.host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
    };
    listen.port = lib.mkOption {
      type = lib.types.port;
      default = 8001;
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/opt/llm";
      description = "Model + config root; INI lands at <stateDir>/llama-cpp.ini";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "ollama";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "ollama";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        # coopmat FA shader path is buggy/slow on gfx1151 (Strix Halo) at deep
        # context; scalar FA is still much faster than FA-off.
        GGML_VK_DISABLE_COOPMAT = "1";
        # Explicitly bind to the 8060S APU
        GGML_VK_VISIBLE_DEVICES = "0";
        # Keep the KV cache inside the GTT partition (no spill)
        RADV_PERFTEST = "nogttspill";
      };
      description = "Extra environment vars for llama-cpp-server";
    };

    serverArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--offline"
        "-ngl 99"
        # Vulkan does the math on the APU; extra CPU threads only add stalls
        "--threads 1"
        "--threads-batch 1"
        "--log-verbosity 2"
        "--load-mode mlock"
        "--flash-attn on"
        "--ctx-checkpoints 0"
        "--fit on"
        "--cont-batching"
        "--cache-prompt"
        "--cache-reuse 256"
        "--metrics"
      ];
      description = "llama-server flags appended after the port/host/preset flags";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule modelType);
      default = { };
      description = "Model presets; keys become INI sections and API model names";
    };

    metrics.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    metrics.textfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter/textfiles";
    };

    contextPolicy = {
      maxHistoryTurns = lib.mkOption {
        type = lib.types.int;
        default = 20;
        description = "Never re-inject more raw history turns than this";
      };
      summarizeAfterTurns = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Compact raw turns into a summary after this many";
      };
      systemPromptCache = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      batchToolCalls = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.listen.port ];

    systemd.tmpfiles.rules =
      [
        "d ${cfg.stateDir} 0755 ${cfg.user} ${cfg.group} -"
        "d ${cfg.stateDir}/models 0755 ${cfg.user} ${cfg.group} -"
        "d ${cfg.stateDir}/models/llama-cpp 0755 ${cfg.user} ${cfg.group} -"
        "Z ${cfg.stateDir} - ${cfg.user} ${cfg.group} -"
      ]
      ++ lib.optionals cfg.metrics.enable [
        "d ${cfg.metrics.textfileDir} 0755 root root -"
      ];

    # Download llama.cpp models from HuggingFace
    systemd.services.llama-cpp-download-models = {
      description = "llama.cpp: download models from HuggingFace";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      restartTriggers = [ (builtins.toJSON cfg.models) ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "${cfg.stateDir}/models/llama-cpp";
        ReadWritePaths = [ "${cfg.stateDir}/models/llama-cpp" ];
        Environment = [
          "HOME=${cfg.stateDir}/models"
          "XDG_CACHE_HOME=${cfg.stateDir}/models/.cache"
        ];
        PrivateTmp = false;
        NoNewPrivileges = false;
        ExecStart = pkgs.writeShellScript "download-models" ''
          ${lib.concatStrings (
            lib.mapAttrsToList (
              entry-name: m:
              let
                modelId = m.modelId;
                mmprojModelId = if m.mmprojModelId != null then m.mmprojModelId else modelId;
                filename = m.filename;
                mmproj = m.mmproj;
                modelDraft = m.modelDraft;
                modelDraftModelId =
                  if m.modelDraftModelId != null then m.modelDraftModelId else modelId;
                matchSplit = builtins.match "(.*)-[0-9]+-of-[0-9]+\\.gguf" filename;
                downloadArgs =
                  if matchSplit != null then
                    "--include ${builtins.head matchSplit}-*-of-*.gguf"
                  else
                    "\"${filename}\"";
              in
              ''
                echo "Downloading ${entry-name} from ${modelId}..."
                ${pkgs.python3Packages.huggingface-hub}/bin/hf download "${modelId}" ${downloadArgs} --local-dir ${cfg.stateDir}/models/llama-cpp --repo-type model
                ${lib.optionalString (mmproj != null) ''
                  echo "Downloading mmproj for ${entry-name}..."
                  ${pkgs.python3Packages.huggingface-hub}/bin/hf download "${mmprojModelId}" "${mmproj}" --local-dir ${cfg.stateDir}/models/llama-cpp --repo-type model
                ''}
                ${lib.optionalString (modelDraft != null) ''
                  echo "Downloading model-draft for ${entry-name}..."
                  ${pkgs.python3Packages.huggingface-hub}/bin/hf download "${modelDraftModelId}" "${modelDraft}" --local-dir ${cfg.stateDir}/models/llama-cpp --repo-type model
                ''}
              ''
            ) cfg.models
          )}
        '';
      };
    };

    # Generate llama.cpp models-preset INI
    systemd.services.llama-cpp-config = {
      description = "llama.cpp: generate models-preset INI";
      wantedBy = [ "multi-user.target" ];
      after = [ "llama-cpp-download-models.service" ];
      requires = [ "llama-cpp-download-models.service" ];
      restartTriggers = [ (builtins.toJSON cfg.models) ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = pkgs.writeShellScript "generate-config" ''
          cat > ${cfg.stateDir}/llama-cpp.ini <<EOF
          ${lib.concatStrings (
            lib.mapAttrsToList (
              entry-name: m:
              let
                extraProperties = m.extraProperties;
              in
              ''
                [${entry-name}]
                model = ${cfg.stateDir}/models/llama-cpp/${m.filename}
                ${lib.optionalString (m.mmproj != null) "mmproj = ${cfg.stateDir}/models/llama-cpp/${m.mmproj}"}
                ${lib.optionalString (m.modelDraft != null) "model-draft = ${cfg.stateDir}/models/llama-cpp/${m.modelDraft}"}
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "${key} = ${value}") extraProperties)}
              ''
            ) cfg.models
          )}
          EOF
        '';
      };
    };

    # llama.cpp server
    systemd.services.llama-cpp-server = {
      description = "llama.cpp server (agent serving stack)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "llama-cpp-config.service"
      ];
      requires = [ "llama-cpp-config.service" ];
      restartTriggers = [ (builtins.toJSON cfg.models) ];
      environment = cfg.environment // {
        XDG_CACHE_HOME = "/var/cache/llama.cpp";
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        LimitMEMLOCK = "infinity";
        WorkingDirectory = "${cfg.stateDir}/models";
        CacheDirectory = "llama.cpp";
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/llama-server"
            "--port ${toString cfg.listen.port}"
            "--host ${cfg.listen.host}"
            "--models-preset ${cfg.stateDir}/llama-cpp.ini"
          ]
          ++ cfg.serverArgs
        );
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.paths.llama-cpp-config-watch = {
      description = "Watch llama.cpp models-preset INI for changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = "${cfg.stateDir}/llama-cpp.ini";
        Unit = "llama-cpp-server.service";
      };
    };

    # Scrape llama-server /metrics into the node_exporter textfile dir so
    # cluster Prometheus picks up cache/reuse series (spec: Layer 1 instrumentation)
    systemd.services.llama-cpp-metrics = lib.mkIf cfg.metrics.enable {
      description = "Scrape llama.cpp Prometheus metrics into textfile collector dir";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "llama-cpp-metrics" ''
          set -euo pipefail
          tmp=$(${pkgs.coreutils}/bin/mktemp)
          trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
          if ${pkgs.curl}/bin/curl -fsS --max-time 10 \
              "http://127.0.0.1:${toString cfg.listen.port}/metrics" -o "$tmp"; then
            ${pkgs.coreutils}/bin/mv "$tmp" "${cfg.metrics.textfileDir}/llama-cpp.prom"
          else
            echo "llama.cpp metrics scrape failed" >&2
            exit 1
          fi
        '';
      };
    };

    systemd.timers.llama-cpp-metrics = lib.mkIf cfg.metrics.enable {
      description = "Periodically scrape llama.cpp metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "60s";
        OnUnitActiveSec = "60s";
        AccuracySec = "5s";
      };
    };

    # Layer 2: agent-side context policy contract
    environment.etc."llm-agent/context-policy.json".text = builtins.toJSON {
      inherit (cfg.contextPolicy)
        maxHistoryTurns
        summarizeAfterTurns
        systemPromptCache
        batchToolCalls
        ;
    };
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "llm-agent-policy" ''
        cat /etc/llm-agent/context-policy.json
      '')
    ];
  };
}
```

- [ ] **Step 2: Format**

```bash
nixfmt modules/nixos/llama-cpp-agent.nix
```

- [ ] **Step 3: Sanity-eval the module file standalone**

```bash
nix-instantiate --parse modules/nixos/llama-cpp-agent.nix >/dev/null && echo "parse OK"
```

- [ ] **Step 4: Commit**

```bash
git add modules/nixos/llama-cpp-agent.nix
git commit -m "feat: add llama-cpp-agent module (serving flags, metrics, context policy, model options)"
```

---

### Task 3: Rewire `hosts/llm01/configuration.nix` onto the module

**Files:**
- Modify: `hosts/llm01/configuration.nix`

**Interfaces:**
- Consumes: `services.llamaCppAgent.*` options from Task 2; `llamaPkgs` specialArg.
- Produces: identical runtime behavior (same unit names, port 8001, same INI), now option-driven. The comin health gate `llama-cpp` check continues to pass unchanged.

- [ ] **Step 1: Add the module import**

In the `imports` list (after `../../modules/nixos/openiscsi.nix`):

```nix
    ../../modules/nixos/llama-cpp-agent.nix
```

- [ ] **Step 2: Delete the inlined llama.cpp blocks from `hosts/llm01/configuration.nix`**

Remove: `systemd.services.llama-cpp-server`, `systemd.paths.llama-cpp-config-watch`, the four `/opt/llm` tmpfiles rules, `systemd.services.llama-cpp-download-models`, `systemd.services.llama-cpp-config`, and `networking.firewall.allowedTCPPorts = [ 8001 ];` (the module now opens the port). Keep `users.users.ollama`, `users.groups.ollama`, kernel params, and everything else.

- [ ] **Step 3: Add the option assignments (replacing the deleted blocks)**

```nix
  # llama.cpp serving stack (options in modules/nixos/llama-cpp-agent.nix)
  services.llamaCppAgent = {
    enable = true;
    package = llamaPkgs.vulkan;
    models = import ./llm-models.nix;
  };
```

Also remove the now-unused `let models = import ./llm-models.nix; llamaPackage = llamaPkgs.vulkan;` bindings (line 143's `llamaPkgs.vulkan` systemPackages entry stays).

- [ ] **Step 4: Format and evaluate**

```bash
nixfmt .
git add -A
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
```

Expected: eval succeeds (prints a store path). If `llama-cpp.ini` path or unit names diverge from the deleted inline versions, fix before continuing.

- [ ] **Step 5: Verify unit names survive (health-gate dependency)**

```bash
nix eval --json .#nixosConfigurations.llm01.config.systemd.services.llama-cpp-server.serviceConfig.ExecStart | jq -r .
```

Expected: a command string starting with the llama-server path, containing `--port 8001` and `--models-preset /opt/llm/llama-cpp.ini`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(llm01): move llama.cpp services into reusable llama-cpp-agent module"
```

---

### Task 4: Layer 1 — serving flag tuning

**Files:**
- Modify: `hosts/llm01/configuration.nix` (serverArgs override only)
- Create: `docs/superpowers/evidence/2026-08-28-ctx-cache-retention-check.txt`

**Interfaces:**
- Consumes: `services.llamaCppAgent.serverArgs` (typed list from Task 2 — appends merge with the default list).
- Produces: final llama-server flag set.

- [ ] **Step 1: Verify `--ctx-cache-retention` exists on the pinned build**

This workspace may be llm01 itself — try locally first:

```bash
llama-server --help 2>&1 | grep -i "cache-retention" || echo "NOT-FOUND-LOCALLY"
```

If `NOT-FOUND-LOCALLY` (**USER ACTION**, run on llm01 and paste output):

```bash
/run/current-system/sw/bin/llama-server --help 2>&1 | grep -i "cache-retention"
```

- [ ] **Step 2: Enable the flag only if verified**

If found, add to `hosts/llm01/configuration.nix` inside the `services.llamaCppAgent` block:

```nix
    serverArgs = [ "--ctx-cache-retention" ];
```

If not found on b10649: do NOT add the flag; write the check output into the evidence file with a note "flag absent on b10649 — skipped (spec permits)". Either way create the evidence file.

- [ ] **Step 3: Format, evaluate, commit**

```bash
nixfmt . && git add -A
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
git commit -m "feat(llm01): retain per-slot context caches across agent turns"
```

(If flag unsupported, commit message: `chore(llm01): record ctx-cache-retention unsupported on b10649`.)

---

### Task 5: Layer 1 instrumentation — cache/reuse metric series

**Files:**
- Create: `docs/superpowers/evidence/2026-08-28-llama-cache-metrics.txt`

**Interfaces:**
- Consumes: llama-server `--metrics` (running) + `llama-cpp-metrics.timer` (Task 2).
- Produces: recorded list of cache-related series names (used later for a Grafana panel; out of scope here).

- [ ] **Step 1: Discover cache-related series** (**USER ACTION** if not local)

```bash
curl -s http://localhost:8001/metrics | grep -iE "cache|reuse|prompt" | sort -u \
  > docs/superpowers/evidence/2026-08-28-llama-cache-metrics.txt
cat docs/superpowers/evidence/2026-08-28-llama-cache-metrics.txt
```

- [ ] **Step 2: Verify the textfile collector publishes them after deploy**

After Task 3's switch on llm01 (owner-run):

```bash
head -5 /var/lib/node-exporter/textfiles/llama-cpp.prom
```

Expected: llama-server metrics lines. Record output in the same evidence file. Commit evidence.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/evidence/2026-08-28-llama-cache-metrics.txt
git commit -m "docs: record llama.cpp cache metric series names"
```

---

### Task 6: Layer 1+3 — context sizing, parallelism, and routing tier aliases in `llm-models.nix`

**Files:**
- Modify: `hosts/llm01/llm-models.nix`

**Interfaces:**
- Consumes: llama.cpp per-model `alias` property (already supported by the INI generator — `extraProperties` pass-through).
- Produces: tier aliases `agent-fast` (small), `agent` (Ling), `agent-quality` (Ornith); 100k context + `parallel 2` + `cont-batching`/`ctx-shift` on the large models. Clients route by setting `model` to the alias.

- [ ] **Step 1: Apply the alias edits**

- `"Qwen3.5-2B"` → add to `extraProperties`: `"alias" = "agent-fast";`
- `"Qwen3.5-4B"` → change `"alias" = "Qwen-3.5-4B,fast,4B";` to `"alias" = "Qwen-3.5-4B,fast,4B,agent-fast";`
- `"Mellum-4B"` → add to `extraProperties`: `"alias" = "mellum,agent-fast";`
- `"Ling-3.0-flash"` → change `"alias" = "Ling-3.0,opencode,hermes,quality,slow";` to `"alias" = "Ling-3.0,opencode,hermes,quality,slow,agent";`
- `"Ornith-1.5-35B"` → change `"alias" = "default,ornith-current,multimodal";` to `"alias" = "default,ornith-current,multimodal,agent-quality";`

- [ ] **Step 2: Apply the context/parallelism edits (spec: 100k + parallel 2 + ctx-shift)**

- `"Ornith-1.5-35B"`:
  - `"ctx-size" = "131072";` → `"ctx-size" = "102400";`
  - `"parallel" = "1";` → `"parallel" = "2";`
  - add to `extraProperties`: `"cont-batching" = "true";` and `"ctx-shift" = "true";`
- `"Ling-3.0-flash"`: same four changes (`ctx-size` 131072 → 102400, `parallel` → `2`, plus `cont-batching`/`ctx-shift` true).
- Leave the small models (`Qwen3.5-2B`, `Qwen3.5-4B`, `Mellum-4B`) untouched — their ctx sizes are already appropriate.

- [ ] **Step 3: Format, evaluate, commit**

```bash
nixfmt . && git add -A
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
git commit -m "feat(llm01): 100k context, parallel 2, cont-batching + ctx-shift on large models, agent tier aliases"
```

---

### Task 7 (optional): Qwen3.8-27B `agent-quality` decision gate

**Files:**
- Modify: `hosts/llm01/llm-models.nix`
- Create: `docs/superpowers/evidence/2026-08-28-qwen38-27b-benchmark.json`

**Interfaces:**
- Consumes: benchmark harness from Task 1.
- Produces: owner decision — keep Ornith-1.5-35B or swap in Qwen3.8-27B for the `agent-quality` tier.

- [ ] **Step 1: Uncomment the `Qwen3.8-27B` block** in `hosts/llm01/llm-models.nix`, matching the current large-model sizing: change `"ctx-size" = "131072";` to `"ctx-size" = "102400";`, `"parallel" = "1";` to `"parallel" = "2";`, and add `"cont-batching" = "true";` plus `"ctx-shift" = "true";` to the uncommented block (keep the rest of the commented values as-is).

- [ ] **Step 2: Evaluate and commit**

```bash
nixfmt . && git add -A
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
git commit -m "feat(llm01): stage Qwen3.8-27B as agent-quality candidate"
```

**USER ACTION (owner):** let comin deploy to llm01 (canary, auto). After models download and server warms up, run:

```bash
python3 scripts/agent-benchmark.py --model llama.cpp \
  --base-url http://localhost:8001 --model-name "Qwen3.8-27B" \
  --rounds 10 --turns-per-round 5 --json \
  > docs/superpowers/evidence/2026-08-28-qwen38-27b-benchmark.json
```

- [ ] **Step 3: Compare against the Ornith baseline** (p50 TTFT, effective tps, total p95). Owner decides swap or revert; record the decision in the evidence JSON's `caveat` field and commit. **If the swap wins:** change Ornith's `alias` from `default,ornith-current,multimodal,agent-quality` to `ornith-1.5,multimodal,agent-quality` and move `agent-quality` to Qwen3.8-27B's alias list.

---

### Task 8: Post-change benchmark + evidence summary

**Files:**
- Create: `docs/superpowers/evidence/2026-08-28-postchange-*.json` and `2026-08-28-latency-summary.md`

**Interfaces:**
- Consumes: baseline files from Task 1; deployed llm01.

- [ ] **Step 1: Re-run both model benchmarks** exactly as Task 1, saving to `docs/superpowers/evidence/2026-08-28-postchange-{ling30flash,ornith15}.json`.

- [ ] **Step 2: Write the comparison summary**

`docs/superpowers/evidence/2026-08-28-latency-summary.md`: table of baseline vs post-change (TTFT p50/p95, total p50/p95, effective tps p50) for both models; verdict per metric (better/worse/equal).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/evidence/
git commit -m "docs: post-change agent latency benchmarks vs baseline"
```

---

### Task 9: Document the pattern

**Files:**
- Modify: `hosts/llm01/README.md`

**Interfaces:**
- Consumes: final module + aliases.
- Produces: doc for the next host adopting the pattern.

- [ ] **Step 1: Add a "Model routing tiers" section** to `hosts/llm01/README.md` containing the tier table from the spec, the `context-policy.json` field meanings, and an example `services.llamaCppAgent` block (copy the one now in `configuration.nix`).

- [ ] **Step 2: Commit**

```bash
git add hosts/llm01/README.md
git commit -m "docs(llm01): document agent routing tiers and context policy"
```

---

## Deployment Notes (owner)

- Work happens on a branch; **llm01 is a canary** — pushing to `main` auto-deploys. Merge only after Tasks 1–6 eval green and the owner is ready.
- The comin health gate checks `llama-cpp` with a 50-minute warmup; a bad flag that prevents startup rolls back automatically.
- `--ctx-cache-retention` (Task 4) triggers a llama-server restart; schedule away from active agent sessions.
