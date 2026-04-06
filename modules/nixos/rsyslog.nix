{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    rsyslog = {
      enable = lib.mkEnableOption "rsyslog log forwarding";
      server = lib.mkOption {
        type = lib.types.str;
        default = "192.168.0.41";
        description = "Syslog server IP address";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 514;
        description = "Syslog server port";
      };
    };
  };

  config = lib.mkIf config.rsyslog.enable {
    services.rsyslogd = {
      enable = true;
      extraConfig = lib.mkBefore ''
        $ModLoad imuxsock
        $ModLoad imjournal
        $WorkDirectory /var/spool/rsyslog
        $ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
        $FileOwner root
        $FileGroup adm
        $FileCreateMode 0640
        $DirCreateMode 0755
        $UMask 0022
        $WorkDirectoryCreateMode 0755

        *.* @@${config.rsyslog.server}:${toString config.rsyslog.port}
      '';
    };
  };
}
