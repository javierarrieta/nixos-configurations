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
      jdk21
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

  # JVM tooling (gradle, maven, sbt, some IDE integrations) resolves the JDK
  # through JAVA_HOME rather than `java` on PATH, so point it at the same
  # derivation that provides the binaries. `pkgs.jdk21` is openjdk on Linux
  # and zulu-ca on aarch64-darwin; both are cached for these systems.
  home.sessionVariables = lib.mkIf (!configOnly) {
    JAVA_HOME = "${pkgs.jdk21}";
  };

  programs.neovim = lib.mkIf (!configOnly) {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    withPython3 = false;
    withRuby = false;
  };
}
