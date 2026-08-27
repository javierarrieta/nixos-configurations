{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./dbus-broker-timeout.nix ];

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
