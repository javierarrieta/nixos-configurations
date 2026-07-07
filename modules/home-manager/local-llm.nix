{
  localModels,
  unstablePkgs,
  ...
}:

let
  inherit (localModels.autocomplete)
    ctxSize
    filename
    modelId
    nPredict
    ;
  modelPath = "$HOME/llm/models/${filename}";
in

{
  home.packages = [ unstablePkgs.llama-cpp ];

  programs.fish.shellAliases."autocomplete-server" =
    "hf download ${modelId} ${filename} --local-dir $HOME/llm/models && \
     llama-server -m ${modelPath} --temp 0.0 --min-p 0.0 --top-p 1.0 --top-k 1 --repeat-penalty 1.0 --presence-penalty 0.0 --frequency-penalty 0.0 --ctx-size ${toString ctxSize} --n-predict ${toString nPredict} --batch-size 512 --ubatch-size 512 --cont-batching --flash-attn on --n-gpu-layers 99 --threads 4 --cache-prompt --cache-reuse 256 --offline --port 8081";
}
