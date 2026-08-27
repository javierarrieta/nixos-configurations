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
    # Do NOT force restartIfChanged here: a restart-instead-of-reload trial
    # (reverted same day) left the system bus dead on both canaries — SCoN
    # double-stopped dbus mid-switch and the queued start died with the
    # aborted switch. Reload can hang under heavy load (node04 2026-08-27,
    # iscsid storm + pod churn) but completes on healthy hosts; 300s gives
    # headroom. If a host hangs again, reboot it rather than raising this.
    restartIfChanged = lib.mkDefault true;
  };
}
