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

  # ---- JDK ------------------------------------------------------------
  # Per-host overrides live in that host's userOptions.nix under `jdk`.
  jdkCfg = userOptions.jdk or { };

  # Opt a host out of the Nix-provided JDK with `jdk.enable = false` in its
  # userOptions.nix, for a machine where a JDK manager outside Nix owns
  # Java. Why the flag exists: such a manager (SDKMAN on oracle) switches
  # versions by rewriting JAVA_HOME and PATH in the shell, but Home Manager
  # re-exports its own session variables into every new shell, so `sdk use
  # java ...` is undone by the next prompt. Package and JAVA_HOME therefore
  # move together -- a host that opts out must keep neither, or `java` on
  # PATH and $JAVA_HOME name two different JDKs and gradle, maven and sbt
  # silently build against the Nix one.
  jdkEnable = jdkCfg.enable or true;
in
{
  # Development toolchains and editor config. The everyday CLI niceties
  # (curl, tmux, ripgrep, fzf, bat, eza, difftastic, dyff, gh, fastfetch)
  # live in ./cli-tools.nix instead, because they are installed on every
  # host while this module is skipped on the k8s fleet.
  #
  # The pi coding agent lives in ./pi -- its own module, imported below rather
  # than inlined here, because it is the part of this environment meant to be
  # shared: settings, models, vendored skills, extensions, agent personas and
  # the global AGENTS.md. It was extracted out of this file on 2026-11-19 for
  # exactly that reason; nothing about its behaviour changed.
  imports = [ ./pi ];

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
      # `herdrPkg` prebuilt release binary (via the herdr-nix flake) rather
      # than `pkgs`, so no Rust/Zig build lands on any host.
      herdrPkg

      pkgsUnfree.coder
    ]
    # The JDK is gated separately because a host may manage Java outside
    # Nix -- see `jdkEnable` above.
    ++ lib.optionals jdkEnable [ jdk21 ]
  );

  # One definition, because the module system rejects the same option twice in
  # one file. `lib.mkIf` per key would have been the shape if these could be
  # separate.
  #
  # JAVA_HOME: JVM tooling (gradle, maven, sbt, some IDE integrations) resolves
  # the JDK through JAVA_HOME rather than `java` on PATH, so point it at the same
  # derivation that provides the binaries. `pkgs.jdk21` is openjdk on Linux and
  # zulu-ca on aarch64-darwin; both are cached for these systems. Follows
  # `jdkEnable`: a host whose JDK comes from outside Nix must not have JAVA_HOME
  # pinned here, or it overrides that manager on every shell.
  #
  # PI_* live in ./pi now, gated on `piEnable` alongside the rest of pi.
  home.sessionVariables = lib.optionalAttrs (!configOnly && jdkEnable) {
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
