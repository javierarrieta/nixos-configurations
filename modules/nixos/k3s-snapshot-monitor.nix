{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.k3sSnapshotMonitor;
  s3Args = lib.concatStringsSep " " (map lib.escapeShellArg cfg.s3Flags);

  # Pulled out of s3Flags rather than declared again, so the verify step cannot drift
  # from the listing step the way the flag list drifted from the server's own.
  flagValue =
    prefix:
    lib.strings.removePrefix prefix (
      lib.lists.findFirst (f: lib.strings.hasPrefix prefix f) "" cfg.s3Flags
    );
  s3Endpoint = flagValue "--etcd-s3-endpoint=";
  s3Bucket = flagValue "--etcd-s3-bucket=";
  s3Region = flagValue "--etcd-s3-region=";

  # Age tells you a snapshot was UPLOADED. It cannot tell you the bytes are a database:
  # k3s treats a successful HTTP 200 as the end of the story, and a truncated or corrupt
  # object sits in the bucket looking perfectly fresh. This downloads the newest object
  # and asks etcdutl to open it, which is the shallowest check that means "restorable".
  #
  # The file is every Secret in the cluster in plaintext, hence umask 077, a private
  # mktemp -d, and shred on every exit path including signals.
  verifyScript = pkgs.writeShellScript "k3s-snapshot-verify" ''
    set -u
    umask 077
    work=$(mktemp -d)
    snap="$work/snap"
    err=$(mktemp)
    list=$(mktemp)
    # Written beside its destination, not in /tmp: mv from tmpfs to a disk filesystem is
    # copy+unlink, so node_exporter can catch a half-written file. A rename inside
    # textfileDir is atomic, and the dot-prefixed name does not end in .prom so the
    # collector skips it until the rename lands.
    out=$(mktemp ${cfg.textfileDir}/.k3s-snapshot-verify.XXXXXX 2>/dev/null) || out="$work/prom"
    cleanup() {
      shred -u "$snap" 2>/dev/null
      rm -f "$err" "$out" "''${list:-}" 2>/dev/null
      rm -rf "$work" 2>/dev/null
    }
    trap cleanup EXIT HUP INT TERM

    status=0
    reason=""

    if ! ${config.services.k3s.package}/bin/k3s etcd-snapshot list ${s3Args} >"$list" 2>"$err"; then
      status=1
      reason="list failed: $(tail -c 200 "$err" | tr '\n' ' ')"
    fi

    # Newest = the largest trailing unix epoch in the object key. Deliberately NOT the
    # Created column: its awk field number depends on how k3s formats Size ("49 MB" is
    # two fields, "49MB" is one), so a release that changes the spacing would move the
    # timestamp out from under a positional parse and do it silently. The key suffix is
    # part of the name k3s itself builds (name-nodeName-unix), so it is stable.
    loc=$("${pkgs.gawk}/bin/awk" '$2 ~ /^s3:\/\// { print $2 }' "$list" | while read -r l; do
            k=''${l##*/}; e=''${k##*-}
            case "$e" in *[!0-9]*) continue ;; esac
            [ -n "$e" ] || continue
            printf '%s\t%s\n' "$e" "$l"
          done | sort -n | tail -n1 | cut -f2)
    if [ -z "$loc" ]; then
      status=1
      reason="no s3:// rows to verify"
    fi

    key=''${loc#s3://${s3Bucket}/}
    if [ "$status" -eq 0 ]; then
      # SigV4 in curl itself (>= 8.9) rather than boto3 or mc: curl is already on every
      # host, and this is the exact command line proven against the live bucket before
      # it shipped. Path-style, matching --etcd-s3-bucket-lookup-type=path.
      #
      # --fail-with-body, not --fail: with --fail the S3 error document is discarded, so a
      # 403 (revoked key, wrong bucket policy) and a DNS failure leave the same one line
      # in the journal. The body lands in "$snap" and explains itself.
      #
      # The `:-` defaults are load-bearing. Under `set -u` an unbound credential aborts the
      # script BEFORE it publishes anything, which leaves the previous -- healthy -- value
      # in the textfile forever: a missing EnvironmentFile would read as "backups fine".
      if ! ${pkgs.curl}/bin/curl --fail-with-body --silent --show-error --location --max-time 600 \
             --aws-sigv4 "aws:amz:${s3Region}:s3" \
             --user "''${AWS_ACCESS_KEY_ID:-}:''${AWS_SECRET_ACCESS_KEY:-}" \
             "https://${s3Endpoint}/${s3Bucket}/''${key}" -o "$snap"; then
        status=1
        reason="download of ''${key} failed"
      fi
    fi

    revision=-1
    keys=-1
    if [ "$status" -eq 0 ]; then
      # passthru.deps.etcdutl, not pkgs.etcd: the top-level attribute is a symlinkJoin of
      # etcdserver + etcdutl + etcdctl, so the whole etcd release would land on four
      # hosts for one binary. Same version (3.6.14), ~1/3 the closure.
      if ! st=$("${pkgs.etcd.passthru.deps.etcdutl}/bin/etcdutl" snapshot status "$snap" --write-out=json 2>"$err"); then
        status=1
        reason="etcdutl could not open the snapshot: $(tail -c 200 "$err" | tr '\n' ' ')"
      else
        revision=$(echo "$st" | ${pkgs.jq}/bin/jq -r '.revision // -1')
        keys=$(echo "$st" | ${pkgs.jq}/bin/jq -r '.totalKey // -1')
        # A non-numeric value makes node_exporter reject the ENTIRE file, which would
        # take restoreable down with it and turn "bad snapshot" into "no monitor".
        case "$revision" in *[!0-9]*) revision=-1 ;; esac
        case "$keys" in *[!0-9]*) keys=-1 ;; esac
      fi
    fi

    if [ "$status" -ne 0 ]; then
      echo "snapshot verify failed: $reason" >&2
    fi

    {
      echo '# HELP k3s_etcd_snapshot_restoreable 1 when the newest snapshot opens as a valid etcd database.'
      echo '# TYPE k3s_etcd_snapshot_restoreable gauge'
      if [ "$status" -eq 0 ]; then echo 'k3s_etcd_snapshot_restoreable 1'; else echo 'k3s_etcd_snapshot_restoreable 0'; fi
      echo '# HELP k3s_etcd_snapshot_revision MVCC revision of the newest snapshot; -1 when unverifiable.'
      echo '# TYPE k3s_etcd_snapshot_revision gauge'
      echo "k3s_etcd_snapshot_revision ''${revision}"
      echo '# HELP k3s_etcd_snapshot_keys Keys in the newest snapshot; a collapse is corruption, not idleness.'
      echo '# TYPE k3s_etcd_snapshot_keys gauge'
      echo "k3s_etcd_snapshot_keys ''${keys}"
    } > "$out"
    # chmod before the mv or node_exporter never sees the file at all. mktemp creates
    # 0600 and mv preserves it; node_exporter runs as the `node-exporter` user, not
    # root (measured on titan: `ps -o user=` -> node-ex+, with
    # --collector.textfile.directory=/var/lib/node-exporter/textfiles). A 0600 root-owned
    # file in that directory is skipped silently -- no scrape error, nothing in the
    # scrape log, just the metric absent from Prometheus while the file on disk reads
    # perfectly. Measured 2026-11-04: comin.prom in the SAME directory is 0644 and was
    # scraped throughout; k3s-snapshot.prom was 0600 and was absent for ~80 minutes,
    # and a real S3 listing timeout at 15:27 landed inside that blind window.
    chmod 0644 "$out"
    mv "$out" ${cfg.textfileDir}/k3s-snapshot-verify.prom
  '';

  script = pkgs.writeShellScript "k3s-snapshot-monitor" ''
    set -u
    # Same-fs rename for the same reason as the verify script: /tmp is tmpfs and
    # /var/lib is not, so `mv` there is a copy and the collector can read it mid-write.
    out=$(mktemp ${cfg.textfileDir}/.k3s-snapshot.XXXXXX 2>/dev/null) || out=$(mktemp)
    trap 'rm -f "$out"' EXIT

    # `k3s etcd-snapshot list` does NOT read the k3s unit's flags -- the S3 endpoint,
    # bucket, region, folder and path-style lookup have to be repeated here. They are
    # passed in verbatim from the host's config so this check exercises exactly the same
    # values the server uses; if the server's flags are wrong, this goes red too.
    status=0
    err=$(mktemp)
    if ! ${config.services.k3s.package}/bin/k3s etcd-snapshot list ${s3Args} >"$out" 2>"$err"; then
      status=1
      # Was `2>/dev/null`, which made a real failure indistinguishable from an empty
      # bucket: the metric went to its -1 sentinel and the journal said nothing at all.
      echo "etcd-snapshot list failed: $(tail -c 300 "$err" | tr '\n' ' ')" >&2
    fi

    # Columns: Name Location Size Created. Only the s3:// rows matter -- k3s also keeps a
    # local copy under the snapshot dir, and a fresh LOCAL file says nothing about whether
    # the upload worked. That distinction is the entire point of this check.
    #
    # `awk` is spelled as a store path on purpose. A systemd unit's PATH here is the
    # service's `path` list (coreutils, findutils, gnugrep, gnused, systemd), NOT
    # /run/current-system/sw/bin, and gawk is not in it. Bare `awk` failed with
    # `command not found` on titan on every run since this module shipped -- the journal
    # said so, and the check still reported the misleading "no s3:// rows" line because
    # an empty `newest` was indistinguishable from an empty bucket. Found 2026-10-03 while
    # chasing a completely different bug.
    newest=$("${pkgs.gawk}/bin/awk" '$2 ~ /^s3:\/\// { print $4 }' "$out" | sort | tail -n1)
    age=-1
    if [ -n "''${newest:-}" ]; then
      if epoch=$(date -d "$newest" +%s 2>/dev/null); then
        age=$(( $(date +%s) - epoch ))
      fi
    elif [ "$status" -ne 0 ]; then
      :	# already reported above; do not also claim the bucket is empty
    elif [ ! -s "$out" ]; then
      echo "etcd-snapshot list succeeded but produced no output at all" >&2
    else
      # Distinct from a failed listing: the command worked, printed rows, and none of
      # them were s3:// -- uploads are not landing rather than not being attempted.
      echo "no s3:// rows in etcd-snapshot list output; snapshots are not reaching the bucket" >&2
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
    } > "$out"
    # chmod before the mv -- see the same line in verifyScript above for why 0600 is
    # invisible rather than loud.
    chmod 0644 "$out"
    mv "$out" ${cfg.textfileDir}/k3s-snapshot.prom
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
    verify = {
      enable = lib.mkEnableOption ''
        Download the newest snapshot and verify it with `etcdutl snapshot status`,
        publishing restoreability, revision and key count alongside the age.
      '';
      interval = lib.mkOption {
        type = lib.types.str;
        default = "6h";
        description = ''
          How often to download and verify the newest snapshot. Each run pulls one
          snapshot over the network, so this is deliberately much slower than the
          age check: it is a proof of restorability, not a liveness probe.
        '';
      };
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
      # `k3s etcd-snapshot list` is a different command from `k3s server` and rejects
      # anything it does not know: `flag provided but not defined:
      # -etcd-snapshot-schedule-cron`, exit non-zero, and the check then publishes the
      # same age=-1 / check_success=0 pair that an EMPTY BUCKET produces. A mis-wired
      # flag is therefore indistinguishable from "no backups exist" from outside the
      # host's journal. Found 2026-11-04 on k8s-server01..03: six snapshots had landed
      # correctly while the monitor reported failure for ten hours.
      {
        assertion =
          lib.lists.findFirst (
            f: lib.strings.hasPrefix "--etcd-snapshot-" f || lib.strings.hasPrefix "--etcd-s3-retention" f
          ) null cfg.s3Flags == null;
        message = ''
          k3sSnapshotMonitor.s3Flags contains a `k3s server`-only flag. Keep it to the
          connection flags `k3s etcd-snapshot list` accepts (--etcd-s3,
          --etcd-s3-endpoint/-bucket/-region/-folder, --etcd-s3-bucket-lookup-type) and
          put --etcd-snapshot-* and --etcd-s3-retention on the k3s.extraFlags side.
          Offending flag: ${
            toString (
              lib.lists.findFirst (
                f: lib.strings.hasPrefix "--etcd-snapshot-" f || lib.strings.hasPrefix "--etcd-s3-retention" f
              ) null cfg.s3Flags
            )
          }
        '';
      }
      # The failure this guards is the one found 2026-10-03 on titan: the credentials
      # were declared, materialised and never reached the process, so every scheduled
      # snapshot failed with Access Denied while the node stayed Ready. Asserting the
      # env file is actually on the k3s unit turns that class of mistake into a build
      # error instead of a silently stale backup.
      (lib.optionals (config ? k3s) {
        assertion = builtins.elem (toString cfg.envFile) config.k3s.environmentFiles;
        message = ''
          k3sSnapshotMonitor.envFile (''${toString cfg.envFile}) is not in k3s.environmentFiles,
          so k3s cannot authenticate to the object store and scheduled etcd snapshots
          will fail. Add it to k3s.environmentFiles -- NOT to
          serviceConfig.EnvironmentFiles, which is not a systemd [Service] key and is
          silently ignored.
        '';
      })
      # The verify step rebuilds the download URL from these three, so an s3Flags list
      # without them would build `https:///` and fail at runtime on a host whose age
      # metric looks perfectly healthy.
      (lib.mkIf cfg.verify.enable {
        assertion = s3Endpoint != "" && s3Bucket != "" && s3Region != "";
        message = ''
          k3sSnapshotMonitor.verify.enable needs --etcd-s3-endpoint, --etcd-s3-bucket and
          --etcd-s3-region in s3Flags to build the download URL. Found:
          endpoint='${s3Endpoint}' bucket='${s3Bucket}' region='${s3Region}'.
        '';
      })
      # The download URL is path-style (endpoint/bucket/key). With vhost lookup the two
      # disagree and every download 404s -- while the age metric, which uses k3s' own
      # listing, stays green.
      (lib.mkIf cfg.verify.enable {
        assertion = builtins.elem "--etcd-s3-bucket-lookup-type=path" cfg.s3Flags;
        message = ''
          k3sSnapshotMonitor.verify builds a path-style URL, so s3Flags needs
          --etcd-s3-bucket-lookup-type=path. A vhost configuration makes every verify
          download fail while the age metric keeps reporting success.
        '';
      })
      # etcdutl opens a bolt file. If compression is ever turned on -- and
      # common/etcd-snapshot-s3.nix names --etcd-snapshot-compress as the size lever --
      # every object becomes an archive, etcdutl fails permanently, and restoreable pins
      # at 0 against a perfectly good backup. Fail the build instead of lying.
      (lib.mkIf cfg.verify.enable {
        assertion =
          !(lib.lists.any (f: lib.strings.hasPrefix "--etcd-snapshot-compress" f) (
            cfg.s3Flags ++ (config.k3s.extraFlags or [ ])
          ));
        message = ''
          k3sSnapshotMonitor.verify cannot read a compressed snapshot; etcdutl expects an
          uncompressed bolt file. Drop --etcd-snapshot-compress, or decompress in the
          verify script before calling etcdutl.
        '';
      })
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
        # `Type`, capitalised. systemd unit keys are case-sensitive and Nix emits
        # serviceConfig keys verbatim, so this was silently ignored -- the journal said
        # `Unknown key 'type' in section [Service], ignoring` on every daemon-reload --
        # and the unit ran Type=simple. systemd therefore did not wait for ExecStart to
        # finish, which is what let a 5-minute hung `etcd-snapshot list` (the 15:27
        # timeout, error ID 40848) present as a clean ~1s "Deactivated successfully".
        Type = "oneshot";
        EnvironmentFile = cfg.envFile;
        ExecStart = script;
      };
    };

    systemd.services.k3s-snapshot-verify = lib.mkIf cfg.verify.enable {
      description = "Verify the newest k3s etcd snapshot opens as a valid database";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # No `path`: every tool is called by absolute store path from the script, and the
      # coreutils the script does need (mktemp, shred, sort, cut, tr) are already on the
      # default unit path.
      serviceConfig = {
        # `Type`, capitalised; see the note in systemd.services.k3s-snapshot-monitor.
        Type = "oneshot";
        EnvironmentFile = cfg.envFile;
        ExecStart = verifyScript;
      };
    };

    systemd.timers.k3s-snapshot-verify = lib.mkIf cfg.verify.enable {
      description = "Download and verify the newest k3s etcd snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = cfg.verify.interval;
        AccuracySec = "1m";
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
