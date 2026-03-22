{
  config,
  lib,
  pkgs,
  unstable,
  nix-sweep,
  home-manager,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  sops = {
    defaultSopsFile = ../../secrets.yaml;
    age.keyFile = "${config.users.users.javier.home}/.config/sops/age/keys.txt";
    age.sshKeyPaths = [ "${config.users.users.javier.home}/.config/sops/age/keys.txt" ];
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
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;

  networking.networkmanager.enable = true;

  environment.systemPackages = with pkgs; [
    git
    zsh
    fish
    vim
  ];

  time.timeZone = "Utc";

  home-manager = {
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

  users.users.javier = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAxtDTZvN/YqOQC1nOGahb/qLp35iYnBTPaGld6/N6k javier@Javiers-MacBook-Air.local"
    ];
  };

  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = true;
      };
    };
  };

  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.11";

  services.nix-sweep = {
    enable = true;
    interval = "daily";
    removeOlder = "7d";
    keepMin = 10;
  };

}
