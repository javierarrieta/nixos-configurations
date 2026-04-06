{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    nixSweep = {
      enable = lib.mkEnableOption "Nix store cleanup via nix-sweep";
      interval = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Cleanup interval";
      };
      removeOlder = lib.mkOption {
        type = lib.types.str;
        default = "7d";
        description = "Remove generations older than this";
      };
      keepMin = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Minimum generations to keep";
      };
    };
  };

  config = lib.mkIf config.nixSweep.enable {
    services.nix-sweep = {
      enable = true;
      interval = config.nixSweep.interval;
      removeOlder = config.nixSweep.removeOlder;
      keepMin = config.nixSweep.keepMin;
    };
  };
}
