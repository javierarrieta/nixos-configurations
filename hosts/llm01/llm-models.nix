{
  "Qwen2.5-coder-1.5B" = {
    modelId = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF";
    filename = "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf";
    extraProperties = {
      "ctx-size" = "8192";
    };
  };
  "Qwen3.5-35B" = {
    modelId = "unsloth/Qwen3.5-35B-A3B-GGUF";
    filename = "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf";
    extraProperties = {
      "ctx-size" = "32768";
    };
    mmproj = "mmproj-F32.gguf";
  };
  "MiroThinker-v1.5-30B" = {
    modelId = "mradermacher/MiroThinker-v1.5-30B-GGUF";
    filename = "MiroThinker-v1.5-30B.Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "32768";
    };
  };
  "Qwen3-coder-Next" = {
    modelId = "unsloth/Qwen3-Coder-Next-GGUF";
    filename = "Qwen3-Coder-Next-Q4_K_M.gguf";
    extraProperties = {
      "ctx-size" = "65386";
    };
  };
}
