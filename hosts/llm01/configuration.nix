{
  config,
  lib,
  pkgs,
  unstable,
  unstablepkgs,
  home-manager,
  ...
}:

{
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
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

    secrets."ssh_keys/javier_authorized" = {
      mode = "0444";
      owner = "javier";
      path = "${config.users.users.javier.home}/.ssh/authorized_keys";
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
    secrets."wireguard/private_key" = {
      mode = "0600";
      owner = "root";
    };
    secrets."wireguard/address" = {
      mode = "0644";
      owner = "root";
    };
    secrets."wireguard/publicKey" = {
      mode = "0644";
      owner = "root";
    };
    secrets."wireguard/endpoint" = {
      mode = "0644";
      owner = "root";
    };
    secrets."wireguard/allowedIPs" = {
      mode = "0644";
      owner = "root";
    };
    secrets."ssh_keys/llm01_host_private" = {
      mode = "0600";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key";
    };
    secrets."ssh_keys/llm01_host_public" = {
      mode = "0644";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key.pub";
    };
  };

  disko.enableConfig = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.systemd.enable = true;
  security.tpm2.enable = true; # Enables TPM2 userspace tools

  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;

  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [ "amdgpu.sched_policy=2" "amd_iommu=off" ];
  boot.extraModprobeConfig = ''
    # Allocate more memory to the GPU VRAM for llama.cpp
    options amdgpu gttsize=120000
    options ttm pages_limit=31457280
    options ttm page_pool_size=27525120
  '';

  programs.zsh.enable = true;

  networking.networkmanager.enable = true;

  networking.hostName = "llm01"; # Define your hostname.

  sops.secrets."wireguard/address" = { };
  sops.secrets."wireguard/publicKey" = { };
  sops.secrets."wireguard/endpoint" = { };
  sops.secrets."wireguard/allowedIPs" = { };

  sops.templates."wg0.conf".content = ''
    [Interface]
    Address = ${config.sops.placeholder."wireguard/address"}
    DNS = 8.8.8.8, 1.1.1.1
    PrivateKey = ${config.sops.placeholder."wireguard/private_key"}

    [Peer]
    PublicKey = ${config.sops.placeholder."wireguard/publicKey"}
    Endpoint = ${config.sops.placeholder."wireguard/endpoint"}
    AllowedIPs = ${config.sops.placeholder."wireguard/allowedIPs"}
    PersistentKeepalive = 25
  '';

  networking.wg-quick.interfaces.wg0.configFile = config.sops.templates."wg0.conf".path;

  environment.systemPackages = with pkgs; [
    tpm2-tss # Provides systemd-cryptenroll
    git
    zsh
    fish
    openiscsi
    vim
    rocmPackages.rocm-smi
    wireguard-tools
    dig
    hdparm
    unstablepkgs.llama-cpp-vulkan
  ];

  time.timeZone = "Utc";

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

  users.users.javier = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.templates."javier-password".path;
    extraGroups = [
      "wheel"
      "networkmanager"
      "render"
      "video"
    ];
    shell = pkgs.zsh;
  };

  users.users.ollama = {
    isSystemUser = true;
    group = "ollama";
    extraGroups = [
      "render"
      "video"
    ];
  };

  users.groups.ollama = { };

  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = true;
      };
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };

    prometheus.exporters.node = {
      enable = true;
      openFirewall = true;
      enabledCollectors = [ "drm" ];
    };

    ollama = {
      enable = true;
      acceleration = "vulkan";
      openFirewall = true;
      host = "0.0.0.0";
      models = "/opt/llm/models";
      package = unstablepkgs.ollama-vulkan;
      environmentVariables = {
        OLLAMA_KEEP_ALIVE = "300";
        OLLAMA_VULKAN = "1";
      };
    };

    open-webui = {
      enable = true;
      openFirewall = true;
      host = "0.0.0.0";
      package = unstablepkgs.open-webui;
    };
  };

  systemd.services.llama-cpp-server = {
    description = "LLaMA C++ Server with Vulkan";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      User = "ollama";
      Group = "ollama";
      WorkingDirectory = "/opt/llm/models";
      ExecStart = "${unstablepkgs.llama-cpp-vulkan}/bin/llama-server --port 8001 --host 0.0.0.0 --models-preset /opt/llm/llama-cpp.ini --offline --jinja -ngl 99 --threads -1 --gpu-layers 999 --n-gpu-layers 999";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8001 ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    download-buffer-size = 67108864;
  };
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  systemd.tmpfiles.rules = [
    "d /opt/llm/models 0755 ollama ollama -"
    "d /home/javier/.ssh 0700 javier javier -"
  ];

  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "git@github.com:javierarrieta/nixos-configurations.git";
        branches.main.name = "main";
        poller.period = 900;
      }
    ];
  };

  system.stateVersion = "25.11";
}
