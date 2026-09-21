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
      healthGate = {
        enable = lib.mkEnableOption "Post-deployment health gate (route/k3s/current-system check with rollback)";
        checks = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "route"
              "k3s"
              "current-system"
              "llama-cpp"
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
          description = "Health checks to run in the post-deployment gate. k3s hosts check route+k3s+current-system (+iscsi where openiscsi.enable); llm01 checks current-system+llama-cpp.";
        };
        halogenWarmupSec = lib.mkOption {
          type = lib.types.int;
          default = 1800;
          description = ''
            How long the halogen-flash check tolerates the service being
            unhealthy before rolling back. A normal weight load takes minutes,
            but a services.halogenFlash.download.revision change makes
            ExecStartPre fetch ~118 GiB, which can run for hours while the
            unit sits in "activating". Hosts that pin weights must raise this
            above the worst-case fetch time or the gate rolls back a deploy
            that is merely still downloading.
          '';
        };
      };
      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Git branch to track. Canaries (node05, llm01) use 'main'; the 10 fleet hosts use 'stable' (promoted manually).";
      };
      pendingMetric = {
        enable = lib.mkEnableOption "Emit comin_pending_confirmation textfile metric via node_exporter";
      };
    };
  };

  config = lib.mkIf config.cominGitOps.enable {
    # Every comin host can serve as a rollout target for scripts/comin-approve.sh
    hermesSsh.enable = true;

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
      openFirewall = true;
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
