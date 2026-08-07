{
  config,
  lib,
  pkgs,
  unstablePkgs,
  unstable,
  nix-sweep,
  home-manager,
  ...
}:
let
  models = import ./llm-models.nix;
  llamaPackage = unstablePkgs.llama-cpp-vulkan;

  # Shared-home dotfiles for the Coder workspace user (no home-manager user).
  # Copy rules (`C`) are idempotent: no-op if the destination already exists.
  coderBashrc = pkgs.writeText "coder-bashrc" ''
    if command -v fish > /dev/null; then exec fish; fi
  '';
  coderGitconfig = pkgs.writeText "coder-gitconfig" ''
    [user]
      name = Coder Workspaces
      email = coder@llm01
    [init]
      defaultBranch = main
  '';
in
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
      python311Packages.huggingface-hub
      nix-tree
      nix-index
      qemu
      coder
    ])
    ++ (with unstablePkgs; [
      rocmPackages.rocm-smi
      rocmPackages.clr
      llama-cpp-vulkan
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

  # Coder workspace host: workspaces run directly as this user via SSH
  users.users.coder = {
    isSystemUser = true;
    group = "coder";
    home = "/home/coder";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINvfTtJaSFJ4drj+LqoS0V0DXIi3LdRKhdcP8WVOqa3P coder-llm01"
    ];
  };
  users.groups.coder = { };

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

  # llama.cpp server service
  systemd.services.llama-cpp-server = {
    description = "llama-cpp server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "llama-cpp-config.service"
    ];
    requires = [ "llama-cpp-config.service" ];
    restartTriggers = [ (builtins.toJSON models) ];
    environment = {
      XDG_CACHE_HOME = "/var/cache/llama.cpp";
      # HSA_* vars were ROCm-only; this service runs the Vulkan backend so they
      # don't apply. coopmat FA shader path is buggy/slow on gfx1151 (Strix Halo)
      # at deep context; fall back to scalar FA which is still much faster than FA-off.
      GGML_VK_DISABLE_COOPMAT = "1";
    };
    serviceConfig = {
      Type = "simple";
      User = "ollama";
      Group = "ollama";
      # Allows the GPU to lock system RAM for direct access
      LimitMEMLOCK = "infinity";
      WorkingDirectory = "/opt/llm/models";
      CacheDirectory = "llama.cpp";
      ExecStart = "${llamaPackage}/bin/llama-server --port 8001 --host 0.0.0.0 --models-preset /opt/llm/llama-cpp.ini --no-mmap --offline -ngl 99 --threads 16 --log-verbosity 2 --metrics";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # Watch llama-cpp config file for changes
  systemd.paths.llama-cpp-config-watch = {
    description = "Watch llama-cpp config file for changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathModified = "/opt/llm/llama-cpp.ini";
      Unit = "llama-cpp-server.service";
    };
  };

  # Firewall
  networking.firewall.allowedTCPPorts = [ 8001 ];

  # Nix settings
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    download-buffer-size = 536870912;
  };
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  # Tempfiles
  systemd.tmpfiles.rules = [
    "d /opt/llm 0755 ollama ollama -"
    "d /opt/llm/models 0755 ollama ollama -"
    "d /opt/llm/models/llama-cpp 0755 ollama ollama -"
    "Z /opt/llm - ollama ollama -"
    "d /home/coder 0755 coder coder -"
    "C /home/coder/.bashrc 0644 coder coder - ${coderBashrc}"
    "C /home/coder/.gitconfig 0644 coder coder - ${coderGitconfig}"
  ];

  # Download llama.cpp models from HuggingFace
  systemd.services.llama-cpp-download-models = {
    description = "Download llama-cpp models from HuggingFace";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    restartTriggers = [ (builtins.toJSON models) ];
    serviceConfig = {
      Type = "oneshot";
      User = "ollama";
      Group = "ollama";
      WorkingDirectory = "/opt/llm/models/llama-cpp";
      ReadWritePaths = [ "/opt/llm/models/llama-cpp" ];
      Environment = [
        "HOME=/opt/llm/models"
        "XDG_CACHE_HOME=/opt/llm/models/.cache"
      ];
      PrivateTmp = false;
      NoNewPrivileges = false;
      ExecStart = pkgs.writeShellScript "download-models" ''
        ${lib.concatStrings (
          lib.mapAttrsToList (
            entry-name: config:
            let
              modelId = config.modelId;
              filename = config.filename;
              mmproj = config.mmproj or null;
              modelDraft = config.modelDraft or null;
              modelDraftModelId = config.modelDraftModelId or modelId;
              matchSplit = builtins.match "(.*)-[0-9]+-of-[0-9]+\\.gguf" filename;
              downloadArgs =
                if matchSplit != null then
                  "--include ${builtins.head matchSplit}-*-of-*.gguf"
                else
                  "\"${filename}\"";
            in
            ''
              echo "Downloading ${entry-name} from ${modelId}..."
              ${pkgs.python311Packages.huggingface-hub}/bin/hf download "${modelId}" ${downloadArgs} --local-dir /opt/llm/models/llama-cpp --repo-type model
              ${lib.optionalString (mmproj != null) ''
                echo "Downloading mmproj for ${entry-name}..."
                ${pkgs.python311Packages.huggingface-hub}/bin/hf download "${modelId}" "${mmproj}" --local-dir /opt/llm/models/llama-cpp --repo-type model
              ''}
              ${lib.optionalString (modelDraft != null) ''
                echo "Downloading model-draft for ${entry-name}..."
                ${pkgs.python311Packages.huggingface-hub}/bin/hf download "${modelDraftModelId}" "${modelDraft}" --local-dir /opt/llm/models/llama-cpp --repo-type model
              ''}
            ''
          ) models
        )}
      '';
    };
  };

  # Generate llama.cpp config file
  systemd.services.llama-cpp-config = {
    description = "Generate llama-cpp config file";
    wantedBy = [ "multi-user.target" ];
    after = [ "llama-cpp-download-models.service" ];
    requires = [ "llama-cpp-download-models.service" ];
    restartTriggers = [ (builtins.toJSON models) ];
    serviceConfig = {
      Type = "oneshot";
      User = "ollama";
      Group = "ollama";
      ExecStart = pkgs.writeShellScript "generate-config" ''
        cat > /opt/llm/llama-cpp.ini <<EOF
        ${lib.concatStrings (
          lib.mapAttrsToList (
            entry-name: config:
            let
              filename = config.filename;
              mmproj = config.mmproj or null;
              modelDraft = config.modelDraft or null;
              extraProperties = config.extraProperties or { };
            in
            ''
              [${entry-name}]
              model = /opt/llm/models/llama-cpp/${filename}
              ${lib.optionalString (mmproj != null) "mmproj = /opt/llm/models/llama-cpp/${mmproj}"}
              ${lib.optionalString (modelDraft != null) "model-draft = /opt/llm/models/llama-cpp/${modelDraft}"}
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "${key} = ${value}") extraProperties)}
            ''
          ) models
        )}
        EOF
      '';
    };
  };

  system.stateVersion = "25.11";
}
