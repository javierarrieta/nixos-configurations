{
  config,
  lib,
  pkgs,
  ...
}:
let
  isPlaceholder = s: lib.hasPrefix "$" s;
  useRuntimeConfig =
    isPlaceholder config.staticNetwork.ipAddress
    || isPlaceholder config.staticNetwork.defaultGateway
    || lib.any isPlaceholder config.staticNetwork.nameservers;
  iface = config.staticNetwork.interface;
  # The SOPS network_env secret holds the runtime-resolved address, gateway and
  # DNS. It is provisioned early in activation, so it is already on disk by the
  # time activationScripts run.
  envFile = config.sops.secrets."${config.networking.hostName}/network_env".path;
  routeFlagsStr =
    if config.staticNetwork.routeFlags == [ ] then
      ""
    else
      lib.concatStringsSep " " config.staticNetwork.routeFlags + " ";
  # True when this host defers its nameservers to the runtime network_env.
  needsRuntimeResolv = lib.any isPlaceholder config.staticNetwork.nameservers;
  # /etc/resolv.conf on those hosts is not managed by NixOS at all: the
  # `networking.nameservers` assignment below is skipped while the values are
  # still "$DNS1"/"$DNS2", and a shell snippet in the activation script writes
  # the file once from the SOPS network_env. That snippet had two silent
  # failure modes and k8s-node04 walked into one of them on 2026-11-17: a host
  # with no usable resolv.conf answers `no such host` for every name on it, so
  # containerd cannot pull and comin cannot fetch, while the node still looks
  # healthy because its pods, its kubelet and its syslog all keep working on
  # cached images and IP literals. It stayed invisible for 17 hours and was
  # only found when kured moved a pod onto the node and that pod needed an
  # image the node had never cached.
  #
  # So: validate before writing, write atomically, and exit non-zero rather than
  # emit `nameserver ` with an empty address. Callers decide how loud to be.
  writeResolvConf = pkgs.writeShellScript "static-network-resolv-conf" ''
    if [ ! -f "${envFile}" ]; then
      echo "static-network: ${envFile} is missing; leaving /etc/resolv.conf alone" >&2
      exit 1
    fi
    . "${envFile}"
    if [ -z "''${DNS1:-}" ] || [ -z "''${DNS2:-}" ]; then
      echo "static-network: DNS1/DNS2 are empty in ${envFile}; refusing to write an invalid /etc/resolv.conf" >&2
      exit 1
    fi
    printf 'nameserver %s\nnameserver %s\n' "$DNS1" "$DNS2" > /etc/resolv.conf.tmp
    mv /etc/resolv.conf.tmp /etc/resolv.conf
  '';
  # Runs every 10s for the life of the boot. Nothing else owns resolv.conf on
  # these hosts once activation finishes, so anything that rewrites it wins
  # until the next switch -- which is how a 17-hour outage stayed one.
  networkWatchLoop = pkgs.writeShellScript "static-network-watch" ''
    while true; do
      ${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via "$DEFAULT_GATEWAY" dev ${iface} 2>/dev/null || true
      ${lib.optionalString needsRuntimeResolv ''
        ${writeResolvConf} || echo "static-network: /etc/resolv.conf self-heal failed; host DNS is broken" >&2
      ''}
      ${pkgs.coreutils}/bin/sleep 10
    done
  '';
in
{
  options = {
    staticNetwork = {
      enable = lib.mkEnableOption "Static network configuration";
      ipAddress = lib.mkOption {
        type = lib.types.str;
        description = "Static IP address";
      };
      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 24;
        description = "Network prefix length";
      };
      defaultGateway = lib.mkOption {
        type = lib.types.str;
        description = "Default gateway IP address";
      };
      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "List of DNS nameservers";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Network interface name";
      };
      routeFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "onlink" ];
        description = ''
          Extra flags appended to every `ip route replace` this module emits
          (runtime service, activation script, route watchdog and the comin
          health gate's heal branch).

          OVH's primary IP is normally a /24 with an on-link gateway, so this
          stays empty. It exists for the routed/failover shape, where the
          gateway is off-link and the kernel refuses the route with
          `Network is unreachable` unless the route is marked onlink -- a
          failure that otherwise shows up as a host that silently loses its
          default route on the first switch.
        '';
      };
    };
  };

  config = lib.mkIf config.staticNetwork.enable {
    # The address stays here: it is eval-safe once defaultGateway is null
    # (parseAddr is only reached through isGateway), and the generated
    # network-addresses-*.service expands the placeholder at runtime from the
    # SOPS network_env EnvironmentFile.
    networking.interfaces.${config.staticNetwork.interface} = {
      ipv4.addresses = [
        {
          address = config.staticNetwork.ipAddress;
          prefixLength = config.staticNetwork.prefixLength;
        }
      ];
      useDHCP = false;
    };

    # Placeholder values are resolved at runtime from the SOPS network_env
    # secret. nixpkgs >= 26.05 parses addresses and gateways during evaluation
    # (which fails on "$IP_ADDRESS"), so defer gateway and nameservers to a
    # runtime service instead of baking shell placeholders into the NixOS
    # networking config.
    networking.defaultGateway = lib.mkIf (
      !isPlaceholder config.staticNetwork.ipAddress && !isPlaceholder config.staticNetwork.defaultGateway
    ) config.staticNetwork.defaultGateway;
    networking.nameservers = lib.mkIf (
      !lib.any isPlaceholder config.staticNetwork.nameservers
    ) config.staticNetwork.nameservers;

    systemd.services.network-runtime-config = lib.mkIf useRuntimeConfig {
      description = "Runtime network configuration from SOPS";
      requires = [ "network-addresses-${config.staticNetwork.interface}.service" ];
      after = [ "network-addresses-${config.staticNetwork.interface}.service" ];
      wantedBy = [ "network.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = config.sops.secrets."${config.networking.hostName}/network_env".path;
      };
      script = ''
        ${lib.optionalString
          (isPlaceholder config.staticNetwork.ipAddress || isPlaceholder config.staticNetwork.defaultGateway)
          ''
            ip route replace ${routeFlagsStr}default via "$DEFAULT_GATEWAY" dev ${config.staticNetwork.interface}
          ''
        }
        ${lib.optionalString needsRuntimeResolv "${writeResolvConf}"}
      '';
    };

    # switch-to-configuration does not re-trigger units whose OnlyBy/WantedBy
    # target is already active (e.g. network.target during a `nixos-rebuild
    # switch`), so network-addresses-<iface>.service is NOT re-run on a switch.
    # That is not only a route problem. If the address currently on the interface
    # came from anything other than that unit -- a DHCP lease covering for a
    # generation whose useDHCP=false named a device the kernel does not have, for
    # instance -- then switching to a correct generation makes networkd drop the
    # lease and nothing puts the static address back. The interface ends up with
    # no address at all and the host is dark until someone reaches a console.
    # Observed on titan 2026-10-02, five minutes after a healthy-looking deploy.
    # Re-applying the address on every activation closes that window, and is a
    # no-op when the address is already the right one.
    #
    # The route half exists for the same reason: hosts (notably k3s servers) lost
    # their default route on the nixpkgs 26.05 switch and k3s crashed with
    # "unable to select an IP from default routes". Gateway and DNS are re-applied
    # here, on every activation (boot + switch), before services restart.
    system.activationScripts.network-runtime = lib.mkIf useRuntimeConfig {
      # sops-nix provisions /run/secrets via the `setupSecrets` activation
      # script. Without this dependency the network_env file may not exist yet
      # when this script runs on a fresh switch (hosts whose /run/secrets was
      # recreated), leaving the default route unset and k3s unable to start.
      deps = [ "setupSecrets" ];
      text = ''
        if [ -f "${envFile}" ]; then
          . "${envFile}"
          ${lib.optionalString (isPlaceholder config.staticNetwork.ipAddress) "${pkgs.iproute2}/bin/ip addr replace \"$IP_ADDRESS\"/${toString config.staticNetwork.prefixLength} dev ${iface}"}
          ${lib.optionalString (isPlaceholder config.staticNetwork.defaultGateway) "${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via \"$DEFAULT_GATEWAY\" dev ${iface}"}
          ${lib.optionalString needsRuntimeResolv "${writeResolvConf} || echo 'static-network: could not re-assert /etc/resolv.conf during activation' >&2"}
        fi
      '';
    };

    # The network-runtime-config oneshot only fires on fresh boots (it is
    # WantedBy network.target which is already active during a switch).
    # The activation script above runs on every activation but can still miss
    # the route mid-switch. A persistent watchdog is the only reliable
    # self-heal: it restores the route no matter when or why it is lost.
    #
    # It now re-asserts resolv.conf in the same loop, for the same reason: the
    # route and the resolver are both runtime state that nothing owns after
    # activation, and the resolver half went unwatched until a node ran 17 hours
    # with a dead one. The unit keeps its name -- renaming it would mean a switch
    # has to stop the old unit before the replacement takes over, and the last
    # thing a half-applied network change needs is a window with no watchdog.
    systemd.services.network-route-watch = lib.mkIf useRuntimeConfig {
      description = "Self-heal default route and /etc/resolv.conf if lost or clobbered";
      after = [
        "network.target"
        "setupSecrets.service"
      ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "10s";
        ExecStart = networkWatchLoop;
        EnvironmentFile = config.sops.secrets."${config.networking.hostName}/network_env".path;
      };
    };
  };
}
