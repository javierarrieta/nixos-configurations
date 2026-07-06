{
  config,
  pkgs,
  unstablePkgs,
  pkgsUnfree,
  unstablePkgsUnfree,
  lib,
  userOptions,
  hostname,
  ...
}:

{
  imports = [
    ../../../modules/home-manager/base.nix
    ../../../modules/home-manager/editors.nix
    ../../../modules/home-manager/term.nix
    ../../../modules/home-manager/media.nix
    ../../../modules/home-manager/macbook/dev-tools.nix
  ];

  home.stateVersion = "25.05";

  home.packages = [
    pkgs.kcl
    pkgs.nodejs_24
    pkgs.opentofu
  ];

  programs.fish = {
    shellAbbrs = {
      "k9st" = {
        expansion = "k9s --namespace stream-app --context Stage/OC1/%";
        position = "command";
        setCursor = true;
      };
      "k9pr" = {
        expansion = "k9s --namespace stream-app --context Prod/OC%";
        position = "command";
        setCursor = true;
      };

      "pf-grafana" =
        "echo 'Open grafana at http://localhost:9091/' && kubectl port-forward service/grafana 9091:3000 -n octo-system --context";
      "pf-prom" =
        "echo 'Open prometheus at http://localhost:9093/' && kubectl port-forward service/prometheus-k8s 9093:9090 -n octo-system --context";
      "pf-akhq" =
        "echo 'Open akhq at http://localhost:9092/' && kubectl port-forward service/akhq 9092:80 -n kafka --context";
      "pf-cruisecontrol" =
        "echo 'Open Cruise Control at https://localhost:9090/' && kubectl port-forward service/scs-data-mesh-prod-cruise-control 9090:9090 -n kafka --context";
      "akhq-pass" =
        "kubectl get secret -n kafka akhq-admin-user-creds -o json | jq '.data.ociVaultContent' | tr -d '\"' | base64 -D | pbcopy";
    };
    shellAliases = {
      "terraform" = "tofu";
      "fashion-token" = "z ${userOptions.workspaces.fashion_token} && cargo run --release ; z -";
      "sshk" = "ssh-add -D && ssh-add -s /usr/local/lib/libykcs11.dylib -t 18h && ssh-add -t 18h";
      "code4cline" = "SHELL=$HOME/.nix-profile/bin/bash code";
      "ministral-reasoning" =
        "llama-server --model ${userOptions.llmModelsDir}/unsloth_Ministral-3-14B-Reasoning-2512-GGUF_Ministral-3-14B-Reasoning-2512-Q4_K_M.gguf --jinja -ngl 99 --threads -1 --ctx-size 32684 --temp 0.6 --top-p 0.95   --offline";
      "ministral-instruct" =
        "llama-server --model ${userOptions.llmModelsDir}/unsloth_Ministral-3-3B-Instruct-2512-GGUF_Ministral-3-3B-Instruct-2512-UD-Q4_K_XL.gguf --jinja -ngl 99 --threads -1 --ctx-size 32684 --temp 0.15 --port 8081 --offline --metrics";
      "devstral" =
        "llama-server --model ${userOptions.llmModelsDir}/unsloth_Devstral-Small-2-24B-Instruct-2512-GGUF-Q4_K_XL.gguf --jinja -ngl 99 --threads -1 --ctx-size 32684 --temp 0.15 --port 8080 --offline --metrics";
      "mirothinker" =
        "llama-server --model ${userOptions.llmModelsDir}/MiroThinker-v1.5-30B.Q4_K_M.gguf --jinja -ngl 99 --threads -1 --ctx-size 32684 --temp 0.15 --offline --metrics";
      "qwencoder-3b" =
        "llama-server --model ${userOptions.llmModelsDir}/Qwen2.5-Coder-3B-Q4_K_M.gguf --jinja -ngl 99 --threads -1 --ctx-size 16342 --temp 0.15 --port 8081 --offline --metrics";
    };
  };

  programs.vscode.profiles.default.extensions = with unstablePkgsUnfree.vscode-extensions; [
    hashicorp.terraform
  ];
}
