{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    k3sServer = {
      enable = lib.mkEnableOption "K3s server configuration";
      serverAddr = lib.mkOption {
        type = lib.types.str;
        description = "K3s server address";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to K3s token file";
      };
      disable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "traefik"
          "servicelb"
        ];
        description = "Components to disable";
      };
      taints = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "node-role.kubernetes.io/master=true:NoSchedule" ];
        description = "Node taints";
      };
    };
  };

  config = lib.mkIf config.k3sServer.enable {
    services.k3s = {
      enable = true;
      role = "server";
      serverAddr = config.k3sServer.serverAddr;
      tokenFile = config.k3sServer.tokenFile;
      extraFlags = toString (
        (map (c: "--disable=${c}") config.k3sServer.disable)
        ++ (map (t: "--node-taint=${t}") config.k3sServer.taints)
      );
    };

    systemd.services.k3s.path = with pkgs; [
      openiscsi
      e2fsprogs
      xfsprogs
      util-linux
    ];
  };
}
