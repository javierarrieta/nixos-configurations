{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:

let
  configOnly = userOptions.configOnly or false;
in
{
  # Everyday CLI niceties, installed on *every* host -- including the k8s
  # fleet, which is deliberately excluded from dev-tools. These are the
  # tools you reach for while SSH'd into a machine mid-incident, so they
  # are not considered "dev" tooling.
  #
  # Every package here is prebuilt in the nixpkgs binary cache for
  # aarch64-linux as well, so adding them to the Pis costs a download and
  # not an on-device Rust compile (the thing the Pi slimming was about).
  home.packages = lib.mkIf (!configOnly) (
    with pkgs;
    [
      curl
      tmux
      ripgrep
      fzf
      bat
      eza
      difftastic
      dyff
      gh
      fastfetch
    ]
  );
}
