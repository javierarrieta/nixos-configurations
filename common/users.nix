{
  config,
  lib,
  pkgs,
  unstablePkgs,
  pkgsUnfree,
  unstablePkgsUnfree,
  herdrPkg,
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
      # base.nix -> dev-tools.nix expects this; home-manager modules get
      # their args from here, not from the NixOS specialArgs, so it has to
      # be re-exported explicitly.
      inherit herdrPkg;
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
    # Single source of truth shared with the Pi bootstrap images; see the header there.
    openssh.authorizedKeys.keys = import ./ssh-keys.nix;
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
