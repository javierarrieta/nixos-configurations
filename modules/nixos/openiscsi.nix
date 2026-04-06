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
  };
}
