{
  config,
  lib,
  pkgs,
  ...
}:

let
  checks = config.cominGitOps.healthGate.checks;
  hasCheck = name: builtins.elem name checks;

  envFile = lib.optionalString (config.sops.secrets ? "${config.networking.hostName}/network_env")
    config.sops.secrets."${config.networking.hostName}/network_env".path;

  routeCheck = lib.optionalString (hasCheck "route") ''
    if ! ${pkgs.iproute2}/bin/ip route show default | ${pkgs.gnugrep}/bin/grep -q default; then
      log "no default route — healing"
      if [ -n "${envFile}" ] && [ -f "${envFile}" ]; then
        . "${envFile}"
        ${pkgs.iproute2}/bin/ip route replace default via "$DEFAULT_GATEWAY" dev "${config.staticNetwork.interface}"
      else
        log "network_env not found at ${envFile} — cannot heal route"
      fi
    fi
  '';

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
      if [ $i -ge 300 ]; then
        log "llama-cpp-server not healthy after warmup (active + :8001) — rolling back"
        rollback_and_suspend "llama-cpp-server unhealthy"
        exit 0
      fi
      sleep 5; i=$((i + 5))
    done
  '';

  currentSystemCheck = ''
    current=$(${pkgs.coreutils}/bin/readlink /run/current-system)
    expected=$(sw_uuid=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.store.deployment_switched // empty'); ${config.services.comin.package}/bin/comin status --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r --arg u "$sw_uuid" '.store.deployments[] | select(.uuid == $u) | .generation.out_path // empty' 2>/dev/null)

    if [ -n "$expected" ] && [ "$current" != "$expected" ]; then
      log "current-system ($current) != switched ($expected) — rolling back"
      rollback_and_suspend "current-system != switched generation"
      exit 0
    fi
  '';

  healthGate = pkgs.writeShellScript "comin-health-gate" healthGateText;
  healthGateText = ''
    set -u
    LOG=/var/log/comin-health-gate.log
    log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

    ${pkgs.coreutils}/bin/mkdir -p /var/log

    rollback_and_suspend() { # reason
      local reason="$1"
      local current prev
      current=$(${pkgs.coreutils}/bin/readlink /run/current-system)
      prev=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r --arg cur "$current" '[.store.deployments[] | select(.status == "done" and .generation.out_path != $cur) | .generation.out_path] | .[0] // empty' 2>/dev/null)
      if [ -n "$prev" ] && [ "$prev" != "$current" ]; then
        log "rolling back to $prev ($reason)"
        ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system-profiles/comin --set "$prev"
        "$prev/bin/switch-to-configuration" switch >> "$LOG" 2>&1
      else
        log "no previous generation to roll back to ($reason)"
      fi
      ${config.services.comin.package}/bin/comin suspend
    }

    case "$COMIN_STATUS" in
      failed)
        log "deployment FAILED: $COMIN_ERROR_MSG — suspending comin"
        ${config.services.comin.package}/bin/comin suspend
        exit 0
        ;;
      done)
        ;;
      *)
        exit 0
        ;;
    esac

    log "deployment done (sha=$COMIN_GIT_SHA) — running health gate"

    ${routeCheck}
    ${k3sCheck}
    ${llamaCppCheck}
    ${currentSystemCheck}

    log "health gate OK"
  '';
in
{
  config = lib.mkIf config.cominGitOps.healthGate.enable {
    services.comin.postDeploymentCommand = healthGate;
  };
}