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
      port = lib.mkOption {
        type = lib.types.port;
        default = 22;
        description = ''
          TCP port sshd listens on. Port choice is not a defence; the option
          exists so a public host can move off the port every scanner probes
          first, and so public-host.nix can assert the firewall opens the same
          port sshd binds.
        '';
      };
      # GitGuardian's "Generic Password" detector reads `passwordAuthentication =
      # lib.mkOption` as a credential assignment. The value is a function call, so it
      # is a false positive. ggshield is silenced for it by match hash in
      # .gitguardian.yaml, but that list is local-only and is never shared with the
      # dashboard, so the platform needs its own ignore. An in-code `# ggignore` does
      # not work here: nixfmt moves a trailing comment off the line the detector
      # matched (verified on this option), which is why none is on this line.
      passwordAuthentication = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether sshd accepts passwords. The fleet default is true because
          every existing host sits behind the LAN or the mesh; an
          internet-facing host must set this false, since key-only auth is the
          whole defence once the box is publicly reachable.
        '';
      };
      listenAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "192.168.0.29"
          "10.0.0.1"
        ];
        description = ''
          Addresses sshd binds. Empty keeps the sshd default (every address),
          which on a k3s node means sshd also answers on cni0 and flannel.1.
          Rendered comma-separated because sshd_config takes one
          ListenAddresses line holding a comma list, not repeated keys.
        '';
      };
    };
  };

  config = lib.mkIf config.ssh.enable {
    services.openssh = {
      enable = true;
      ports = [ config.ssh.port ];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = config.ssh.passwordAuthentication;
      }
      // lib.optionalAttrs (config.ssh.listenAddresses != [ ]) {
        ListenAddresses = lib.concatStringsSep "," config.ssh.listenAddresses;
      };
      hostKeys = [
        {
          path = config.ssh.hostKeyPath;
          type = config.ssh.hostKeyType;
        }
      ];
    };
  };
}
