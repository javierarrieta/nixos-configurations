{
  config,
  lib,
  pkgs,
  ...
}:
let
  vars = import ./vars.nix { inherit config pkgs; };
in
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../common/users.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/static-network.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/nix-sweep.nix
    ../../modules/nixos/wireguard.nix
    ../../modules/nixos/public-host.nix
    ../../modules/nixos/k3s.nix
    ../../modules/nixos/k8s-network.nix
    ../../modules/nixos/prometheus.nix
    ../../modules/nixos/k3s-snapshot-monitor.nix
    ../../modules/nixos/rsyslog.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/comin-health-gate.nix
  ];

  base.enable = true;
  systemPackages.enable = true;
  # Public on the internet from the first boot (spec D3): key-only, off the
  # default port, and never dependent on the mesh being up.
  ssh = {
    enable = true;
    port = 13491;
    passwordAuthentication = false;
  };
  sopsBase.enable = true;
  # javier's personal SSH private key does not belong on an internet-facing host: it is
  # a lateral-movement path paid for nothing (titan reaches the fleet over the mesh, not
  # by impersonating a laptop). Dropping it is also what lets Task 17 scope titan's own
  # age key to titan's secrets alone.
  sopsBase.javierSshKey = false;
  # The password stays, but as titan's own hash in titan's own sops file. sshd is key-only
  # here (ssh.passwordAuthentication above), so this password is unreachable over the
  # network: it exists for the IP-KVM console and for sudo. Without it there is no console
  # login at all -- root has no password and the account was locked, so the only way into
  # a box that had lost its network was editing init=/bin/sh at the boot menu. That is not
  # a recovery path worth relying on at 3am (learned 2026-10-02, the day it happened).
  sopsBase.javierPasswordHash = true;
  sopsBase.javierPasswordSecret = "users/javier_password_hash_titan";
  sopsBase.javierPasswordSopsFile = ../../secrets/titan.yaml;

  # common/users.nix turns the sudo password off fleet-wide. A box reachable from the
  # internet should not hand root to whoever lands a shell as javier, so it comes back
  # here. mkForce because the common module assigns it unconditionally.
  security.sudo.wheelNeedsPassword = lib.mkForce true;
  nixSweep.enable = true;

  networking.hostName = vars.hostname;

  staticNetwork = {
    enable = true;
    interface = vars.networkInterface;
    ipAddress = vars.ipAddress;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
    # OVH's primary IP is a /24 with an on-link gateway, so this is empty.
    routeFlags = [ ];
  };
  networking.interfaces.${vars.networkInterface}.useDHCP = false;
  # eno2 is present and physically down (confirmed in rescue mode). Declaring it
  # keeps a DHCP client off a dead link and documents that the second NIC is
  # unused rather than overlooked.
  networking.interfaces.eno2.useDHCP = false;

  # These five live in secrets/titan.yaml, not secrets.yaml. SOPS encrypts a data key to
  # every recipient of a file, so any key that opens secrets.yaml opens all of it -- the
  # only way to give titan a key that reads just titan's secrets is to put those secrets in
  # a file of their own (see .sops.yaml and Task 17). The path is relative to this file and
  # must move with it.
  sops.secrets."titan/network_env" = {
    sopsFile = ../../secrets/titan.yaml;
    mode = "0400";
    owner = "root";
  };
  sops.secrets."wireguard/titan_private_key" = {
    sopsFile = ../../secrets/titan.yaml;
    mode = "0400";
    owner = "root";
  };

  wireguard = {
    enable = true;
    role = "hub";
    address = "${vars.meshAddress}/24";
    privateKeyFile = config.sops.secrets."wireguard/titan_private_key".path;
    forwardToLan = true;
    # Hub migration (spec §11a). One mesh, one set of addresses that never change.
    #
    # Shape: this file lists titan's side, but the CORE is a triangle -- titan, the
    # techdelivery VPS and the OPNsense box each hold a direct link to the other
    # two, so losing titan costs the leaves and whatever sits behind titan, and not
    # home-to-VPS. Those two links live in the VPS's and OPNsense's own configs
    # (hand-maintained; private companion doc §5), which is also where titan
    # advertises the leaf /32s it forwards for. No shared keys, no standby hub, no
    # failover procedure: redundancy here is just a link that is still up.
    #
    # The VPS peer is present now that its new-mesh keypair exists, and it dials
    # titan like everyone else -- hence no endpoint. It is a hub on the OLD mesh and
    # a client on this one at the same time, which is fine: different interfaces,
    # different keys, different meshes.
    #
    # llm01 is absent on purpose: its mesh peer is a leftover from when it had to
    # be bridged to the VPS, and it now sits inside the home LAN. titan reaches it
    # at 192.168.0.29 through the OPNsense peer's 192.168.0.0/24, so it needs no
    # tunnel of its own. Retiring llm01's own wg0 is a Task 15 step, sequenced
    # AFTER whatever monitored it over the mesh is repointed at the LAN address --
    # doing it first is a self-inflicted outage of your own monitoring.
    #
    # chiclana is absent too, and for longer: nobody can touch that box for a few
    # months, so it stays on the old 192.168.2.0/24 mesh via the VPS. That makes
    # the old hub permanent-but-scoped -- it keeps running with chiclana as its
    # only member -- and it means OPNsense must keep its old-mesh link as well as
    # its new one, or home loses chiclana until the box is reachable again.
    #
    # WHY 192.168.0.0/24 IS IN allowedIPs NOW, AND WHY IT WAITED. AllowedIPs become
    # routes the moment the generation is deployed, whether or not the peer ever
    # handshakes. Advertising the LAN before the tunnel worked would have installed
    # `192.168.0.0/24 dev wg0` on a box with no live path to it, and titan's Attic
    # cache resolves into that range: nix-cache.home.arrieta.eu -> 192.168.0.42
    # (verified 2026-10-02, and it is in nix.settings.extra-substituters). Before the
    # tunnel, a build wanting it got "no route to host" and fell through to
    # cache.nixos.org in milliseconds; with a black hole route it eats a full connect
    # timeout per narinfo lookup instead -- every path in the closure, silently, which
    # is a slow-build mystery with no error to grep. So it waited until the tunnel was
    # proven live in both directions on 2026-10-02.
    #
    # Two things need this route, and neither works without it:
    #   - backups: extraHosts pins s3.l.arrieta.eu to 192.168.0.42, so restic cannot
    #     reach MinIO until titan has a path into the LAN;
    #   - the binary cache: same address, so without it every deploy on titan
    #     compiles from source instead of downloading.
    #
    # Roadwarriors sit at .129/.130, NOT the .101/.102 they had on the old flat
    # /24. publicHost answers 6443/10250/9100/4243 only to wireguard.staticSubnet
    # (192.168.133.0/25 = .0-.127), so .101 and .102 would have handed the two
    # laptops control-plane access and made the static/roadwarrior split decorative.
    peers = [
      # OPNsense, home LAN gateway. Its own /32 plus the LAN range it routes for --
      # see the note above for why that range waited for a live tunnel, and the Q5d
      # decision in spec §11a for why OPNsense must hold a return route for it.
      #
      # This is NOT the key OPNsense uses on the old mesh (that one is still
      # PZ00ZAz1..., and the VPS keeps using it for chiclana). One box, two
      # identities, because it belongs to two meshes at once: the old instance
      # dials the VPS, the new `wg_titan` instance dials here. Separate keypairs
      # rather than one key on two interfaces, so a roaming bug on one mesh cannot
      # silently corrupt the other.
      {
        publicKey = "dkpVTI+DtKSo2giq6HVUF5WHQzwmxH5tofQW65bCRhg=";
        allowedIPs = [
          "192.168.133.2/32"
          # titan's only path to the home network: MinIO for backups, and the Attic
          # cache, both at 192.168.0.42.
          "192.168.0.0/24"
        ];
      }
      # pixel7 (roadwarrior)
      {
        publicKey = "e7WsXBdlcjQP1GF8NjDsNzlKVtds55AA3ZaNltoQtno=";
        allowedIPs = [ "192.168.133.129/32" ];
      }
      # macbookair (roadwarrior)
      {
        publicKey = "zhW9LX3U9R9Dt5IMxUMI/HlCzsOEFQbUWdslZHDra2g=";
        allowedIPs = [ "192.168.133.130/32" ];
      }
      # macbookpro (roadwarrior), added 2026-10-03. Same machine as the `macbookpro
      # laptop` sops recipient -- i.e. the daily-driver admin box, not a phone.
      # Mesh-only like the others: one /32, nothing routed beyond it, deliberately
      # inside 192.168.133.128/25 so publicHost's staticSubnet (192.168.133.0/25 =
      # .0-.127) keeps titan's 6443/10250/9100/4243 off it.
      #
      # OPEN QUESTION, left open on purpose: being the admin laptop, this is exactly the
      # peer that will want the API server. Granting it is a one-liner --
      # publicHost.meshTCPPortExtraSources = [ "192.168.133.131/32" ] -- but that option
      # is a single multiport rule, so it opens 9100 and 4243 (unauthenticated metrics)
      # and 10250 alongside 6443. Doing it properly means splitting meshTCPPorts into
      # per-source port lists in public-host.nix. And reaching 6443 is not cluster admin
      # anyway: the kubeconfig stays root:root 0600 on titan.
      {
        publicKey = "knrQmeNK2Jy94nqKYveB+f2vSVVX9UispvlbhQYTCgM=";
        allowedIPs = [ "192.168.133.131/32" ];
      }
      # techdelivery VPS -- the old hub, demoted to a plain client of this mesh while
      # staying a hub on 192.168.2.0/24 for chiclana. Its own /32 only: it advertises
      # nothing it routes for, so there is no overlap with the OPNsense peer's
      # 192.168.0.0/24. Overlapping AllowedIPs across peers is the trap here -- the
      # kernel picks a route arbitrarily and you get a green handshake with
      # black-holed traffic.
      #
      # What this edge is FOR, since nothing on the VPS was found to need it: it is
      # the leaf -> titan -> VPS path, so a flipped laptop can still reach
      # VPS-internal addresses and (via the VPS bridge) chiclana. Point-to-point
      # only -- the VPS does not forward to its own LAN unless that is asked for.
      {
        publicKey = "gmIG3/ixbRJhOTYYfbE+F7uXqfEfNMwLtSgUoy81BGQ=";
        allowedIPs = [ "192.168.133.5/32" ];
      }
    ];
  };

  # Inbound default-deny; the allowlist is the contract in spec §4.4.
  publicHost.enable = true;

  # Home LAN devices reach titan through the OPNsense peer with a 192.168.0.x
  # source, not a mesh /32, so the static /25 alone would refuse them the mesh
  # ports even with a healthy tunnel. Blast radius, stated plainly: every device
  # on the LAN -- including the IoT ones nobody trusts -- can now reach 6443,
  # 10250 and the exporters on titan. The k3s API still demands credentials; 9100
  # and 4243 are unauthenticated metrics, so "read titan's metrics" stops being a
  # mesh-peer privilege. Narrow it to specific hosts later if that turns out to be
  # more than was needed.
  #
  # Still matched with -i wg0, so this cannot expose the ports on the public NIC, and
  # it needs the OPNsense peer to advertise 192.168.0.0/24 -- without that route titan
  # has no way back to a LAN source. It does now.
  publicHost.meshTCPPortExtraSources = [ "192.168.0.0/24" ];

  # The secret itself. It lives in secrets/titan.yaml, NOT secrets.yaml: an etcd snapshot is every
  # Secret in the cluster in plaintext, so the key that writes it should be
  # decryptable by titan's own age key and by no other host (Task 17's split).
  sops.secrets."titan/minio_env" = {
    sopsFile = ../../secrets/titan.yaml;
    mode = "0400";
    owner = "root";
  };

  # Credentials for the scheduled etcd snapshots. k3s reads --etcd-s3-access-key from
  # $AWS_ACCESS_KEY_ID and --etcd-s3-secret-key from $AWS_SECRET_ACCESS_KEY, so the file
  # is exactly two KEY=value lines and no flag carries a secret into the world-readable
  # unit file. It is wired into the k3s unit via k3s.environmentFiles below -- see the
  # note there for why serviceConfig.EnvironmentFiles (plural) is not an option.

  # Nothing else watches whether snapshots actually land. k3s swallows S3 failures
  # inside the server (Rancher #14144): the node stays Ready, k3s stays healthy, and
  # the bucket quietly stops receiving objects. This publishes the age of the newest
  # object in the bucket so a stale backup becomes a metric instead of a rumour.
  # Scraping it needs a Prometheus that can reach titan over the mesh -- see README.
  k3sSnapshotMonitor = {
    enable = true;
    envFile = config.sops.secrets."titan/minio_env".path;
    s3Flags = vars.snapshotS3Flags;
  };

  sops.secrets."ssh_keys/titan_host_private" = {
    sopsFile = ../../secrets/titan.yaml;
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/titan_host_public" = {
    sopsFile = ../../secrets/titan.yaml;
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  # environmentFiles is merged here rather than assigned separately because `k3s` is
  # already defined wholesale from vars.nix.
  #
  # It MUST be k3s.environmentFiles, not systemd.services.k3s.serviceConfig.
  # EnvironmentFiles (plural): systemd has no such [Service] key, silently ignores it,
  # and k3s then authenticates to MinIO anonymously -- every scheduled snapshot fails
  # with `Access Denied` while the node stays Ready and the build stays green. Found
  # 2026-10-03; the restore drill had passed only because the manual `etcd-snapshot save`
  # inherited credentials from the operator's shell, not from the unit.
  k3s = vars.k3s // {
    environmentFiles = [ config.sops.secrets."titan/minio_env".path ];
  };

  # k8s-network contributes the network_env file to k3s.environmentFiles (and forces it
  # onto network-addresses-eno1), which is what resolves the $IP_ADDRESS placeholders for
  # k3s' own node-ip detection. k3s.nix joins the whole list into one EnvironmentFile=
  # directive, so both files land on the unit.
  k8sNetwork = {
    enable = true;
    primaryInterface = vars.networkInterface;
    hostName = vars.hostname;
  };

  sops.secrets."k3s_token_titan" = {
    sopsFile = ../../secrets/titan.yaml;
    mode = "0600";
    owner = "root";
  };

  # Same as the fleet's k3s hosts: without these, pod traffic crossing a bridge
  # bypasses netfilter and NetworkPolicy silently does nothing.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };

  # Observability and backups over the mesh (spec Q9). Every target below is a
  # home LAN address reachable only through wg0, so none of them may depend on
  # the home resolver being right.
  rsyslog = {
    enable = true;
    # Target is the home LAN collector, reached through wg0.
    diskQueue = {
      enable = true;
    };
  };

  # Scraped by home Prometheus through wg0. No firewall rule here:
  # public-host.nix already allows 9100/4243 from wireguard.staticSubnet only.
  prometheus.nodeExporter.enable = true;

  # Pin the MinIO host so etcd snapshots and restic do not depend on
  # split-horizon DNS resolving s3.l.arrieta.eu to the LAN address. The mesh
  # route exists; this removes the resolver from the critical path (spec Q7).
  networking.hosts = {
    "192.168.0.42" = [ "s3.l.arrieta.eu" ];
  };

  # The module default is the LAN name, and substitution must not hinge on the
  # mesh: a deploy that cannot substitute builds the whole closure on a 150 G
  # root (spec §12 note on build-on-remote). This is the public DDNS name the
  # CI runners already push and pull through -- verified live, and the signing
  # key is per-cache, not per-host, so nothing else changes.
  atticCache.url = "https://nix-cache.home.arrieta.eu/nixos-config";

  # journald on a k3s host with a 150 G root filesystem needs a ceiling; the
  # fleet learned that the hard way when a runaway logger filled a node's disk.
  # This is an override of base.nix's option, not an extraConfig append: an
  # appended SystemMaxUse line only wins because journald keeps the last one and
  # the host merges after its imports -- true, but invisible when it stops being
  # true.
  base.journald.systemMaxUse = "2G";

  # disko creates the arrays and LVs but does not configure the initrd to
  # assemble them at boot; without swraid the root filesystem is never found.
  boot.swraid.enable = true;
  # boot.swraid writes an mdadm.conf with neither MAILADDR nor PROGRAM, which
  # nixpkgs warns will crash mdmon. RAID1 with 1.2 metadata never starts mdmon,
  # so this is noise today — but noise that hides the next real mdadm warning.
  boot.swraid.mdadmConf = ''
    MAILADDR root
  '';
  # services.lvm drives boot.initrd.services.lvm.enable (which otherwise only
  # follows services.lvm.enable). Asserted in the task's verification step --
  # a missing LVM in the initrd is a panic on a box whose only console is IP-KVM.
  services.lvm.enable = true;
  boot.initrd.availableKernelModules = [
    "nvme"
    "raid1"
    "dm-mod"
  ];
  # Keep the OVH-generated boot entry working: disko formats a fresh ESP and
  # base.nix installs systemd-boot into it.
  boot.loader.systemd-boot.configurationLimit = 5;

  # Canary ring, auto-confirm: titan is the only WAN-reached host, so a bad
  # deploy is caught by its own health gate rather than by a human at 3am.
  # Revisit confirmerMode when it holds workloads worth a manual gate (spec D10).
  cominGitOps = {
    enable = true;
    branch = "main";
    confirmerMode = "auto";
    hermesEnable = false;
    healthGate = {
      enable = true;
      # No iSCSI on titan (no Longhorn), and halogen-flash is llm01-only.
      checks = [
        "route"
        "k3s"
        "current-system"
      ];
    };
  };

  # comin.nix opens 4243 globally, which is harmless on the fleet (firewall off)
  # but would publish the exporter on a host whose firewall is up. public-host.nix
  # already accepts 4243 from the mesh only, and its assertion refuses the build
  # if a mesh port ever reaches the global allowlist -- this is what keeps that
  # assertion green. Plain false, not mkForce: comin.nix sets this at mkDefault
  # priority precisely so a firewalled host can refuse it without a force that
  # no later module could legitimately override.
  services.comin.exporter.openFirewall = false;

  system.stateVersion = "26.05";
}
