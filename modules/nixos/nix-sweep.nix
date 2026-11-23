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

    # The collector, as distinct from the generation pruner above.
    #
    # Deliberately NOT nested under nixSweep, and emitted outside the
    # nixSweep.enable gate below: every host in the flake imports this module
    # (hosts/wsl imports it and never sets nixSweep.enable), so this is the one
    # place that reaches all of them without a per-host line.
    nixGc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run a scheduled nix-collect-garbage, i.e. the thing that actually frees
          store paths. On by default because every host in this flake wants one;
          a host opts out with nixGc.enable = false rather than by omission.
        '';
      };
      dates = lib.mkOption {
        type = lib.types.singleLineStr;
        default = "weekly";
        description = "When to collect, as a systemd.time(7) calendar expression.";
      };
      deleteOlderThan = lib.mkOption {
        type = lib.types.str;
        default = "30d";
        description = ''
          Passed to nix-collect-garbage as --delete-older-than. Prunes profile
          generations older than this before collecting. Nix never drops the
          current generation, nor the newest generation past the cutoff, so a
          rollback target always survives (see deleteGenerationsOlderThan in
          src/libstore/profiles.cc).
        '';
      };
      randomizedDelaySec = lib.mkOption {
        type = lib.types.singleLineStr;
        default = "3h";
        description = ''
          Spread each collect over this window. A collect walks the whole store,
          and OnCalendar=weekly lands every host on Monday 00:00 sharp; the Pis
          are SD-card rooted and already opted out of the optimiser for that
          reason. Kept under 4h so the window closes before the 04:15 optimiser.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.nixGc.enable {
      # Nothing in this fleet has ever run a real collector on a schedule, and
      # that -- not the absence of nix.gc -- is what filled k8s-node04. Measured
      # there 2026-11-23: 14786 unreachable store paths, one manual collect
      # freed 7.5 GiB, root went 91% -> 72% (issue #189).
      #
      # The two mechanisms that look like a GC and are not:
      #
      # - nix-sweep's --gc step is quota-gated (gcQuota = 60 below). Upstream
      #   returns "Nothing to do" unless the store exceeds that percentage of its
      #   block device, and no host is close: measured 2026-09-28 the fleet sits
      #   at 3.7-29.4%, and node04 was at ~43% the day it filled up. The step
      #   fires daily and exits early daily, on every host.
      # - nix.settings.min-free / max-free fire only while Nix is building, so
      #   growth between builds is never collected.
      #
      # --delete-older-than is not the part that matters, contrary to how #189
      # reads it: nix-sweep already prunes the system and comin profiles daily at
      # remove-older 7d. What was missing is the collect. The flag still earns its
      # place by reaching the profiles nix-sweep is not pointed at --
      # nix-collect-garbage recurses all of /nix/var/nix/profiles, so per-user and
      # home-manager profiles are included -- and by pruning past keepMin = 10 on
      # a host that deploys rarely.
      nix.gc = {
        automatic = true;
        dates = config.nixGc.dates;
        options = "--delete-older-than ${config.nixGc.deleteOlderThan}";
        randomizedDelaySec = config.nixGc.randomizedDelaySec;
      };
    })

    (lib.mkIf config.nixSweep.enable {
      services.nix-sweep = {
        enable = true;
        interval = config.nixSweep.interval;
        removeOlder = config.nixSweep.removeOlder;
        keepMin = config.nixSweep.keepMin;
        # cleanout alone only prunes profile generations; without gc the store
        # paths stay on disk forever.
        #
        # Kept, but note this step has never collected anywhere: gcQuota = 60 is
        # unreachable fleet-wide (see the note in the nixGc block). The weekly
        # nix-gc timer above is what collects; this one is the emergency path for
        # a host that crosses 60% of its device.
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
      # with the nix-gc timer, which now runs on every host: weekly at Monday
      # 00:00 plus a randomized delay capped under 4h (see nixGc.randomizedDelaySec).
      nix.optimise = {
        automatic = config.nixSweep.optimise;
        dates = config.nixSweep.optimiseDates;
      };
    })
  ];
}
