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

      javierPasswordSecret = lib.mkOption {
        type = lib.types.str;
        default = "users/javier_password_hash";
        description = ''
          Which sops key holds the hash. Override it on a host that must not share
          the fleet password -- an internet-facing box needs a break-glass password
          whose loss does not open every other machine.
        '';
      };

      javierPasswordSopsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File holding javierPasswordSecret. null means defaultSopsFile, i.e. the
          whole-repo secrets.yaml. Set it for hosts whose secrets live in a narrower
          file that their own age key can open (titan).
        '';
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
          ${config.sopsBase.javierPasswordSecret} = {
            mode = "0600";
            owner = "root";
            neededForUsers = true;
          }
          // lib.optionalAttrs (config.sopsBase.javierPasswordSopsFile != null) {
            sopsFile = config.sopsBase.javierPasswordSopsFile;
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
