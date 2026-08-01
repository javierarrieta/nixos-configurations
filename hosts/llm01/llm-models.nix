{
  "Qwen3.5-2B" = {
    modelId = "unsloth/Qwen3.5-2B-GGUF";
    filename = "Qwen3.5-2B-Q4_K_M.gguf";
    extraProperties = {
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
      "ctx-size" = "65536";
    };
  };
  "Mellum-4B" = {
    modelId = "mradermacher/Mellum-4b-base-GGUF";
    filename = "Mellum-4b-base.Q4_K_M.gguf";
    extraProperties = {
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
  #     "ctx-size" = "65536";
  #   };
  # };
  # "Nemotron-Cascade-2-30B-A3B" = {
  #   modelId = "mradermacher/Nemotron-Cascade-2-30B-A3B-i1-GGUF";
  #   filename = "Nemotron-Cascade-2-30B-A3B.i1-Q4_K_M.gguf";
  #   extraProperties = {
  #     "ctx-size" = "200000";
  #   };
  # };
  # "Gemma-4-26B-A4B-it" = {
  #   modelId = "unsloth/gemma-4-26B-A4B-it-GGUF";
  #   filename = "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf";
  #   extraProperties = {
  #     "ctx-size" = "200000";
  #   };
  # };
  "Gemma-4-12B" = {
    modelId = "unsloth/gemma-4-12b-it-GGUF";
    filename = "gemma-4-12b-it-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
    mmproj = "mmproj-F16.gguf";
  };
  # "Ornith-1.0-35b" = {
  #   modelId = "deepreinforce-ai/Ornith-1.0-35B-GGUF";
  #   filename = "ornith-1.0-35b-Q6_K.gguf";
  #   extraProperties = {
  #     "ctx-size" = "200000";
  #   };
  # };
  "VibeThinker-3B" = {
    modelId = "mradermacher/VibeThinker-3B-i1-GGUF";
    filename = "VibeThinker-3B.i1-Q6_K.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
  };
  "Laguna-S-2.1" = {
    modelId = "unsloth/Laguna-S-2.1-GGUF";
    filename = "UD-Q4_K_M/Laguna-S-2.1-UD-Q4_K_M-00001-of-00003.gguf";
    modelDraft = "laguna-s-2.1-DFlash-BF16.gguf";
    modelDraftModelId = "poolside/Laguna-S-2.1-GGUF";
    extraProperties = {
      "ctx-size" = "200000";
      "spec-type" = "draft-dflash";
      "spec-draft-n-max" = "15";
    };
  };
}
