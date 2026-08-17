{
  config,
  lib,
  pkgs,
  ...
}:
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
            ]
          );
          default = [
            "route"
            "k3s"
            "current-system"
          ];
          description = "Health checks to run in the post-deployment gate. k3s hosts check route+k3s+current-system; llm01 checks current-system+llama-cpp.";
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
  };
}
