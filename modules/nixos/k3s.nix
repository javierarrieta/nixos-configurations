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
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.k3s_1_36;
        defaultText = lib.literalExpression "pkgs.k3s_1_36";
        description = ''
          The k3s derivation to install.

          Pinned to a minor rather than left at pkgs.k3s on purpose. pkgs.k3s is
          whatever minor the channel happens to default to -- in nixos-26.05 that
          is `k3s = k3s_1_35` in pkgs/top-level/all-packages.nix -- so using it
          here would let an unrelated `nix flake update` move every node in the
          fleet between Kubernetes minors without anyone deciding to. Naming the
          minor makes the bump a reviewable change with a PR of its own.

          Why 1.36 is safe from 1.35.8 (all three verified 2026-11-01, not
          assumed):
            * etcd is unchanged. k3s v1.35.8+k3s1 and v1.36.4+k3s1 both embed
              etcd v3.6.14-k3s1, so this bump does not cross the 3.5 -> 3.6
              data-directory boundary -- that migration already happened when the
              fleet went to 1.35, and it is the step that makes a k3s downgrade
              need `etcdutl migrate`.
            * the bundled Traefik chart is byte-identical between the two minors
              (40.1.4+up40.1.0 in both 1_35/chart-versions.nix and
              1_36/chart-versions.nix), so titan -- the one host that does NOT
              pass --disable=traefik -- does not get a chart bump from this.
            * Kubernetes 1.36 stops serving no API versions at all; the newest
              removal entry in the upstream deprecation guide is still v1.32.
              The only 1.36 deprecation touching this fleet is Service
              .spec.externalIPs (deprecated, still functional), used once, in
              k8s-casa apply/50-apps/casa/bambuddy.yaml.

          Still one patch behind upstream: nixpkgs carries 1.36.4, upstream has
          1.36.5. Expected for a release branch; do not chase it here.

          Set a host back to pkgs.k3s to hold that one node on 1.35 while the
          control plane goes first -- k3s skew allows servers newer than agents,
          never the reverse.
        '';
      };
      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Environment files the k3s unit must load.";
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

    # Keep the DHCP client off the pod network.
    #
    # nixpkgs' dhcpcd module only keeps dhcpcd off interfaces NixOS itself
    # declares -- it builds `ignoredInterfaces` out of networking.interfaces,
    # bridges, sits and bonds. k3s creates flannel.1, cni0 and a fresh veth for
    # every pod sandbox behind NixOS' back, so dhcpcd claims each one: it
    # solicits a lease, gets nothing, falls back to IPv4LL, and then -- the part
    # that actually hurts -- installs a default route through the pod overlay.
    # Measured on k8s-node04, 2026-11-18:
    #
    #   flannel.1: soliciting a DHCP lease
    #   flannel.1: adding default route
    #   flannel.1: using IPv4LL address 169.254.219.67
    #
    # Upstream carries the same defect for Docker-created veths, route overwrite
    # included (NetworkConfiguration/dhcpcd#531), and the crash is the one
    # container-runtime hosts are known for: dhcpcd dies in ipv6nd_expire under
    # veth churn and systemd restarts it straight into the next one. Every pod
    # sandbox makes more veths, so the workload feeds the loop. Core dumps in 24h
    # on 2026-11-18: k8s-node04 112, k8s-node02 100, and nine hosts total with
    # dhcpcd touching flannel.1.
    #
    # It lives here rather than in k8s-network.nix because the interfaces are
    # k3s': k3s.nix is the one module every k3s host includes, and
    # k8s-network.nix is not included by the Raspberry Pi workers. That is a
    # placement argument and nothing more -- the Pi workers do not run a DHCP
    # client at all (see the enableDHCP note below), so there was nothing there
    # waiting to be rescued.
    #
    # Denying the overlay is preferred over `networking.dhcpcd.enable = false`
    # because it removes the observed harm without pulling the DHCP safety net
    # out from under the physical interfaces; static-network.nix records a host
    # that went dark when a lease was the only thing covering a bad static
    # config. Turning dhcpcd off entirely is the right follow-up, because nothing
    # in this repo asks for it -- and note that the option is not the client.
    # nixpkgs gates the unit on `dhcpcd.enable && (networking.useDHCP || any
    # declared interface with useDHCP = true)`, so although
    # networking.dhcpcd.enable reads true on 16 of the 17 configurations (only
    # wsl is false), a dhcpcd unit exists on exactly nine: k8s-node01..05,
    # k8s-server01..03 and titan -- the same nine that showed the crash loop,
    # which is the honest way to read the "nine hosts" figure above. The Pi
    # workers, the three *-minimal images and llm01 have no dhcpcd unit at all:
    # useDHCP is false there and no declared interface asks for DHCP. That is why
    # `useDHCP = false` alone would not have fixed this, and why the list below is
    # inert on those hosts.
    #
    # The safety net is already imaginary on the nine that do run it. Every
    # declared interface is static, so nixpkgs ignores it (enp1s0/enp3s0, enp2s0,
    # eno1/eno2), wg0 is ignored through networking.wireguard.interfaces, and the
    # list below denies the overlay -- so what is left for dhcpcd to manage is
    # nothing. `networking.dhcpcd.enable = false` is therefore equivalent rather
    # than risky, and it deletes the crash source outright instead of fencing it
    # in. Keep it as its own change with its own canary; `dhcpcd --status` on one
    # host is the proof, and this is a style choice now rather than an unknown.
    #
    # What is NOT listed, and why: nixpkgs already emits `denyinterfaces ... lo
    # peth* vif* tap* tun* virbr* vnet* vboxnet* sit*` in the dhcpcd.conf it
    # generates, so tap* needs no entry here (veth* genuinely is missing
    # upstream -- that is the one that was biting). wg0 is covered by a
    # different route: the module adds `lib.attrNames
    # config.networking.wireguard.interfaces` to the same ignored list and
    # modules/nixos/wireguard.nix declares networking.wireguard.interfaces.wg0,
    # so the mesh is already off-limits to dhcpcd without an entry.
    #
    # Two limits worth knowing. This list is flannel-shaped: it names k3s'
    # embedded CNI, and a switch to cilium (lxc*, cilium_host), calico (cali*,
    # tunl0) or anything that adds a plain bridge reintroduces the bug silently
    # -- dhcpcd does not complain about an interface nobody told it about. And
    # it is scoped to k3s, so llm01 gets none of it. Today that costs nothing --
    # llm01 has no dhcpcd unit either -- but it is one line of config away from
    # being wrong: setting networking.useDHCP, or declaring any interface with
    # useDHCP = true, hands llm01 a DHCP client that has never been denied
    # anything. Rootless podman keeps its veths in a rootless netns so the host
    # netns is clean; if rootful containers or a useDHCP ever land there, this
    # list belongs in a shared module rather than here.
    networking.dhcpcd.denyInterfaces = [
      "flannel.*"
      "cni0"
      "veth*"
      "kube*"
      "docker*"
      "br-*"
    ];

    # Required for NetworkPolicy to actually be enforced, not merely accepted.
    #
    # K3s' embedded flannel puts pods on a vxlan bridge (cni0), and bridged
    # traffic bypasses netfilter unless these are on. Without them a
    # NetworkPolicy is accepted by the API, reported as applied, and does
    # nothing -- strictly worse than having no policy, because the manifest reads
    # like a fix. K3s' network policy controller (kube-router's netpol library)
    # is on by default and only turned off by --disable-network-policy, which no
    # host in this fleet passes, so policies are live.
    #
    # Set here rather than per-host because every k3s host needs it and only
    # k8s-node04, k8s-node05 and titan had it -- the other ten ran with
    # unenforced policies. k3s.nix is the one module all thirteen include;
    # k8s-network.nix is not included by the Raspberry Pi workers.
    #
    # net.ipv4.ip_forward belongs to the same class: the flannel CNI sets it at
    # runtime, so the cluster survives a missing value, but nothing persisted it
    # and a reboot left it 0 until the CNI next ran.
    #
    # br_netfilter is what makes the two net.bridge keys below exist at all;
    # without the module loaded the write has nowhere to land.
    #
    # The failure is time-dependent, which is what makes it easy to miss. On a
    # running node flannel and kube-proxy have already loaded the module, so
    # `nixos-rebuild switch` applies the sysctls cleanly -- confirmed on
    # k8s-node04 on 2026-10-06, where the key read 1 straight after activation
    # with no reboot involved. But systemd-sysctl runs in early boot, before k3s
    # has started, and a failed sysctl write is a non-fatal warning: the build
    # stays green, the node comes up Ready, and the keys are simply absent. So
    # the setting would survive an activation and silently vanish on the next
    # reboot -- reintroducing exactly the defect #82 was written to remove, at a
    # random later date, on whichever node rebooted first.
    #
    # systemd-modules-load.service runs before systemd-sysctl.service, so this
    # is what makes the sysctls survive a reboot rather than only an activation.
    boot.kernelModules = [ "br_netfilter" ];

    # mkDefault so a host can still opt out without lib.mkForce.
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
      "net.ipv4.ip_forward" = lib.mkDefault 1;
    };

    # One `EnvironmentFile=` directive PER FILE. Two traps, both found on titan the
    # hard way on 2026-10-03:
    #
    #   1. `EnvironmentFiles=` (plural) is not a [Service] key. systemd ignores it
    #      with a journal warning and starts the unit anyway, so credentials never
    #      arrive and k3s authenticates to the object store anonymously -- every
    #      scheduled etcd snapshot failed with `Access Denied` while the node stayed
    #      Ready and the build stayed green. `systemctl show -p EnvironmentFiles`
    #      reports the *property* name (plural) parsed from the singular directive,
    #      which is what made the wrong spelling look correct.
    #   2. Space-joining the paths into ONE `EnvironmentFile=a b` does NOT work: the
    #      value is taken as a single filename, loading it fails, and the unit dies
    #      with `Result: resources`. This took k3s down on deploy. Reproduce with
    #        systemd-run -p "EnvironmentFile=/a /b" true   -> fails (resources)
    #        systemd-run -p EnvironmentFile=/a true        -> succeeds
    #
    # A list makes the unit writer emit one line per path, the form that loads.
    # Composed here rather than assigned per-host because k8s-network.nix used
    # lib.mkForce on this option; two mkForce definitions cannot merge, so a host
    # adding a second file had no legal way to do it. Contributors append to
    # k3s.environmentFiles instead.
    systemd.services.k3s.serviceConfig.EnvironmentFile = lib.mkIf (config.k3s.environmentFiles != [ ]) (
      lib.mkForce config.k3s.environmentFiles
    );

    services.k3s = {
      enable = true;
      package = lib.mkDefault config.k3s.package;
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
