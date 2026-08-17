{
  config,
  lib,
  pkgs,
  ...
}:
let
  vars = import ./vars.nix { inherit config pkgs; };
in
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../common/users.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/static-network.nix
    ../../modules/nixos/rsyslog.nix
    ../../modules/nixos/openiscsi.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/k3s.nix
    ../../modules/nixos/k8s-network.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/nix-sweep.nix
  ];

  base.enable = true;
  systemPackages.enable = true;
  ssh.enable = true;

  staticNetwork = {
    enable = true;
    interface = "enp3s0";
    ipAddress = vars.ipAddress;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
  };

  networking.interfaces.enp3s0.useDHCP = false;
  networking.interfaces.enp1s0.useDHCP = false;

  rsyslog.enable = true;

  openiscsi.enable = true;

  sopsBase.enable = true;

  k3s = vars.k3s;

  k8sNetwork = {
    enable = true;
    primaryInterface = "enp3s0";
    secondaryInterfaces = [ "enp1s0" ];
    hostName = vars.hostname;
  };

  cominGitOps.enable = true;

  nixSweep.enable = true;

  networking.hostName = vars.hostname;

  sops.secrets."k3s_token" = {
    mode = "0600";
    owner = "root";
  };
  sops.secrets."k8s-node02/network_env" = {
    mode = "0400";
    owner = "root";
  };
  sops.secrets."ssh_keys/k8s-node02_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/k8s-node02_host_public" = {
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  system.stateVersion = "23.11";
}
