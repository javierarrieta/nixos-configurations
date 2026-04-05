{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    sopsBase = {
      enable = lib.mkEnableOption "Common SOPS secrets configuration";
    };
  };

  config = lib.mkIf config.sopsBase.enable {
    sops = {
      defaultSopsFile = ../../secrets.yaml;
      age.keyFile = "/var/lib/sops-nix/key.txt";
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      secrets."users/javier_password_hash" = {
        mode = "0600";
        owner = "root";
        neededForUsers = true;
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
  };
}
