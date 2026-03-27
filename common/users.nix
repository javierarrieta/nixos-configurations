{
  config,
  lib,
  pkgs,
  ...
}:

{
  programs.zsh.enable = true;
  
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
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7hbsmE8Ve4mfIsUrTTHRTq2pdO5ZjOLJsEdjhR4lakDpbe4NH1L5iFHGlIMQGnvHQuBZKqIhaIcVR1uriXWqouQTlfRS884jfvLOeYXo6jPzrFJaXLaHl35vyEE9SLZKTvm4F7B7ZyUGI5sBvXRBIw7VvYdEcLSdIawyTtIaHbZuUfnfqiqgeSR7zxrzNpG7gXAgpumy1xBNGRCIQRJs/IdYljL3Yx4uaFQB6CDHSUzpID+hFUafhPtPoTAlHZJEyIyD8bDd5UMt3jUWcEg5lPxNmPYTsB8uiF0pImfKZfYVyrb9hYJklHpmpTihhqsDvni6lnR0wX6xcvxI96XYipo1qJyI4eshIGjjRU93Si+wzhVP9CoKVQeuhpKSkX2t+BFVewPKUb8SqvIyd0WfxX7cZGbWYWxamvN1/LaHT68IfPgfvattviL+PL7zpQA3C8orTbGiqJRtlglw07sdCyz5Wgy0TW6Lmetx4TRkSPLbrakgYvaogbpaev0FTd4c= javier@Franciscos-MBP"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOHYYT+i+mHzpO2+LObL1bOmb7Ry0c3Ju/7T4/01aybf jaarriet@jaarriet-mac"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTCPPiQVMBxqQdAyUgUvM7FL+Fi8FErDOIxhdz/WlLu javier@kvm"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhwR+SbHJQR8mSFe5UvBVNlcuG6vpXLU6K+4Rh3z25N javier@DESKTOP-9N12DRJ"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  systemd.tmpfiles.rules = [
    "d /home/javier/.ssh 0700 javier javier -"
  ];
}
