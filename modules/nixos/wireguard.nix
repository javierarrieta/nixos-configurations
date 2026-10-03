# Declarative WireGuard for the home mesh.
#
# WHY THIS MODULE EXISTS. Until titan the hub lived on a non-NixOS VPS and the
# only NixOS-side WG was llm01's NetworkManager profile with SOPS-fed files.
# Owning the hub means owning it declaratively: keys from sops, peers from the
# flake, and the mesh ranges exported as options so public-host.nix consumes
# them instead of hardcoding a second copy of the same /25.
#
# WHY THE SUBNET SPLIT. Roadwarriors (phones, laptops) get
# 192.168.133.128/25 and static peers 192.168.133.0/25. Both arrive on wg0, so
# an interface-based firewall rule cannot tell them apart; the split only means
# something if the firewall matches on the source subnet, which is what
# public-host.nix does with staticSubnet.
{ config, lib, ... }:
let
  cfg = config.wireguard;

  peerOpts = {
    options = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "Peer public key (wireguard public keys are safe to commit).";
      };
      allowedIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Routes this peer advertises. On the hub this is the peer's own /32
          plus, for the home-LAN gateway peer, the LAN range titan must reach.
        '';
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "titan.arrieta.eu:51820";
        description = "host:port, only for the peer role (the hub is dialled).";
      };
      persistentKeepalive = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = 25;
        description = "Needed for NAT'd peers; null disables it.";
      };
    };
  };
in
{
  options = {
    wireguard = {
      enable = lib.mkEnableOption "the WireGuard mesh interface wg0";

      role = lib.mkOption {
        type = lib.types.enum [
          "hub"
          "peer"
        ];
        description = "hub listens and holds every peer; peer dials one hub. The endpoint shape each role implies is asserted in the config body.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        example = "192.168.133.1/24";
        description = "This host's tunnel address with prefix.";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 51820;
        description = "UDP listen port.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to the private key, from sops. Never inline the key.";
      };

      peers = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule peerOpts);
        default = [ ];
        description = "Hub: every peer. Peer role: exactly one entry, the hub.";
      };

      meshSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.133.0/24";
        description = "Whole mesh. Kept out of 172.16/12 (Docker) and 10.42/10.43 (k3s defaults).";
      };
      staticSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.133.0/25";
        description = "Static peers. The only source the control plane and exporters answer.";
      };
      roadwarriorSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.133.128/25";
        description = "Phones and laptops: ingress apps and the home LAN, never the control plane.";
      };
      lanSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.0.0/24";
        description = "Home LAN, reachable through the hub link.";
      };

      forwardToLan = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Hub only: enable IPv4 forwarding and SNAT mesh -> LAN traffic to the
          hub's tunnel address. Without SNAT the home router needs a return
          route for the mesh subnet, and that dependency has already bitten this
          fleet once (AGENTS.md, fresh worker switches dropping the route).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.role != "hub" || builtins.filter (p: p.endpoint != null) cfg.peers == [ ];
        message = "wireguard.role = \"hub\" is dialled, it dials nothing: every peer's endpoint must stay null.";
      }
      {
        assertion =
          cfg.role != "peer" || builtins.length (builtins.filter (p: p.endpoint != null) cfg.peers) == 1;
        message = "wireguard.role = \"peer\" needs exactly one peer with a non-null endpoint: the hub.";
      }
      # Added 2026-10-03 after a paste error produced the same publicKey twice in
      # titan's peer list. Nothing else catches that: Nix allows duplicate list items,
      # the build passes, and the kernel ends up with two identical routes for one key
      # and picks arbitrarily -- the same black-holed-traffic-with-a-green-handshake
      # failure mode as overlapping AllowedIPs, which is documented right next to it in
      # hosts/titan/configuration.nix. Cheap to assert, expensive to discover live.
      {
        assertion =
          builtins.length (lib.unique (map (p: p.publicKey) cfg.peers)) == builtins.length cfg.peers;
        message = "wireguard.peers contains the same publicKey twice. Two peers under one key means two routes to the same /32 and the kernel picks one arbitrarily -- a green handshake with black-holed traffic.";
      }
    ];

    networking.wireguard.interfaces.wg0 = {
      ips = [ cfg.address ];
      listenPort = cfg.listenPort;
      privateKeyFile = cfg.privateKeyFile;
      peers = map (p: {
        inherit (p)
          publicKey
          allowedIPs
          endpoint
          persistentKeepalive
          ;
      }) cfg.peers;
    };

    networking.firewall = {
      # Reverse-path filtering drops WireGuard: packets arrive on wg0 with
      # sources whose route is not wg0 (roaming roadwarriors, the advertised
      # LAN range), and rpfilter discards them before any allow rule is
      # consulted. This is the classic WG-on-a-firewalled-host failure and it is
      # silent.
      checkReversePath = false;
      allowedUDPPorts = [ cfg.listenPort ];
    };

    # WHY FORWARD IS NEVER TOUCHED HERE. Everything above only decides what the
    # hub does with packets addressed to itself; mesh transit (peer A -> peer B,
    # mesh -> home LAN) is forwarded by the kernel and traverses the FORWARD
    # chain, which this module deliberately never filters. That is a real
    # dependency, not an oversight, and it was checked at this lock: the iptables
    # firewall backend builds rules in INPUT and nat and never mentions FORWARD
    # (grep of firewall-iptables.nix finds none), so forwarded traffic rides the
    # kernel's default ACCEPT. The only FORWARD jump the iptables stack can
    # install comes from nat-iptables.nix, gated on networking.nat, which is off
    # on titan. An nftables flip would break mesh transit the moment
    # networking.firewall.filterForward is set, because that backend installs
    # `chain forward { type filter hook forward; policy drop; }`.
    boot.kernel.sysctl = lib.mkIf cfg.forwardToLan { "net.ipv4.ip_forward" = "1"; };

    networking.firewall.extraCommands = lib.mkIf cfg.forwardToLan ''
      # -C first: the firewall unit re-runs extraCommands on every restart and a
      # duplicate MASQUERADE rule is a slow leak of identical rules.
      iptables -t nat -C POSTROUTING -s ${cfg.meshSubnet} -d ${cfg.lanSubnet} -o wg0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s ${cfg.meshSubnet} -d ${cfg.lanSubnet} -o wg0 -j MASQUERADE
    '';
  };
}
