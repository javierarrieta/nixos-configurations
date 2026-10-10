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
      exitNode = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Hub only: this peer may use the hub as its internet egress. Nothing about the
          peer's own allowedIPs changes -- the exit is decided by the CLIENT's AllowedIPs
          (0.0.0.0/0 there), never by the hub's. What this flag buys is the hub's
          permission to SNAT that peer; see wireguard.exitNode.
        '';
      };
    };
  };

  # Sources the hub may SNAT to the internet, taken from the peers' own /32s so an
  # address is written in exactly one place.
  exitSources = lib.unique (
    lib.concatLists (
      map (p: lib.filter (ip: lib.hasSuffix "/32" ip) p.allowedIPs) (lib.filter (p: p.exitNode) cfg.peers)
    )
  );

  # EXIT NODE rules. Enforcement is the SNAT scope, not a route and not a filter rule:
  # only the sources listed here get masqueraded, so a peer that default-routes without
  # permission forwards out with a mesh source the public internet has no return path
  # for. Black hole, not leak -- which is why this needs no FORWARD chain rules and gets
  # to keep the "FORWARD is never filtered" property documented further down.
  #
  # IPv6 is deliberately absent: a hub with no IPv6 transit cannot be a v6 exit, and a
  # client that default-routes only 0.0.0.0/0 keeps using its own network's IPv6, which
  # leaks where it lives. The client sends ::/0 into the tunnel so those packets die
  # instead of leaking; see hosts/titan/README.md.
  exitRules = lib.concatMapStrings (src: ''
    # -C before -A: extraCommands re-runs on every firewall restart and duplicates
    # accumulate silently in the nat table.
    iptables -t nat -C POSTROUTING -s ${src} -o ${cfg.exitNode.wanInterface} -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s ${src} -o ${cfg.exitNode.wanInterface} -j MASQUERADE
    # PMTUD. nixos-fw's INPUT policy refuses some ICMP, so a forwarded path that needs a
    # smaller MSS stalls on large uploads instead of being told about it. Clamping on the
    # SYN makes both ends agree without depending on ICMP arriving.
    iptables -t mangle -C POSTROUTING -s ${src} -o ${cfg.exitNode.wanInterface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
      || iptables -t mangle -A POSTROUTING -s ${src} -o ${cfg.exitNode.wanInterface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  '') exitSources;

  lanRules = ''
    # -C first: the firewall unit re-runs extraCommands on every restart and a
    # duplicate MASQUERADE rule is a slow leak of identical rules.
    iptables -t nat -C POSTROUTING -s ${cfg.meshSubnet} -d ${cfg.lanSubnet} -o wg0 -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s ${cfg.meshSubnet} -d ${cfg.lanSubnet} -o wg0 -j MASQUERADE
  '';
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

      exitNode = {
        enable = lib.mkEnableOption "internet egress (exit node) for peers marked exitNode";
        wanInterface = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "eno1";
          description = ''
            Interface exit traffic is SNAT'd out of. No default on purpose: guessing the
            WAN interface on the box whose default route you are replacing is how you
            black-hole the host you are configuring.
          '';
        };
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
      # The exit lives on the client, so a hub peer's allowedIPs must never grow a default
      # route. On the hub those lists are the PEERS' addresses and become routes on this
      # host: 0.0.0.0/0 there installs a default route into wg0 and black-holes the hub's
      # own internet -- the same self-inflicted black hole as the
      # 192.168.0.0/24-before-the-tunnel story in hosts/titan/configuration.nix. Scoped to
      # the hub on purpose: on a peer-role host, 0.0.0.0/0 on the hub's entry is exactly
      # how you do default-route into the tunnel.
      {
        assertion =
          cfg.role != "hub"
          || lib.all (
            p:
            lib.intersectLists p.allowedIPs [
              "0.0.0.0/0"
              "::/0"
            ] == [ ]
          ) cfg.peers;
        message = "a hub peer's allowedIPs contains 0.0.0.0/0 or ::/0. On the hub those lists are the peer's own addresses and become routes on THIS host: a default route into wg0 black-holes the hub's own internet. Configure the exit on the client, never here.";
      }
      {
        assertion = !cfg.exitNode.enable || cfg.role == "hub";
        message = "wireguard.exitNode is a hub-side SNAT policy; a peer-role host has nothing to forward for anyone else.";
      }
      {
        assertion = !cfg.exitNode.enable || cfg.exitNode.wanInterface != "";
        message = "wireguard.exitNode.enable needs wireguard.exitNode.wanInterface to name the interface exit traffic is SNAT'd out of.";
      }
      {
        assertion = !cfg.exitNode.enable || exitSources != [ ];
        message = "wireguard.exitNode.enable is on but no peer sets exitNode = true: dead config that reads like a VPN is available.";
      }
      {
        assertion = lib.all (p: !p.exitNode || lib.any (ip: lib.hasSuffix "/32" ip) p.allowedIPs) cfg.peers;
        message = "a peer with exitNode = true must advertise at least one /32 in allowedIPs: without that route the hub has no way back to the tunnel endpoint and every forwarded packet dies on the return leg.";
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
    boot.kernel.sysctl = lib.mkIf (cfg.forwardToLan || cfg.exitNode.enable) {
      "net.ipv4.ip_forward" = "1";
    };

    # ONE assignment for both rule sets: repeating the key inside a single attrset
    # literal is a Nix eval error ("attribute already defined"), and types.lines merges
    # definitions coming from different modules -- public-host.nix contributing to the
    # same option is fine, two assignments here are not.
    networking.firewall.extraCommands =
      (lib.optionalString cfg.exitNode.enable exitRules) + (lib.optionalString cfg.forwardToLan lanRules);
  };
}
