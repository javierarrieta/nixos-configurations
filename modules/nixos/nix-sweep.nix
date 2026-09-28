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
      optimise = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run nix-store --optimise periodically (hard-link identical store files).";
      };
      optimiseDates = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "04:15" ];
        description = "When to run the store optimiser (systemd.time(7)).";
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

    # Dedup identical files across the store. nix-sweep prunes generations but
    # never deduplicates, so every host running overlapping package sets pays
    # full price for repeated bytes. Runs Nice=19 / IOSchedulingClass=idle
    # upstream, so it will not starve k3s.
    #
    # Staggered to 04:15 rather than the 03:45 default so it does not line up
    # with the nix-gc timer (03:15) on hosts that also enable it.
    nix.optimise = {
      automatic = config.nixSweep.optimise;
      dates = config.nixSweep.optimiseDates;
    };
  };
}
