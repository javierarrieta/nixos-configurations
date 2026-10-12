# One coder CLI config directory per Coder server.
#
# The coder CLI holds exactly one server URL and one session token in its config
# directory (`$CODER_CONFIG_DIR`, default `~/.config/coderv2`), so a second Coder
# server means re-running `coder login` on every hop. The CLI has no profile
# object; the supported seam is the global `--global-config` / `$CODER_CONFIG_DIR`
# flag, which every subcommand honours -- `login` included -- so each name below
# keeps its own url+session and they never overwrite each other. Verified against
# coder 2.36.1: a fresh CODER_CONFIG_DIR is created on first use and reports
# "not logged in" independently of the default one.
#
# Two servers today, both real, neither a mistake:
#   titan  https://coder.titan.arrieta.eu  -- k8s provider, see ../k8s-titan
#   casa   https://coder.home.arrieta.eu   -- the llm01 / casa-cluster server,
#          AGENTS.md "Coder Workspaces (llm01)"
#
# Aliases rather than a wrapper script in home.packages: the only thing needed is
# an env prefix on the command, and `shellAliases` is the mechanism already used
# for that class of thing (see `sshk` in home/hosts/macbookpro/home.nix). A
# wrapper named `coder` would shadow the real binary for anything resolving it
# off PATH -- coder's own ssh and IDE helpers do -- which is the opposite of the
# point. Both fish and zsh get them because shell.nix enables both.
#
# The directories themselves need no setup: coder creates them on first use, and
# `coder-<name> login <url>` is what populates one.
{
  config,
  lib,
  userOptions,
  ...
}:

let
  cfg = config.coderProfiles;
  home = userOptions.userHome;
  aliases = lib.mapAttrs' (
    name: url:
    lib.nameValuePair "coder-${name}" "CODER_CONFIG_DIR=${home}/.config/coderv2-${name} coder"
  ) cfg.servers;
in
{
  options.coderProfiles = {
    enable = lib.mkEnableOption ''
      one coder CLI config directory per Coder server, reached with coder-<name>
    '';

    servers = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        titan = "https://coder.titan.arrieta.eu";
        casa = "https://coder.home.arrieta.eu";
      };
      description = ''
        name = base URL. Each name gets a coder-<name> alias and its own
        ~/.config/coderv2-<name>. Override per-host to add or drop a server.
      '';
    };

    silenceVersionWarning = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Export CODER_NO_VERSION_WARNING=1. A client/server version mismatch is a
        warning, not a failure -- the CLI lists templates across a mismatch -- so
        leaving this off keeps a real skew visible. Turn it on only once the nag
        is noise that has already been triaged.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.fish.shellAliases = aliases;
    programs.zsh.shellAliases = aliases;

    home.sessionVariables = lib.mkIf cfg.silenceVersionWarning {
      CODER_NO_VERSION_WARNING = "1";
    };
  };
}
