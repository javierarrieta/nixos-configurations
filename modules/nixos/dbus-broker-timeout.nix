{
  config,
  lib,
  pkgs,
  ...
}:
{
  systemd.services.dbus-broker = {
    # Reload jobs (SIGHUP on nixos-rebuild switch) run against the START
    # timeout: there is no systemd "ReloadTimeoutSec" key — setting one is
    # silently ignored ("Unknown key ... ignoring", seen on k8s-node04
    # 2026-08-27) and the 90s default still aborts switches on I/O-slow hosts.
    serviceConfig.TimeoutStartSec = 300;
  };
}
