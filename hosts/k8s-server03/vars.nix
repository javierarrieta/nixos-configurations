{ config, pkgs }:
let
  # Off-node etcd snapshots to MinIO. Each member needs its own folder (retention is
  # scoped per folder) and its own minute. See common/etcd-snapshot-s3.nix.
  etcdSnapshot = import ../../common/etcd-snapshot-s3.nix {
    folder = "casa/server03";
    cron = "40 */6 * * *";
  };
in
{
  hostname = "k8s-server03";
  # CLI-safe subset, fed to k3sSnapshotMonitor. Handing the server-only flags to
  # `k3s etcd-snapshot list` exits fatal; see common/etcd-snapshot-s3.nix.
  snapshotS3Flags = etcdSnapshot.s3Flags;
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://192.168.0.12:6443";
    tokenFile = config.sops.secrets."k3s_token".path;
    disable = [
      "traefik"
      "servicelb"
    ];
    taints = [ "node-role.kubernetes.io/master=true:NoSchedule" ];
    # Expose 10257/10259 so Prometheus can scrape the control plane. See the
    # option docs in modules/nixos/k3s.nix - the endpoints are authenticated,
    # not open. Requires a service restart of k3s on this host.
    controlPlaneMetricsBindAddress = "0.0.0.0";
    # Expose etcd's metrics port on the node address as well as loopback, so
    # Prometheus can scrape 192.168.0.13:2381. Without this k3s binds 2381 to
    # loopback only (k3s pkg/etcd/etcd.go, listenMetricsURLs) and every scrape
    # of this host fails with connection refused, which surfaces as
    # etcdInsufficientMembers / etcdMembersDown even though etcd is healthy.
    # Unlike the two ports above, 2381/metrics is UNAUTHENTICATED - the NixOS
    # firewall is off on this host, so anything on the LAN can read it. The
    # payload is operational only (disk fsync, leader changes, DB size, peer
    # traffic), no keys and no object data.
    # Requires a service restart of k3s on this host.
    extraFlags = [ "--etcd-expose-metrics" ] ++ etcdSnapshot.serverFlags;
  };
}
