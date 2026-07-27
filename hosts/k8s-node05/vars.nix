{ config, pkgs }:
{
  hostname = "k8s-node05";
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
      "arch=amd64"
    ];
    kubeletArgs = [ "pod-max-pids=2048" ];
  };
}
