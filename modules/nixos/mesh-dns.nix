# A DNS resolver for mesh clients, on the hub, reachable only through the tunnel.
#
# WHY THIS EXISTS. A roadwarrior that default-routes through titan (wireguard.exitNode)
# loses the resolver it had on the local network: with 0.0.0.0/0 in the tunnel, the
# router address it used to ask is now *also* routed into the tunnel, so every lookup
# dies and the VPN feels broken rather than private. The client has to be pointed at a
# resolver that is reachable through the tunnel, and the honest answer is the hub
# itself -- which also means queries leave from titan's box instead of a third party's,
# and the split-horizon zones can be resolved from wherever the laptop happens to be.
#
# WHY IT CANNOT BE AN OPEN RESOLVER. It binds the hub's own wg0 address and nothing
# else, so it is unreachable from the internet by construction rather than by firewall
# luck -- the firewall rule below is what makes INPUT accept it, not what hides it. The
# listen address is not an option: it is derived from wireguard.address, because a
# free-form listenAddress on a public host is one typo away from an amplifier.
#
# WHY IT DOES NOT TOUCH THE HUB'S OWN RESOLUTION. services.unbound.resolveLocalQueries
# defaults to true, which puts 127.0.0.1 in /etc/resolv.conf. On titan that would make
# the host's own name resolution (nix substitute hosts, s3 endpoints, the Attic cache)
# depend on a tunnel address, and would fight static-network.nix, which writes
# /etc/resolv.conf from the SOPS network_env at activation. So it is off, and the hub
# keeps resolving by its own upstreams.
{ config, lib, ... }:
let
  cfg = config.meshDns;

  # wg0's own address without the prefix -- "192.168.133.1/24" -> "192.168.133.1".
  listenAddress = lib.head (lib.splitString "/" config.wireguard.address);
in
{
  options = {
    meshDns = {
      enable = lib.mkEnableOption "a mesh-only DNS resolver on the hub's tunnel address";

      allowedSubnets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.168.133.0/24" ];
        description = ''
          Source CIDRs allowed to query. Required, with no default: "who may use this
          resolver" is the whole security question for a DNS server sitting on a
          host with a public address.
        '';
      };

      forwardAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "1.1.1.1"
          "9.9.9.9"
        ];
        description = ''
          Public upstreams for everything not covered by splitZones. Empty means
          unbound recurses from the root servers, which is fine but slower and
          chattier from a datacenter IP.
        '';
      };

      splitZones = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = {
          "l.arrieta.eu." = [ "192.168.0.41" ];
        };
        description = ''
          Zone -> upstream resolvers, for names public DNS does not answer. The
          trailing dot matters: unbound matches zones by suffix, and an unqualified
          name would forward more than it looks like it does.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # `or false` because wireguard.nix is an import, not a dependency: without it
        # `config.wireguard.enable` is an unknown option and the eval dies with an
        # option error instead of this message (same shape as public-host.nix).
        assertion = config.wireguard.enable or false;
        message = "meshDns serves the mesh, but wireguard is disabled on this host.";
      }
      {
        assertion = cfg.allowedSubnets != [ ];
        message = "meshDns.enable needs meshDns.allowedSubnets: a resolver with nobody allowed is dead config, and one that defaults to everything is an open resolver on a public box.";
      }
      {
        assertion = cfg.forwardAddresses != [ ] || cfg.splitZones != { };
        message = "meshDns.enable with neither forwardAddresses nor splitZones leaves unbound with no upstream for the zones it is meant to answer.";
      }
    ];

    services.unbound = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        server = {
          interface = [ listenAddress ];
          access-control = map (subnet: "${subnet} allow") cfg.allowedSubnets;
        };
        forward-zone = (
          lib.optionals (cfg.forwardAddresses != [ ]) [
            {
              name = ".";
              forward-addr = cfg.forwardAddresses;
            }
          ]
          ++ lib.mapAttrsToList (zone: addrs: {
            name = zone;
            forward-addr = addrs;
          }) cfg.splitZones
        );
      };
    };

    # wg0 is what makes the listen address exist. nixpkgs sets ip-freebind so unbound
    # survives starting before the tunnel is up, but ordering it anyway means the first
    # query after boot is not racing an interface that has not been created yet.
    systemd.services.unbound = {
      after = [ "wireguard-wg0.service" ];
      wants = [ "wireguard-wg0.service" ];
    };

    # INPUT is default-deny on a public host (public-host.nix), and unbound opens no
    # hole for itself. Matched with -i wg0 so the answer is "through the tunnel", and
    # emitted from extraCommands, which lands before nixos-fw's final refuse rule --
    # see the note on that mechanism in public-host.nix.
    networking.firewall.extraCommands = lib.concatMapStrings (subnet: ''
      iptables -C nixos-fw -i wg0 -s ${subnet} -p udp --dport 53 -j nixos-fw-accept 2>/dev/null \
        || iptables -A nixos-fw -i wg0 -s ${subnet} -p udp --dport 53 -j nixos-fw-accept
      iptables -C nixos-fw -i wg0 -s ${subnet} -p tcp --dport 53 -j nixos-fw-accept 2>/dev/null \
        || iptables -A nixos-fw -i wg0 -s ${subnet} -p tcp --dport 53 -j nixos-fw-accept
    '') cfg.allowedSubnets;
  };
}
