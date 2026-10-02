{ config, pkgs }:
let
  networkInterface = "eth0";
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
