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

      # --- embedded etcd (spec D1) ---
      # A lone k3s server does NOT get etcd: without this flag it runs on sqlite at
      # server/db/state.db, and every --etcd-s3-* flag below is inert. This was
      # discovered the hard way on 2026-10-02 -- `k3s etcd-snapshot save` answered
      # "etcd datastore disabled" -- because the module comment claimed an empty
      # serverAddr implied embedded etcd. It does not; upstream only omits --server.
      #
      # Enabling it is not a flag flip on a live cluster: k3s cannot migrate
      # sqlite -> etcd in place. The migration is 'stop k3s, move state.db aside,
      # start with this flag, re-apply' -- see the Backup section of README.md.
      # Done now, while the cluster is empty, rather than after workloads land.
      "--cluster-init"

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
      # BARE HOST: NO SCHEME AND NO PORT. Two separate traps, both hit on
      # 2026-10-03.
      #   - No port: s3.l.arrieta.eu is a Traefik Ingress on 443; the Service's 9000
      #     is an in-cluster port never reachable from outside (k8s-casa
      #     apply/50-apps/casa/minio.yaml). Pinning :9000 hits the MetalLB VIP and
      #     hangs until --etcd-s3-timeout.
      #   - No scheme: minio-go rejects an endpoint carrying one, with
      #     "Endpoint url cannot have fully qualified paths." k3s' own default is the
      #     bare "s3.amazonaws.com". Rancher #14144 documents this failing SILENTLY
      #     in the server -- the CLI at least tells you. TLS is on by default;
      #     --etcd-s3-insecure is what disables it, not the scheme.
      "--etcd-s3-endpoint=s3.l.arrieta.eu"
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
      # 24 snapshots at the 6h cadence below = 6 days of recovery points.
      "--etcd-s3-retention=24"
      # Every 6h, not hourly. Measured on 2026-10-02: pidstat showed zero block
      # writes across every process at idle, so the datastore is nowhere near a
      # disk-endurance problem -- but an hourly full copy of the DB, uploaded over a
      # 17 ms tunnel, is still work that buys nothing past the 4th snapshot.
      # The embedded quotes are load-bearing. k3s.extraFlags is toString'd into one
      # ExecStart string, so an unquoted cron is word-split by systemd into
      # `--etcd-snapshot-schedule-cron=0` plus three stray args and k3s refuses to
      # start. Verified by evaluating the generated ExecStart.
      "--etcd-snapshot-schedule-cron=\"0 */6 * * *\""
      # Paired with node-status-update-frequency below; do not change one without
      # the other. Grace period MUST exceed the kubelet's lease renew interval or
      # kube-controller-manager declares the node NotReady and, after the 5m
      # NoExecute taint, evicts the workloads off the only node in the cluster.
      "--kube-controller-manager-arg=node-monitor-grace-period=5m"
    ];
    kubeletArgs = [
      # The 150 G root filesystem is small enough that a fat image cache starves
      # etcd before the kubelet would evict anything on its own.
      "image-gc-high-threshold=80"
      "image-gc-low-threshold=70"
      "eviction-hard=nodefs.available<10%"
      # Kubelet renews its node lease and posts node status on this interval
      # (default 10s). On a single-node cluster with no autoscaler and no other
      # node to reschedule onto, that is ~8,600 fsyncs a day into the datastore
      # for information nobody consumes faster than once a minute. MUST be paired
      # with --kube-controller-manager-arg=node-monitor-grace-period above.
      "node-status-update-frequency=2m"
    ];
  };
}
