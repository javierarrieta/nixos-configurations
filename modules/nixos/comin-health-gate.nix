{
  config,
  lib,
  pkgs,
  ...
}:

let
  checks = config.cominGitOps.healthGate.checks;
  hasCheck = name: builtins.elem name checks;

  envFile = lib.optionalString (
    config.sops.secrets ? "${config.networking.hostName}/network_env"
  ) config.sops.secrets."${config.networking.hostName}/network_env".path;

  # Same placeholder detection as static-network.nix: vars.nix either carries
  # "$..." placeholders resolved at runtime from the SOPS network_env secret,
  # or real values baked in at eval time (k8s-pi*, which have no network_env).
  isPlaceholder = s: lib.hasPrefix "$" s;
  # Shell reference for the expected gateway. MUST be a single $ (no \$
  # escaping): inside an indented Nix string the backslash survives eval, so
  # "\$DEFAULT_GATEWAY" reaches grep as match-text containing a literal '$'
  # instead of expanding at runtime.
  defaultGatewayRef =
    if isPlaceholder config.staticNetwork.defaultGateway then
      "$DEFAULT_GATEWAY"
    else
      config.staticNetwork.defaultGateway;

  routeCheckBody = ''
    if ! ${pkgs.iproute2}/bin/ip route show default | ${pkgs.gnugrep}/bin/grep -q "default via ${defaultGatewayRef} dev ${config.staticNetwork.interface}"; then
      log "no correct default route — healing"
      ${pkgs.iproute2}/bin/ip route replace default via "${defaultGatewayRef}" dev ${config.staticNetwork.interface}
    fi
  '';

  # Placeholder hosts: $DEFAULT_GATEWAY only exists after sourcing network_env
  # and the script runs under `set -u`, so source BEFORE the test — which also
  # lets the heal branch rely on the sourced vars. Literal-gateway hosts need
  # no sourcing; if a placeholder host lost its env file, skip the check with a
  # log instead of expanding unset vars.
  routeCheck = lib.optionalString (hasCheck "route") (
    if envFile != "" then
      lib.replaceStrings [ "\n" ] [ "\n  " ] ''
        if [ -f "${envFile}" ]; then
          . "${envFile}"
          ${routeCheckBody}
        else
          log "network_env not found at ${envFile} — cannot check/heal route"
        fi
      ''
    else
      routeCheckBody
  );

  k3sCheck = lib.optionalString (hasCheck "k3s") ''
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet k3s; then
      log "k3s not active — resetting and starting"
      ${pkgs.systemd}/bin/systemctl reset-failed k3s
      ${pkgs.systemd}/bin/systemctl start k3s
    fi
  '';

  llamaCppCheck = lib.optionalString (hasCheck "llama-cpp") ''
    i=0
    until ${pkgs.systemd}/bin/systemctl is-active --quiet llama-cpp-server \
        && ${pkgs.iproute2}/bin/ss -tln | ${pkgs.gnugrep}/bin/grep -q ':8001 '; do
      if [ $i -ge 600 ]; then
        log "llama-cpp-server not healthy after warmup (active + :8001) — rolling back"
        rollback_and_suspend "llama-cpp-server unhealthy"
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 5; i=$((i + 5))
    done
  '';

  # A switch that dies mid-activation (e.g. iscsid.socket refusing to start on
  # a stale node db, seen 2026-08-26 on k8s-node05) leaves home-manager files
  # updated while /run/current-system stays old; a later GC then deletes the
  # rolled-back generation's binaries. Catch the iSCSI variant here: heal once,
  # roll back if still broken. Only active on hosts with openiscsi.enable.
  iscsiCheck = lib.optionalString (hasCheck "iscsi" && config.openiscsi.enable) ''
    if ! ${pkgs.openiscsi}/bin/iscsiadm -m node >/dev/null 2>&1; then
      log "iscsiadm -m node failing — healing stale node db"
      ${pkgs.systemd}/bin/systemctl stop iscsid.socket iscsid.service
      ${pkgs.coreutils}/bin/rm -rf /etc/iscsi/nodes /etc/iscsi/send_targets
      ${pkgs.coreutils}/bin/mkdir -p /etc/iscsi/nodes /etc/iscsi/send_targets
      ${pkgs.systemd}/bin/systemctl start iscsid.service iscsid.socket
      ${pkgs.coreutils}/bin/sleep 5
    fi
    if ! ${pkgs.openiscsi}/bin/iscsiadm -m node >/dev/null 2>&1; then
      rollback_and_suspend "iscsi unhealthy after heal"
      exit 0
    fi
  '';

  # /run/current-system can legitimately lag behind the last comin-switched
  # generation right after a boot (boot entry vs last switch); that mismatch
  # caused false rollbacks on 2026-08-18/21. Give the machine 10 min of uptime
  # before enforcing this check.
  currentSystemCheck = ''
    uptime_s=$(cut -d. -f1 /proc/uptime)
    if [ "$uptime_s" -lt 600 ]; then
      log "up $uptime_s s — skipping current-system check (post-boot grace period)"
    else
      current=$(${pkgs.coreutils}/bin/readlink /run/current-system)
      expected=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '.deployer.deployment.generation.out_path // empty')

      if [ -n "$expected" ] && [ "$current" != "$expected" ]; then
        log "current-system ($current) != switched ($expected) — rolling back"
        rollback_and_suspend "current-system != switched generation"
        exit 0
      fi
    fi
  '';

  healthGate = pkgs.writeShellScriptBin "comin-health-gate" healthGateText;
  healthGateText = ''
    set -u
    LOG=/var/log/comin-health-gate.log
    log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

    ${pkgs.coreutils}/bin/mkdir -p /var/log

    FLAG_DIR=/var/lib/comin-health-gate
    RETRY_FLAG="$FLAG_DIR/failed-retry-pending"
    ${pkgs.coreutils}/bin/mkdir -p "$FLAG_DIR"

    rollback_and_suspend() { # reason
      local reason="$1"
      local current prev
      current=$(${pkgs.coreutils}/bin/readlink /run/current-system)
      prev=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r --arg cur "$current" '[.store.deployments[] | select(.status == "done" and .generation.out_path != $cur) | .generation.out_path] | .[0] // empty' 2>/dev/null)
      if [ -n "$prev" ] && [ "$prev" != "$current" ] && [ -x "$prev/bin/switch-to-configuration" ]; then
        log "rolling back to $prev ($reason)"
        ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system-profiles/comin --set "$prev"
        "$prev/bin/switch-to-configuration" switch >> "$LOG" 2>&1
      elif [ -n "$prev" ] && [ ! -x "$prev/bin/switch-to-configuration" ]; then
        # Rollback target was garbage-collected (seen 2026-08-21) — switching to
        # it would fail anyway; keep the running system and just suspend.
        log "rollback target $prev not usable ($reason) — suspending without rollback"
      else
        log "no previous generation to roll back to ($reason)"
      fi
      ${config.services.comin.package}/bin/comin suspend
    }

    case "$COMIN_STATUS" in
      failed)
        # Never roll back on a failed switch (half-activated system is unsafe
        # to re-switch), but do not just suspend either: heal what we can,
        # then retry once so transient dbus-broker reload timeouts self-recover.
        log "deployment FAILED: $COMIN_ERROR_MSG — running pre-suspend healing"
        ${routeCheck}
        ${k3sCheck}
        if [ -f "$RETRY_FLAG" ]; then
          ${pkgs.coreutils}/bin/rm -f "$RETRY_FLAG"
          log "already retried after this failure — suspending comin"
          ${config.services.comin.package}/bin/comin suspend
          exit 0
        fi
        ${pkgs.coreutils}/bin/touch "$RETRY_FLAG"
        log "retrying same generation once (comin deployment submit-latest)"
        ${config.services.comin.package}/bin/comin deployment submit-latest >> "$LOG" 2>&1
        exit 0
        ;;
      done)
        # Success resets the bounded-retry counter for future failures.
        ${pkgs.coreutils}/bin/rm -f "$RETRY_FLAG"
        ;;
      *)
        exit 0
        ;;
    esac

    log "deployment done (sha=$COMIN_GIT_SHA) — running health gate"

    ${routeCheck}
    ${k3sCheck}
    ${llamaCppCheck}
    ${iscsiCheck}
    ${currentSystemCheck}

    log "health gate OK"
  '';
in
{
  config = lib.mkIf config.cominGitOps.healthGate.enable {
    # The gate must live at a CONSTANT path: comin's deployer caches
    # postDeploymentCommand (a store path) in its yaml at daemon startup and
    # runs it after every deploy. If the daemon outlives its source
    # generation (comin keeps only 3 deployment profiles), nix-sweep's GC
    # deletes that generation's gate copy and the cached path goes dead —
    # the gate then silently stops running (fork/exec ENOENT, seen
    # 2026-08-29 on the fleet ring). The system-environment path is
    # GC-protected by the system profile and always resolves to the
    # current generation's gate, even when an old daemon deploys it.
    environment.systemPackages = [ healthGate ];
    services.comin.postDeploymentCommand = "/run/current-system/sw/bin/comin-health-gate";
  };
}
