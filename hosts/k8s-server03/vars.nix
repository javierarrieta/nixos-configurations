{ config, pkgs }:
{
  hostname = "k8s-server03";
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3sOptions = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--advertise-address $IP_ADDRESS"
      "--cluster-cidr 10.42.0.0/16"
      "--service-cidr 10.43.0.0/16"
    ];
    tokenFile = config.sops.secrets."k3s_token".path;
    serverAddr = "https://192.168.0.13:6443";
  };
}
