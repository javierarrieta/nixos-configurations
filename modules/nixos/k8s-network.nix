{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    k8sNetwork = {
      enable = lib.mkEnableOption "Kubernetes network configuration";
      primaryInterface = lib.mkOption {
        type = lib.types.str;
        description = "Primary network interface";
      };
      secondaryInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Secondary network interfaces to disable DHCP on";
      };
      hostName = lib.mkOption {
        type = lib.types.str;
        description = "Host name for network secrets";
      };
    };
  };

  config = lib.mkIf config.k8sNetwork.enable {
    # See k3s.nix: mkDefault so public-host.nix can win without mkForce.
    networking.firewall.enable = lib.mkDefault false;

    systemd.services."network-addresses-${config.k8sNetwork.primaryInterface}".serviceConfig.EnvironmentFile =
      lib.mkForce config.sops.secrets."${config.k8sNetwork.hostName}/network_env".path;
    systemd.services.k3s.serviceConfig.EnvironmentFile =
      lib.mkForce
        config.sops.secrets."${config.k8sNetwork.hostName}/network_env".path;
  };
}
