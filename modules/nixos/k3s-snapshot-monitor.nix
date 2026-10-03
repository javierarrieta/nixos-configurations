{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.k3sSnapshotMonitor;
  s3Args = lib.concatStringsSep " " (map lib.escapeShellArg cfg.s3Flags);
  script = pkgs.writeShellScript "k3s-snapshot-monitor" ''
    set -u
    out=$(mktemp)
    trap 'rm -f "$out"' EXIT

    # `k3s etcd-snapshot list` does NOT read the k3s unit's flags -- the S3 endpoint,
    # bucket, region, folder and path-style lookup have to be repeated here. They are
    # passed in verbatim from the host's config so this check exercises exactly the same
    # values the server uses; if the server's flags are wrong, this goes red too.
    status=0
    if ! ${pkgs.k3s}/bin/k3s etcd-snapshot list ${s3Args} >"$out" 2>/dev/null; then
      status=1
    fi

    # Columns: Name Location Size Created. Only the s3:// rows matter -- k3s also keeps a
    # local copy under the snapshot dir, and a fresh LOCAL file says nothing about whether
    # the upload worked. That distinction is the entire point of this check.
    newest=$(awk '$2 ~ /^s3:\/\// { print $4 }' "$out" | sort | tail -n1)
    age=-1
    if [ -n "''${newest:-}" ]; then
      if epoch=$(date -d "$newest" +%s 2>/dev/null); then
        age=$(( $(date +%s) - epoch ))
      fi
    fi

    # Written atomically: node_exporter reads whatever is in the directory and a
    # half-written file shows up as a scrape error.
    {
      echo '# HELP k3s_etcd_snapshot_age_seconds Age in seconds of the newest etcd snapshot in object storage.'
      echo '# TYPE k3s_etcd_snapshot_age_seconds gauge'
      echo "k3s_etcd_snapshot_age_seconds ''${age}"
      echo '# HELP k3s_etcd_snapshot_check_success 1 when the object-store listing succeeded, 0 when it did not.'
      echo '# TYPE k3s_etcd_snapshot_check_success gauge'
      if [ "$status" -eq 0 ] && [ "$age" -ge 0 ]; then
        echo 'k3s_etcd_snapshot_check_success 1'
      else
        echo 'k3s_etcd_snapshot_check_success 0'
      fi
    } > "$out.prom"
    mv "$out.prom" ${cfg.textfileDir}/k3s-snapshot.prom
  '';
in
{
  options.k3sSnapshotMonitor = {
    enable = lib.mkEnableOption ''
      Report the age of the newest k3s etcd snapshot in object storage as a
      node_exporter textfile metric
    '';
    envFile = lib.mkOption {
      type = lib.types.path;
      description = "Environment file with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.";
    };
    s3Flags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        The --etcd-s3* flags, repeated from the k3s server config. They must match,
        because `k3s etcd-snapshot list` does not inherit anything from the unit.
      '';
    };
    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter/textfiles";
      description = "Directory node_exporter reads textfile metrics from.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "How often to refresh the metric.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.s3Flags != [ ];
        message = "k3sSnapshotMonitor.s3Flags is empty; the check would list local snapshots only and always look healthy.";
      }
      {
        assertion = builtins.elem "--etcd-s3" cfg.s3Flags;
        message = "k3sSnapshotMonitor.s3Flags must contain --etcd-s3, otherwise k3s lists local snapshots and the metric is meaningless.";
      }
    ];

    # The NixOS node_exporter does not read the textfile dir unless told to; the fleet's
    # textfile metrics work through the in-cluster DaemonSet's hostPath mount instead,
    # which does not exist on a host outside the cluster.
    services.prometheus.exporters.node.enabledCollectors = [ "textfile" ];
    services.prometheus.exporters.node.extraFlags = [
      "--collector.textfile.directory=${cfg.textfileDir}"
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.textfileDir} 0755 root root -"
    ];

    systemd.services.k3s-snapshot-monitor = {
      description = "Publish k3s etcd snapshot age to node_exporter";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        type = "oneshot";
        EnvironmentFile = cfg.envFile;
        ExecStart = script;
      };
    };

    systemd.timers.k3s-snapshot-monitor = {
      description = "Refresh k3s etcd snapshot age metric";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "10s";
      };
    };
  };
}
