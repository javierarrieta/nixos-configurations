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

      javierSshKey = lib.mkEnableOption "provision javier's personal SSH keypair" // {
        default = true;
      };

      javierPasswordHash = lib.mkEnableOption "provision javier's password hash" // {
        default = true;
      };
    };
  };

  config = lib.mkIf config.sopsBase.enable {
    sops = {
      defaultSopsFile = ../../secrets.yaml;
      age.keyFile = "/var/lib/sops-nix/key.txt";
      age.sshKeyPaths = [ ]; # Empty - SSH keys are provisioned by SOPS itself (avoids chicken-and-egg)

      # optionalAttrs rather than `lib.mkIf` on each entry: sops.secrets is an attrsOf
      # submodule, and `foo = lib.mkIf false {...}` still materialises the attribute as
      # an empty instance, which then fails at build time looking for a key that is not
      # in the file.
      secrets =
        lib.optionalAttrs config.sopsBase.javierPasswordHash {
          "users/javier_password_hash" = {
            mode = "0600";
            owner = "root";
            neededForUsers = true;
          };
        }
        // lib.optionalAttrs config.sopsBase.javierSshKey {
          # javier's *personal* login keypair, so a host can ssh onward as javier. On an
          # internet-facing host that is a lateral-movement path paid for nothing: turn it
          # off there (titan) instead of accepting it as the fleet default.
          "ssh_keys/javier_private" = {
            mode = "0600";
            owner = "javier";
            path = "${config.users.users.javier.home}/.ssh/id_ed25519";
          };
          "ssh_keys/javier_public" = {
            mode = "0644";
            owner = "javier";
            path = "${config.users.users.javier.home}/.ssh/id_ed25519.pub";
          };
        };
    };
  };
}
