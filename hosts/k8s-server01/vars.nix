{ config, pkgs }:
{
  hostname = "k8s-server01";
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://192.168.0.12:6443";
    tokenFile = config.sops.secrets."k3s_token".path;
    disable = [
      "traefik"
      "servicelb"
    ];
    taints = [ "node-role.kubernetes.io/master=true:NoSchedule" ];
  };
}
