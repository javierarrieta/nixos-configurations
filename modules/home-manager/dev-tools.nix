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
  home.packages = lib.mkIf (!configOnly) (
    with pkgs;
    [
      htop
      git
      curl
      wget
      tmux
      btop
      ripgrep
      yq
      jq
      rustup
      fzf
      bash
      zsh
      bat
      lsd
      difftastic
      dyff
      age
      sops
      fastfetch
      nixfmt
      nixfmt-tree
      kubernetes-helm
      scala-cli
      pstree
      nodejs_24
      gh
      bun

      hugo
    ]
  );

  programs.neovim = lib.mkIf (!configOnly) {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    withPython3 = false;
    withRuby = false;
  };
}
