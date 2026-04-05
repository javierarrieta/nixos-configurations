{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    k3sAgent = {
      enable = lib.mkEnableOption "K3s agent configuration";
      serverAddr = lib.mkOption {
        type = lib.types.str;
        description = "K3s server address";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to K3s token file";
      };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra flags for K3s agent";
      };
    };
  };

  config = lib.mkIf config.k3sAgent.enable {
    services.k3s = {
      enable = true;
      role = "agent";
      serverAddr = config.k3sAgent.serverAddr;
      tokenFile = config.k3sAgent.tokenFile;
      extraFlags = toString config.k3sAgent.extraFlags;
    };

    systemd.services.k3s.path = with pkgs; [
      openiscsi
      e2fsprogs
      xfsprogs
      util-linux
    ];
  };
}
