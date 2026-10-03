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
        default = "";
        description = ''
          K3s server address. Empty omits --server entirely; non-empty emits
          --server=<addr>, which for a server role means "join this cluster".

          WARNING: empty serverAddr does NOT mean embedded etcd. A lone k3s server
          without --cluster-init runs on sqlite, and a server pointed at itself
          without an initialised etcd cluster will not form one. --cluster-init is
          a separate flag and is NOT set by this module; hosts that need it must
          put it in extraFlags. Found 2026-10-02 on titan, where the assumption
          left the cluster on sqlite and every --etcd-s3 flag inert. (The home
          fleet's k8s-server01 also lacks --cluster-init; its etcd was bootstrapped
          out-of-band and persists only because the data directory does. Do not
          "fix" a live etcd cluster by adding the flag.)
        '';
      };
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to the K3s token file. null omits --token-file entirely; the
          empty string does NOT (upstream tests for null, so "" emits a bare
          --token-file that eats the following argument). A single-node server
          with --cluster-init mints its own token and needs no file.
        '';
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
      clusterCidr = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "10.62.0.0/16";
        description = ''
          Pod CIDR. Empty keeps the k3s default 10.42.0.0/16. Set it on any host
          whose pod ranges could ever be routed to another cluster -- titan
          reaches the home LAN over WireGuard, where 10.42/10.43 are already
          claimed by two clusters.
        '';
      };
      serviceCidr = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "10.63.0.0/16";
        description = "Service CIDR. Empty keeps the k3s default 10.43.0.0/16.";
      };
      requiresMountFor = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "var-lib-rancher-k3s-storage.mount" ];
        description = ''
          systemd units k3s must wait for -- the mount units of filesystems under
          /var/lib/rancher. Without this, k3s can win the race against a separate
          data LV, create the directory on the root filesystem, and silently write
          PersistentVolume data to / until the root disk fills.
        '';
      };
    };
  };

  config = lib.mkIf config.k3s.enable {
    # k3s needs to masquerade and DNAT freely, so the fleet disables the NixOS
    # firewall outright. mkDefault rather than a hard assignment so an
    # internet-facing host (titan) can keep the firewall on via public-host.nix
    # without lib.mkForce; every existing host leaves it at false.
    networking.firewall.enable = lib.mkDefault false;

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
        ++ lib.optionals (config.k3s.clusterCidr != "") [ "--cluster-cidr=${config.k3s.clusterCidr}" ]
        ++ lib.optionals (config.k3s.serviceCidr != "") [ "--service-cidr=${config.k3s.serviceCidr}" ]
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

    # requires + after: `after` alone would still start k3s when the mount unit
    # failed, and k3s would then write PV data to / unnoticed.
    systemd.services.k3s = {
      requires = config.k3s.requiresMountFor;
      after = config.k3s.requiresMountFor;
    };
  };
}
