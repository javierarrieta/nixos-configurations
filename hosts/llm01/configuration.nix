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
  # This points to the specific Vulkan package from the flake
  llamaPackage = llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;

  models = {
    "Qwen2.5-coder-1.5B" = {
      modelId = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF";
      filename = "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf";
      extraProperties = {
        "ctx-size" = "8192";
      };
    };
    "Qwen3.5-35B" = {
      modelId = "unsloth/Qwen3.5-35B-A3B-GGUF";
      filename = "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf";
      extraProperties = {
        "ctx-size" = "65386";
      };
    };
    "MiroThinker-v1.5-30B" = {
      modelId = "mradermacher/MiroThinker-v1.5-30B-GGUF";
      filename = "MiroThinker-v1.5-30B.Q4_K_M.gguf";
      extraProperties = {
        "ctx-size" = "65386";
      };
    };
    "Qwen3-coder-Next" = {
      modelId = "unsloth/Qwen3-Coder-Next-GGUF";
      filename = "Qwen3-Coder-Next-Q4_K_M.gguf";
      extraProperties = {
        "ctx-size" = "65386";
      };
    };
  };
in
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
  boot.kernelParams = [
    "amdgpu.sched_policy=2"
    "amd_iommu=off"
  ];
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

  environment.systemPackages = [
    pkgs.tpm2-tss # Provides systemd-cryptenroll
    pkgs.git
    pkgs.zsh
    pkgs.fish
    pkgs.openiscsi
    pkgs.vim
    pkgs.rocmPackages.rocm-smi
    pkgs.wireguard-tools
    pkgs.dig
    pkgs.hdparm
    pkgs.python311Packages.huggingface-hub
    llamaPackage
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
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAxtDTZvN/YqOQC1nOGahb/qLp35iYnBTPaGld6/N6k javier@Javiers-MacBook-Air.local"
    ];
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

    open-webui = {
      enable = true;
      openFirewall = true;
      host = "0.0.0.0";
      package = unstablepkgs.open-webui;
    };
  };

  systemd.services.llama-cpp-server = {
    description = "llama-cpp server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "llama-cpp-config.service" ];
    requires = [ "llama-cpp-config.service" ];
    serviceConfig = {
      Type = "simple";
      User = "ollama";
      Group = "ollama";
      WorkingDirectory = "/opt/llm/models";
      ExecStart = "${llamaPackage}/bin/llama-server --port 8001 --host 0.0.0.0 --models-preset /opt/llm/llama-cpp.ini --offline -ngl 99 --threads 8 --gpu-layers 999 --n-gpu-layers 999";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.paths.llama-cpp-config-watch = {
    description = "Watch llama-cpp config file for changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathModified = "/opt/llm/llama-cpp.ini";
      Unit = "llama-cpp-server.service";
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
    "d /opt/llm/models/llama-cpp 0755 ollama ollama -"
    "d /home/javier/.ssh 0700 javier javier -"
  ];

  systemd.services.llama-cpp-download-models = {
    description = "Download llama-cpp models from HuggingFace";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
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
            in
            ''
               echo "Downloading ${entry-name} from ${modelId}..."
               ${pkgs.python311Packages.huggingface-hub}/bin/hf download "${modelId}" "${filename}" --local-dir /opt/llm/models/llama-cpp --repo-type model
            ''
          ) models
        )}
      '';
    };
  };

  systemd.services.llama-cpp-config = {
    description = "Generate llama-cpp config file";
    wantedBy = [ "multi-user.target" ];
    after = [ "llama-cpp-download-models.service" ];
    requires = [ "llama-cpp-download-models.service" ];
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
              extraProperties = config.extraProperties or { };
            in
            ''
               [${entry-name}]
               model = /opt/llm/models/llama-cpp/${filename}
               ${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "${key} = ${value}") extraProperties)}
            ''
          ) models
        )}
        EOF
      '';
    };
  };

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

  system.stateVersion = "25.11";
}
