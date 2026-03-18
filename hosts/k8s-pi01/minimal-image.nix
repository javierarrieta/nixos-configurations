{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  boot.kernelParams = [
    "8250.nr_uarts=1"
    "console=ttyAMA0,115200"
    "console=tty1"
  ];

  networking.hostName = "k8s-pi01";

  time.timeZone = "UTC";

  users.users.javier = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAxtDTZvN/YqOQC1nOGahb/qLp35iYnBTPaGld6/N6k javier@Javiers-MacBook-Air.local"
    ];
  };

  services.openssh = {
    enable = true;
  };

  programs.fish.enable = true;

  systemd.tmpfiles.rules = [
    "d /home/javier/.ssh 0700 javier javier -"
  ];

  system.stateVersion = "25.11";
}
