# MacBook Pro host: mirrors the macbookair host (same modules and settings).
# Kept as a separate host directory so the two laptops can diverge without
# one silently changing the other; userOptions.nix carries the per-machine
# identity (user, home, git identity).
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
let
  pythonVersion = lib.replaceStrings [ "." ] [ "" ] userOptions.pythonVersion;
in
{
  imports = [
    ../../../modules/home-manager/base.nix
    ../../../modules/home-manager/editors.nix
    ../../../modules/home-manager/term.nix
    ../../../modules/home-manager/media.nix
    ../../../modules/home-manager/macbook/dev-tools.nix
    ../../../modules/home-manager/local-llm.nix
    ../../../modules/home-manager/kube-segregation.nix
  ];

  _module.args.localModels = import ./local-models.nix;

  # Read-only-by-default kubeconfig; admin via `kadm` (~/.kube/admin.yaml).
  # Defaults match the k8s-casa split done on this machine.
  kubeSegregation.enable = true;

  home.stateVersion = "25.05";

  home.sessionVariables = {
    SOPS_AGE_KEY_FILE = "${userOptions.userHome}/.config/sops/age/keys.txt";
  };

  programs.fish.shellAliases = {
    "sshk" = "ssh-add -D && ssh-add -t 18h";
  };

  home.packages = [
    pkgs.nmap
    pkgs.opam
    pkgs.gemini-cli
    pkgs."python${pythonVersion}Packages".wakeonlan
    pkgs.minio-client
    pkgs.wp-cli

    unstablePkgs.opencode
  ];
}
