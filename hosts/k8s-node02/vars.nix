{ config, pkgs }:
{
  hostname = "k8s-node02";
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.0.11:6443";
    tokenFile = config.sops.secrets."k3s_token".path;
    labels = [
      "storage=ssd"
      "arch=amd64"
      "cpu=n100"
    ];
    # Image GC defaults (85% high / 40% low) never fire here. Measured 2026-10-21
    # this node sat at 78.5% used (53.6 GiB of 68.3) holding 20 GiB of
    # unreferenced images -- teslamate, wealthfolio's investment-portfolio-manager,
    # immich, coder, open-webui -- and kubelet collected nothing, because 78.5%
    # is below the trigger. `crictl rmi --prune` had to be run by hand.
    #
    # 70% makes GC trigger at ~20.5 GiB free instead of ~10.2 GiB, which is real
    # margin against the ~2.44 GiB imagefs eviction threshold that evicted pods
    # on k8s-node04 the same day.
    #
    # Temporary: drop this once the root is grown to the declared 120G
    # (nixos-configurations#141). A percentage tuned around an undersized disk is
    # a workaround for the disk, not a cluster policy.
    kubeletArgs = [
      "pod-max-pids=2048"
      "image-gc-high-threshold=70"
      "image-gc-low-threshold=50"
    ];
  };
}
