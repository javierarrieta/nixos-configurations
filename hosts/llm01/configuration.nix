{
  config,
  lib,
  pkgs,
  unstablePkgs,
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
    ../../modules/nixos/pi-cache.nix
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
    halogen-flash.nixosModules.default

    # Users
    ../../common/users.nix
  ];

  # Module enablement
  base.enable = true;
  # pi is installed by dev-tools.nix here; without this the comin build
  # compiles the bun2nix package from source on every deploy.
  piCache.enable = true;
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
  # A services.halogenFlash.download.revision change turns ExecStartPre into a
  # ~118 GiB fetch that leaves the unit "activating" for hours. The 30 min
  # default would roll back a deploy that is merely still downloading, so the
  # window here is sized to outlast a full weights fetch.
  cominGitOps.healthGate.halogenWarmupSec = 14400; # 4h
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
  # GPU memory params per upstream's measured configuration
  # (halogen-flash-server README, "the host settings these numbers were
  # measured on"): gttsize/pages_limit scale to installed RAM — llm01 has
  # ~126 GiB usable, so the 128 GB row applies (124 GiB = 99.3% of RAM; the
  # values are ceilings, not reservations). amd_iommu=off is upstream's one
  # measured lever: 13-16% of prefill vs amd_iommu=pt, at the cost of DMA
  # translation machine-wide and the NPU. vm_update_mode/noretry/
  # sg_display are deliberately NOT set (upstream: "leave them off").
  # cwsr_enable=0 is our own addition: ROCm#5724 GPU-hang workaround.
  boot.kernelParams = [
    "amdgpu.gttsize=126976"
    "ttm.pages_limit=32505856"
    "amd_iommu=off"
    "amdgpu.cwsr_enable=0"
  ];
  # Modprobe copies of the same values (module-load time; kernel params
  # above win when both apply) — kept in sync to avoid divergent GTT sizing
  # depending on load order.
  boot.extraModprobeConfig = ''
    options amdgpu gttsize=126976
    options ttm pages_limit=32505856
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
    ]);

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
  };

  # Logs are forwarded to Loki via rsyslog; keep the local journal small.
  # Same value base.nix already ships, stated explicitly because the intent (Loki
  # holds the history, the journal is a ring buffer) is the point. An option, not
  # an extraConfig append: two SystemMaxUse lines in one file work only because
  # journald keeps the last one.
  base.journald.systemMaxUse = "500M";

  # halogen-flash-server (Strix Halo, Qwen3.8-Flash-Next, ROCm) is the
  # serving stack on this host. It owns the iGPU's ~112-120 GiB GTT pool, so
  # nothing else configured here may claim it.
  #
  # The llama.cpp stack that used to sit here is gone (2026-09-30): the
  # service was already disabled and halogen-flash replaced it. Note that
  # `llamaPkgs.vulkan` was also in systemPackages.extraPackages, so the
  # package stayed in the system closure even with the service off -- that is
  # why removal, not just leaving it disabled, was the point.
  services.halogenFlash = {
    enable = true;
    user = "ollama"; # rootless podman; container runs as ollama (uid 27002)
    podmanHome = "/opt/llm/halogen"; # ollama's podman storage + unit $HOME (image layers live here)
    mode = "all";
    modelsDir = "/opt/llm/models/halogen"; # ~130 GiB of headroom needed
    download.enable = true;
    # No `download.revision` here on purpose: it comes from the flake's
    # `defaultWeightsRevision`, so the image and the model version it is
    # known-good with live together and move together in one reviewed PR.
    # Overriding it here would split that pair across two repos again.
    # Pull the pinned image at service start, as `user` — rootless podman
    # stores images per-user, so a root `podman pull` would be invisible to
    # this unit. Safe to leave on because the module pins `image` by digest:
    # if the registry is unreachable but that exact digest is already local
    # the unit still succeeds, so an outage does not take the server down.
    # A digest that is neither pullable nor present fails the unit, and the
    # role units Require it — loud, and caught by the comin health gate.
    pull.enable = true;
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
