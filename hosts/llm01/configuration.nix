{
  config,
  lib,
  pkgs,
  unstablePkgs,
  llamaPkgs,
  nix-sweep,
  home-manager,
  ...
}:
{
  imports = [
    # Hardware
    ./disko.nix
    ./hardware-configuration.nix

    # Modules
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/prometheus.nix
    ../../modules/nixos/rsyslog.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/nix-sweep.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/comin-health-gate.nix
    ../../modules/nixos/coder-host.nix
    ../../modules/nixos/openiscsi.nix
    ../../modules/nixos/llama-cpp-agent.nix

    # Users
    ../../common/users.nix
  ];

  # Module enablement
  base.enable = true;
  systemPackages.enable = true;
  ssh.enable = true;
  prometheus.nodeExporter.enable = true;
  prometheus.nodeExporter.collectors = [ "drm" ];
  rsyslog.enable = true;
  sopsBase.enable = true;
  nixSweep.enable = true;
  cominGitOps.enable = true;
  cominGitOps.pollInterval = 900;
  cominGitOps.confirmerMode = "auto";
  cominGitOps.healthGate.enable = true;
  cominGitOps.healthGate.checks = [
    "current-system"
    "llama-cpp"
  ];
  coderHost.enable = true;
  # The built-in Coder provisioner runs in k3s and reaches llm01's Podman/helper
  # APIs from the LAN; restrict to the cluster network only.
  coderHost.allowedApiSources = [ "192.168.0.0/24" ];

  # SOPS host-specific secrets (base secrets are provided by sops-base module)
  sops.secrets."wireguard/private_key" = {
    mode = "0600";
    owner = "root";
  };
  sops.secrets."wireguard/address" = {
    mode = "0644";
    owner = "root";
  };
  sops.secrets."wireguard/publicKey" = {
    mode = "0644";
    owner = "root";
  };
  sops.secrets."wireguard/endpoint" = {
    mode = "0644";
    owner = "root";
  };
  sops.secrets."wireguard/allowedIPs" = {
    mode = "0644";
    owner = "root";
  };
  sops.secrets."ssh_keys/llm01_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/llm01_host_public" = {
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  # Disk configuration
  disko.enableConfig = true;

  # Boot (boot loader and initrd come from base module)
  security.tpm2.enable = true; # Enables TPM2 userspace tools

  # Hardware
  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;
  boot.initrd.kernelModules = [
    "amdgpu"
    "nfs"
    "nfs4"
  ];

  # Kernel configuration
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [
    "amdgpu.sched_policy=2"
    "amd_iommu=pt"
    "amdgpu.gttsize=112640"
    "ttm.pages_limit=28835840"
    "ttm.page_pool_size=26214400"
  ];
  boot.extraModprobeConfig = ''
    # Allocate more memory to the GPU VRAM for llama.cpp
    options amdgpu gttsize=120000
    options ttm pages_limit=31457280
    options ttm page_pool_size=27525120
  '';

  # Network
  networking.networkmanager.enable = true;
  networking.hostName = "llm01";

  # System packages (common set comes from system-packages module)
  systemPackages.extraPackages =
    (with pkgs; [
      zsh
      wireguard-tools
      dig
      hdparm
      nix-tree
      nix-index
      python3Packages.huggingface-hub
      qemu
    ])
    ++ (with unstablePkgs; [
      rocmPackages.rocm-smi
      rocmPackages.clr
    ])
    ++ [ llamaPkgs.vulkan ];

  home-manager.users.javier.imports = [
    ../../modules/home-manager/llm.nix
  ];

  # System users for LLM services
  users.users = {
    ollama = {
      isSystemUser = true;
      group = "ollama";
      uid = 27002;
      extraGroups = [
        "render"
        "video"
      ];
    };
  };

  users.groups = {
    ollama = {
      gid = 27002;
    };
  };

  # Services
  services = {
    # SSH comes entirely from the ssh module (PermitRootLogin = "no")
    # Node exporter enable/collectors come from the prometheus module
    prometheus.exporters.node.openFirewall = true;

    # Logs are forwarded to Loki via rsyslog; keep the local journal small
    journald.extraConfig = ''
      SystemMaxUse=500M
    '';
  };

  # llama.cpp serving stack (options in modules/nixos/llama-cpp-agent.nix)
  services.llamaCppAgent = {
    enable = true;
    package = llamaPkgs.vulkan;
    models = import ./llm-models.nix;
    # benchmark 2026-08-28: threads 1 regressed Ornith (MoE A3B) throughput 30%
    threads = 8;
    threadsBatch = 8;
  };

  # Nix settings
  nix.settings = {
    download-buffer-size = 536870912;
  };
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  system.stateVersion = "25.11";
}
