{
  "Qwen3.5-2B" = {
    modelId = "unsloth/Qwen3.5-2B-GGUF";
    filename = "Qwen3.5-2B-Q4_K_M.gguf";
    extraProperties = {
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
      "alias" = "Qwen-3.5-4B,fast,4B";
      "parallel" = "1";
      "flash-attn" = "on";
      "ctx-size" = "140000";
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q5_0";
      "batch-size" = "4096";
      "ubatch-size" = "1024";
    };
  };
  "Mellum-4B" = {
    modelId = "mradermacher/Mellum-4b-base-GGUF";
    filename = "Mellum-4b-base.Q4_K_M.gguf";
    extraProperties = {
      "flash-attn" = "on";
      "ctx-size" = "8192";
      "n-predict" = "128";
      "temp" = "0.0";
      "top-k" = "1";
      "top-p" = "1.0";
      "min-p" = "0.0";
      "repeat-penalty" = "1.0";
      "cache-prompt" = "true";
      "cache-reuse" = "256";
    };
  };
  # "Qwen3.6-35B" = {
  #   modelId = "unsloth/Qwen3.6-35B-A3B-GGUF";
  #   filename = "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "200000";
  #   };
  #   mmproj = "mmproj-F32.gguf";
  # };

  # "Qwopus3.6-35B-A3B-Coder" = {
  #   modelId = "Jackrong/Qwopus3.6-35B-A3B-Coder-MTP-GGUF";
  #   filename = "Qwopus3.6-35B-A3B-Coder-MTP-Q5_K_M.gguf";
  #   extraProperties = {
  #     "ctx-size" = "200000";
  #   };
  #   mmproj = "mmproj-F32.gguf";
  # };
  # "MiroThinker-v1.5-30B" = {
  #   modelId = "mradermacher/MiroThinker-v1.5-30B-GGUF";
  #   filename = "MiroThinker-v1.5-30B.Q4_K_M.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "65536";
  #   };
  # };
  # "Nemotron-Cascade-2-30B-A3B" = {
  #   modelId = "mradermacher/Nemotron-Cascade-2-30B-A3B-i1-GGUF";
  #   filename = "Nemotron-Cascade-2-30B-A3B.i1-Q4_K_M.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "200000";
  #   };
  # };
  # "Gemma-4-26B-A4B-it" = {
  #   modelId = "unsloth/gemma-4-26B-A4B-it-GGUF";
  #   filename = "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "200000";
  #   };
  # };
  # "Gemma-4-12B" = {
  #   modelId = "unsloth/gemma-4-12b-it-GGUF";
  #   filename = "gemma-4-12b-it-Q4_K_M.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "200000";
  #   };
  #   mmproj = "mmproj-F16.gguf";
  # };
  # "Ornith-1.0-35b" = {
  #   modelId = "deepreinforce-ai/Ornith-1.0-35B-GGUF";
  #   filename = "ornith-1.0-35b-Q6_K.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "200000";
  #   };
  # };
  # "VibeThinker-3B" = {
  #   modelId = "mradermacher/VibeThinker-3B-i1-GGUF";
  #   filename = "VibeThinker-3B.i1-Q6_K.gguf";
  #   extraProperties = {
  #     "flash-attn" = "on";
  #     "ctx-size" = "200000";
  #     "cache-type-k" = "q8_0";
  #     "cache-type-v" = "q5_0";
  #   };
  # };
  # "Laguna-S-2.1" = {
  #   modelId = "unsloth/Laguna-S-2.1-GGUF";
  #   filename = "UD-Q4_K_M/Laguna-S-2.1-UD-Q4_K_M-00001-of-00003.gguf";
  #   # modelDraft = "laguna-s-2.1-DFlash-BF16.gguf";
  #   # modelDraftModelId = "poolside/Laguna-S-2.1-GGUF";
  #   extraProperties = {
  #     "alias" = "default";
  #     "ctx-size" = "131072";
  #     # With parallel=2, each slot gets 65536 (131072/2 = 65536 after padding).
  #     # --parallel 16 would split into 8K/slot, causing tools to reject model.
  #     "parallel" = "1";
  #     "flash-attn" = "on";
  #     "cache-type-k" = "q8_0";
  #     "cache-type-v" = "q5_0";
  #     "temperature" = "0.0";
  #     "top-p" = "0.95";
  #     "batch-size" = "2048";
  #     "ubatch-size" = "512";
  #     "threads" = "8";
  #     "spec-type" = "ngram-simple";
  #     "spec-draft-n-max" = "8";
  #     "load-mode" = "mlock";
  #     "cache-prompt" = "false"; # <-- Prevents cache fragmentation locks
  #   };
  # };
  # "Ornith-1.5-35B" = {
  #   modelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
  #   filename = "Ornith-1.5-35B-Q5_K_M.gguf";
  #   # modelDraft = "mtpdraft-Q8_0.gguf";
  #   mmprojModelId = "ornith-ai/Ornith-1.5-35B-A3B-GGUF";
  #   mmproj = "mmproj-Ornith-1.5-35B-BF16.gguf";
  #   extraProperties = {
  #     "alias" = "default,hermes,opencode,ornith-current";
  #     "flash-attn" = "on";
  #     "ctx-size" = "131072";
  #     "parallel" = "1";
  #     "cache-type-k" = "q5_1";
  #     "cache-type-v" = "q5_1";
  #     "temperature" = "0.6";
  #     "top-p" = "0.95";
  #     "top-k" = "20";
  #     "min-p" = "0.0";
  #     "presence-penalty" = "0.0";
  #     "repeat-penalty" = "1.0";
  #     # "spec-draft-n-max" = "4";
  #     # "spec-draft-n-min" = "1";
  #     "batch-size" = "4096";
  #     "ubatch-size" = "1024";
  #     "load-mode" = "mlock";
  #     "image-min-tokens" = "1024";
  #     "cache-prompt" = "false"; # <-- Prevents cache fragmentation locks
  #   };
  # };
  # "Qwen3.8-27B" = {
  #   modelId = "unsloth/Qwen3.8-27B-GGUF";
  #   filename = "Qwen3.8-27B-Q6_K.gguf";
  #   mmproj = "mmproj-F16.gguf";
  #   extraProperties = {
  #     "alias" = "Qwen-3.8-27B,qwen-current,quality,slow";
  #     "ctx-size" = "131072";
  #     # With parallel=2, each slot gets 65536 (131072/2 = 65536 after padding).
  #     # --parallel 16 would split into 8K/slot, causing tools to reject model.
  #     "parallel" = "1";
  #     "flash-attn" = "on";
  #     "cache-type-k" = "q8_0";
  #     "cache-type-v" = "q5_0";
  #     "temperature" = "1.0";
  #     "top-p" = "0.95";
  #     "top-k" = "20";
  #     "min-p" = "0.0";
  #     "presence-penalty" = "0.0";
  #     "repeat-penalty" = "1.0";
  #     "spec-type" = "draft-mtp";
  #     "spec-draft-n-max" = "6";
  #     "spec-draft-p-min" = "0.80";
  #     "batch-size" = "4096";
  #     "ubatch-size" = "1024";
  #     "load-mode" = "mlock";
  #     "image-min-tokens" = "1024";
  #     "cache-prompt" = "false"; # <-- Prevents cache fragmentation locks
  #     "chat-template-kwargs" = "{\"reasoning_effort\": \"low\"}";
  #   };
  # };
  "Ling-3.0-flash" = {
    modelId = "bartowski/Ling-3.0-flash-GGUF";
    filename = "Ling-3.0-flash-IQ4_XS/Ling-3.0-flash-IQ4_XS-00001-of-00002.gguf";
    extraProperties = {
      "alias" = "Ling-3.0,quality,slow";
      "flash-attn" = "on";
      "ctx-size" = "131072";
      "parallel" = "1";
      # Hybrid/recurrent arch rejects different K vs V cache quants
      "cache-type-k" = "q8_0";
      "cache-type-v" = "q8_0";
      "temperature" = "0.6";
      "top-p" = "0.95";
      "top-k" = "20";
      "min-p" = "0.0";
      "repeat-penalty" = "1.0";
      "batch-size" = "4096";
      "ubatch-size" = "1024";
      "load-mode" = "mlock";
      # Baked-in NextN/MTP layer acts as draft model (bartowski quants include it).
      # Note: Vulkan had a reported MTP hang (ggml_vk_wait_for_fence) upstream;
      # if it stalls, drop these two lines or add --no-spec-draft-backend-sampling.
      "spec-type" = "draft-mtp";
      "spec-draft-n-max" = "4";
      "cache-prompt" = "false";
    };
  };
}
