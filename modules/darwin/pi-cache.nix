{ config, lib, ... }:
{
  options = {
    piCache = {
      enable = lib.mkEnableOption ''
        the pi.cachix.org binary cache on macOS
      '';
    };
  };

  config = lib.mkIf config.piCache.enable {
    # pi is a bun2nix build of upstream earendil-works/pi and is not on
    # cache.nixos.org; without a trusted cache the first build per system
    # compiles the whole agent from source. Same problem and same key as
    # modules/nixos/pi-cache.nix.
    #
    # This has to be a nix-darwin module rather than a home-manager one.
    # Substitution happens inside the nix daemon, and trusted-public-keys is
    # read only when the daemon starts: keys sent by a client from
    # ~/.config/nix/nix.conf are dropped silently rather than rejected, so a
    # user-level config cannot authorise a cache and you get
    # "substituter ... does not have a valid signature" instead of an error
    # about the config. See https://github.com/NixOS/nix/issues/1921. The key
    # must reach /etc/nix/nix.conf, and nix-darwin is what writes that file.
    #
    # extra-* rather than substituters / trusted-public-keys so the
    # cache.nixos.org defaults survive. nix-darwin also emits extra-* keys
    # after the plain ones, which keeps the generated nix.conf readable.
    nix.settings.extra-substituters = [ "https://pi.cachix.org" ];
    nix.settings.extra-trusted-public-keys = [
      "pi.cachix.org-1:lGeoGJaZ5ZDabuRzkcD5EBTNnDM4HJ1vqeOxlWk1Flk="
    ];
  };
}
