{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    prometheus = {
      nodeExporter = {
        enable = lib.mkEnableOption "Prometheus node exporter";
        port = lib.mkOption {
          type = lib.types.port;
          default = 9002;
          description = "Port for node exporter";
        };
        collectors = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "systemd" ];
          description = "List of collectors to enable";
        };
      };
    };
  };

  config = lib.mkIf config.prometheus.nodeExporter.enable {
    services.prometheus.exporters.node = {
      enable = true;
      port = config.prometheus.nodeExporter.port;
      enabledCollectors = config.prometheus.nodeExporter.collectors;
    };
  };
}
