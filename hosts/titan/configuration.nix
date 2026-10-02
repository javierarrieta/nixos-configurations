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
  # Neither of these belongs on an internet-facing host. javier's personal SSH private
  # key would be a lateral-movement path paid for nothing (titan reaches the fleet over
  # the mesh, not by impersonating a laptop), and a key-only box has no password to
  # provision -- the account is locked in common/users.nix instead. Dropping them is also
  # what lets Task 17 scope titan's own age key to titan's secrets alone.
  sopsBase.javierSshKey = false;
  sopsBase.javierPasswordHash = false;
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
  # eth1 is present and physically down (confirmed in rescue mode). Declaring it
  # keeps a DHCP client off a dead link and documents that the second NIC is
  # unused rather than overlooked.
  networking.interfaces.eth1.useDHCP = false;

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
    address = "192.168.133.1/24";
    privateKeyFile = config.sops.secrets."wireguard/titan_private_key".path;
    forwardToLan = true;
    # Peers are added by the hub migration (spec §11a). Empty here on purpose:
    # an empty hub is a working hub, and shipping the hub before the peers are
    # rewired is what keeps the old path alive during the move.
    peers = [ ];
  };

  # Inbound default-deny; the allowlist is the contract in spec §4.4.
  publicHost.enable = true;

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

  k3s = vars.k3s;

  # k8s-network forces the network_env EnvironmentFile onto both
  # network-addresses-eno1 and k3s, which is what resolves the $IP_ADDRESS
  # placeholders for k3s' own node-ip detection.
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
