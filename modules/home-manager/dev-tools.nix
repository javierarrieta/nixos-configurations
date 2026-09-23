{
  config,
  pkgs,
  pkgsUnfree,
  lib,
  userOptions,
  herdrPkg,
  ...
}:

let
  configOnly = userOptions.configOnly or false;
in
{
  # Development toolchains and editor config. The everyday CLI niceties
  # (curl, tmux, ripgrep, fzf, bat, eza, difftastic, dyff, gh, fastfetch)
  # live in ./cli-tools.nix instead, because they are installed on every
  # host while this module is skipped on the k8s fleet.
  home.packages = lib.mkIf (!configOnly) (
    with pkgs;
    [
      htop
      git
      wget
      btop
      yq
      jq
      rustup
      bash
      zsh
      age
      sops
      nixfmt
      nixfmt-tree
      kubernetes-helm
      scala-cli
      pstree
      lsof
      binutils
      nodejs_24
      bun

      # Terminal-native runtime for AI coding agents. Comes from the
      # `herdrPkg` special arg (prebuilt release binary via the herdr-nix
      # flake) rather than `pkgs`, so no Rust/Zig build lands on any host.
      herdrPkg

      pkgsUnfree.coder
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
