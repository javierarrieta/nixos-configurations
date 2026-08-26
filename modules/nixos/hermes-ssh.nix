# Restricted SSH account for the hermes automation agent (comin-approve
# rollout runner). The account can only run the two comin commands the
# approve script needs; everything else is rejected by a forced command.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  allowlist = pkgs.writeShellScript "hermes-allowlist" ''
    set -u
    log() { echo "$(date -u +%FT%TZ) $*" >> /var/log/hermes-ssh.log; }
    case "''${SSH_ORIGINAL_COMMAND:-}" in
      "comin status --json")
        log "allowed: comin status --json"
        exec comin status --json
        ;;
      "comin confirmation accept")
        log "allowed: comin confirmation accept"
        exec comin confirmation accept
        ;;
      *)
        log "denied: ''${SSH_ORIGINAL_COMMAND:-<interactive/no command>}"
        echo "hermes: only 'comin status --json' and 'comin confirmation accept' are allowed" >&2
        exit 1
        ;;
    esac
  '';
in
{
  options = {
    hermesSsh = {
      enable = lib.mkEnableOption "restricted hermes agent SSH account";
    };
  };

  config = lib.mkIf config.hermesSsh.enable {
    users.users.hermes = {
      isNormalUser = true;
      description = "Hermes automation agent (restricted)";
      shell = pkgs.bash;
      # Locked password (no hash) — pubkey auth only.
      openssh.authorizedKeys.keys = [
        ''command="/etc/hermes-allowlist",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJdSdN/C6lJ1/y/pRoqu0yj17wqKLf4+kjcaqsru6cu hermes@techdelivery''
      ];
    };

    environment.etc."hermes-allowlist".source = allowlist;

    systemd.tmpfiles.rules = [
      "f /var/log/hermes-ssh.log 0644 root root -"
    ];
  };
}
