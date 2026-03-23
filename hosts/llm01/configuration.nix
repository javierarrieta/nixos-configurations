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

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;

  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [
    "amdgpu.sched_policy=2"
    "amd_iommu=pt"
    "amdgpu.gttsize=120000"
    "ttm.pages_limit=31457280"
    "ttm.page_pool_size=27525120"
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

  # sops.templates."wg0.conf".content = ''
  #   [Interface]
  #   Address = ${config.sops.placeholder."wireguard/address"}
  #   DNS = 8.8.8.8, 1.1.1.1
  #   PrivateKey = ${config.sops.placeholder."wireguard/private_key"}

  #   [Peer]
  #   PublicKey = ${config.sops.placeholder."wireguard/publicKey"}
  #   Endpoint = ${config.sops.placeholder."wireguard/endpoint"}
  #   AllowedIPs = ${config.sops.placeholder."wireguard/allowedIPs"}
  #   PersistentKeepalive = 25
  # '';

  # networking.wg-quick.interfaces.wg0.configFile = config.sops.templates."wg0.conf".path;

  environment.systemPackages = [
    pkgs.tpm2-tss # Provides systemd-cryptenroll
    pkgs.git
    pkgs.zsh
    pkgs.fish
    pkgs.openiscsi
    pkgs.vim
    pkgs.wireguard-tools
    pkgs.dig
    pkgs.hdparm
    pkgs.python311Packages.huggingface-hub
    pkgs.nix-tree
    pkgs.nix-index
    pkgs.qemu

    unstablePkgs.rocmPackages.rocm-smi
    unstablePkgs.rocmPackages.clr

    unstablePkgs.llama-cpp-vulkan
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

  users = {
    mutableUsers = false;
    users = {
      javier = {
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
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhwR+SbHJQR8mSFe5UvBVNlcuG6vpXLU6K+4Rh3z25N javier@DESKTOP-9N12DRJ"
        ];
      };
      ollama = {
        isSystemUser = true;
        group = "ollama";
        extraGroups = [
          "render"
          "video"
        ];
      };
      comfyui = {
        isSystemUser = true;
        group = "comfyui";
        uid = 27001;
        extraGroups = [
          "render"
          "video"
        ];
      };
    };
    groups = {
      ollama = {
        
      };
      comfyui = {
        gid = 27001;
      };
    };
  };
  security.sudo.wheelNeedsPassword = false; # TODO: Remove when issues with passwords are resolved

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

    rsyslogd = {
      enable = true;
      extraConfig = ''
        $ModLoad imuxsock
        $ModLoad imjournal
        $WorkDirectory /var/spool/rsyslog
        $ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat

        *.* @@192.168.0.41:514
      '';
    };

    comfyui = {
      enable = true;
      gpuSupport = "rocm";
      enableManager = true;
      listenAddress = "0.0.0.0";
      openFirewall = true;
    };
  };

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
      HSA_OVERRIDE_GFX_VERSION = "11.5.0";
      HSA_ENABLE_SDMA = "0";
      HSA_DISABLE_FRAGMENT_ALLOCATOR = "1";
      XDG_CACHE_HOME = "/opt/llm/.cache/llama.cpp";
    };
    serviceConfig = {
      Type = "simple";
      User = "ollama";
      Group = "ollama";
      # Allows the GPU to lock system RAM for direct access
      LimitMEMLOCK = "infinity";
      WorkingDirectory = "/opt/llm/models";
      CacheDirectory = "llama.cpp";
      ExecStart = "${llamaPackage}/bin/llama-server --port 8001 --host 0.0.0.0 --models-preset /opt/llm/llama-cpp.ini --flash-attn on --no-mmap --offline -ngl 99 --threads 16";
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
    download-buffer-size = 536870912;
  };
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  systemd.tmpfiles.rules = [
    "d /opt/llm 0755 ollama ollama -"
    "Z /opt/llm - ollama ollama -"
    "d /home/javier/.ssh 0700 javier javier -"
  ];

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
              matchSplit = builtins.match "(.*)-[0-9]+-of-[0-9]+\\.gguf" filename;
              downloadArgs =
                if matchSplit != null then
                  "--include \"${builtins.head matchSplit}-*-of-*.gguf\""
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
              extraProperties = config.extraProperties or { };
            in
            ''
              [${entry-name}]
              model = /opt/llm/models/llama-cpp/${filename}
              ${lib.optionalString (mmproj != null) "mmproj = /opt/llm/models/llama-cpp/${mmproj}"}
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

  services.nix-sweep = {
    enable = true;
    interval = "daily";
    removeOlder = "7d";
    keepMin = 10;
  };

}
