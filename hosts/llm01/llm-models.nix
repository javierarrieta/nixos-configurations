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
      "ctx-size" = "8192";
    };
  };
  "Qwen3.5-35B" = {
    modelId = "unsloth/Qwen3.5-35B-A3B-GGUF";
    filename = "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf";
    extraProperties = {
      "ctx-size" = "98304";
    };
    mmproj = "mmproj-F32.gguf";
  };
  "MiroThinker-v1.5-30B" = {
    modelId = "mradermacher/MiroThinker-v1.5-30B-GGUF";
    filename = "MiroThinker-v1.5-30B.Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "65536";
    };
  };
  "Nemotron-Cascade-2-30B-A3B" = {
    modelId = "mradermacher/Nemotron-Cascade-2-30B-A3B-i1-GGUF";
    filename = "Nemotron-Cascade-2-30B-A3B.i1-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "120000";
    };
  };
  "Qwen3.5-27B" = {
    modelId = "Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-GGUF";
    filename = "Qwen3.5-27B.Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "120000";
    };
  };
  # "Qwen3.5-122B-A10B" = {
  #   modelId = "unsloth/Qwen3.5-122B-A10B-GGUF";
  #   filename = "Q4_K_M/Qwen3.5-122B-A10B-Q4_K_M-00001-of-00003.gguf";
  #   extraProperties = {
  #     "ctx-size" = "120000";
  #   };
  # };
  # "Mistral-Small-4-119B-2603" = {
  #   modelId = "unsloth/Mistral-Small-4-119B-2603-GGUF";
  #   filename = "UD-Q4_K_XL/Mistral-Small-4-119B-2603-UD-Q4_K_XL-00001-of-00003.gguf";
  #   extraProperties = {
  #     "ctx-size" = "65536";
  #   };
  # };
}
