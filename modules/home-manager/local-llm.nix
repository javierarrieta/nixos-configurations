{ unstablePkgs, ... }:

{
  home.packages = [ unstablePkgs.llama-cpp ];

  programs.fish.shellAliases."autocomplete-server" =
    "hf download mradermacher/zeta-2.1-i1-GGUF zeta-2.1.i1-IQ3_XS.gguf --local-dir $HOME/llm/models && \
     llama-server -m $HOME/llm/models/zeta-2.1.i1-IQ3_XS.gguf --temp 0.0 --min-p 0.0 --top-p 1.0 --top-k 1 --repeat-penalty 1.0 --presence-penalty 0.0 --frequency-penalty 0.0 --ctx-size 2048 --batch-size 512 --ubatch-size 512 --cont-batching --flash-attn on --n-gpu-layers 99 --threads 4 --offline --port 8081";
}
