{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    ssh = {
      enable = lib.mkEnableOption "SSH server with host key configuration";
      hostKeyPath = lib.mkOption {
        type = lib.types.str;
        default = "/etc/ssh/ssh_host_ed25519_key";
        description = "Path to SSH host private key";
      };
      hostKeyType = lib.mkOption {
        type = lib.types.str;
        default = "ed25519";
        description = "SSH host key type";
      };
    };
  };

  config = lib.mkIf config.ssh.enable {
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          path = config.ssh.hostKeyPath;
          type = config.ssh.hostKeyType;
        }
      ];
    };
  };
}
