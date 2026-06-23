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
  # "Qwen3.6-35B" = {
  #   modelId = "unsloth/Qwen3.6-35B-A3B-GGUF";
  #   filename = "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
  #   extraProperties = {
  #     "ctx-size" = "200000";
  #   };
  #   mmproj = "mmproj-F32.gguf";
  # };

  "Qwopus3.6-35B" = {
    modelId = "Jackrong/Qwopus3.6-35B-A3B-v1-MTP-GGUF";
    filename = "Qwopus3.6-35B-A3B-v1-MTP-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
    mmproj = "mmproj-F32.gguf";
  };
  # "MiroThinker-v1.5-30B" = {
  #   modelId = "mradermacher/MiroThinker-v1.5-30B-GGUF";
  #   filename = "MiroThinker-v1.5-30B.Q4_K_M.gguf";
  #   extraProperties = {
  #     "ctx-size" = "65536";
  #   };
  # };
  "Nemotron-Cascade-2-30B-A3B" = {
    modelId = "mradermacher/Nemotron-Cascade-2-30B-A3B-i1-GGUF";
    filename = "Nemotron-Cascade-2-30B-A3B.i1-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
  };
  "Gemma-4-26B-A4B-it" = {
    modelId = "unsloth/gemma-4-26B-A4B-it-GGUF";
    filename = "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
  };
  "Gemma-4-12B" = {
    modelId = "unsloth/gemma-4-12b-it-GGUF";
    filename = "gemma-4-12b-it-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
    mmproj = "mmproj-F16.gguf";
  };
  "VibeThinker-3B" = {
    modelId = "mradermacher/VibeThinker-3B-i1-GGUF";
    filename = "VibeThinker-3B.i1-Q6_K.gguf";
    extraProperties = {
      "ctx-size" = "200000";
    };
  };
}
