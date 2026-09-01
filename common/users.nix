{
  config,
  lib,
  pkgs,
  unstablePkgs,
  pkgsUnfree,
  unstablePkgsUnfree,
  ...
}:

{
  programs.zsh.enable = true;

  home-manager = {
    backupFileExtension = "orig";
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit unstablePkgs pkgsUnfree unstablePkgsUnfree;
      hostname = config.networking.hostName;
      userOptions = {
        username = "javier";
        userHome = "/home/javier";
        gitName = "Javier Arrieta";
        gitEmail = "javier@techdelivery.es";
        gitDefaultBranch = "main";
        githubUser = "javierarrieta";
        pythonVersion = "3.13";
        homeManagerConfigDir = "/home/javier/code/nixos-configurations";
      };
    };
    users.javier = {
      imports = [
        ../modules/home-manager/base.nix
      ];
      home.stateVersion = "25.11";
    };
  };

  users.mutableUsers = false;
  users.users.javier = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets."users/javier_password_hash".path;
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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC+5Q6F5SqhlkN/3Bb1aM9WDxOcZOFdg803ON3vZnhZa nixos@WSL-PC-Javier"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  systemd.tmpfiles.rules = [
    "d /home/javier/.ssh 0700 javier javier -"
    "d /home/javier/.ssh/agent 0700 javier javier -"
  ];

  system.activationScripts.postActivation = ''
    # sops provisions /home/javier/.ssh as root; re-chown to javier on every switch so agent-forwarding socket can be created without reboot
    # NB: resolve the group dynamically — llm01's live group db has drifted
    # (javier's primary group there is `users`, gid 100; group `javier` absent)
    mkdir -p /home/javier/.ssh /home/javier/.ssh/agent
    chmod 0700 /home/javier/.ssh /home/javier/.ssh/agent
    chown javier:"$(id -gn javier 2>/dev/null || echo users)" /home/javier/.ssh /home/javier/.ssh/agent
  '';

  systemd.services.javier-ssh-agent-fix = {
    description = "Ensure /home/javier/.ssh owned by javier after sops provisions secrets";
    after = [ "sops-nix.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "javier-ssh-agent-fix" ''
        mkdir -p /home/javier/.ssh /home/javier/.ssh/agent
        chmod 0700 /home/javier/.ssh /home/javier/.ssh/agent
        chown javier:"$(id -gn javier 2>/dev/null || echo users)" /home/javier/.ssh /home/javier/.ssh/agent
      '';
    };
  };

}
