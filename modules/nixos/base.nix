{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./dbus-broker-timeout.nix
    # Imported unconditionally, NOT inside the `base.enable` gate below: the
    # binary cache is wanted on every host, including ones that do not opt into
    # the rest of base.nix. The old ryzen7 workstation imported this file without
    # ever setting base.enable = true, so gating the cache on that flag would
    # silently leave such a host off the cache.
    ./attic-cache.nix

    # base.journald.systemMaxUse is declared unconditionally (options always
    # are) but only emitted under base.enable, so a host that imports this file
    # without enabling it -- as ryzen7 used to -- could set a ceiling that nothing
    # ever writes. Fail the eval instead of ignoring it silently.
    (
      { config, lib, ... }:
      lib.mkIf (!config.base.enable) {
        assertions = [
          {
            assertion = config.base.journald.systemMaxUse == "500M";
            message =
              ""
              + "base.journald.systemMaxUse is set but base.enable is false, so "
              + "no journald config is emitted and the ceiling is a no-op. "
              + "Enable base or drop the ceiling.";
          }
        ];
      }
    )
  ];

  options = {
    base = {
      enable = lib.mkEnableOption "Base system configuration";
      journald = {
        systemMaxUse = lib.mkOption {
          type = lib.types.str;
          default = "500M";
          description = ''
            Ceiling for the journal, in systemd units. A host that wants a
            different ceiling sets this rather than appending its own
            SystemMaxUse line to services.journald.extraConfig: journald takes
            the last assignment in the file, so an appended line works only for
            as long as the merge order of extraConfig stays the way someone
            assumed, and a silently reverted ceiling is a disk full at 3am.
          '';
        };
      };
    };
  };

  config = lib.mkIf config.base.enable {
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";
    users.defaultUserShell = pkgs.fish;
    programs.fish.enable = true;

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.initrd.systemd.enable = true;

    boot.supportedFilesystems = [ "nfs" ];
    services.rpcbind.enable = true;

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Cap the journal so logs cannot fill the disk (llm01 already used 500M).
    # The value is an option (base.journald.systemMaxUse) so a host with a
    # bigger root overrides it once instead of racing the merge order of
    # extraConfig with a second SystemMaxUse line.
    services.journald.extraConfig = ''
      SystemMaxUse=${config.base.journald.systemMaxUse}
      SystemKeepFree=1G
    '';
  };
}
