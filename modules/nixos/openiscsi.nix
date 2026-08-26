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
    };
  };
}
