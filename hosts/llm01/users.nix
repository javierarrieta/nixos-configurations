{
  config,
  lib,
  pkgs,
  ...
}:

{
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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhwR+SbHJQR8mSFe5UvBVNlcuG6vpXLU6K+4Rh3z25N javier@DESKTOP-9N12DRJ"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  systemd.tmpfiles.rules = [
    "d /home/javier/.ssh 0700 javier javier -"
  ];
}
