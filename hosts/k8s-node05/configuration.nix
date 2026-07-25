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
    ../../modules/nixos/prometheus.nix
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
    interface = "enp0s20u2";
    ipAddress = vars.ipAddress;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
  };

  networking.interfaces.enp0s20u2.useDHCP = false;

  prometheus.nodeExporter.enable = true;

  rsyslog.enable = true;

  openiscsi.enable = true;

  sopsBase.enable = true;

  k3s = vars.k3s;

  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      ENERGY_PERF_POLICY_ON_AC = "balance-power";
    };
  };

  k8sNetwork = {
    enable = true;
    primaryInterface = "enp0s20u2";
    hostName = vars.hostname;
  };

  cominGitOps.enable = true;

  nixSweep.enable = true;

  networking.hostName = vars.hostname;

  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };

  boot.kernelParams = [
    "overlay.override_cgroup=1"
    "cgroup.no_restrict=1"
  ];

  services.smartd.enable = true;

  sops.secrets."k3s_token" = {
    mode = "0600";
    owner = "root";
  };
  sops.secrets."k8s-node05/network_env" = {
    mode = "0400";
    owner = "root";
  };
  sops.secrets."ssh_keys/k8s-node05_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/k8s-node05_host_public" = {
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
