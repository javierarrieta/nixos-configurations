{ config, pkgs }:
{
  hostname = "k8s-node03";
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3sOptions = {
    enable = true;
    role = "agent";
    extraFlags = toString [
      #"--node-label node-role.kubernetes.io/worker=true"
      "--node-label storage=ssd"
      "--node-label arch=amd64"
      "--node-label cpu=n100"
    ];
    tokenFile = config.sops.secrets."k8s-node03/k3s_token".path;
    serverAddr = "https://$SERVER_ADDR:6443";
  };

  lokiPromtailClient = {
    url = "$LOKI_URL";
  };
}
