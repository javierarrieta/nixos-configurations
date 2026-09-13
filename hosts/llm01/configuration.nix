{
  config,
  lib,
  pkgs,
  unstablePkgs,
  llamaPkgs,
  nix-sweep,
  home-manager,
  halogen-flash,
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
    ../../modules/nixos/llama-cpp/agent.nix
    halogen-flash.nixosModules.default

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
    "halogen-flash"
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
    # ROCm#5724: newer amdgpu MES 0x83 firmware hangs the GPU in known-good
    # ROCm workloads on Strix Halo (flash_serve wedged twice mid-load with
    # 'HW Exception: GPU Hang'). Disabling CWSR is the upstream workaround;
    # the Vulkan/llama.cpp path is unaffected. Drop this when the firmware
    # fix lands in linux-firmware.
    "amdgpu.cwsr_enable=0"
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

  # llama.cpp serving stack (options in modules/nixos/llama-cpp/agent.nix)
  services.llamaCppAgent = {
    # enable = true;                 # leave off until the weights are wanted
    package = llamaPkgs.vulkan;
    models = import ./llm-models.nix;
    threads = 8;
    threadsBatch = 8;
    metrics.enable = true;
    # 6-model preset; router default cap is 4 — without this, requests for
    # the 6th model evict a loaded one and scrapes re-load it (thrash loop)
    extraServerArgs = [ "--models-max 6" ];
    environment = {
      GGML_VK_DISABLE_COOPMAT = "1";
      GGML_VK_VISIBLE_DEVICES = "0";
      RADV_PERFTEST = "nogttspill";
    };
  };

  # halogen-flash-server (Strix Halo, Qwen3.8-Flash-Next, ROCm).
  # MUTUALLY EXCLUSIVE with llamaCppAgent: both live in the same ~112–120 GiB
  # GTT pool on this iGPU, so enable only one at a time. To go back to
  # llama.cpp: set halogenFlash.enable = false and llamaCppAgent.enable = true.
  services.halogenFlash = {
    enable = true;
    user = "ollama"; # rootless podman; container runs as ollama (uid 27002)
    podmanHome = "/opt/llm/halogen"; # ollama's podman storage + unit $HOME (image layers live here)
    mode = "all";
    modelsDir = "/opt/llm/models/halogen"; # ~130 GiB of headroom needed
    download.enable = true;
    # environment.HALOGEN_VISION_TOWER = "1"; # enable vision sidecar on /v1
  };

  # Nix settings
  nix.settings = {
    download-buffer-size = 536870912;
  };
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  system.stateVersion = "25.11";
}
