{ config, pkgs }:
let
  networkInterface = "enp0s20u1";
in
{
  hostname = "k8s-node05";
  inherit networkInterface;
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3s = {
    enable = true;
    role = "agent";
    # Held on 1.35 while the casa control plane moves first. node05 is a worker
    # on the auto-deploy canary ring (branch main), so an unpinned bump would put
    # a 1.36 kubelet on a cluster whose API servers are still 1.35 -- Kubernetes
    # skew allows servers newer than agents, never the reverse.
    #
    # Suspending comin here is NOT an alternative: comin-approve.sh treats any
    # suspended canary as a health-gate rollback and aborts the whole fleet run,
    # so the hold-back has to be a version pin, not a pause.
    #
    # REMOVE THIS PIN once k8s-server01..03 report v1.36.4+k3s1 (PR #162). Nothing
    # enforces it -- EXPECT_VERSION only covers the fleet ring, and node05 is not
    # in it -- so a forgotten pin leaves this node a minor behind indefinitely.
    package = pkgs.k3s;
    serverAddr = "https://192.168.0.11:6443";
    tokenFile = config.sops.secrets."k3s_token".path;
    labels = [
      "arch=amd64"
    ];
    kubeletArgs = [ "pod-max-pids=2048" ];
    extraFlags = [ "--flannel-iface=${networkInterface}" ];
  };
}
