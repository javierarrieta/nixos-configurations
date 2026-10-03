{ config, lib, ... }:
{
  options = {
    piCache = {
      enable = lib.mkEnableOption ''
        the pi.cachix.org binary cache for the pi coding agent
      '';
    };
  };

  config = lib.mkIf config.piCache.enable {
    # pi comes from the `pi` flake input (a bun2nix build of upstream
    # earendil-works/pi) and is not on cache.nixos.org. The flake publishes a
    # prebuilt copy at https://pi.cachix.org, but a flake's own nixConfig is a
    # *client-side* trust setting that the root nix daemon never applies, so a
    # comin-triggered build ignores it and compiles the whole agent from source
    # on every deploy.
    #
    # This is its own module rather than a stanza in base.nix because base.nix is
    # gated on base.enable, and ryzen7 -- a workstation, since removed from the
    # repo -- imported base.nix without ever setting base.enable = true. It
    # deliberately ran without the base profile (bash rather than fish, its own
    # bootloader config), so putting the cache there would have silently skipped
    # the one host that needed it most. llm01 and wsl are the current users: import
    # this next to base.nix on any host whose home-manager installs pi.
    #
    # extra-* rather than substituters so cache.nixos.org stays in the list.
    nix.settings.extra-substituters = [ "https://pi.cachix.org" ];
    nix.settings.extra-trusted-public-keys = [
      "pi.cachix.org-1:lGeoGJaZ5ZDabuRzkcD5EBTNnDM4HJ1vqeOxlWk1Flk="
    ];
  };
}
