{
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
}
