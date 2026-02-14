# This is a flake-based NixOS configuration
# Apply with: nixos-rebuild switch --flake .#nixos
{
  config,
  lib,
  pkgs,
  unstable,
  unstablePkgs,
  ...
}:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  # Sops configuration for secrets management
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "${config.users.users.javier.home}/.config/sops/age/keys.txt";
    age.sshKeyPaths = [ "${config.users.users.javier.home}/.config/sops/age/keys.txt" ];
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
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # AMD GPU support
  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Load AMD GPU kernel modules
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelPackages = pkgs.linuxPackages_latest; # Ensure you are on 6.13+
  boot.kernelParams = [ "amdgpu.sched_policy=2" ];

  # networking.hostName = "nixos"; # Define your hostname.

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = true;

  # WireGuard VPN configuration - secrets managed by sops
  sops.secrets."wireguard/address" = { };
  sops.secrets."wireguard/publicKey" = { };
  sops.secrets."wireguard/endpoint" = { };
  sops.secrets."wireguard/allowedIPs" = { };
  
  sops.templates."wg0.conf".content = ''
    [Interface]
    Address = ${config.sops.placeholder."wireguard/address"}
    DNS = 10.0.0.1
    PrivateKey = ${config.sops.placeholder."wireguard/private_key"}
    
    [Peer]
    PublicKey = ${config.sops.placeholder."wireguard/publicKey"}
    Endpoint = ${config.sops.placeholder."wireguard/endpoint"}
    AllowedIPs = ${config.sops.placeholder."wireguard/allowedIPs"}
    PersistentKeepalive = 25
  '';

  networking.wg-quick.interfaces.wg0.configFile = config.sops.templates."wg0.conf".path;

  # System-wide packages
  environment.systemPackages = with pkgs; [
    git
    zsh
    fish
    openiscsi
    vim
    rocmPackages.rocm-smi
    wireguard-tools
  ];

  # Set your time zone.
  time.timeZone = "Utc";

  users.users.javier = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "render"
      "video"
    ];
    packages = with pkgs; [
      htop
      btop
      git
      screen
      opencode
      nvtopPackages.amd
      sops
      age
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

  # Enable the OpenSSH daemon.
  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = true; # Avoid lockdown while testing encryption
      };
    };

    ollama = {
      enable = true;
      acceleration = "vulkan"; # Better support for AMD iGPUs
      openFirewall = true; # This opens port 11434
      host = "0.0.0.0"; # Listen on all interfaces (needed for remote access)
      models = "/opt/llm/models";
      # rocmOverrideGfx = "11.5.0";
      package = unstablePkgs.ollama-vulkan;
      # acceleration = "rocm";
  
      environmentVariables = {
        # Vital for preventing the 100% GPU hang you saw earlier
        OLLAMA_KEEP_ALIVE = "60"; 
        # Force the Vulkan runner
        OLLAMA_VULKAN = "1";
      };
    };

    open-webui = {
      enable = true;
      openFirewall = true;
      host = "0.0.0.0";
      package = unstablePkgs.open-webui;
    };
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  # Create Ollama models directory
  systemd.tmpfiles.rules = [
    "d /opt/llm/models 0755 ollama ollama -"
  ];

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?

}
