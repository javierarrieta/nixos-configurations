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

  # ── Qwen3.8-27B ─────────────────────────────────────────────────
  # Dense 27B, slow (~60s TTFT) but high quality. No mmproj → cache_reuse works.
  # 160k ctx is cheap on this hybrid-attention arch (measured 35.8GB GTT
  # total with Ornith-Text 160k×2 + Qwen3.5-4B resident, 2026-09-01).
  "Qwen3.8-27B" = {
    modelId = "unsloth/Qwen3.8-27B-GGUF";
    filename = "Qwen3.8-27B-UD-Q4_K_M.gguf";
    extraProperties = {
      "alias" = "Qwen-3.8-27B,qwen-current,slow,agent-quality";
      "ctx-size" = "160000";
      "parallel" = "2";
      "flash-attn" = "on";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
      "temperature" = "1.0";
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

  "Qwen2.5-VL-7B" = {
    modelId = "unsloth/Qwen2.5-VL-7B-Instruct-GGUF";
    filename = "Qwen2.5-VL-7B-Instruct-UD-Q5_K_XL.gguf";
    mmprojModelId = "unsloth/Qwen2.5-VL-7B-Instruct-GGUF";
    mmproj = "mmproj-BF16.gguf";
    extraProperties = {
      "alias" = "vision,qwen-vl,vision-model";
      "flash-attn" = "on";
      "ctx-size" = "32768";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
    };
  };

  # ── Ornith variants ──────────────────────────────────────────────
  # With multimodal projector (image input). cache_reuse disabled by
  # server when mmproj is loaded.
  # TEMPORARILY commented out (2026-09-01): GTT residency experiment —
  # with this + Ornith-Text resident the preset exceeds 118GB GTT and
  # every /metrics?model= scrape of an evicted model force-loads it.
  # "Ornith-1.5-35B" = {
  #   modelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
  #   filename = "Ornith-1.5-35B-Q6_K.gguf";
  #   mmprojModelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
  #   mmproj = "mmproj-Ornith-1.5-35B-BF16.gguf";
  #   extraProperties = {
  #     "alias" = "multimodal,agent-multimodal";
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
  #     "presence-penalty" = "0.0";
  #     "repeat-penalty" = "1.0";
  #     "batch-size" = "4096";
  #     "ubatch-size" = "1024";
  #     "load-mode" = "mlock";
  #     "image-min-tokens" = "1024";
  #     "cache-prompt" = "false";
  #   };
  # };
  # Text-only (no mmproj) — cache_reuse enabled for prefix caching.
  "Ornith-1.5-35B-Text" = {
    modelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
    filename = "Ornith-1.5-35B-Q6_K.gguf";
    extraProperties = {
      "alias" = "default,ornith,ornith-text,cache,quality,agent";
      "flash-attn" = "on";
      "ctx-size" = "160000";
      "parallel" = "2";
      "cont-batching" = "true";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
      "temperature" = "0.6";
      "top-p" = "0.95";
      "top-k" = "20";
      "min-p" = "0.0";
      "presence-penalty" = "0.05";
      # 1.0 disabled llama.cpp's default penalty and Ornith-1.5 loops on it
      # (repetitive output, 2026-09).
      "repeat-penalty" = "1.12";
      "batch-size" = "4096";
      "ubatch-size" = "1024";
      "load-mode" = "mlock";
      "cache-prompt" = "true";
      "cache-reuse" = "1024";
    };
  };
}
