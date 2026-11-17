{
  config,
  lib,
  pkgs,
  ...
}:
let
  pendingMetricText = ''
    set -u
    json=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null || ${pkgs.coreutils}/bin/echo -n ''')
    # 0 = nothing pending, 1 = awaiting `comin confirmation accept`,
    # 2 = probe broken (comin status failed, empty output, or unexpected shape).
    # The previous fallback emitted 0 on any error, so a dead probe was
    # indistinguishable from a healthy idle host.
    read_field() { # jq-filter -> value, or 2 when the probe cannot answer
      local out
      out=$(${pkgs.coreutils}/bin/printf '%s' "$json" | ${pkgs.jq}/bin/jq -r "$1" 2>/dev/null) || out=""
      if [ -z "$out" ]; then out=2; fi
      ${pkgs.coreutils}/bin/printf '%s' "$out"
    }

    if [ -z "$json" ]; then
      pending=2
      suspended=2
    else
      pending=$(read_field 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end')
      # A suspended deployer never switches again until someone runs `comin
      # resume`. The exporter's own comin_is_suspended covers manager-level
      # suspension only, so the deployer-level suspend that the health gate
      # triggers read as fully healthy on 2026-09-21 while the host sat on a
      # generation that had just been rolled back.
      suspended=$(read_field 'if (.deployer.is_suspended? == true) then 1 else 0 end')
    fi

    ${pkgs.coreutils}/bin/printf 'comin_pending_confirmation %s\n' "$pending" > /tmp/comin.prom.$$
    ${pkgs.coreutils}/bin/printf 'comin_deployer_suspended %s\n' "$suspended" >> /tmp/comin.prom.$$
    ${pkgs.coreutils}/bin/mv /tmp/comin.prom.$$ /var/lib/node-exporter/textfiles/comin.prom

    # nixos_reboot_required: is the booted system older than the deployed one?
    #
    # This is deliberately NOT comin's own comin_need_to_reboot. That gauge cannot
    # be used as a reboot gate, for two reasons read off nlewo/comin at the pinned
    # rev rather than inferred:
    #   - internal/prometheus/prometheus.go calls needToReboot.Set exactly once,
    #     always with true. Nothing ever sets it back to 0, so it is a one-way
    #     latch: 0 from daemon start until some deploy in this process says
    #     "reboot", then 1 forever after -- including after the reboot lands.
    #   - internal/manager/manager.go recomputes the flag at startup from the
    #     persisted deployment but publishes no event, so any comin restart drops a
    #     genuinely pending reboot back to 0. Observed 2026-11-17 on node05, titan
    #     and llm01: all three had deployed a generation carrying a different
    #     kernel and all three reported comin_need_to_reboot 0.
    # Measuring it here, on a 60s timer, is what makes it a state rather than a
    # one-shot edge -- which is the whole property the upstream gauge lacks.
    #
    # The compared triple is exactly kured's rebootSentinelCommand (k8s-casa
    # apply/10-infra/kured.yaml), proven on this fleet since 2026-10-07, so this
    # metric predicts what kured will act on. It does NOT cover non-kernel reasons
    # to reboot (a systemd bump, say); that is a deliberate scope limit, not an
    # oversight -- a kernel bump is the class that silently never activates here,
    # and it is the one kured exists for.
    #
    # 2 = probe broken, matching the convention `pending` above already uses, so a
    # dead probe is never mistaken for "no reboot needed". comin's own NeedToReboot
    # fails open to false on a readlink error; this does not.
    reboot=0
    booted=""
    current=""
    probe_ok=1
    for node in initrd kernel kernel-modules; do
      b=$(${pkgs.coreutils}/bin/readlink "/run/booted-system/$node" 2>/dev/null) || probe_ok=0
      c=$(${pkgs.coreutils}/bin/readlink "/run/current-system/$node" 2>/dev/null) || probe_ok=0
      booted="$booted $b"
      current="$current $c"
    done
    if [ "$probe_ok" -eq 0 ]; then
      reboot=2
    elif [ "$booted" != "$current" ]; then
      reboot=1
    fi

    # Same-fs rename, not /tmp: /tmp is tmpfs, so a cross-device mv is a copy and
    # the collector can observe a half-written file. Same reasoning as
    # modules/nixos/k3s-snapshot-monitor.nix.
    rb_out=$(${pkgs.coreutils}/bin/mktemp /var/lib/node-exporter/textfiles/.reboot-required.XXXXXX 2>/dev/null)
    if [ -n "$rb_out" ]; then
      ${pkgs.coreutils}/bin/printf 'nixos_reboot_required %s\n' "$reboot" > "$rb_out"
      # chmod BEFORE the mv, or node_exporter never sees the file at all. mktemp
      # creates 0600 and mv preserves it; node_exporter runs as the node-exporter
      # user, not root. This is the exact trap already written down in
      # modules/nixos/k3s-snapshot-monitor.nix -- I copied that file's same-fs
      # mktemp pattern and missed the chmod sitting eight lines below it.
      # Shipped 5e619d8; measured on titan within minutes of it deploying: the
      # timer ran (comin.prom mtime advancing every 60s), the file existed, and
      # nixos_reboot_required was absent from the scrape. The else branch below
      # was never the problem -- a shell redirect creates 0644 under umask 022.
      ${pkgs.coreutils}/bin/chmod 0644 "$rb_out"
      ${pkgs.coreutils}/bin/mv "$rb_out" /var/lib/node-exporter/textfiles/reboot-required.prom
    else
      ${pkgs.coreutils}/bin/printf 'nixos_reboot_required %s\n' "$reboot" > /var/lib/node-exporter/textfiles/reboot-required.prom
    fi
  '';
in
{
  imports = [ ./hermes-ssh.nix ];

  options = {
    cominGitOps = {
      enable = lib.mkEnableOption "Comin GitOps deployment";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/javierarrieta/nixos-configurations.git";
        description = "Git repository URL for Comin";
      };
      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Poll interval in seconds";
      };
      confirmerMode = lib.mkOption {
        type = lib.types.enum [
          "manual"
          "auto"
          "without"
        ];
        default = "manual";
        description = "Comin deploy confirmer mode. manual requires 'comin confirmation accept' on each host before deploying.";
      };
      hermesEnable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to create the 'hermes' deployer account. Fleet hosts need it:
          the hermes agent SSHes in to run comin confirmation accept. A host on
          the public internet with confirmerMode = auto has no use for it and
          should not carry a second SSH-login-capable account.
        '';
      };
      healthGate = {
        enable = lib.mkEnableOption "Post-deployment health gate (route/k3s/current-system check with rollback)";
        checks = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "route"
              "k3s"
              "current-system"
              "halogen-flash"
              "iscsi"
            ]
          );
          default = [
            "route"
            "k3s"
            "current-system"
            "iscsi"
          ];
          description = "Health checks to run in the post-deployment gate. k3s hosts check route+k3s+current-system (+iscsi where openiscsi.enable); llm01 checks current-system+halogen-flash.";
        };
        halogenWarmupSec = lib.mkOption {
          type = lib.types.int;
          default = 1800;
          description = ''
            How long the halogen-flash check tolerates the service being
            unhealthy before rolling back. The service answers /health only once
            the checkpoint is resident, and a normal weight load takes minutes.
            Since halogen-flash 21a686c a download.revision change no longer
            blocks the deploy -- the fetch runs in a background unit and the
            switch returns immediately -- so this window covers the weight load,
            not the transfer. Hosts on slow storage should still raise it above
            their worst-case load time, or the gate rolls back a deploy that is
            merely still loading.
          '';
        };
      };
      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Git branch to track. Canaries (node05, llm01, titan) use 'main'; the 10 fleet hosts use 'stable' (promoted manually).";
      };
      pendingMetric = {
        enable = lib.mkEnableOption "Emit comin_pending_confirmation textfile metric via node_exporter";
      };
    };
  };

  config = lib.mkIf config.cominGitOps.enable {
    # Every comin host can serve as a rollout target for scripts/comin-approve.sh
    hermesSsh.enable = config.cominGitOps.hermesEnable;

    services.comin = {
      enable = true;
      remotes = [
        {
          name = "origin";
          url = config.cominGitOps.repositoryUrl;
          branches.main.name = config.cominGitOps.branch;
          poller.period = config.cominGitOps.pollInterval;
        }
      ];
      buildConfirmer.mode = "without";
      deployConfirmer.mode = config.cominGitOps.confirmerMode;
    };

    # comin's exporter port is only reachable on the k3s hosts because k3s.nix /
    # k8s-network.nix turn networking.firewall off. Hosts that are not part of k3s
    # (llm01) keep the NixOS default firewall enabled, so without this the scrape
    # SYN to 4243 is silently dropped and Prometheus reports
    # "context deadline exceeded" while comin is perfectly healthy locally.
    # Harmless on hosts where the firewall is already disabled.
    services.comin.exporter = {
      listen_address = ""; # all interfaces (comin default, stated for clarity)
      # mkDefault, not a plain assignment: a host whose firewall is actually up
      # must refuse this with a plain `false` (see public-host.nix, whose
      # mesh-leak assertion refuses the build if 4243 ever reaches the global
      # allowlist) rather than reaching for mkForce, which nothing downstream
      # could correct. Harmless on the fleet, where the firewall is disabled.
      openFirewall = lib.mkDefault true;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/node-exporter/textfiles 0755 root root -"
    ];

    systemd.services.comin-pending-metric = {
      description = "Write comin_pending_confirmation textfile metric";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "comin-pending-metric" pendingMetricText;
      };
    };

    systemd.timers.comin-pending-metric = {
      description = "Periodically refresh comin_pending_confirmation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "60";
        OnUnitActiveSec = "60";
        AccuracySec = "10";
      };
    };
  };
}
