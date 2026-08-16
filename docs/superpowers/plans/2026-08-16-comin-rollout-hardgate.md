# Comin Staggered Hard-Gate Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the fleet-wide comin auto-apply into a **hard-gate canary rollout**: `k8s-node05` is a true auto-canary (auto deploys, health-gate rollback catches failures), while every other host pauses at deploy pending a `comin confirmation accept`. A single `scripts/comin-approve.sh` gatekeeper verifies node05 converged healthy, then walks the rollout order (node04 → … → server03) accepting each host only after the previous one is verified. A `comin_pending_confirmation` textfile metric is exposed to the existing cluster Prometheus so an alert can fire when a manual-gated host is ready. The alert rule itself is deliberately deferred (Alertmanager not yet enabled).

**Architecture:** `k8s-node05` gets `deployConfirmer.mode = "auto"` — it exercises the full auto-deploy → health-gate → rollback path on every commit to main, with a one-node blast radius. The other 11 hosts get `deployConfirmer.mode = "manual"` (build stays automatic), pausing at `switch-to-configuration switch` until `comin confirmation accept` runs on that host. `scripts/comin-approve.sh` is the single gate: it waits for node05's auto-deploy to converge (deploy done **and** not suspended **and** node Ready), aborts if node05 is suspended (health-gate rollback = canary failed), then auto-accepts the remaining hosts in least→most critical order with a `kubectl get node` health wait between each. A `postDeploymentCommand` health-gate on the 11 k3s hosts (including node05) rolls back to the previous successful generation and suspends comin if a deploy leaves the host unhealthy. A `systemd.timer` writes `comin_pending_confirmation` into the node_exporter textfile dir, which the kube-prometheus-stack DaemonSet mounts and scrapes automatically (no new ScrapeConfig).

**Tech Stack:** NixOS modules (`services.comin` from `github:nlewo/comin` rev `e72d8cc7ad188dbb109994cba9babf026bacf6ab`), bash (`scripts/comin-approve.sh`), systemd timers, kube-prometheus-stack HelmRelease (in `~/code/k8s-casa`), node_exporter textfile collector.

## Global Constraints

- Comin pinned rev is `e72d8cc7ad188dbb109994cba9babf026bacf6ab` (= `v0.14.0-14-ge72d8cc`). All module options used below exist there (`services.comin.deployConfirmer.mode`, `services.comin.buildConfirmer.mode`, `services.comin.postDeploymentCommand`, `services.comin.machineId`, `services.comin.package`).
- 12 comin hosts. `k8s-node05` is the auto-canary (`deployConfirmer.mode = "auto"`). Manual rollout order (least→most critical): `k8s-node04, k8s-node03, k8s-node02, k8s-node01, k8s-pi01, k8s-pi02, k8s-pi03, llm01, k8s-server01, k8s-server02, k8s-server03`.
- `comin status --json` uses protojson `UseProtoNames`, so JSON keys are snake_case: `deploy_confirmer.submitted`, `deploy_confirmer.confirmed`, `store.deployments[].status`, `store.deployments[].generation.out_path`, `store.deployment_switched` (a **UUID**, not a store path), `deployer.deployment.status`.
- Comin's system profile is `/nix/var/nix/profiles/system-profiles/comin`; rollback = `nix-env --profile <that> --set <prev-out-path>` then `<prev-out-path>/bin/switch-to-configuration switch`. `nixos-rebuild --rollback` targets the wrong profile — do NOT use it.
- `comin confirmation accept` on a host accepts the **currently pending** generation on that host (build or deploy). It is local-socket only (`/var/lib/comin/grpc.sock`); must run on the host, not from the Mac. node05 never needs this — it is auto.
- **Health-gate rollback signal:** after a health-gate rollback, `deployer.deployment.status` stays `"done"` (the deployment itself finished; the rollback happens after). The canary check in `comin-approve.sh` MUST therefore verify `is_suspended == false` (suspension = rollback happened) in addition to `status == done`.
- Network recovery for fresh worker switches: `ip route replace default via <gw> dev <iface>` then `systemctl reset-failed k3s; systemctl start k3s` (k3s unit is `k3s.service` on both servers and agents). The runtime gateway comes from the SOPS `network_env` secret (`config.sops.secrets."<hostname>/network_env".path`), NOT from `config.networking.defaultGateway` (which is null when `vars.nix` uses placeholders).
- `llm01` has NO k3s and NO `staticNetwork` (uses networkmanager) — it must NOT import the health-gate module (which references `config.k3s`, `config.staticNetwork`, and the `network_env` secret). Only the 11 k3s hosts import `modules/nixos/comin-health-gate.nix`.
- Textfile dir is `/var/lib/node-exporter/textfiles` on the host, mounted at `/host/textfiles` in the DS pod, scraped via the existing `node-exporter` PodMonitor (targetPort 9100). No new ScrapeConfig.
- Deferred (document in AGENTS.md, do NOT implement now): Pi closure-copy (`nix-copy-closure` pi01→pi02/03), reboot watchdog (`comin-reboot.nix`), remaining host migrations (pi02/pi03/llm01), llm01 health gate, and the `comin_pending_confirmation > 0` alert rule.
- Every changed Nix file must pass `nixfmt .`. Every changed host config must pass `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel --show-trace` on the Mac.
- NEVER commit plaintext secrets. No secret material is touched by this plan.

---

### Task 1: Add confirmer + health-gate options to `modules/nixos/comin.nix`

**Files:**
- Modify: `modules/nixos/comin.nix`

**Interfaces:**
- Produces: new module options `cominGitOps.confirmerMode` (enum `manual`/`auto`/`without`, default `"manual"`), `cominGitOps.pendingMetric.enable` (bool, default `true`), `cominGitOps.healthGate.enable` (bool, default `false`; flipped on by the host-side health-gate module). Sets `services.comin.deployConfirmer.mode` and `services.comin.buildConfirmer.mode`.

- [ ] **Step 1: Add the new options**

Edit `modules/nixos/comin.nix`. Current file (37 lines) defines `cominGitOps.enable`, `repositoryUrl`, `pollInterval`. Add to the `options` block:

```nix
      confirmerMode = lib.mkOption {
        type = lib.types.enum [
          "manual"
          "auto"
          "without"
        ];
        default = "manual";
        description = "Comin deploy confirmer mode. manual requires 'comin confirmation accept' on each host before deploying. node05 overrides to 'auto' (canary).";
      };
      healthGate = {
        enable = lib.mkEnableOption "Post-deployment health gate (route/k3s/current-system check with rollback)";
      };
      pendingMetric = {
        enable = lib.mkEnableOption "Emit comin_pending_confirmation textfile metric via node_exporter";
      };
```

- [ ] **Step 2: Wire the confirmer modes in the `config` block**

In `config = lib.mkIf config.cominGitOps.enable { ... }`, inside `services.comin`, add:

```nix
      buildConfirmer.mode = "without";
      deployConfirmer.mode = config.cominGitOps.confirmerMode;
```

- [ ] **Step 3: Verify the module evaluates**

Run: `nix eval .#nixosConfigurations.k8s-node05.config.cominGitOps.confirmerMode --show-trace`
Expected: `"manual"`

- [ ] **Step 4: Commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin.nix
git add modules/nixos/comin.nix
git commit -q -m "feat(comin): add confirmerMode, healthGate, and pendingMetric options"
```

### Task 2: Health-gate module `modules/nixos/comin-health-gate.nix`

**Files:**
- Create: `modules/nixos/comin-health-gate.nix`

**Interfaces:**
- Consumes: `cominGitOps.healthGate.enable` (set here), `config.services.comin.package`, `config.k3s.enable`, `config.staticNetwork.enable/interface`, `config.sops.secrets."<hostname>/network_env".path`.
- Produces: `services.comin.postDeploymentCommand` pointing at a `pkgs.writeShellScript` health gate. On `COMIN_STATUS=done` it checks route + k3s + current-system, auto-heals, and on persistent failure rolls back to the previous successful generation and suspends comin. On `COMIN_STATUS=failed` it suspends comin and notifies.
- **Only the 11 k3s hosts import this module** (node01-05, server01-03, pi01-03). `llm01` must not.

- [ ] **Step 1: Write the module**

Create `modules/nixos/comin-health-gate.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  envFile = config.sops.secrets."${config.networking.hostName}/network_env".path;
  healthGate = pkgs.writeShellScript "comin-health-gate" ''
    set -u
    LOG=/var/log/comin-health-gate.log
    log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

    ${pkgs.coreutils}/bin/mkdir -p /var/log

    case "$COMIN_STATUS" in
      failed)
        log "deployment FAILED: $COMIN_ERROR_MSG — suspending comin"
        ${config.services.comin.package}/bin/comin suspend
        exit 0
        ;;
      done)
        ;;
      *)
        # COMIN_STATUS unset/unknown → not a deploy we manage
        exit 0
        ;;
    esac

    log "deployment done (sha=$COMIN_GIT_SHA) — running health gate"

    # 1) default route present? heal from the SOPS network_env secret.
    if ! ${pkgs.iproute2}/bin/ip route show default | ${pkgs.grep}/bin/grep -q default; then
      log "no default route — healing"
      if [ -f "$envFile" ]; then
        . "$envFile"
        ${pkgs.iproute2}/bin/ip route replace default via "$DEFAULT_GATEWAY" dev "${config.staticNetwork.interface}"
      else
        log "network_env not found at $envFile — cannot heal route"
      fi
    fi

    # 2) k3s active?
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet k3s; then
      log "k3s not active — resetting and starting"
      ${pkgs.systemd}/bin/systemctl reset-failed k3s
      ${pkgs.systemd}/bin/systemctl start k3s
    fi

    # 3) current-system matches the switched deployment's out_path
    #    (deployment_switched holds a UUID, not a store path — resolve it)
    current=$(${pkgs.coreutils}/bin/readlink /run/current-system)
    expected=$(sw_uuid=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.store.deployment_switched // empty'); ${config.services.comin.package}/bin/comin status --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r --arg u "$sw_uuid" '.store.deployments[] | select(.uuid == $u) | .generation.out_path // empty' 2>/dev/null)

    if [ -n "$expected" ] && [ "$current" != "$expected" ]; then
      log "current-system ($current) != switched ($expected) — rolling back"
      # Pick the most recent done out_path that is not the current system
      # (this deploy already finished, so it is the current one).
      prev=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r --arg cur "$current" '[.store.deployments[] | select(.status == "done" and .generation.out_path != $cur) | .generation.out_path] | .[0] // empty' 2>/dev/null)
      if [ -n "$prev" ] && [ "$prev" != "$current" ]; then
        ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system-profiles/comin --set "$prev"
        "$prev/bin/switch-to-configuration" switch >> "$LOG" 2>&1
      fi
      ${config.services.comin.package}/bin/comin suspend
      log "rolled back to $prev and suspended"
      exit 0
    fi

    log "health gate OK"
  '';
in
{
  config = lib.mkIf config.cominGitOps.healthGate.enable {
    services.comin.postDeploymentCommand = healthGate;
  };
}
```

Note: the module references `config.k3s`, `config.staticNetwork`, and the `network_env` secret, which only exist on the 11 k3s hosts. `llm01` does NOT import this module.

- [ ] **Step 2: Validate the script renders on a k3s host and confirm llm01 has no reference**

```bash
nix eval --raw .#nixosConfigurations.k8s-node05.config.services.comin.postDeploymentCommand --show-trace | xargs -I{} bash -n {} && echo "node05 syntax OK"
nix eval .#nixosConfigurations.llm01.config.services.comin.postDeploymentCommand --show-trace
```
Expected: node05 prints `<store path> syntax OK`; llm01 prints `null` (postDeploymentCommand unset — the health-gate module is not imported there).

- [ ] **Step 3: Commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin-health-gate.nix
git add modules/nixos/comin-health-gate.nix
git commit -q -m "feat(comin): postDeploymentCommand health gate (route/k3s check, rollback, suspend)"
```

### Task 3: Import the health-gate module on the 11 k3s hosts

**Files:**
- Modify: `hosts/k8s-node01/configuration.nix`, `hosts/k8s-node02/configuration.nix`, `hosts/k8s-node03/configuration.nix`, `hosts/k8s-node04/configuration.nix`, `hosts/k8s-node05/configuration.nix`, `hosts/k8s-server01/configuration.nix`, `hosts/k8s-server02/configuration.nix`, `hosts/k8s-server03/configuration.nix`, `hosts/k8s-pi01/configuration.nix`, `hosts/k8s-pi02/configuration.nix`, `hosts/k8s-pi03/configuration.nix`

**Interfaces:**
- Consumes: Task 1 (the `healthGate.enable` option), Task 2 (the module).
- Produces: `cominGitOps.healthGate.enable = true` + the `comin-health-gate.nix` import on every k3s host.

- [ ] **Step 1: Add the import and enablement to each of the 11 hosts**

Each `hosts/<host>/configuration.nix` already has a line `../../modules/nixos/comin.nix` in `imports` and a `cominGitOps.enable = true;` line. For **each of the 11 k3s hosts** (node01-05, server01-03, pi01-03):

1. Add `../../modules/nixos/comin-health-gate.nix` to the `imports` list (directly after the `comin.nix` import).
2. Add `cominGitOps.healthGate.enable = true;` next to the existing `cominGitOps.enable = true;`.

Additionally, **`hosts/k8s-node05/configuration.nix`** gets the auto-canary override next to its `cominGitOps.enable = true;`:

```nix
cominGitOps.confirmerMode = "auto";
```

node05 is the only host with `confirmerMode = "auto"`; all other 11 keep the default `"manual"`.

- [ ] **Step 2: Verify eval on a representative agent, server, and Pi**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.k8s-server01.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.k8s-pi01.config.system.build.toplevel --show-trace
```
Expected: all three evaluate without error.

- [ ] **Step 3: Commit**

```bash
cd ~/code/nixos-configurations
git add hosts/k8s-node0{1,2,3,4,5}/configuration.nix hosts/k8s-server0{1,2,3}/configuration.nix hosts/k8s-pi0{1,2,3}/configuration.nix
git commit -q -m "feat(hosts): enable comin health gate on all 11 k3s hosts"
```

### Task 4: `comin_pending_confirmation` textfile metric writer

**Files:**
- Modify: `modules/nixos/comin.nix`

**Interfaces:**
- Consumes: `cominGitOps.pendingMetric.enable`; `config.services.comin.package`.
- Produces: `systemd.timer` + oneshot service writing `/var/lib/node-exporter/textfiles/comin.prom` with `comin_pending_confirmation 1|0` every 60s; `systemd.tmpfiles` entry creating the directory.

- [ ] **Step 1: Add the timer, service, and tmpfiles rule**

In `modules/nixos/comin.nix`, inside the `config` block, add:

```nix
  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter/textfiles 0755 root root -"
  ];

  systemd.services.comin-pending-metric = {
    description = "Write comin_pending_confirmation textfile metric";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "comin-pending-metric" ''
        set -u
        json=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null || ${pkgs.coreutils}/bin/echo -n '')
        pending=$(${pkgs.coreutils}/bin/printf '%s' "$json" \
          | ${pkgs.jq}/bin/jq -r 'if (.deploy_confirmer.submitted != "" and .deploy_confirmer.confirmed == "") then 1 else 0 end' 2>/dev/null \
          || ${pkgs.coreutils}/bin/printf '0')
        ${pkgs.coreutils}/bin/printf 'comin_pending_confirmation %s\n' "$pending" > /tmp/comin.prom.$$
        ${pkgs.coreutils}/bin/mv /tmp/comin.prom.$$ /var/lib/node-exporter/textfiles/comin.prom
      '';
    };
  };

  systemd.timers.comin-pending-metric = {
    description = "Periodically refresh comin_pending_confirmation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60";
      OnUnitActiveSec = "60";
      AccuracySec = "10";
    };
  };
```

These are enabled by default via `pendingMetric.enable`'s `mkEnableOption` default `true`; to keep the `lib.mkIf config.cominGitOps.enable` structure clean, the whole block above already sits inside that `config` block, so it only applies when comin is enabled at all.

- [ ] **Step 2: Verify the service unit renders**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.systemd.services.comin-pending-metric.serviceConfig.ExecStart --show-trace
```
Expected: prints the derived store path to the writeShellScript.

- [ ] **Step 3: Commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin.nix
git add modules/nixos/comin.nix
git commit -q -m "feat(comin): emit comin_pending_confirmation textfile metric"
```

### Task 5: `scripts/comin-approve.sh` gatekeeper

**Files:**
- Create: `scripts/comin-approve.sh`

**Interfaces:**
- Consumes: SSH access to all 12 hosts, `comin status --json`, `kubectl`, `jq`, `osascript` (macOS).
- Produces: an executable script that alerts + waits on node05, then auto-accepts the rollout order with health waits.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Comin hard-gate rollout. node05 is the auto-canary; the rest are
# manual and accepted here in least -> most critical order.
CANARY=k8s-node05
ORDER=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 llm01 k8s-server01 k8s-server02 k8s-server03)

deploy_status() { # host -> deployer.deployment.status
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r '.deployer.deployment.status // "none"'
}

is_suspended() { # host -> "true" if comin is suspended
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r '.is_suspended // "false"'
}

pending() { # host -> prints 1 if a deploy confirmation is pending
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r 'if (.deploy_confirmer.submitted != "" and .deploy_confirmer.confirmed == "") then 1 else 0 end'
}

node_ready() { # node -> 1 when Ready
  kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}

wait_for() { # desc, seconds, cmd...
  local desc="$1" timeout="$2"; shift 2
  local i=0
  until "$@" | grep -q "1\|True\|done"; do
    [ $i -lt "$timeout" ] || { echo "TIMEOUT waiting for $desc"; exit 1; }
    sleep 5; i=$((i + 5))
  done
  echo "$desc OK"
}

# 1) Wait for the canary to converge. Suspension = the health gate
#    rolled it back, so abort the rollout.
echo "== waiting for canary $CANARY to auto-deploy"
wait_for "$CANARY deploy done" 900 deploy_status "$CANARY"
if [ "$(is_suspended "$CANARY")" = "true" ]; then
  osascript -e "display notification \"$CANARY rolled back (comin suspended) — rollout aborted\" with title \"comin approve\""
  echo "ABORT: $CANARY rolled back (comin suspended). Fix main before retrying."
  exit 1
fi
wait_for "$CANARY node Ready" 600 node_ready "$CANARY"
echo "== canary $CANARY healthy"

# 2) Accept the manual hosts in order, waiting for each to converge.
for h in "${ORDER[@]}"; do
  if [ "$(pending "$h")" != "1" ]; then
    echo "== $h: nothing pending, skipping"
    continue
  fi
  echo "== $h: deploy confirmation pending — accepting"
  ssh "$h" 'comin confirmation accept'
  wait_for "$h deploy done" 900 deploy_status "$h"
  if [ "$(is_suspended "$h")" = "true" ]; then
    echo "ABORT: $h rolled back (comin suspended). Investigate before continuing."
    exit 1
  fi
  wait_for "$h node Ready" 600 node_ready "$h"
done
echo "ALL HOSTS DEPLOYED AND READY"
```

- [ ] **Step 2: Make it executable and syntax-check**

```bash
chmod +x scripts/comin-approve.sh
bash -n scripts/comin-approve.sh && echo "syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/comin-approve.sh
git commit -q -m "feat(scripts): comin-approve.sh hard-gate rollout gatekeeper"
```

### Task 6: node_exporter textfile mount in kube-prometheus-stack (k8s-casa repo)

**Files:**
- Modify: `~/code/k8s-casa/apply/10-infra/monitoring/prometheus.yaml` (HelmRelease `kube-prometheus-stack`)

**Interfaces:**
- Consumes: host dir `/var/lib/node-exporter/textfiles` (Task 4).
- Produces: DS node_exporter running `--collector.textfile.directory=/host/textfiles`; existing `node-exporter` PodMonitor (targetPort 9100) scrapes `comin_pending_confirmation` automatically.

- [ ] **Step 1: Add the node-exporter subchart values**

In `apply/10-infra/monitoring/prometheus.yaml`, inside `spec.values`, append:

```yaml
    prometheus-node-exporter:
      extraArgs:
        - --collector.textfile.directory=/host/textfiles
      extraHostVolumeMounts:
        - name: textfiles
          mountPath: /host/textfiles
          hostPath: /var/lib/node-exporter/textfiles
```

- [ ] **Step 2: Validate the YAML**

```bash
cd ~/code/k8s-casa
python3 -c "import yaml,sys; yaml.safe_load(open('apply/10-infra/monitoring/prometheus.yaml')); print('YAML OK')"
```
Expected: `YAML OK` (client dry-run may fail without a cluster; parse validation is the goal).

- [ ] **Step 3: Commit**

```bash
cd ~/code/k8s-casa
git add apply/10-infra/monitoring/prometheus.yaml
git commit -q -m "feat(monitoring): mount node_exporter textfile collector for comin_pending_confirmation"
```

### Task 7: Fleet-wide enablement + final verification

**Files:**
- Modify: none (module defaults already apply to all 12 hosts)

**Interfaces:**
- Consumes: all prior tasks.

- [ ] **Step 1: Confirm the confirmer modes across the fleet**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.services.comin.deployConfirmer.mode --show-trace
nix eval .#nixosConfigurations.k8s-server03.config.services.comin.deployConfirmer.mode --show-trace
nix eval .#nixosConfigurations.llm01.config.services.comin.deployConfirmer.mode --show-trace
```
Expected: node05 prints `"auto"` (canary); server03 and llm01 print `"manual"`. Also confirm build mode:
```bash
nix eval .#nixosConfigurations.k8s-node05.config.services.comin.buildConfirmer.mode --show-trace
```
Expected: `"without"`.

- [ ] **Step 2: Full evaluation of representative hosts (all code paths)**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.k8s-pi01.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
```
Expected: all evaluate without error (llm01 has no health-gate reference, so its `services.comin.postDeploymentCommand` stays `null`).

- [ ] **Step 3: Format + commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin.nix modules/nixos/comin-health-gate.nix
git add -A
git commit -q -m "feat(comin): hard-gate rollout (node05 auto-canary, manual confirmers, health gate, pending metric, approve script)"
```

### Task 8: Document the deferred TODOs in AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add a "Hard-Gate Rollout" subsection**

In `AGENTS.md`, after the existing **GitOps with Comin** section, add:

```markdown
### Hard-Gate Rollout (2026-08)

`k8s-node05` is the auto-canary: it auto-deploys every commit to main
(`deployConfirmer.mode = "auto"`), exercising the health-gate rollback
path with a one-node blast radius. The other 11 hosts run
`deployConfirmer.mode = "manual"`: they fetch/build automatically but
pause before `switch-to-configuration switch` until
`comin confirmation accept` runs on that host (local unix socket only —
never from the Mac).

Manual rollout order (least -> most critical): `k8s-node04 ->
k8s-node03 -> k8s-node02 -> k8s-node01 -> k8s-pi01 -> k8s-pi02 ->
k8s-pi03 -> llm01 -> k8s-server01 -> k8s-server02 -> k8s-server03`.

Gatekeeper:
```bash
./scripts/comin-approve.sh
```
It waits for node05's auto-deploy to converge (deploy done **and** not
suspended **and** node Ready), aborts if node05 is suspended (health
gate rolled it back), then auto-accepts the rest with a `kubectl get
node` wait between hosts.

Health gate (`postDeploymentCommand`, 11 k3s hosts only — NOT llm01):
on `COMIN_STATUS=done` it checks the default route, k3s service, and that
`/run/current-system` matches the switched generation's `out_path`;
auto-heals (restore route from the SOPS `network_env` / restart k3s) and on
persistent failure rolls back the comin profile
(`/nix/var/nix/profiles/system-profiles/comin`, NOT `nixos-rebuild --rollback`)
and suspends comin. On `COMIN_STATUS=failed` it suspends comin. Note:
after a rollback `deployer.deployment.status` stays `"done"` — the
approve script detects rollback via `is_suspended`, not status.

Metric: `comin_pending_confirmation` is written to
`/var/lib/node-exporter/textfiles/comin.prom` every 60s and scraped by
the cluster Prometheus via the DS node_exporter textfile mount.

#### TODO features (not yet implemented)
- [ ] Alert rule `comin_pending_confirmation > 0` — blocked on enabling Alertmanager.
- [ ] Pi closure-copy: after package trims, build once on pi01 then
      `nix-copy-closure --to k8s-pi02 / --to k8s-pi03` (kernel drv
      unaffected by trims; pi01 kernel build currently running in
      background).
- [ ] Reboot watchdog (`modules/nixos/comin-reboot.nix` on k8s-server01):
      drain -> reboot -> uncordon per host when
      `/run/current-system/kernel` != `/run/booted-system/kernel`;
      skip servers, llm01 notify-only.
- [ ] Health gate for `llm01` (no k3s/staticNetwork; needs a
      current-system-only check).
- [ ] Migrate remaining hosts to 26.05: pi02 -> pi03 -> llm01; final sweep.
- [ ] Replace the hardcoded `comin.devices` target list in
      `k8s-casa/apply/50-apps/monitoring/prom-scrapes.yaml` with k8s
      autodiscovery (`kubernetesSDConfigs.role: node`, relabel
      `__meta_kubernetes_node_address_InternalIP` -> `$IP:4243`, plus
      `instance`/`node`/`hostname` labels). Covers all cluster nodes
      automatically; non-node hosts (llm01, esphome) stay as a small
      static list.
```

- [ ] **Step 2: Commit**

```bash
cd ~/code/nixos-configurations
git add AGENTS.md
git commit -q -m "docs(AGENTS): document comin hard-gate rollout and deferred TODOs"
```