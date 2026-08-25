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
      # cleanout alone only prunes profile generations; without gc the store
      # paths stay on disk forever
      gc = true;
      gcQuota = 60;
      gcModest = true;
      # comin keeps a full system closure per deployed commit in its own
      # profile; without sweeping it those closures pin the store
      profiles = [
        "system"
        "/nix/var/nix/profiles/system-profiles/comin"
      ];
    };
  };
}
