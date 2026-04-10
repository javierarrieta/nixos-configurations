{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    k3s = {
      enable = lib.mkEnableOption "K3s configuration";
      role = lib.mkOption {
        type = lib.types.enum [
          "server"
          "agent"
        ];
        description = "K3s role: server or agent";
      };
      serverAddr = lib.mkOption {
        type = lib.types.str;
        description = "K3s server address (required for agent role)";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to K3s token file";
      };
      disable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Components to disable (server only)";
      };
      taints = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Node taints";
      };
      labels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Node labels";
      };
      kubeletArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Kubelet arguments";
      };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional flags";
      };
    };
  };

  config = lib.mkIf config.k3s.enable {
    # Disable firewall for Kubernetes networking
    networking.firewall.enable = false;

    services.k3s = {
      enable = true;
      role = config.k3s.role;
      serverAddr = config.k3s.serverAddr;
      tokenFile = config.k3s.tokenFile;
      extraFlags = toString (
        (lib.optionals (config.k3s.role == "server") (map (c: "--disable=${c}") config.k3s.disable))
        ++ (map (t: "--node-taint=${t}") config.k3s.taints)
        ++ (map (l: "--node-label=${l}") config.k3s.labels)
        ++ (map (a: "--kubelet-arg=${a}") config.k3s.kubeletArgs)
        ++ config.k3s.extraFlags
      );
    };

    systemd.services.k3s.path = with pkgs; [
      openiscsi
      e2fsprogs
      xfsprogs
      util-linux
      cryptsetup
    ];
  };
}
