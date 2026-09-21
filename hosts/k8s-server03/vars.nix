{ config, pkgs }:
{
  hostname = "k8s-server03";
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
    # Expose 10257/10259 so Prometheus can scrape the control plane. See the
    # option docs in modules/nixos/k3s.nix - the endpoints are authenticated,
    # not open. Requires a service restart of k3s on this host.
    controlPlaneMetricsBindAddress = "0.0.0.0";
  };
}
