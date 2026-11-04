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
    ../../modules/nixos/k3s-snapshot-monitor.nix
    ../../modules/nixos/k8s-network.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/comin-health-gate.nix
    ../../modules/nixos/nix-sweep.nix
  ];

  base.enable = true;
  systemPackages.enable = true;
  ssh.enable = true;

  staticNetwork = {
    enable = true;
    interface = "enp2s0";
    ipAddress = vars.ipAddress;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
  };

  networking.interfaces.enp2s0.useDHCP = false;

  rsyslog.enable = true;

  openiscsi.enable = true;

  sopsBase.enable = true;

  # Credentials for the scheduled etcd snapshots. k3s reads --etcd-s3-access-key from
  # $AWS_ACCESS_KEY_ID and --etcd-s3-secret-key from $AWS_SECRET_ACCESS_KEY, so no flag
  # carries a secret into the world-readable unit file.
  #
  # It MUST be k3s.environmentFiles, not systemd.services.k3s.serviceConfig.
  # EnvironmentFiles (plural): systemd has no such [Service] key, ignores it silently,
  # and k3s then authenticates to MinIO anonymously -- every scheduled snapshot fails
  # with `Access Denied` while the node stays Ready and the build stays green. Found
  # 2026-10-03 on titan; the restore drill had passed only because the manual
  # `etcd-snapshot save` inherited credentials from the operator's shell.
  k3s = vars.k3s // {
    environmentFiles = [ config.sops.secrets."casa/minio_env".path ];
  };

  # Nothing else watches whether snapshots actually land: k3s swallows S3 failures
  # inside the server (Rancher #14144), so the node stays Ready and the bucket quietly
  # stops receiving objects. This publishes the age of the newest object under this
  # member's prefix into the node_exporter textfile dir, which the in-cluster
  # node-exporter DaemonSet already reads on this host -- the same path
  # comin_pending_confirmation travels.
  k3sSnapshotMonitor = {
    enable = true;
    envFile = config.sops.secrets."casa/minio_env".path;
    s3Flags = vars.snapshotS3Flags;
    # Age proves an upload landed; this proves the bytes open as a database.
    verify.enable = true;
  };

  k8sNetwork = {
    enable = true;
    primaryInterface = "enp2s0";
    hostName = vars.hostname;
  };

  cominGitOps.enable = true;
  cominGitOps.branch = "stable";
  cominGitOps.healthGate.enable = true;

  nixSweep.enable = true;

  networking.hostName = vars.hostname;

  sops.secrets."k3s_token" = {
    mode = "0600";
    owner = "root";
  };
  # Shared by all three control-plane members: a MinIO key scoped to the casa-etcd
  # bucket and nothing else. Exactly two KEY=value lines, AWS_ACCESS_KEY_ID and
  # AWS_SECRET_ACCESS_KEY. This must exist in secrets.yaml BEFORE the generation that
  # references it activates -- a missing EnvironmentFile fails the k3s unit at start.
  sops.secrets."casa/minio_env" = {
    mode = "0400";
    owner = "root";
  };
  sops.secrets."k8s-server01/network_env" = {
    mode = "0400";
    owner = "root";
  };
  sops.secrets."ssh_keys/k8s-server01_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/k8s-server01_host_public" = {
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  system.stateVersion = "23.11";
}
