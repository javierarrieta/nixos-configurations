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
      default = { };
      description = "Host-specific GPU/driver env (e.g. Strix Halo vars)";
    };

    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "llama-server --threads (generation threads). Vulkan does the math on the APU; keep low to avoid stalls.";
    };

    threadsBatch = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "llama-server --threads-batch (prompt ingestion threads).";
    };

    serverArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--offline"
        "-ngl 99"
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

    extraServerArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional llama-server flags appended after serverArgs";
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

    systemd.tmpfiles.rules = [
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
                modelDraftModelId = if m.modelDraftModelId != null then m.modelDraftModelId else modelId;
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
                ${lib.optionalString (
                  m.modelDraft != null
                ) "model-draft = ${cfg.stateDir}/models/llama-cpp/${m.modelDraft}"}
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
            "--threads ${toString cfg.threads}"
            "--threads-batch ${toString cfg.threadsBatch}"
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
      after = [ "llama-cpp-server.service" ];
      requires = [ "llama-cpp-server.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "llama-cpp-metrics" ''
          set -euo pipefail
          port="${toString cfg.listen.port}"
          url="http://127.0.0.1:$port"

          # Fetch loaded model IDs from the OpenAI-compatible models endpoint
          models_json=$(${pkgs.curl}/bin/curl -fsS --max-time 10 "$url/v1/models") \
            || { echo "llama.cpp models fetch failed" >&2; exit 1; }

          model_ids=$(echo "$models_json" | ${pkgs.jq}/bin/jq -r '.data[].id') \
            || { echo "llama.cpp models parse failed" >&2; exit 1; }

          if [ -z "$model_ids" ]; then
            echo "no loaded models, skipping metrics scrape" >&2
            exit 0
          fi

          out="${cfg.metrics.textfileDir}/llama-cpp.prom"
          tmp=$(${pkgs.coreutils}/bin/mktemp)
          trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

          # Scrape per-model metrics; deduplicate HELP/TYPE headers with awk
          first=true
          for model_id in $model_ids; do
            if ${pkgs.curl}/bin/curl -fsS --max-time 10 \
                "$url/metrics?model=$model_id" -o "$tmp"; then
              if $first; then
                ${pkgs.coreutils}/bin/cat "$tmp" > "$out"
                first=false
              else
                ${pkgs.coreutils}/bin/cat "$tmp" | ${pkgs.gawk}/bin/awk '
                  /^# (HELP|TYPE) / { if (!seen[$0]++) print; next }
                  { print }
                ' >> "$out"
              fi
            else
              echo "llama.cpp metrics scrape failed for model $model_id" >&2
            fi
          done
        '';
      };
    };

    systemd.timers.llama-cpp-metrics = lib.mkIf cfg.metrics.enable {
      description = "Periodically scrape llama.cpp metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "300s";
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
