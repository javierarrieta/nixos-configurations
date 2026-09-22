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

      kernelFlavour = lib.mkOption {
        type = lib.types.enum [
          "vendor"
          "mainline"
        ];
        default = "vendor";
        description = ''
          Which kernel the board boots.

          "vendor" = pkgs.linuxPackages_rpi4, the Raspberry Pi downstream
          kernel still shipped by nixpkgs. It is in no aarch64 binary cache
          and nixpkgs now warns on every evaluation that the linux-rpi
          series is going away, so each Pi recompiles it natively (~5h) on
          every config change.

          "mainline" = pkgs.linuxPackages_6_18, the generic aarch64 kernel,
          which IS on cache.nixos.org: kernel, modules and initrd are
          downloaded instead of compiled. It ships the same
          bcm2711-rpi-*.dtb set and the same `ethernet0 = &genet` device
          tree alias as the vendor tree, so the boot chain
          (config.txt -> U-Boot -> extlinux FDTDIR) and the eth0 interface
          name are unchanged.

          Trade-off: the GENET ethernet MAC is built in on the vendor kernel
          (CONFIG_BCMGENET=y in bcm2711_defconfig) but a module on the
          generic one, so the MAC and PHY drivers are listed explicitly
          below; without them upstream users report an ethernet that links
          but passes no traffic.
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
    # raspberryPi.kernelFlavour = "mainline" sidesteps the kernel half of
    # this class outright (cached kernel, nothing compiled here), but the
    # ceiling stays: the ~555 non-kernel derivations still build on the
    # board, and they are what is left of the deploy time.
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
    boot.kernelPackages =
      if cfg.kernelFlavour == "mainline" then pkgs.linuxPackages_6_18 else pkgs.linuxPackages_rpi4;

    # Mainline only: the GENET MAC and the Broadcom PHY are modules on the
    # generic kernel, built in on the vendor one. Load the PHY before the
    # MAC, and stage both in the initrd so no boot path is left without
    # ethernet -- the field failure mode is a link that passes no traffic.
    #
    # Naming trap: in this kernel the GENET module is `genet`, not
    # `bcmgenet` (drivers/net/ethernet/broadcom/genet/genet.ko; verified
    # against the 6.18.49 modules output). `bcmgenet` survives only as a
    # `platform:` alias, and the older field reports that list `bcmgenet`,
    # `bcm_phy_lib` and `mdio_bcm_unimac` predate the rename -- the PHY lib
    # is pulled by modules.dep and the unimac MDIO is built in here.
    boot.kernelModules = lib.optionals (cfg.kernelFlavour == "mainline") [
      "broadcom"
      "genet"
    ];
    boot.initrd.availableKernelModules = lib.optionals (cfg.kernelFlavour == "mainline") [
      "broadcom"
      "genet"
    ];

    # Mainline only: without a filter every DTB the generic kernel builds
    # lands in /boot on each switch, and this board only ever needs its own.
    hardware.deviceTree.filter = lib.mkIf (cfg.kernelFlavour == "mainline") (
      lib.mkDefault "bcm2711-rpi-*.dtb"
    );

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
