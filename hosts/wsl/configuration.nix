{
  config,
  pkgs,
  lib,
  home-manager,
  nix-sweep,
  ...
}:

{
  imports = [
    ../../modules/nixos/wsl-base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/nix-sweep.nix
  ];

  base.enable = true;
  systemPackages.enable = false;

# User
  programs.zsh.enable = true;
  users.mutableUsers = true;
  users.users.javier = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.zsh;
  };

  # WSL2 enablement
  wsl.enable = true;
  wsl.defaultUser = "javier";
  wsl.wslConf = {
    network.generateResolvConf = true;
    network.generateHosts = true;
  };

  # No bootloader (WSL doesn't need one)

  # Network (DHCP from Windows host, DNS via WSL resolv.conf)

  # No SSH server
  services.openssh.enable = false;

  # No firewall
  networking.firewall.enable = false;

  # Allow login without password (WSL)
  users.allowNoPasswordLogin = true;

  # Home Manager
  home-manager = {
    backupFileExtension = "orig";
    useGlobalPkgs = true;
    useUserPackages = true;
    users.javier = {
      imports = [
        ../../modules/home-manager/base.nix
      ];
      home.stateVersion = "25.11";
      home.username = "javier";
      home.homeDirectory = "/home/javier";
    };
  };

  # System packages (console only, no GUI)
  environment.systemPackages = with pkgs; [
    vim
    neovim
    wget
    git
    starship
    fish
    openssh
  ];

  # Nix settings
  nix.optimise.automatic = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Nix-sweep configuration
  services.nix-sweep = {
    enable = true;
    interval = "daily";
    removeOlder = "7d";
    keepMin = 10;
  };

  # Tempfiles
  systemd.tmpfiles.rules = [
    "d /home/javier/.ssh 0700 javier javier -"
  ];

  system.stateVersion = "25.11";
}
