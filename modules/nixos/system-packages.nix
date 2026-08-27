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
      excludePackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Packages to exclude from the common set (e.g. heavy/irrelevant ones on low-power nodes)";
      };
    };
  };

  config = lib.mkIf config.systemPackages.enable {
    environment.systemPackages =
      lib.foldl (acc: p: lib.remove p acc) (with pkgs; [
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
        logrotate
        rsyslog
        tpm2-tss
        iptables
        lsof
        binutils
        jq
        yq
      ]) config.systemPackages.excludePackages
      ++ config.systemPackages.extraPackages;
  };
}
