{
  config,
  lib,
  pkgs,
  unstable,
  unstablepkgs,
  home-manager,
  llama-cpp,
  ...
}:
let
  vars = import ./vars.nix {
    inherit
      config
      pkgs
      lib
      ;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./users.nix
  ];

  sops = {
    defaultSopsFile = ../../secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."users/javier_password_hash" = {
      mode = "0600";
      owner = "root";
    };
    templates."javier-password" = {
      content = "${config.sops.placeholder."users/javier_password_hash"}";
    };
    secrets."ssh_keys/javier_private" = {
      mode = "0600";
      owner = "javier";
      path = "${config.users.users.javier.home}/.ssh/id_ed25519";
    };
    secrets."ssh_keys/javier_public" = {
      mode = "0644";
      owner = "javier";
      path = "${config.users.users.javier.home}/.ssh/id_ed25519.pub";
    };
    secrets."k8s-pi03/k3s_token" = {
      mode = "0600";
      owner = "root";
    };
    secrets."ssh_keys/k8s-pi03_host_private" = {
      mode = "0600";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key";
    };
    secrets."ssh_keys/k8s-pi03_host_public" = {
      mode = "0644";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key.pub";
    };
  };

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_rpi4;
  boot.kernelParams = [
    "8250.nr_uarts=1"
    "console=ttyAMA0,115200"
    "console=tty1"
  ];

  networking.hostName = vars.hostname;

  networking.interfaces.eth0.ipv4.addresses = [
    {
      address = vars.ipAddress;
      prefixLength = 24;
    }
  ];
  networking.interfaces.eth0.useDHCP = false;
  networking.defaultGateway = vars.defaultGateway;
  networking.nameservers = vars.nameservers;

  networking.firewall.enable = false;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  users.defaultUserShell = pkgs.fish;

  environment.systemPackages = with pkgs; [
    vim
    wget
    screen
    htop
    git
    fish
    prometheus-node-exporter
    k3s
    kubernetes-helm
    openiscsi
    nfs-utils
    xfsprogs
    age
    sops
    neovim
    btop
    libraspberrypi
  ];

  programs.fish.enable = true;

  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  services.openssh = {
    enable = true;
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  services.openiscsi = {
    enable = true;
    name = "openscsi";
  };

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" ];
    port = 9002;
  };

  home-manager = {
    backupFileExtension = "orig";
    useGlobalPkgs = true;
    useUserPackages = true;
    users.javier = {
      imports = [
        ../../modules/home-manager/base.nix
        ./home-manager.nix
      ];
      home.stateVersion = "25.11";
      home.username = "javier";
      home.homeDirectory = "/home/javier";
    };
  };

  services.k3s = vars.k3sOptions;

  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/javierarrieta/nixos-configurations.git";
        branches.main.name = "main";
        poller.period = 300;
      }
    ];
  };

  systemd.services.k3s.path = with pkgs; [
    openiscsi
    e2fsprogs
    xfsprogs
    util-linux
  ];

  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    "f /var/log/rsyslog.log 0644 root root - -"
    "f /var/spool/rsyslog/* 0640 root adm - -"
  ];

  services.rsyslogd = {
    enable = true;
    extraConfig = ''
      $ModLoad imuxsock
      $ModLoad imjournal
      $WorkDirectory /var/spool/rsyslog
      $ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
      $FileOwner root
      $FileGroup adm
      $FileCreateMode 0640
      $DirCreateMode 0755
      $UMask 0022
      $WorkDirectoryCreateMode 0755

      *.* @@192.168.0.41:514
    '';
  };

  hardware.enableRedistributableFirmware = true;

  system.stateVersion = "25.11";
}
