# Firewall posture for a host sitting on the public internet.
#
# WHY A SEPARATE MODULE. Every other host in this fleet runs with the NixOS
# firewall disabled (k3s.nix, k8s-network.nix) because they live behind a LAN or
# the mesh. Here the opposite is true: the box has a routable IPv4, OVH traffic
# reaches it within minutes of boot, and the k3s control plane must never answer
# to the world. This module is the one place that says what is reachable.
#
# WHY RAW iptables for the mesh ports. wg0 carries static peers and roadwarriors
# alike, so networking.firewall.interfaces.wg0.allowedTCPPorts cannot express
# "static peers only" -- it would hand 6443 and 10250 to any lost phone. The
# rule has to match the source subnet, which is why it lives in extraCommands and
# why it consumes wireguard.staticSubnet rather than repeating the /25.
{ config, lib, ... }:
let
  cfg = config.publicHost;

  # Every TCP port the nixos firewall would accept from anywhere, in whichever
  # shape it was spelled: the flat global list, any per-interface list, and
  # anything swept up by a range (global or per-interface). A mesh port turning
  # up in any of these is the control plane going public, and the less obvious
  # shapes are easy to add by accident, so the check walks all of them rather
  # than only the one that actually happened once.
  fw = config.networking.firewall;
  ifaces = builtins.attrValues fw.interfaces;
  anywhereTCPPorts = fw.allowedTCPPorts ++ lib.concatLists (map (i: i.allowedTCPPorts) ifaces);
  anywhereTCPRanges =
    fw.allowedTCPPortRanges ++ lib.concatLists (map (i: i.allowedTCPPortRanges) ifaces);
  inAnyOpenRange = p: lib.any (r: r.from <= p && p <= r.to) anywhereTCPRanges;

  # Guard for meshTCPPortExtraSources. A typo here -- 0.0.0.0/0, a fat-fingered
  # public range -- puts the k3s control plane on the internet, and because the
  # rule is matched with -i wg0 it would still read back as a tunnel-only
  # allowance. So anything outside RFC1918 is an eval failure, not a surprise.
  isPrivateCIDR =
    c:
    builtins.match "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]+\\.[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+)(/[0-9]+)?" c
    != null;
  # meshTCPPorts is the default list a host keeps as-is; meshTCPPortExtras is what
  # consumer modules contribute. They are separate options because list assignment
  # in NixOS REPLACES: a module that wanted to add one port would otherwise have to
  # restate 6443, 9100, 10250 and the rest, and forgetting one reads back as a
  # working firewall with the control plane quietly blocked. Both feed one rule.
  meshPorts = lib.unique (cfg.meshTCPPorts ++ cfg.meshTCPPortExtras);
  leakedMeshPorts = lib.unique (
    (lib.intersectLists meshPorts anywhereTCPPorts) ++ (builtins.filter inAnyOpenRange meshPorts)
  );

  # PER-SOURCE PORT RULES. meshTCPPorts, meshTCPPortExtras and meshTCPPortExtraSources
  # all feed exactly ONE multiport rule, so the source list and the port list are the
  # same knob: granting one laptop 6443 through meshTCPPortExtraSources also hands it
  # 9100 and 4243 (unauthenticated metrics) and 10250 (authenticated but RCE-shaped).
  # That coupling was found the hard way on 2026-10-20 when the admin laptops needed the
  # API server. A rule states "these sources, these ports" and emits its own iptables
  # line, so a narrow grant no longer has to buy the whole mesh port list.
  #
  # Rules are ADDITIVE. They never subtract from the base rule: a source in both the
  # static /25 and a rule gets the union, which is what "accept" chains mean.
  ruleSources = lib.concatLists (map (r: r.sources) cfg.meshTCPPortRules);
  badRuleSources = lib.filter (c: !isPrivateCIDR c) ruleSources;
  # An empty sources or ports list would emit `iptables -m multiport --dports` with no
  # argument, which fails at firewall start -- i.e. a silently half-applied nixos-fw
  # chain on the box whose default is DROP. Refuse it at eval instead.
  degenerateRules = builtins.filter (r: r.sources == [ ] || r.ports == [ ]) cfg.meshTCPPortRules;
in
{
  options = {
    publicHost = {
      enable = lib.mkEnableOption "public-internet host firewall posture";

      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 13491;
        description = "TCP port opened for SSH. Must match ssh.port.";
      };

      ingressTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          80
          443
        ];
        description = "Public ingress (Traefik via ServiceLB).";
      };

      meshTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          6443
          9100
          4243
          10250
          10257
          10259
        ];
        description = ''
          Control plane and exporters. Accepted only from
          wireguard.staticSubnet (plus publicHost.meshTCPPortExtraSources):
          10250 is authenticated but RCE-shaped, and roadwarriors must not reach
          any of it. A roadwarrior that legitimately needs one of these ports does
          NOT get it here; it gets a publicHost.meshTCPPortRules entry naming the
          port it needs.
        '';
      };

      meshTCPPortRules = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              sources = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                description = ''
                  Source CIDRs for this rule. Must be RFC1918; must be non-empty.
                '';
              };
              ports = lib.mkOption {
                type = lib.types.listOf lib.types.port;
                description = ''
                  TCP ports accepted from exactly these sources. Must be non-empty.
                  Ports here are still tunnel-only: the rule is matched with -i wg0
                  like the base one.
                '';
              };
            };
          }
        );
        default = [ ];
        example = [
          {
            sources = [ "192.168.133.130/32" ];
            ports = [ 6443 ];
          }
        ];
        description = ''
          Extra -i wg0 accept rules pairing a specific source list with a specific
          port list, for the case where one peer needs one mesh port and must not
          get the rest. Additive to meshTCPPorts; see the ruleSources comment for
          why this exists separately at all.
        '';
      };

      meshTCPPortExtras = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        example = [ 2381 ];
        description = ''
          Ports ADDED to meshTCPPorts by consumer modules, so a host does not have
          to restate the default list to publish one more port. Same -i wg0 match,
          same sources, same posture as meshTCPPorts -- the split is purely because
          list assignment replaces rather than appends.
        '';
      };

      meshTCPPortExtraSources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.168.0.0/24" ];
        description = ''
          Extra source CIDRs accepted for meshTCPPorts, on top of
          wireguard.staticSubnet. Still matched with -i wg0, so this widens only
          what may arrive through the tunnel; it cannot expose these ports on the
          public interface. Entries must be RFC1918.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.openssh.enable -> (config.services.openssh.ports == [ cfg.sshPort ]);
        message = ''
          publicHost.sshPort is ${toString cfg.sshPort} but sshd listens on
          ${lib.concatStringsSep ", " (map toString config.services.openssh.ports)}.
          Either SSH is unreachable from outside or the firewall opens a port
          nothing listens on. Set ssh.port to match.
        '';
      }
      {
        assertion = leakedMeshPorts == [ ];
        message = ''
          ${lib.concatStringsSep ", " (map toString leakedMeshPorts)}
          is reachable from the whole internet: it appears in
          networking.firewall.allowedTCPPorts, in an interfaces.<name> port list,
          or inside an allowedTCPPortRanges entry. Mesh-only ports must appear only in
          publicHost.meshTCPPorts, which accepts them from the tunnel alone.
        '';
      }
      {
        assertion = builtins.all isPrivateCIDR cfg.meshTCPPortExtraSources;
        message =
          "publicHost.meshTCPPortExtraSources must be RFC1918 (10/8, "
          + "172.16/12, 192.168/16); got "
          + lib.concatStringsSep ", " cfg.meshTCPPortExtraSources
          + ". These are control-plane ports and a public or 0.0.0.0/0 entry here "
          + "is the exact mistake this module exists to prevent.";
      }
      {
        assertion = badRuleSources == [ ];
        message =
          "publicHost.meshTCPPortRules sources must be RFC1918 (10/8, 172.16/12, "
          + "192.168/16); got "
          + lib.concatStringsSep ", " badRuleSources
          + ". Same rule as meshTCPPortExtraSources: these are control-plane ports "
          + "and the -i wg0 match makes a public CIDR here read back as tunnel-only "
          + "while it is the hole this module exists to prevent.";
      }
      {
        assertion = degenerateRules == [ ];
        message =
          "${toString (builtins.length degenerateRules)} of publicHost.meshTCPPortRules "
          + "have an empty sources or ports list. That emits an iptables multiport "
          + "rule with no dports, which fails at firewall start on a host whose "
          + "default policy is DROP.";
      }
      {
        # Every rule below is matched with -i wg0, so a rule is meaningless without a
        # tunnel even in the case where meshTCPPorts is empty.
        assertion = cfg.meshTCPPortRules == [ ] || (config.wireguard.enable or false);
        message = ''
          publicHost.meshTCPPortRules is non-empty but wireguard is disabled, so the
          rules would match a tunnel that does not exist. Either enable wireguard or
          empty meshTCPPortRules.
        '';
      }
      {
        # `or false` because wireguard.nix is an import, not a dependency of this
        # module: without it `config.wireguard.enable` is an unknown option and
        # the eval dies with an option error instead of this message.
        assertion = meshPorts == [ ] || (config.wireguard.enable or false);
        message = ''
          publicHost mesh ports (${lib.concatStringsSep ", " (map toString meshPorts)})
          are non-empty but wireguard is disabled, so the
          mesh rule would match a subnet with no tunnel behind it. Either enable
          wireguard or empty meshTCPPorts.
        '';
      }
    ];

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ cfg.sshPort ] ++ cfg.ingressTCPPorts;
      # extraCommands is emitted inside the nixos-fw chain *before* its final
      # refuse rule (firewall-iptables.nix), so appending here works; -A after
      # the chain was closed would be dead code. nixos-fw-accept is the module's
      # own accept target.
      extraCommands = ''
        # The allowlist below is interface-agnostic, so a pod on the CNI bridge could
        # reach sshd on the node. Refuse that first; -I so it lands ahead of the
        # accepts in this chain. Key-only auth makes this hardening, not exposure.
        iptables -I nixos-fw -i cni0 -p tcp --dport ${toString cfg.sshPort} -j DROP
      ''
      + lib.optionalString (meshPorts != [ ]) (
        lib.concatMapStrings (src: ''
          iptables -A nixos-fw -i wg0 -s ${src} -p tcp \
            -m multiport --dports ${lib.concatStringsSep "," (map toString meshPorts)} \
            -j nixos-fw-accept
        '') ([ config.wireguard.staticSubnet ] ++ cfg.meshTCPPortExtraSources)
      )
      # One line per (rule, source). Same chain, same -i wg0, same accept target as
      # the base rule; only the source/port pairing differs.
      + lib.concatMapStrings (
        r:
        lib.concatMapStrings (src: ''
          iptables -A nixos-fw -i wg0 -s ${src} -p tcp \
            -m multiport --dports ${lib.concatStringsSep "," (map toString r.ports)} \
            -j nixos-fw-accept
        '') r.sources
      ) cfg.meshTCPPortRules;
    };
  };
}
