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
            ip route replace default via "$DEFAULT_GATEWAY" dev ${config.staticNetwork.interface}
          ''
        }
        ${lib.optionalString (lib.any isPlaceholder config.staticNetwork.nameservers) ''
          rm -f /etc/resolv.conf
          cat > /etc/resolv.conf <<EOF
          nameserver $DNS1
          nameserver $DNS2
          EOF
        ''}
      '';
    };

    # switch-to-configuration does not re-trigger units whose OnlyBy/WantedBy
    # target is already active (e.g. network.target during a `nixos-rebuild
    # switch`), so the network-runtime-config service defined above is NOT run
    # on a switch -- only on a fresh boot. That left static-network hosts
    # (notably k3s servers) without a default route after the nixpkgs 26.05
    # switch, which made k3s crash with "unable to select an IP from default
    # routes". Re-apply the runtime gateway/DNS here, on every activation
    # (boot + switch), so the route is always present before services restart.
    system.activationScripts.network-runtime = lib.mkIf useRuntimeConfig {
      # sops-nix provisions /run/secrets via the `setupSecrets` activation
      # script. Without this dependency the network_env file may not exist yet
      # when this script runs on a fresh switch (hosts whose /run/secrets was
      # recreated), leaving the default route unset and k3s unable to start.
      deps = [ "setupSecrets" ];
      text = ''
        if [ -f "${envFile}" ]; then
          . "${envFile}"
          ${lib.optionalString (isPlaceholder config.staticNetwork.defaultGateway) "${pkgs.iproute2}/bin/ip route replace default via \"$DEFAULT_GATEWAY\" dev ${iface}"}
          ${lib.optionalString (lib.any isPlaceholder config.staticNetwork.nameservers) "rm -f /etc/resolv.conf\nprintf \"nameserver %s\\nnameserver %s\\n\" \"$DNS1\" \"$DNS2\" > /etc/resolv.conf"}
        fi
      '';
    };

    # The network-runtime-config oneshot only fires on fresh boots (it is
    # WantedBy network.target which is already active during a switch).
    # The activation script above runs on every activation but can still miss
    # the route mid-switch. A persistent watchdog is the only reliable
    # self-heal: it restores the route no matter when or why it is lost.
    systemd.services.network-route-watch = lib.mkIf useRuntimeConfig {
      description = "Self-heal default route if lost during nixos-rebuild switch";
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
        ExecStart = "${pkgs.bash}/bin/bash -c 'while true; do ${pkgs.iproute2}/bin/ip route replace default via \"$DEFAULT_GATEWAY\" dev ${iface} 2>/dev/null; ${pkgs.coreutils}/bin/sleep 10; done'";
        EnvironmentFile = config.sops.secrets."${config.networking.hostName}/network_env".path;
      };
    };
  };
}
