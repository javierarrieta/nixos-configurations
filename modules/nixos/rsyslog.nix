{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.rsyslog;

  # Legacy action-queue directives. They configure the action created *after*
  # them, so they belong immediately before the forwarding rule below.
  #
  # Interpolated onto the forwarding line instead of sitting on a line of its
  # own because an indented-string interpolation always leaves its own newline
  # behind: with the option off that stray blank line would rewrite the
  # generated rsyslog.conf of every host that never asked for a queue. Off,
  # this is "" and those hosts stay byte-identical.
  #
  # MaxDiskSpace is the point and the bound: an unbounded queue on a 150 G
  # root is the same outage as the dropped logs it is meant to prevent.
  diskQueueDirectives = lib.optionalString cfg.diskQueue.enable ''
    $ActionQueueType LinkedList
    $ActionQueueFileName remote-fwd
    $ActionQueueMaxDiskSpace ${cfg.diskQueue.maxDiskSpace}
    $ActionQueueSaveOnShutdown on
    $ActionResumeRetryCount -1

  '';
in
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
      diskQueue = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Buffer forwarded messages on disk instead of in memory. Off by
            default because it changes behaviour on every host that turns it on;
            opt-in per host.

            Needed by any host whose log target is reached over WireGuard: the
            tunnel can be down for minutes (hub restart, renumbering) while the
            in-memory queue overflows and drops the evidence you wanted the
            remote copy for.
          '';
        };
        maxDiskSpace = lib.mkOption {
          type = lib.types.addCheck lib.types.str (s: builtins.match "^[0-9]+[kKmMgG]?$" s != null);
          default = "1g";
          description = ''
            Ceiling on the on-disk queue, in the units rsyslog accepts (k, m,
            g), validated at eval so a typo is a build error rather than a
            rsyslog that fails to start during an incident. Not advisory:
            $ActionResumeRetryCount -1 retries forever, so without a ceiling a
            long mesh outage grows the queue until the root filesystem is gone.
            Size it against the root you actually have; the default is what
            titan's 150 G root can spare.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
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

        ${diskQueueDirectives}*.* @@${cfg.server}:${toString cfg.port}
      '';
    };

    # NixOS rsyslogd's defaultConfig writes /var/log/messages, /var/log/warn,
    # /var/log/dhcpd and /var/log/mail but nothing rotates them; k3s logging
    # volume makes /var/log/messages the biggest offender. The spool dir holds
    # rsyslog internal state (imjournal state, queues) and must NOT be rotated.
    services.logrotate.settings = {
      "rsyslog-local-logs" = {
        files = [
          "/var/log/messages"
          "/var/log/warn"
          "/var/log/dhcpd"
          "/var/log/mail"
        ];
        frequency = "daily";
        rotate = 7;
        compress = true;
        delaycompress = true;
        notifempty = true;
        sharedscripts = true;
        create = "0640 root adm";
        postrotate = "/run/current-system/sw/bin/systemctl kill -s HUP syslog.service";
      };
    };
  };
}
