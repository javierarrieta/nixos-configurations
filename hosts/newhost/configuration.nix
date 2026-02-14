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
    ../../hardware-configuration.nix
  ];

  sops = {
    defaultSopsFile = ../../secrets.yaml;
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

  users.users.javier = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    packages = with pkgs; [
      htop
      btop
      git
      screen
      opencode
      sops
      age
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
}
