{ config, pkgs }:
{
  hostname = "k8s-server01";
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
     "--disable=traefik"
     "--disable=servicelb"
     "--node-taint=node-role.kubernetes.io/master=true:NoSchedule"
    ];
    tokenFile = config.sops.secrets."k3s_token".path;
    serverAddr = "https://192.168.0.12:6443";
  };
}
