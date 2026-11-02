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
        iotop
        git
        fish
        prometheus-node-exporter
        smartmontools
        # The interactive `k3s` CLI (k3s kubectl, k3s etcd-snapshot) must be the
        # same minor as the server binary, or `k3s etcd-snapshot list` on a 1.36
        # node is run through a 1.35 client. Read back from the k3s module rather
        # than naming pkgs.k3s, which is pinned to a different minor.
        config.services.k3s.package
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
        sysstat
        fio
        strace
        tcpdump
        mtr
        dnsutils
        nmap
        iproute2
        pciutils
        usbutils
        rsync
      ]) config.systemPackages.excludePackages
      ++ config.systemPackages.extraPackages;
  };
}
