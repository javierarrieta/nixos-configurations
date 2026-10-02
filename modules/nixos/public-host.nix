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
  leakedMeshPorts = lib.unique (
    (lib.intersectLists cfg.meshTCPPorts anywhereTCPPorts)
    ++ (builtins.filter inAnyOpenRange cfg.meshTCPPorts)
  );
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
          wireguard.staticSubnet: 10250 is authenticated but RCE-shaped, and
          roadwarriors must not reach any of it.
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
        # `or false` because wireguard.nix is an import, not a dependency of this
        # module: without it `config.wireguard.enable` is an unknown option and
        # the eval dies with an option error instead of this message.
        assertion = cfg.meshTCPPorts == [ ] || (config.wireguard.enable or false);
        message = ''
          publicHost.meshTCPPorts is non-empty but wireguard is disabled, so the
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
      + lib.optionalString (cfg.meshTCPPorts != [ ]) ''
        iptables -A nixos-fw -i wg0 -s ${config.wireguard.staticSubnet} -p tcp \
          -m multiport --dports ${lib.concatStringsSep "," (map toString cfg.meshTCPPorts)} \
          -j nixos-fw-accept
      '';
    };
  };
}
