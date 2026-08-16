{
  config,
  lib,
  pkgs,
  unstable,
  unstablepkgs,
  home-manager,
  llama-cpp,
  ...
}:
let
  vars = import ./vars.nix {
    inherit config pkgs lib;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../common/users.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/static-network.nix
    ../../modules/nixos/prometheus.nix
    ../../modules/nixos/rsyslog.nix
    ../../modules/nixos/openiscsi.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/k3s.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/raspberry-pi.nix
  ];

  base.enable = true;
  systemPackages.enable = true;
  systemPackages.excludePackages = [
    pkgs.kubernetes-helm
    pkgs.tpm2-tss
  ];
  ssh.enable = true;
  raspberryPi.enable = true;

  # Override boot loader for Raspberry Pi
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = true;

  staticNetwork = {
    enable = true;
    interface = "eth0";
    ipAddress = vars.ipAddress;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
  };

  networking.interfaces.eth0.useDHCP = false;

  prometheus.nodeExporter.enable = true;
  prometheus.nodeExporter.port = 9002;

  rsyslog.enable = true;

  openiscsi.enable = true;

  sopsBase.enable = true;

  k3s = vars.k3s;

  cominGitOps = {
    enable = true;
    pollInterval = 300;
  };

  networking.hostName = vars.hostname;

  hardware.enableRedistributableFirmware = true;

  sops.secrets."k3s_token" = {
    mode = "0600";
    owner = "root";
  };
  sops.secrets."ssh_keys/k8s-pi02_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/k8s-pi02_host_public" = {
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    "f /var/log/rsyslog.log 0644 root root - -"
    "f /var/spool/rsyslog/* 0640 root adm - -"
  ];

  system.stateVersion = "25.11";
}
