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

  k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.0.11:6443";
    tokenFile = lib.mkIf (config.sops.secrets ? "k3s_token") config.sops.secrets."k3s_token".path;
    labels = [
      "storage=sd"
      "arch=aarch64"
      "cpu=rpi4"
    ];
  };
}
