{ config, pkgs }:
{
  hostname = "k8s-node04";
  ipAddress = "192.168.0.17";
  defaultGateway = "192.168.0.1";
  # LAN resolvers, matching node01/02/03/05 and the servers.
  #
  # The literal 8.8.8.8/8.8.4.4 here made CoreDNS on this node forward the
  # private `casa.arrieta` zone to Google, which returns an authoritative
  # NXDOMAIN because `.arrieta` is not a real TLD. CoreDNS runs on node04 and
  # node05 and kube-proxy splits queries across both, so every private-zone
  # lookup from a pod had a ~50% chance of landing on the replica that could
  # not resolve it. Measured 2026-10-21: gatus `ldap-lb`
  # (tcp://ldap.casa.arrieta:636) failed 89 of 178 probes, each one an
  # NXDOMAIN from 10.42.7.175 (this node's coredns) with no SYN following.
  #
  # Placeholders rather than literals: this host has the SOPS network_env
  # secret, so $DNS1/$DNS2 are resolved at activation by
  # modules/nixos/static-network.nix. k8s-pi* hardcode their nameservers
  # instead because they have no network_env, and a literal "$DNS1" in
  # resolv.conf fails at the first query rather than at build.
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
