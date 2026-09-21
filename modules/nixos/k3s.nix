{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    k3s = {
      enable = lib.mkEnableOption "K3s configuration";
      role = lib.mkOption {
        type = lib.types.enum [
          "server"
          "agent"
        ];
        description = "K3s role: server or agent";
      };
      serverAddr = lib.mkOption {
        type = lib.types.str;
        description = "K3s server address (required for agent role)";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to K3s token file";
      };
      disable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Components to disable (server only)";
      };
      taints = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Node taints";
      };
      labels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Node labels";
      };
      kubeletArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Kubelet arguments";
      };
      controlPlaneMetricsBindAddress = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Address the embedded kube-controller-manager and kube-scheduler bind
          their secure metrics ports to (10257 / 10259). Only meaningful for the
          "server" role; ignored on agents.

          Empty string leaves K3s' own default in place, which is 127.0.0.1 -
          unreachable from anywhere else, so Prometheus cannot scrape it and
          KubeControllerManagerDown / KubeSchedulerDown fire permanently.

          "0.0.0.0" exposes both ports on every interface. That is acceptable
          here because /metrics is NOT in either component's default
          --authorization-always-allow-paths set (/healthz,/readyz,/livez), so
          every metrics request is authenticated via the API server and requires
          the caller to hold nonResourceURLs ["/metrics"] get. Serving is TLS with
          a self-signed cert, so scrapers must skip verification.
        '';
      };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional flags";
      };
    };
  };

  config = lib.mkIf config.k3s.enable {
    # Disable firewall for Kubernetes networking
    networking.firewall.enable = false;

    services.k3s = {
      enable = true;
      role = config.k3s.role;
      serverAddr = config.k3s.serverAddr;
      tokenFile = config.k3s.tokenFile;
      extraFlags = toString (
        (lib.optionals (config.k3s.role == "server") (map (c: "--disable=${c}") config.k3s.disable))
        ++ (map (t: "--node-taint=${t}") config.k3s.taints)
        ++ (map (l: "--node-label=${l}") config.k3s.labels)
        ++ (map (a: "--kubelet-arg=${a}") config.k3s.kubeletArgs)
        # K3s appends user-supplied component args last, so these override its
        # hardcoded 127.0.0.1 binding. Flag names are kube-controller-manager-arg
        # and kube-scheduler-arg (not controller-manager-arg).
        ++ lib.optionals (config.k3s.role == "server" && config.k3s.controlPlaneMetricsBindAddress != "") [
          "--kube-controller-manager-arg=bind-address=${config.k3s.controlPlaneMetricsBindAddress}"
          "--kube-scheduler-arg=bind-address=${config.k3s.controlPlaneMetricsBindAddress}"
        ]
        ++ config.k3s.extraFlags
      );
    };

    systemd.services.k3s.path = with pkgs; [
      openiscsi
      e2fsprogs
      xfsprogs
      util-linux
      cryptsetup
    ];
  };
}
