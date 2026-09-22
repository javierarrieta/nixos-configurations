{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.raspberryPi;
in
{
  options = {
    raspberryPi = {
      enable = lib.mkEnableOption "Raspberry Pi 4 specific configuration";

      buildJobs = lib.mkOption {
        type = lib.types.either lib.types.ints.positive (lib.types.enum [ "auto" ]);
        default = 2;
        example = 4;
        description = ''
          Maximum concurrent Nix builds on this Pi (nix.settings.max-jobs).
          "auto" uses every core, which is what the nix default does and what
          caused the OOM class described below; raise it only on boards with
          enough RAM to hold that many concurrent cc1 processes.
        '';
      };

      buildCores = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = ''
          NIX_BUILD_CORES handed to each individual build (nix.settings.cores),
          which is what make -j follows inside a derivation. Kept at 1 so that
          buildJobs is the single knob controlling peak memory: buildJobs x
          buildCores is roughly the number of compiler processes alive at once.
        '';
      };

      zram = {
        enable = (lib.mkEnableOption "compressed zram swap as an OOM safety valve") // {
          default = true;
        };
        memoryPercent = lib.mkOption {
          type = lib.types.ints.between 1 100;
          default = 50;
          description = "zram device size as a percentage of physical RAM.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # --- native-build memory ceiling -------------------------------------
    # linux-rpi is in no aarch64 binary cache (verified against
    # cache.nixos.org: 404 for both the .drv and the out path), so every Pi
    # compiles the kernel itself. Under the nix defaults (max-jobs = "auto",
    # cores = 0) that is -j4 of concurrent cc1 on a board whose generated
    # hardware-configuration.nix also sets `swapDevices = [ ]` -- no swap at
    # all. On 2026-09-21 k8s-pi01's comin log stops dead mid-compile:
    #   17:07:38  CC  mm/workingset.o
    #   17:07:38  store: generation b5339a68-... removed from the store
    #   ...then 93 minutes of silence, and four later "New commits have been
    #   fetched" with no build ever restarting.
    # A SIGKILLed compiler never gets its error into comin's log stream, so a
    # dead build reads as a live one and the builder stays wedged. Capping
    # concurrency bounds peak RSS; zram absorbs the residual spike without
    # wearing the SD card the way a real swapfile would.
    #
    # Plain assignment, not mkDefault: mkDefault (prio 50) would outrank a
    # host's own nix.settings assignment (prio 100). Tune via
    # raspberryPi.buildJobs / buildCores, or mkForce nix.settings here.
    nix.settings.max-jobs = cfg.buildJobs;
    nix.settings.cores = cfg.buildCores;

    zramSwap = lib.mkIf cfg.zram.enable {
      enable = true;
      memoryPercent = cfg.zram.memoryPercent;
    };
    # --- end native-build memory ceiling -------------------------------

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;
    boot.kernelPackages = pkgs.linuxPackages_rpi4;
    boot.kernelParams = [
      "8250.nr_uarts=1"
      "console=ttyAMA0,115200"
      "console=tty1"
      "cgroup_enable=cpuset"
      "cgroup_memory=1"
      "cgroup_enable=memory"
    ];

    environment.systemPackages = with pkgs; [
      libraspberrypi
    ];
  };
}
