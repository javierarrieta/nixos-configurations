{ pkgs, ... }:

{
  home.packages = [ pkgs.llama-cpp ];

  programs.fish.shellAliases."autocomplete-server" =
    "hf download Jackrong/Qwopus3.5-4B-Coder-MTP-GGUF Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf --local-dir $HOME/llm/models && \
     llama-server -m $HOME/llm/models/Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.1 --presence_penalty 0.0 --repeat-penalty 1.0 --chat-template-kwargs '{\"enable_thinking\": false}' --reasoning-budget -1 --offline -ngl 99 --threads -1 --ctx-size 8192 --port 8081";
}
