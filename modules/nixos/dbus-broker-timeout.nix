{
  config,
  lib,
  pkgs,
  ...
}:
{
  systemd.services.dbus-broker = {
    serviceConfig.ReloadTimeoutSec = 300;
  };
}
