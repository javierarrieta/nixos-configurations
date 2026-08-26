{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    openiscsi = {
      enable = lib.mkEnableOption "Open-iSCSI for Longhorn";
      name = lib.mkOption {
        type = lib.types.str;
        default = "openscsi";
        description = "iSCSI name";
      };
    };
  };

  config = lib.mkIf config.openiscsi.enable {
    services.openiscsi = {
      enable = true;
      name = config.openiscsi.name;
    };

    # open-iscsi 2.1.12 / nixpkgs 2026-08: switch-to-configuration starts
    # iscsid.service and iscsid.socket in parallel; when the service wins the
    # race the socket start is refused ("Socket service iscsid.service already
    # active") and the whole switch exits with status 4, tripping the comin
    # health gate. Ordering the socket before the service removes the race.
    systemd.services.iscsid = {
      after = [ "iscsid.socket" ];
      wants = [ "iscsid.socket" ];
      preStart = lib.mkAfter ''
        # 2.1.12 expects /run/lock/iscsi to exist but upstream's unit never
        # creates it; a missing dir makes every iscsiadm call fail with
        # "Could not open/create lock file".
        mkdir -p /run/lock/iscsi

        # Stale node records from a previous open-iscsi version break
        # `iscsiadm -m node` outright (seen cluster-wide during the 26.05
        # migration). Self-heal at daemon start: only wipe when the db actually
        # fails to parse — active sessions survive and Longhorn rediscovers
        # targets afterwards.
        if ! ${pkgs.openiscsi}/bin/iscsiadm -m node >/dev/null 2>&1; then
          echo "iscsid-pre-start: node db unreadable — wiping stale records"
          rm -rf /etc/iscsi/nodes /etc/iscsi/send_targets
          mkdir -p /etc/iscsi/nodes /etc/iscsi/send_targets
        fi
      '';
    };

    systemd.tmpfiles.rules = [
      # belt-and-suspenders for the preStart above (covers early boots where
      # iscsid runs before any script had a chance)
      "d /run/lock/iscsi 0700 root root -"
    ];
  };
}
