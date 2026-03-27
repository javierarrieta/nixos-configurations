# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{
  config,
  lib,
  pkgs,
  nix-sweep,
  ...
}:
let
  vars = import ./vars.nix { inherit config pkgs; };
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./users.nix
    ./disko.nix
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
    secrets."k3s_token" = {
      mode = "0600";
      owner = "root";
    };
    secrets."k8s-server01/network_env" = {
      mode = "0400";
      owner = "root";
    };
    secrets."ssh_keys/k8s-server01_host_private" = {
      mode = "0600";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key";
    };
    secrets."ssh_keys/k8s-server01_host_public" = {
      mode = "0644";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key.pub";
    };
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.systemd.enable = true;

  # boot.loader.grub.device = "/dev/sda";   # (for BIOS systems only)

  networking.hostName = vars.hostname; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = "UTC";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  # virtualisation.docker.enable = true;

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  users.defaultUserShell = pkgs.fish;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    screen
    htop
    git
    fish
    prometheus-node-exporter
    smartmontools
    k3s
    kubernetes-helm
    openiscsi # For longhorn
    nfs-utils
    xfsprogs
    age
    sops
    neovim
    btop
    rsyslog
    tpm2-tss # Provides systemd-cryptenroll
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs.fish.enable = true;
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;
  # Enable the OpenSSH daemon.
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
    # Required for longhorn
    enable = true;
    name = "openscsi";
  };
  services.prometheus = {
    exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9002;
      };
    };
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

  systemd.services.k3s.path = with pkgs; [
    openiscsi
    e2fsprogs # mkfs.ext4
    xfsprogs # mkfs.xfs
    util-linux # mount, umount, blkid
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

  systemd.tmpfiles.rules = [
    # Hack for Longhorn, see https://github.com/longhorn/longhorn/issues/2166#issuecomment-1864656450
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.interfaces.enp3s0.ipv4.addresses = [
    {
      address = vars.ipAddress;
      prefixLength = 24;
    }
  ];
  networking.interfaces.enp3s0.useDHCP = false;

  networking.defaultGateway = vars.defaultGateway;
  networking.nameservers = vars.nameservers;

  networking.firewall = {
    enable = false;
    # allowedTCPPorts = [
    #   6443 # k3s: required so that pods can reach the API server (running on port 6443 by default)
    # 2379 # k3s, etcd clients: required if using a "High Availability Embedded etcd" configuration
    # 2380 # k3s, etcd peers: required if using a "High Availability Embedded etcd" configuration
    # ];
    # allowedUDPPorts = [
    #   8472 # k3s, flannel: required if using multi-node for inter-node networking
    # ];
  };

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

  # fileSystems."/storage01" = {
  #   device = "/dev/disk/by-uuid/57f18cec-59c3-4343-8a5a-180acdc3f2b1";
  #   fsType = "ext4";
  # };

  # Load network secrets into systemd services
  systemd.services."network-addresses-enp3s0".serviceConfig.EnvironmentFile =
    lib.mkForce
      config.sops.secrets."k8s-server01/network_env".path;
  systemd.services.network-setup.serviceConfig.EnvironmentFile =
    lib.mkForce
      config.sops.secrets."k8s-server01/network_env".path;
  systemd.services.k3s.serviceConfig.EnvironmentFile =
    lib.mkForce
      config.sops.secrets."k8s-server01/network_env".path;

  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/javierarrieta/nixos-configurations.git";
        branches.main.name = "main";
        poller.period = 900;
      }
    ];
  };

  services.nix-sweep = {
    enable = true;
    interval = "daily";
    removeOlder = "7d";
    keepMin = 10;
  };

}
