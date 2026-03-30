{
  config,
  lib,
  pkgs,
  ...
}:

let
  vars = import ./vars.nix {
    inherit
      config
      pkgs
      lib
      ;
  };
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  users.users.javier = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "video"
    ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAxtDTZvN/YqOQC1nOGahb/qLp35iYnBTPaGld6/N6k javier@Javiers-MacBook-Air.local"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7hbsmE8Ve4mfIsUrTTHRTq2pdO5ZjOLJsEdjhR4lakDpbe4NH1L5iFHGlIMQGnvHQuBZKqIhaIcVR1uriXWqouQTlfRS884jfvLOeYXo6jPzrFJaXLaHl35vyEE9SLZKTvm4F7B7ZyUGI5sBvXRBIw7VvYdEcLSdIawyTtIaHbZuUfnfqiqgeSR7zxrzNpG7gXAgpumy1xBNGRCIQRJs/IdYljL3Yx4uaFQB6CDHSUzpID+hFUafhPtPoTAlHZJEyIyD8bDd5UMt3jUWcEg5lPxNmPYTsB8uiF0pImfKZfYVyrb9hYJklHpmpTihhqsDvni6lnR0wX6xcvxI96XYipo1qJyI4eshIGjjRU93Si+wzhVP9CoKVQeuhpKSkX2t+BFVewPKUb8SqvIyd0WfxX7cZGbWYWxamvN1/LaHT68IfPgfvattviL+PL7zpQA3C8orTbGiqJRtlglw07sdCyz5Wgy0TW6Lmetx4TRkSPLbrakgYvaogbpaev0FTd4c= javier@Franciscos-MBP"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOHYYT+i+mHzpO2+LObL1bOmb7Ry0c3Ju/7T4/01aybf jaarriet@jaarriet-mac"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTCPPiQVMBxqQdAyUgUvM7FL+Fi8FErDOIxhdz/WlLu javier@kvm"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_rpi4;
  boot.kernelParams = [
    "8250.nr_uarts=1"
    "console=ttyAMA0,115200"
    "console=tty1"
  ];

  networking.hostName = vars.hostname;

  networking.interfaces.eth0.ipv4.addresses = [
    {
      address = vars.ipAddress;
      prefixLength = 24;
    }
  ];
  networking.interfaces.eth0.useDHCP = false;
  networking.defaultGateway = vars.defaultGateway;
  networking.nameservers = vars.nameservers;

  networking.firewall.enable = false;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  users.defaultUserShell = pkgs.fish;

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    fish
    libraspberrypi
  ];

  programs.fish.enable = true;

  services.openssh = {
    enable = true;
    # Will generate a new host key on first boot
  };

  # Enable Comin for GitOps deployment of the full configuration
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/javierarrieta/nixos-configurations.git";
        branches.main.name = "main";
        poller.period = 300;
      }
    ];
  };

  system.stateVersion = "25.11";
}
