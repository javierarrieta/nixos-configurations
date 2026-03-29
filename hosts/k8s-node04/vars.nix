{ config, pkgs }:
{
  hostname = "k8s-node04";
  ipAddress = "192.168.0.17";
  defaultGateway = "192.168.0.1";
  nameservers = [
    "8.8.8.8"
    "8.8.4.4"
  ];

  k3sOptions = {
    enable = true;
    role = "agent";
    extraFlags = toString [
      #"--node-label node-role.kubernetes.io/worker=true"
      "--node-label storage=ssd"
      "--node-label arch=amd64"
      "--node-label cpu=n100"
      "--kubelet-arg pod-max-pids=8192"
    ];
    tokenFile = config.sops.secrets."k3s_token".path;
    serverAddr = "https://192.168.0.11:6443";
  };
}
