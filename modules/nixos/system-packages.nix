{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    systemPackages = {
      enable = lib.mkEnableOption "Common system packages";
      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Additional packages to install";
      };
    };
  };

  config = lib.mkIf config.systemPackages.enable {
    environment.systemPackages =
      with pkgs;
      [
        vim
        wget
        screen
        htop
        git
        fish
        prometheus-node-exporter
        smartmontools
        k3s
        kubernetes-helm
        openiscsi
        nfs-utils
        xfsprogs
        age
        sops
        neovim
        btop
        rsyslog
        tpm2-tss
      ]
      ++ config.systemPackages.extraPackages;
  };
}
