{
  config,
  lib,
  pkgs,
  ...
}:

let
  sshKeys = import ../../common/ssh-keys.nix;
in
{
  options = {
    minimalImage.enable = lib.mkEnableOption "Minimal image base configuration";
  };

  config = lib.mkIf config.minimalImage.enable {
    users.users.javier = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "video"
      ];
      shell = pkgs.fish;
      openssh.authorizedKeys.keys = sshKeys;
    };

    users.defaultUserShell = pkgs.fish;

    environment.systemPackages = with pkgs; [
      vim
      wget
      git
      fish
    ];

    programs.fish.enable = true;

    services.openssh.enable = true;

    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

    networking.firewall.enable = false;

    security.sudo.wheelNeedsPassword = false;

    system.stateVersion = "25.11";
  };
}
