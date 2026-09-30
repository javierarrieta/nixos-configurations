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
    # the rest of base.nix. ryzen7 imports this file without ever setting
    # base.enable = true, so gating the cache on that flag would silently leave
    # that host off the cache.
    ./attic-cache.nix
  ];

  options = {
    base = {
      enable = lib.mkEnableOption "Base system configuration";
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

    # Cap the journal so logs cannot fill the disk (llm01 already used 500M)
    services.journald.extraConfig = ''
      SystemMaxUse=500M
      SystemKeepFree=1G
    '';
  };
}
