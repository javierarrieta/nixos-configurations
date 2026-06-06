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
    # Modules
    ../../modules/nixos/nix-sweep.nix
  ];

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
    network.generateResolvConf = false;
    network.generateHosts = false;
  };

  # No bootloader (WSL doesn't need one)

  # No network config (DHCP from Windows host)

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
