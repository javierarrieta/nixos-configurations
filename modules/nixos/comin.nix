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
    pending=$(${pkgs.coreutils}/bin/printf '%s' "$json" \
      | ${pkgs.jq}/bin/jq -r 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end' 2>/dev/null \
      || ${pkgs.coreutils}/bin/printf '0')
    ${pkgs.coreutils}/bin/printf 'comin_pending_confirmation %s\n' "$pending" > /tmp/comin.prom.$$
    ${pkgs.coreutils}/bin/mv /tmp/comin.prom.$$ /var/lib/node-exporter/textfiles/comin.prom
  '';
in
{
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
