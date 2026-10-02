{ config, pkgs }:
let
  networkInterface = "eno1";
in
{
  hostname = "titan";
  inherit networkInterface;
  # Placeholders on purpose: nixpkgs 26.05 parses addresses at eval time, so the
  # real values arrive at runtime from the SOPS `titan/network_env` secret.
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3s = {
    enable = true;
    role = "server";
    # Single-node cluster of its own: no serverAddr, no token file. The token
    # secret exists so a future second node can join without re-initialising.
    tokenFile = config.sops.secrets."k3s_token_titan".path;
    # Both home clusters already run the k3s defaults, and titan reaches the home
    # LAN over WireGuard, so the defaults would collide.
    clusterCidr = "10.62.0.0/16";
    serviceCidr = "10.63.0.0/16";
    # Keep the k3s bundle intact: Traefik + ServiceLB are the public ingress path
    # on a host with no LoadBalancer controller of its own (spec D4).
    disable = [ ];
    taints = [ ];
    controlPlaneMetricsBindAddress = "0.0.0.0";
    requiresMountFor = [ "var-lib-rancher-k3s-storage.mount" ];
    extraFlags = [
      # wg0 is up before k3s starts, and flannel's interface auto-detection will
      # pick it; the pod network then runs into a tunnel that leads to the home
      # LAN instead of the local bridge. Pin it to the public NIC (spec §6).
      "--flannel-iface=${networkInterface}"

      # --- etcd snapshots to MinIO over the mesh (spec §13b, Task 16a) ---
      # An etcd snapshot is every Secret in the cluster in plaintext, so the bucket
      # is the most sensitive object in the design: the MinIO key is scoped to
      # exactly titan-etcd and titan-pvc and nothing else.
      #
      # Every flag name below was verified against the host binary on 2026-10-02
      # (`k3s server --help`). The first draft of this task invented a
      # `--etcd-snapshot-s3-*` family that does not exist; k3s exits on an unknown
      # flag, so that version would have killed k3s at startup and tripped the
      # health gate. Re-verify after any k3s major bump.
      "--etcd-s3"
      # NO PORT. s3.l.arrieta.eu is a Traefik Ingress on 443; the Service's 9000 is
      # an in-cluster port that is never reachable from outside (k8s-casa
      # apply/50-apps/casa/minio.yaml). Pinning :9000 connects to the MetalLB VIP
      # and hangs until --etcd-s3-timeout.
      "--etcd-s3-endpoint=https://s3.l.arrieta.eu"
      "--etcd-s3-bucket=titan-etcd"
      "--etcd-s3-region=us-east-1"
      "--etcd-s3-folder=titan"
      # Path style is mandatory, not an optimisation: 'auto' lookup would resolve
      # titan-etcd.s3.l.arrieta.eu, which has no DNS record and no cert because the
      # Ingress serves exactly one host. k8s-techdelivery sets addressing_style=path
      # against the same MinIO for the same reason.
      "--etcd-s3-bucket-lookup-type=path"
      # S3 retention, NOT --etcd-snapshot-retention: that one counts local snapshot
      # files, which do not exist when snapshots go to S3. Wrong flag here means the
      # bucket silently grows forever.
      "--etcd-s3-retention=24"
      # The embedded quotes are load-bearing. k3s.extraFlags is toString'd into one
      # ExecStart string, so an unquoted cron is word-split by systemd into
      # `--etcd-snapshot-schedule-cron=0` plus three stray args and k3s refuses to
      # start. Verified by evaluating the generated ExecStart.
      "--etcd-snapshot-schedule-cron=\"0 * * * *\""
    ];
    kubeletArgs = [
      # The 150 G root filesystem is small enough that a fat image cache starves
      # etcd before the kubelet would evict anything on its own.
      "image-gc-high-threshold=80"
      "image-gc-low-threshold=70"
      "eviction-hard=nodefs.available<10%"
    ];
  };
}
