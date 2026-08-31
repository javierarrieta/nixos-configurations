{
  "Qwen3.5-2B" = {
    modelId = "unsloth/Qwen3.5-2B-GGUF";
    filename = "Qwen3.5-2B-Q4_K_M.gguf";
    extraProperties = {
      "alias" = "Qwen-3.5-2B";
      "flash-attn" = "on";
      "ctx-size" = "8192";
      "reasoning-budget" = "-1";
      "temp" = "0.7";
      "top-k" = "100";
      "top-p" = "0.80";
      "min-p" = "0.0";
      "repeat-penalty" = "1.0";
      "chat-template-kwargs" = "{\"enable_thinking\": false}";
    };
  };
  "Qwen3.5-4B" = {
    modelId = "unsloth/Qwen3.5-4B-GGUF";
    filename = "Qwen3.5-4B-Q4_K_M.gguf";
    extraProperties = {
      "alias" = "Qwen-3.5-4B,fast,4B,agent-fast";
      "parallel" = "1";
      "flash-attn" = "on";
      "ctx-size" = "80000";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
      "batch-size" = "4096";
      "ubatch-size" = "1024";
      "cache-prompt" = "true";
      "cache-reuse" = "256";
    };
  };
  "Mellum-4B" = {
    modelId = "mradermacher/Mellum-4b-base-GGUF";
    filename = "Mellum-4b-base.Q4_K_M.gguf";
    extraProperties = {
      "alias" = "mellum";
      "flash-attn" = "on";
      "ctx-size" = "8192";
      "n-predict" = "128";
      "temp" = "0.0";
      "top-k" = "1";
      "top-p" = "1.0";
      "min-p" = "0.0";
      "repeat-penalty" = "1.0";
      "cache-prompt" = "true";
      "cache-reuse" = "1024";
    };
  };

  # ── Ornith variants ──────────────────────────────────────────────
  # With multimodal projector (image input). cache_reuse disabled by
  # server when mmproj is loaded — no prefix caching benefit.
  "Ornith-1.5-35B" = {
    modelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
    filename = "Ornith-1.5-35B-Q6_K.gguf";
    mmprojModelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
    mmproj = "mmproj-Ornith-1.5-35B-BF16.gguf";
    extraProperties = {
      "alias" = "default,ornith,multimodal,agent,hermes,opencode";
      "flash-attn" = "on";
      "ctx-size" = "80000";
      "parallel" = "1";
      "cont-batching" = "true";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
      "temperature" = "0.6";
      "top-p" = "0.95";
      "top-k" = "20";
      "min-p" = "0.0";
      "presence-penalty" = "0.0";
      "repeat-penalty" = "1.0";
      "batch-size" = "4096";
      "ubatch-size" = "1024";
      "load-mode" = "mlock";
      "image-min-tokens" = "1024";
      "cache-prompt" = "false";
    };
  };
  # Text-only (no mmproj) — cache_reuse enabled for prefix caching.
  "Ornith-1.5-35B-Text" = {
    modelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
    filename = "Ornith-1.5-35B-Q6_K.gguf";
    extraProperties = {
      "alias" = "ornith-text,cache,quality";
      "flash-attn" = "on";
      "ctx-size" = "80000";
      "parallel" = "1";
      "cont-batching" = "true";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
      "temperature" = "0.6";
      "top-p" = "0.95";
      "top-k" = "20";
      "min-p" = "0.0";
      "presence-penalty" = "0.0";
      "repeat-penalty" = "1.0";
      "batch-size" = "4096";
      "ubatch-size" = "1024";
      "load-mode" = "mlock";
      "cache-prompt" = "true";
      "cache-reuse" = "1024";
    };
  };

  # ── Commented out ────────────────────────────────────────────────
  # Ling-3.0-flash: bailingmoe3/KDA recurrent — cache_reuse incompatible,
  # context checkpoints don't help (TTFT scales linearly).
  # "Ling-3.0-flash" = {
  #   modelId = "bartowski/Ling-3.0-flash-GGUF";
  #   filename = "Ling-3.0-flash-IQ4_XS/Ling-3.0-flash-IQ4_XS-00001-of-00002.gguf";
  #   extraProperties = {
  #     "alias" = "Ling-3.0,long-horizon";
  #     "flash-attn" = "on";
  #     "ctx-size" = "80000";
  #     "parallel" = "1";
  #     "cont-batching" = "true";
  #     "cache-type-k" = "q8_0";
  #     "cache-type-v" = "q8_0";
  #     "temperature" = "0.6";
  #     "top-p" = "0.95";
  #     "top-k" = "20";
  #     "min-p" = "0.0";
  #     "repeat-penalty" = "1.0";
  #     "batch-size" = "4096";
  #     "ubatch-size" = "1024";
  #     "load-mode" = "mlock";
  #     "spec-type" = "draft-mtp";
  #     "spec-draft-n-max" = "2";
  #   };
  # };
  # Qwen3.8-27B: good quality but too slow for agents (~60s TTFT).
  # "Qwen3.8-27B" = {
  #   modelId = "unsloth/Qwen3.8-27B-GGUF";
  #   filename = "Qwen3.8-27B-UD-Q6_K.gguf";
  #   extraProperties = {
  #     "alias" = "Qwen-3.8-27B,qwen-current,slow";
  #     "ctx-size" = "80000";
  #     "parallel" = "1";
  #     "flash-attn" = "on";
  #     "cache-type-k" = "q8_0";
  #     "cache-type-v" = "q8_0";
  #     "temperature" = "1.0";
  #     "top-p" = "0.95";
  #     "top-k" = "20";
  #     "min-p" = "0.0";
  #     "presence-penalty" = "0.0";
  #     "repeat-penalty" = "1.0";
  #     "batch-size" = "4096";
  #     "ubatch-size" = "1024";
  #     "load-mode" = "mlock";
  #     "cache-prompt" = "true";
  #     "cache-reuse" = "1024";
  #   };
  # };
}
