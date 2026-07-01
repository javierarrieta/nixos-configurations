{
  config,
  lib,
  pkgs,
  nixpkgs,
  nix-sweep,
  home-manager,
  ...
}:

{
  imports = [
    # Hardware
    ./hardware-configuration.nix

    # Modules
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/nix-sweep.nix

    # Users
    ../../common/users.nix
  ];

  # Boot loader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 5;

  # AMD GPU configuration
  boot.extraModprobeConfig = ''
    # Allocate more memory to the GPU VRAM for llama.cpp
    options amdgpu gttsize=25000
    options ttm pages_limit=3932160
    options ttm page_pool_size=3932160
  '';

  # Network
  networking.hostName = "ryzen7";
  networking.interfaces.enp3s0.ipv4.addresses = [
    {
      address = "192.168.1.182";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "8.8.8.8" ];
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;

  # SOPS configuration
  sops = {
    defaultSopsFile = ../../secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."users/javier_password_hash" = {
      mode = "0600";
      owner = "root";
      neededForUsers = true;
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
    secrets."ssh_keys/ryzen7_host_private" = {
      mode = "0600";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key";
    };
    secrets."ssh_keys/ryzen7_host_public" = {
      mode = "0644";
      owner = "root";
      path = "/etc/ssh/ssh_host_ed25519_key.pub";
    };
  };

  # Tempfiles
  systemd.tmpfiles.rules = [
    "d /home/javier/.ssh 0700 javier javier -"
  ];

  # System user for llama service
  users.users.ollama = {
    isSystemUser = true;
    group = "ollama";
    extraGroups = [
      "render"
      "video"
    ];
  };

  users.groups.ollama = { };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    neovim
    wget
    git
    vulkan-tools
    starship
    fish
    llama-cpp-vulkan
    open-webui
    python313Packages.chromadb
  ];

  # Services
  ssh.enable = true;

  # Open WebUI
  services.open-webui = {
    package = pkgs.open-webui;
    enable = true;
    port = 8083;
    host = "0.0.0.0";
  };

  # Nix settings
  nix.optimise.automatic = true;
  nixpkgs.config.allowUnfree = true;

  home-manager.users.javier.imports = [
    ../../modules/home-manager/base.nix
    ../../modules/home-manager/llm.nix
  ];

  # Hardware
  hardware.graphics.enable32Bit = true;
  hardware.graphics.enable = true;

  # Llama service
  systemd.services.llama-svc = {
    enable = true;
    description = "Llama service";
    unitConfig = {
      Type = "simple";
    };
    serviceConfig = {
      ExecStart = "${pkgs.llama-cpp-vulkan}/bin/llama-server -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF  --host 0.0.0.0  --ctx-size 16384 --metrics'";
      Type = "simple";
      User = "ollama";
      Group = "ollama";
      WorkingDirectory = "/opt/llm/models";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    wantedBy = [ "multi-user.target" ];
  };

  # Nix-sweep configuration
  services.nix-sweep = {
    enable = true;
    interval = "daily";
    removeOlder = "7d";
    keepMin = 10;
  };

  system.stateVersion = "25.11";
}
