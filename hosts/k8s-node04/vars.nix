{ config, pkgs }:
{
  hostname = "k8s-node04";
  ipAddress = "192.168.0.17";
  defaultGateway = "192.168.0.1";
  nameservers = [
    "8.8.8.8"
    "8.8.4.4"
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
    # Image GC defaults (85% high / 40% low) are too late for a 48.9 GiB root.
    # 85% of this disk means GC starts with ~7.3 GiB free, and the imagefs
    # eviction threshold is ~2.44 GiB -- a maintenance-wave image unpack crosses
    # that gap in minutes. On 2026-10-21 this node reached ~0.74 GiB free and
    # evicted casa/hindsight and monitoring/loki-canary on imagefs.available.
    #
    # 70% makes GC trigger at ~14.7 GiB free instead, roughly 6x the eviction
    # threshold. Verified afterwards: `crictl rmi --prune` freed 6 GiB here, and
    # containerd is only 11 GiB against 31 GiB used, so the real problem is the
    # disk size, not image accumulation.
    #
    # Temporary: drop this once the root is grown to the declared 120G
    # (nixos-configurations#140).
    kubeletArgs = [
      "pod-max-pids=2048"
      "image-gc-high-threshold=70"
      "image-gc-low-threshold=50"
    ];
  };
}
