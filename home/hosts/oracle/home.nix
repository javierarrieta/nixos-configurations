{
  config,
  pkgs,
  unstablePkgs,

  lib,
  userOptions,
  hostname,
  ...
}:

let
  sshKeyAskpass = pkgs.writeShellScript "ssh-key-askpass" ''
    printf '%s\n' "$SSH_KEY_PASSWORD"
  '';
in
{
  imports = [
    ../../../modules/home-manager/base.nix
    ../../../modules/home-manager/editors.nix
    ../../../modules/home-manager/term.nix
    ../../../modules/home-manager/media.nix
    ../../../modules/home-manager/macbook/dev-tools.nix
    ../../../modules/home-manager/local-llm.nix
  ];

  _module.args.localModels = import ./local-models.nix;

  home.stateVersion = "25.05";

  home.packages = [
    pkgs.kcl
    pkgs.nodejs_24
    pkgs.opentofu
  ];

  programs.fish = {
    functions.sshk = {
      description = "Load SSH keys using a shared password";
      body = ''
        read --silent --prompt-str "SSH key password: " sshKeyPassword
        or return
        echo

        set --function --export SSH_KEY_PASSWORD "$sshKeyPassword"
        set --function --export SSH_ASKPASS "${sshKeyAskpass}"
        set --function --export SSH_ASKPASS_REQUIRE force
        set --function --export DISPLAY :0

        ssh-add -D
        and ssh-add -s /usr/local/lib/libykcs11.dylib -t 18h
        and ssh-add -t 18h
        set --local sshkStatus $status

        set --erase SSH_KEY_PASSWORD SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY sshKeyPassword
        return $sshkStatus
      '';
    };
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
      "pf-opensearch" =
        "echo 'Open OpenSearch at https://localhost:5601/' && kubectl -n opensearch port-forward svc/scs-opensearch-prod-dashboards 5601:5601 --context";
      "akhq-pass" =
        "kubectl get secret -n kafka akhq-admin-user-creds -o json | jq '.data.ociVaultContent' | tr -d '\"' | base64 -D | pbcopy";
    };
    shellAliases = {
      "codex-brew" = "/opt/homebrew/bin/codex";
      "terraform" = "tofu";
      "fashion-token" = "z ${userOptions.workspaces.fashion_token} && cargo run --release ; z -";
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

}
