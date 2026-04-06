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
    kubeletArgs = [ "pod-max-pids=2048" ];
  };
}
