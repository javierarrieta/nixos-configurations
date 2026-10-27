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

  # coder-titan / coder-casa: one CLI config dir per Coder server, so switching
  # servers is not a re-login. Defaults carry both URLs.
  coderProfiles.enable = true;

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

    # Recursive's local Flint inference CLI (see pkgs/rec/default.nix). The
    # package is only the CLI; the ~30 GB model is fetched on the first
    # `rec pull` / `rec serve` into ~/.local/share/rec, and `rec doctor` refuses
    # to run on anything below an M4 Pro / M5 Pro / M5 Max with 48 GB unified
    # memory, so installing it here costs nothing until it is actually used.
    # `rec launch pi` / `rec launch opencode` also want node + npm, which
    # modules/home-manager/macbook/dev-tools.nix provides via nodejs_24 (the
    # docs name Node 22). Quoted because `rec` is a reserved word in Nix.
    # Neither `rec uninstall` nor `rec update` is safe on a packaged install --
    # both assume upstream's ~/.local/share/rec/releases layout -- so bump the
    # version in pkgs/rec/default.nix. `rec doctor` passes from the store path
    # (macbookpro, 2026-10-27); `rec pull` is the step still untested there.
    pkgs."rec"

    unstablePkgs.opencode
  ];
}
