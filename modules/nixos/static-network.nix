{
  config,
  lib,
  pkgs,
  ...
}:
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
    networking.interfaces.${config.staticNetwork.interface} = {
      ipv4.addresses = [
        {
          address = config.staticNetwork.ipAddress;
          prefixLength = config.staticNetwork.prefixLength;
        }
      ];
      useDHCP = false;
    };
    networking.defaultGateway = config.staticNetwork.defaultGateway;
    networking.nameservers = config.staticNetwork.nameservers;
  };
}
