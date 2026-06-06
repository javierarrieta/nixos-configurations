{
  config,
  pkgs,
  home-manager,
  nix-sweep,
  ...
}:

{
  imports = [
    # Modules
    ../../modules/nixos/nix-sweep.nix
  ];

  # User (no SOPS — no hashed password)
  programs.zsh.enable = true;
  users.mutableUsers = false;
  users.users.javier = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.zsh;
  };

  security.sudo.wheelNeedsPassword = false;

  # WSL2 enablement
  wsl.enable = true;
  wsl.defaultProfile = "nixos";
  wsl.defaultUser = "javier";
  wsl.extraBaseConfig = ''
    [wsl2]
    networkTranslation=true
  '';

  # No bootloader (WSL doesn't need one)

  # No network config (DHCP from Windows host)

  # No SSH server
  services.openssh.enable = false;

  # No firewall
  networking.firewall.enable = false;

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
