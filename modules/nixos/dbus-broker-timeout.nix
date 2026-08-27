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
    # dbus-broker's reload HANGS (not merely slow) when a switch coincides
    # with heavy load — on k8s-node04 (2026-08-27) it outlived 300s while
    # iscsid was in a reconnect storm and k3s churned pods. Reloads also
    # failed at 90s on 08-16/17/26. A restart is bounded and deterministic,
    # so switch-to-configuration must never pick the reload path.
    reloadIfChanged = lib.mkForce false;
  };
}
