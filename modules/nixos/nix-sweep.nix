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
      minFree = lib.mkOption {
        type = lib.types.str;
        default = "8G";
        description = ''
          Free-space GC trigger: when free space in the store's filesystem drops
          below this during a build, collect until maxFree is available or there
          is no more garbage. "0" disables.
        '';
      };
      maxFree = lib.mkOption {
        type = lib.types.str;
        default = "16G";
        description = "Stop the free-space GC once this much is available.";
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

    # Free-space-triggered GC, in absolute bytes rather than a device percentage.
    #
    # nix-sweep's gcQuota is store size as a % of the device, which is the wrong
    # unit for this fleet: root filesystems span 48.9G (node04) to 460G (node03),
    # so one percentage means wildly different absolute things. Measured 2026-09-28
    # every node sits at 3.7-29.4% store-vs-device, so gcQuota = 60 never fires
    # anywhere -- and tuning it down to bite on node04 (~40%) would still let
    # node03 reach 184 GiB before collecting.
    #
    # This keys on actual free bytes, so 8G means 8G on every host. It fires
    # during a build, which is exactly when a comin deploy can fill the disk
    # mid-activation. It cannot delete GC roots -- the system profile and the comin
    # profiles stay reachable, so rollback survives a collect.
    #
    # Sized against the tightest hosts (node02 19.3 GiB avail, node04 12.8 GiB)
    # and stores of 14.4-25.2 GiB, so a single deploy delta of a few GiB stays
    # well clear of the trigger.
    #
    # Caveat: this only fires while Nix is building. Growth from /var/lib/rancher
    # (containerd) is the kubelet's image GC's problem, not something a Nix
    # setting can guard.
    nix.settings = {
      min-free = config.nixSweep.minFree;
      max-free = config.nixSweep.maxFree;
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
