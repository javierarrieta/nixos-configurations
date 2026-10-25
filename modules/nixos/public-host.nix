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

  # STRICT IPv4 CIDR parse, shared by every source guard below. Returns { addr;
  # bits; } or null, with octets bounded at 255 and the prefix at 32.
  #
  # The bounds are not pedantry: iptables rejects a bad octet and a /33 at LOAD
  # time, and a rule that fails to load leaves a half-applied nixos-fw chain on a
  # host whose default policy is DROP. That is exactly the failure mode the
  # degenerateRules assertion refuses at eval, so the same strictness belongs here.
  # The previous regex-only guard let `192.168.133.130/33` and `192.168.999.1/24`
  # evaluate cleanly and die at firewall start instead.
  #
  # octet and prefixLen carry NO capturing parens of their own: parseIPv4CIDR counts
  # groups by position, and wrapping an already-parenthesised pattern silently doubles
  # them (POSIX ERE has no `(?:...)` to opt out). And the prefix is matched twice rather
  # than as an optional group, because builtins.match drops trailing non-participating
  # groups: one regex with `(/n)?` returns 5 groups for a bare IP and 5 for a bad
  # prefix, which is enough to read `192.168.133.130/33` as a valid /32.
  octet = "25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9]";
  prefixLen = "3[0-2]|[12][0-9]|[0-9]";
  # Written as arithmetic, not as literals, for the same reason the RFC1918 bases
  # below are: a hand-computed 32-bit constant is exactly where an off-by-one-octet
  # bug hides (192.168.0.0 is 3232235520, not 192 * 2**24).
  v4 =
    a: b: c: d:
    (a * 16777216) + (b * 65536) + (c * 256) + d;
  parseIPv4CIDR =
    c:
    let
      mCidr = builtins.match "(${octet})\\.(${octet})\\.(${octet})\\.(${octet})/(${prefixLen})" c;
      mBare = builtins.match "(${octet})\\.(${octet})\\.(${octet})\\.(${octet})" c;
      m = if mCidr != null then mCidr else mBare;
      n = i: builtins.fromJSON (builtins.elemAt m i);
    in
    if m == null then
      null
    else
      {
        addr = v4 (n 0) (n 1) (n 2) (n 3);
        bits = if mCidr != null then n 4 else 32;
      };

  # Guard for meshTCPPortExtraSources and for meshTCPPortRules sources. A typo
  # here -- 0.0.0.0/0, a fat-fingered public range -- puts the k3s control plane on
  # the internet, and because the rule is matched with -i wg0 it would still read
  # back as a tunnel-only allowance. So anything unparseable or outside RFC1918 is
  # an eval failure, not a surprise.
  inRange =
    p: base: size:
    p.addr >= base && p.addr < base + size;
  # The three RFC1918 ranges, as ranges rather than masks because a size is easier to
  # eyeball: /8 is 2**24 addresses, /12 is 2**20, /16 is 2**16.
  isPrivateCIDR =
    c:
    let
      p = parseIPv4CIDR c;
    in
    p != null
    && (
      inRange p (v4 10 0 0 0) 16777216
      || inRange p (v4 172 16 0 0) 1048576
      || inRange p (v4 192 168 0 0) 65536
    );
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
  # Because a rule is the one place a narrow grant is spelled by hand, everything about
  # it is refused at eval rather than discovered at firewall start: sources must parse
  # as strict RFC1918 CIDRs (parseIPv4CIDR), must be covered by a wireguard.peers
  # allowedIPs entry -- an address no peer owns is inert today and a hole the day
  # someone assigns it -- and each rule needs a non-empty port list that fits one
  # multiport match.
  ruleSources = lib.concatLists (map (r: r.sources) cfg.meshTCPPortRules);
  badRuleSources = lib.filter (c: !isPrivateCIDR c) ruleSources;
  # An empty sources or ports list would emit `iptables -m multiport --dports` with no
  # argument, which fails at firewall start -- i.e. a silently half-applied nixos-fw
  # chain on the box whose default is DROP. Refuse it at eval instead.
  degenerateRules = builtins.filter (r: r.sources == [ ] || r.ports == [ ]) cfg.meshTCPPortRules;
  # iptables' multiport match takes at most 15 ports in one --dports list; a 16th
  # fails at firewall start, i.e. the same half-applied chain as an empty list.
  # Counted on the deduplicated list because that is what gets emitted.
  overSizedRules = builtins.filter (
    r: (builtins.length (lib.unique r.ports)) > 15
  ) cfg.meshTCPPortRules;

  # `outer` covers `inner`, whole networks, so a /32 rule source inside a peer that
  # advertises a /24 counts as covered rather than tripping the check below.
  # Bit arithmetic rather than modulo: Nix has no % operator, and builtins.bitAnd
  # with a /bits mask is the network address in one step (bits = 0 -> mask 0 -> 0).
  pow2 = e: if e == 0 then 1 else 2 * pow2 (e - 1);
  sizeOf = p: pow2 (32 - p.bits);
  maskOf = p: 4294967296 - (sizeOf p);
  netOf = p: builtins.bitAnd p.addr (maskOf p);
  covers =
    outer: inner:
    let
      o = parseIPv4CIDR outer;
      i = parseIPv4CIDR inner;
    in
    o != null
    && i != null
    && i.bits >= o.bits
    && netOf i >= netOf o
    && (netOf i + sizeOf i) <= (netOf o + sizeOf o);

  # Peer addresses, for the source cross-check. `or [ ]` for the same reason as
  # `config.wireguard.enable or false` below: wireguard.nix is an import, not a
  # dependency of this module, so without it this path would be an option error
  # instead of an assertion message.
  peerCIDRs = lib.unique (lib.concatLists (map (p: p.allowedIPs) (config.wireguard.peers or [ ])));
  orphanRuleSources = lib.filter (src: !lib.any (peer: covers peer src) peerCIDRs) ruleSources;
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
                  Source CIDRs for this rule. Must be non-empty, RFC1918, and
                  covered by some wireguard.peers allowedIPs entry -- a rule for an
                  address no peer owns is inert today and a hole the day someone
                  assigns it, so the module refuses it at eval.
                '';
              };
              ports = lib.mkOption {
                type = lib.types.listOf lib.types.port;
                description = ''
                  TCP ports accepted from exactly these sources. Must be non-empty
                  and at most 15 distinct ports (iptables' multiport cap; more fails
                  at firewall start). Not restricted to meshTCPPorts: a rule may name
                  any port, so this is a general wg0 source/port pairing and the
                  leakedMeshPorts assertion does not police it -- a wg0-only rule is
                  not an internet leak. Either way the ports stay tunnel-only, since
                  the rule is matched with -i wg0 like the base one.
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
        assertion = orphanRuleSources == [ ];
        message =
          "publicHost.meshTCPPortRules names sources covered by no wireguard.peers "
          + "allowedIPs entry: "
          + lib.concatStringsSep ", " orphanRuleSources
          + ". A rule for an address no peer owns is inert today and a hole the day "
          + "someone assigns that address to a peer, and a typo in a real peer's /32 "
          + "is an admin laptop that silently cannot reach the API. Add the peer or "
          + "fix the rule.";
      }
      {
        assertion = overSizedRules == [ ];
        message =
          "${toString (builtins.length overSizedRules)} of publicHost.meshTCPPortRules "
          + "list more than 15 distinct ports. iptables' multiport match caps one "
          + "rule at 15 dports and fails at firewall start on a host whose default "
          + "policy is DROP; split the rule in two.";
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
            -m multiport --dports ${lib.concatStringsSep "," (map toString (lib.unique r.ports))} \
            -j nixos-fw-accept
        '') r.sources
      ) cfg.meshTCPPortRules;
    };
  };
}
