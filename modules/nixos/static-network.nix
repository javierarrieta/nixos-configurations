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
  };
}
