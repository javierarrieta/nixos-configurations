{
  config,
  pkgs,
  lib,
}:
{
  hostname = "k8s-pi01";
  ipAddress = "192.168.0.21";
  defaultGateway = "192.168.0.1";
  nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  k3sOptions = {
    enable = true;
    role = "agent";
    extraFlags = [
      "--node-label storage=sd"
      "--node-label arch=aarch64"
      "--node-label cpu=rpi4"
    ];
    tokenFile = lib.mkIf (
      config.sops.secrets ? "k8s-pi01/k3s_token"
    ) config.sops.secrets."k8s-pi01/k3s_token".path;
    serverAddr = "https://192.168.0.200:6443";
  };

  lokiPromtailClient = {
    url = "http://192.168.0.41:3100/loki/api/v1/push";
  };
}
