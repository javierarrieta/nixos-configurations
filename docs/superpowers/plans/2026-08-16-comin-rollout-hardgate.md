# Comin Branch-Based Hard-Gate Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the fleet-wide comin auto-apply into a **branch-based hard-gate rollout** with two rings:
- **Canary ring (branch `main`, auto-deploy):** `k8s-node05` + `llm01`. Every commit to `main` auto-deploys to both, and a `postDeploymentCommand` health gate validates + auto-rolls-back + suspends comin on failure.
- **Fleet ring (branch `stable`, manual-confirm):** `k8s-node01/02/03/04`, `k8s-server01/02/03`, `k8s-pi01/02/03` (10 hosts). They track `stable`; promotion is a **manual git merge `main` → `stable`** (an explicit human gate), after which each fleet host pauses at deploy pending a `comin confirmation accept`.

A single `scripts/comin-approve.sh` gatekeeper verifies both canaries converged healthy, then walks the fleet order (node04 → … → server03) accepting each host only after the previous one is verified. A `comin_pending_confirmation` textfile metric is exposed to the existing cluster Prometheus so an alert can fire when a manual-gated host is ready. The alert rule itself is deliberately deferred (Alertmanager not yet enabled).

**Architecture:** `main` = canary ring. `k8s-node05` and `llm01` get `deployConfirmer.mode = "auto"` — they exercise the full auto-deploy → health-gate → rollback path on every commit to main, with a two-host blast radius. `stable` = fleet ring: the 10 fleet hosts get `deployConfirmer.mode = "manual"` (build stays automatic), pausing at `switch-to-configuration switch` until `comin confirmation accept` runs on that host. `scripts/comin-approve.sh` is the single gate: it waits for both canaries to converge (deploy done **and** not suspended, node Ready where applicable), aborts if any canary is suspended (health-gate rollback = canary failed), then auto-accepts the fleet in least→most critical order with a `kubectl get node` health wait between each. All 12 hosts run a `postDeploymentCommand` health gate: the 10 k3s fleet hosts + node05 check route + k3s + current-system; llm01 checks current-system + llama-cpp-server (active + listening on 8001). A `systemd.timer` writes `comin_pending_confirmation` into the node_exporter textfile dir, which the kube-prometheus-stack DaemonSet mounts and scrapes automatically (no new ScrapeConfig).

**Rollout workflow (after implementation):**
```bash
# 1. Push to main → node05 + llm01 auto-deploy, health-gated
git push origin main
# 2. Confirm canaries converged (approve script's pre-flight does this):
./scripts/comin-approve.sh    # waits for canaries; exits with "merge main→stable to promote" if fleet has nothing pending
# 3. Promote (manual, human gate):
git checkout stable && git merge main && git push origin stable
# 4. Gate the fleet:
./scripts/comin-approve.sh    # now fleet hosts have pending confirmations → accepted in order
```

**Tech Stack:** NixOS modules (`services.comin` from `github:nlewo/comin` rev `e72d8cc7ad188dbb109994cba9babf026bacf6ab`), bash (`scripts/comin-approve.sh`), systemd timers, kube-prometheus-stack HelmRelease (in `~/k8s-casa`), node_exporter textfile collector.

## Global Constraints

- Comin pinned rev is `e72d8cc7ad188dbb109994cba9babf026bacf6ab` (= `v0.14.0-14-ge72d8cc`). All module options used below exist there (`services.comin.deployConfirmer.mode`, `services.comin.buildConfirmer.mode`, `services.comin.postDeploymentCommand`, `services.comin.machineId`, `services.comin.package`).
- 12 comin hosts, two rings:
  - **Canary ring (`main`):** `k8s-node05` + `llm01`, `deployConfirmer.mode = "auto"`.
  - **Fleet ring (`stable`):** `k8s-node01/02/03/04`, `k8s-server01/02/03`, `k8s-pi01/02/03`, `deployConfirmer.mode = "manual"`. Fleet rollout order (least→most critical): `k8s-node04, k8s-node03, k8s-node02, k8s-node01, k8s-pi01, k8s-pi02, k8s-pi03, k8s-server01, k8s-server02, k8s-server03`.
- **Branch tracking is per-host** via a new `cominGitOps.branch` option mapping to `branches.main.name`. Canaries keep the default `"main"`; the 10 fleet hosts set `"stable"`. comin selects the branch head exactly as it did for `main` — no tag/commit pinning involved.
- `comin status --json` uses protojson `UseProtoNames`, so JSON keys are snake_case: `deploy_confirmer.submitted`, `deploy_confirmer.confirmed`, `store.deployments[].status`, `store.deployments[].generation.out_path`, `store.deployment_switched` (a **UUID**, not a store path), `deployer.deployment.status`.
- Comin's system profile is `/nix/var/nix/profiles/system-profiles/comin`; rollback = `nix-env --profile <that> --set <prev-out-path>` then `<prev-out-path>/bin/switch-to-configuration switch`. `nixos-rebuild --rollback` targets the wrong profile — do NOT use it.
- `comin confirmation accept` on a host accepts the **currently pending** generation on that host (build or deploy). It is local-socket only (`/var/lib/comin/grpc.sock`); must run on the host, not from the Mac. Canaries never need this — they are auto.
- **Health-gate rollback signal:** after a health-gate rollback, `deployer.deployment.status` stays `"done"` (the deployment itself finished; the rollback happens after). The canary check in `comin-approve.sh` MUST therefore verify `is_suspended == false` (suspension = rollback happened) in addition to `status == done`.
- Network recovery for fresh worker switches: `ip route replace default via <gw> dev <iface>` then `systemctl reset-failed k3s; systemctl start k3s` (k3s unit is `k3s.service` on both servers and agents). The runtime gateway comes from the SOPS `network_env` secret (`config.sops.secrets."<hostname>/network_env".path`), NOT from `config.networking.defaultGateway` (which is null when `vars.nix` uses placeholders).
- **Health-gate checks are per-host** via a new `cominGitOps.healthGate.checks` option (list of enum `route`/`k3s`/`current-system`/`llama-cpp`). k3s hosts (node05 + 10 fleet) use the default `["route", "k3s", "current-system"]`. `llm01` uses `["current-system", "llama-cpp"]`:
  - No `route` check on llm01 — it has NO `staticNetwork` (networkmanager) and NO `network_env` secret; referencing `config.staticNetwork.interface` there would fail eval, so the module must build the route-check string only via `lib.optionalString (elem "route" checks)`.
  - No `k3s` check on llm01 — it is not a k3s host.
  - `llama-cpp` check on llm01: `systemctl is-active llama-cpp-server` **and** port 8001 listening, with a bounded warmup retry (models reload on config change) before rolling back.
- The Pi hosts (pi01/02/03) have no `network_env` secret (real static IPs in `vars.nix`) — the module guards that reference with `config.sops.secrets ? "<host>/network_env"`, so the route-check heal degrades to log-only there.
- Textfile dir is `/var/lib/node-exporter/textfiles` on the host, mounted at `/host/textfiles` in the DS pod, scraped via the existing `node-exporter` PodMonitor (targetPort 9100). No new ScrapeConfig.
- Deferred (document in AGENTS.md, do NOT implement now): Pi closure-copy (`nix-copy-closure` pi01→pi02/03), reboot watchdog (`comin-reboot.nix`), remaining host migrations (pi02/pi03), and the `comin_pending_confirmation > 0` alert rule.
- Every changed Nix file must pass `nixfmt .`. Every changed host config must pass `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel --show-trace` on the Mac.
- NEVER commit plaintext secrets. No secret material is touched by this plan.

---

### Task 1: comin module options — `confirmerMode`, `branch`, `healthGate.checks`, `pendingMetric`

**Files:**
- Modify: `modules/nixos/comin.nix`

**Interfaces:**
- Produces: module options `cominGitOps.confirmerMode` (enum `manual`/`auto`/`without`, default `"manual"`), `cominGitOps.branch` (str, default `"main"`), `cominGitOps.pendingMetric.enable` (bool, default `true`), `cominGitOps.healthGate.enable` (bool, default `false`), `cominGitOps.healthGate.checks` (list of enum, default `["route", "k3s", "current-system"]`). Wires `services.comin.deployConfirmer.mode`, `services.comin.buildConfirmer.mode`, and `branches.main.name`.
- **Status:** `confirmerMode`, `healthGate.enable`, `pendingMetric.enable` are already committed (`b177612`). This task adds `branch` and `healthGate.checks`.

- [ ] **Step 1: Add the `branch` and `healthGate.checks` options**

Edit `modules/nixos/comin.nix`. The `options.cominGitOps` block already has `enable`, `repositoryUrl`, `pollInterval`, `confirmerMode`, `healthGate.enable`, `pendingMetric.enable`. Add:

```nix
      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Git branch to track. Canaries (node05, llm01) use 'main'; the 10 fleet hosts use 'stable' (promoted manually).";
      };
```

and inside `healthGate` (turn it from a bare `enable` attrset into a full submodule):

```nix
      healthGate = {
        enable = lib.mkEnableOption "Post-deployment health gate with rollback";
        checks = lib.mkOption {
          type = lib.types.listOf (lib.types.enum [
            "route"
            "k3s"
            "current-system"
            "llama-cpp"
          ]);
          default = [
            "route"
            "k3s"
            "current-system"
          ];
          description = "Health checks to run in the post-deployment gate. k3s hosts check route+k3s+current-system; llm01 checks current-system+llama-cpp.";
        };
      };
```

- [ ] **Step 2: Wire the branch into the `config` block**

In `config = lib.mkIf config.cominGitOps.enable { ... }`, inside `services.comin.remotes[0].branches.main`, change the hardcoded name:

```nix
          branches.main.name = config.cominGitOps.branch;
```

`buildConfirmer.mode = "without"` and `deployConfirmer.mode = config.cominGitOps.confirmerMode` are already in place from `b177612`.

- [ ] **Step 3: Verify the module evaluates**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.cominGitOps.branch --show-trace
nix eval .#nixosConfigurations.k8s-node05.config.cominGitOps.healthGate.checks --show-trace
```
Expected: `"main"` and `[ "route" "k3s" "current-system" ]`.

- [ ] **Step 4: Commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin.nix
git add modules/nixos/comin.nix
git commit -q -m "feat(comin): add branch and healthGate.checks options"
```

### Task 2: Health-gate module `modules/nixos/comin-health-gate.nix`

**Files:**
- Create: `modules/nixos/comin-health-gate.nix`

**Interfaces:**
- Consumes: `cominGitOps.healthGate.enable` + `cominGitOps.healthGate.checks` (set per host), `config.services.comin.package`, `config.staticNetwork.interface` (route check only, gated on the `checks` list so llm01 never references it), `config.sops.secrets."<hostname>/network_env".path` (guarded — Pi hosts have no secret). Does NOT reference `config.k3s` (the k3s check uses the literal unit name `k3s`).
- Produces: `services.comin.postDeploymentCommand` pointing at a `pkgs.writeShellScript` health gate. On `COMIN_STATUS=done` it runs the configured checks, auto-heals where possible (route restore / k3s restart), and on persistent failure rolls back to the previous successful generation and suspends comin. On `COMIN_STATUS=failed` it suspends comin and notifies.
- **All 12 hosts import this module.** k3s hosts default to `checks = ["route", "k3s", "current-system"]`; llm01 sets `checks = ["current-system", "llama-cpp"]`.

- [ ] **Step 1: Write the module**

Create `modules/nixos/comin-health-gate.nix`:

```nix
{ config, lib, pkgs, ... }:

let
  checks = config.cominGitOps.healthGate.checks;
  hasCheck = name: builtins.elem name checks;

  # Only hosts using the SOPS placeholder pattern (node01-05, server01-03)
  # have a network_env secret. The Pis (pi01-03) and llm01 don't — guard the
  # reference or the module fails to evaluate there. Must be interpolated with
  # ${envFile} (Nix) NOT $envFile (shell): writeShellScript does not propagate
  # shell variables from the module's let bindings.
  envFile = lib.optionalString (config.sops.secrets ? "${config.networking.hostName}/network_env")
    config.sops.secrets."${config.networking.hostName}/network_env".path;

  # Route check: restore the default route from the SOPS network_env secret.
  # Only built when "route" is in checks (k3s hosts), so llm01 never evaluates
  # config.staticNetwork.interface (static-network module not imported there).
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

  # k3s check: reset-failed + start if inactive. Only on k3s hosts.
  k3sCheck = lib.optionalString (hasCheck "k3s") ''
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet k3s; then
      log "k3s not active — resetting and starting"
      ${pkgs.systemd}/bin/systemctl reset-failed k3s
      ${pkgs.systemd}/bin/systemctl start k3s
    fi
  '';

  # llama-cpp check: llm01 only. Service must be active AND listening on 8001.
  # Bounded retry so a model reload after a config change (restartTriggers) is
  # not mistaken for a failed deploy.
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

  # current-system check: the switched deployment's out_path must match
  # /run/current-system (deployment_switched holds a UUID, not a store path —
  # resolve it). Runs on every host.
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

  healthGate = pkgs.writeShellScript "comin-health-gate" ''
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
        # COMIN_STATUS unset/unknown → not a deploy we manage
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
```

Note: the module references `config.services.comin.package`, `config.staticNetwork.interface` (route check only, gated on `checks`), and (conditionally) the `network_env` secret. It does NOT reference `config.k3s` — the k3s check uses the literal unit name `k3s`. `rollback_and_suspend` is defined once and reused by the llama-cpp + current-system checks.

- [ ] **Step 2: Validate the module parses (render check deferred to Task 3)**

The rendered-script syntax check must run after Task 3 imports the module on a host (before that `config.services.comin.postDeploymentCommand` is `null`). Here, just verify the module is valid Nix:

```bash
nix-instantiate --parse modules/nixos/comin-health-gate.nix && echo "module parses OK"
```
Expected: `module parses OK`.

- [ ] **Step 3: Commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin-health-gate.nix
git add modules/nixos/comin-health-gate.nix
git commit -q -m "feat(comin): postDeploymentCommand health gate (per-host checks, rollback, suspend)"
```

### Task 3: Import the health-gate module + configure the two rings on all 12 hosts

**Files:**
- Modify: `hosts/k8s-node01/configuration.nix`, `hosts/k8s-node02/configuration.nix`, `hosts/k8s-node03/configuration.nix`, `hosts/k8s-node04/configuration.nix`, `hosts/k8s-node05/configuration.nix`, `hosts/k8s-server01/configuration.nix`, `hosts/k8s-server02/configuration.nix`, `hosts/k8s-server03/configuration.nix`, `hosts/k8s-pi01/configuration.nix`, `hosts/k8s-pi02/configuration.nix`, `hosts/k8s-pi03/configuration.nix`, `hosts/llm01/configuration.nix`

**Interfaces:**
- Consumes: Task 1 (the `healthGate.enable`/`healthGate.checks`/`branch` options), Task 2 (the module).
- Produces: `cominGitOps.healthGate.enable = true` + the `comin-health-gate.nix` import on **all 12 hosts**; `cominGitOps.branch = "stable"` on the 10 fleet hosts; `confirmerMode = "auto"` + `healthGate.checks = ["current-system", "llama-cpp"]` on llm01.

- [ ] **Step 1: Canary ring — `hosts/k8s-node05/configuration.nix`**

The import list already has `../../modules/nixos/comin.nix`. Add the health-gate import directly after it:

```nix
    ../../modules/nixos/comin-health-gate.nix
```

Next to the existing `cominGitOps.enable = true;`, add:

```nix
  cominGitOps.confirmerMode = "auto";   # canary — auto-deploys every main commit
  cominGitOps.healthGate.enable = true;
```

Branch stays default `"main"`; checks stay default `["route", "k3s", "current-system"]`.

- [ ] **Step 2: Canary ring — `hosts/llm01/configuration.nix`**

Import list already has `../../modules/nixos/comin.nix`. Add:

```nix
    ../../modules/nixos/comin-health-gate.nix
```

Next to the existing `cominGitOps.enable = true;` and `cominGitOps.pollInterval = 900;`, add:

```nix
  cominGitOps.confirmerMode = "auto";   # canary — auto-deploys every main commit
  cominGitOps.healthGate.enable = true;
  cominGitOps.healthGate.checks = [
    "current-system"
    "llama-cpp"
  ];
```

Note: no `branch` override → llm01 tracks `main`. No `route`/`k3s` checks → no reference to `config.staticNetwork` (module not imported on llm01), and the llama-cpp check covers the LLM service (active + `:8001`).

- [ ] **Step 3: Fleet ring — the 10 k3s hosts (node01-04, server01-03, pi01-03)**

For each of `hosts/k8s-node01/02/03/04/`, `hosts/k8s-server01/02/03/`, `hosts/k8s-pi01/02/03/configuration.nix`:

1. Add `../../modules/nixos/comin-health-gate.nix` to the `imports` list (directly after the `comin.nix` import).
2. Add `cominGitOps.healthGate.enable = true;` next to the existing `cominGitOps.enable = true;`.
3. Add `cominGitOps.branch = "stable";` — this host tracks the fleet ring. `confirmerMode` stays default `"manual"`.

Resulting per-host block:
```nix
  cominGitOps.enable = true;
  cominGitOps.branch = "stable";
  cominGitOps.healthGate.enable = true;
```

- [ ] **Step 4: Verify eval on representatives of every code path**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.k8s-server01.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.k8s-pi01.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
```
Expected: all four evaluate without error (this proves the route-check `config.staticNetwork.interface` reference is correctly gated off on llm01, and the Pi `network_env` guard works).

Also verify the health-gate script renders + is syntactically valid on all three variants, and the branch wiring:

```bash
nix eval --raw .#nixosConfigurations.k8s-node05.config.services.comin.postDeploymentCommand --show-trace | xargs -I{} bash -n {} && echo "node05 syntax OK"
nix eval --raw .#nixosConfigurations.k8s-pi01.config.services.comin.postDeploymentCommand --show-trace | xargs -I{} bash -n {} && echo "pi01 syntax OK"
nix eval --raw .#nixosConfigurations.llm01.config.services.comin.postDeploymentCommand --show-trace | xargs -I{} bash -n {} && echo "llm01 syntax OK"
nix eval .#nixosConfigurations.k8s-node01.config.services.comin.remotes[0].branches.main.name --show-trace
nix eval .#nixosConfigurations.k8s-node05.config.services.comin.remotes[0].branches.main.name --show-trace
nix eval .#nixosConfigurations.llm01.config.services.comin.remotes[0].branches.main.name --show-trace
```
Expected: three `<store path> syntax OK` lines; branches print `"stable"` for node01 and `"main"` for node05/llm01.

- [ ] **Step 5: Commit**

```bash
cd ~/code/nixos-configurations
git add hosts/k8s-node0{1,2,3,4,5}/configuration.nix hosts/k8s-server0{1,2,3}/configuration.nix hosts/k8s-pi0{1,2,3}/configuration.nix hosts/llm01/configuration.nix
git commit -q -m "feat(hosts): two-ring rollout — canaries node05+llm01 on main, fleet on stable, health gate on all 12"
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
        json=$(${config.services.comin.package}/bin/comin status --json 2>/dev/null || ${pkgs.coreutils}/bin/echo -n ''')
        pending=$(${pkgs.coreutils}/bin/printf '%s' "$json" \
          | ${pkgs.jq}/bin/jq -r 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end' 2>/dev/null \
          || ${pkgs.coreutils}/bin/printf '0')
        ${pkgs.coreutils}/bin/printf 'comin_pending_confirmation %s\n' "$pending" > /tmp/comin.prom.$$
        ${pkgs.coreutils}/bin/mv /tmp/comin.prom.$$ /var/lib/node-exporter/textfiles/comin.prom
      '';
    };
  };

  > **Nix escape gotcha:** inside a `''...''` indented string, `''` would
  > terminate the string, so the shell empty-string arg to `echo -n` must be
  > written `'''` (three quotes → renders as `''`). Verified at eval time.

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
- Produces: an executable script that (1) verifies both canaries converged healthy, then (2) auto-accepts the 10 fleet hosts in order with health waits. Safe to re-run: canary pre-flight always runs; fleet hosts with nothing pending are skipped.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Comin branch-based hard-gate rollout.
# Canary ring (auto, branch main): node05 + llm01 — must converge healthy or we abort.
# Fleet ring (manual, branch stable): accepted here in least -> most critical order.
CANARY_RING=(k8s-node05 llm01)
ORDER=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03)
# k8s nodes only (llm01 is not a cluster node — skip its node_ready wait)
K8S_NODES=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03 k8s-node05)

is_k8s_node() { # host -> 0 if the host is a k8s node
  printf '%s\n' "${K8S_NODES[@]}" | grep -qx "$1"
}

deploy_status() { # host -> deployer.deployment.status
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r '.deployer.deployment.status? // "none"'
}

is_suspended() { # host -> "true" if comin is suspended
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r '.is_suspended // "false"'
}

pending() { # host -> prints 1 if a deploy confirmation is pending
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end'
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

# 1) Canary pre-flight. Suspension = the health gate rolled a canary back,
#    so abort the rollout before touching the fleet.
for c in "${CANARY_RING[@]}"; do
  echo "== waiting for canary $c to auto-deploy"
  wait_for "$c deploy done" 1200 deploy_status "$c"
  if [ "$(is_suspended "$c")" = "true" ]; then
    osascript -e "display notification \"$c rolled back (comin suspended) — rollout aborted\" with title \"comin approve\""
    echo "ABORT: $c rolled back (comin suspended). Fix main before retrying."
    exit 1
  fi
  if is_k8s_node "$c"; then
    wait_for "$c node Ready" 600 node_ready "$c"
  else
    echo "== $c: not a k8s node, skipping node Ready wait"
  fi
done
echo "== canary ring healthy (node05 + llm01)"

# 2) Fleet pre-check: tell the operator when promotion hasn't happened yet.
#    Fleet hosts track 'stable'; a pending confirmation only appears after the
#    main -> stable merge is pushed.
fleet_pending=0
for h in "${ORDER[@]}"; do
  [ "$(pending "$h")" = "1" ] && fleet_pending=1
done
if [ "$fleet_pending" = "0" ]; then
  echo "Fleet has no pending confirmations — merge main -> stable and push, then re-run."
  exit 0
fi

# 3) Accept the fleet in order, waiting for each to converge.
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
  if is_k8s_node "$h"; then
    wait_for "$h node Ready" 600 node_ready "$h"
  else
    echo "== $h: not a k8s node, skipping node Ready wait"
  fi
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
git commit -q -m "feat(scripts): comin-approve.sh branch-based hard-gate rollout gatekeeper"
```

### Task 6: node_exporter textfile mount in kube-prometheus-stack (k8s-casa repo)

**Files:**
- Modify: `~/k8s-casa/apply/10-infra/monitoring/prometheus.yaml` (HelmRelease `kube-prometheus-stack`)

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
cd ~/k8s-casa
python3 -c "import yaml,sys; yaml.safe_load(open('apply/10-infra/monitoring/prometheus.yaml')); print('YAML OK')"
```
Expected: `YAML OK` (client dry-run may fail without a cluster; parse validation is the goal).

- [ ] **Step 3: Commit**

```bash
cd ~/k8s-casa
git add apply/10-infra/monitoring/prometheus.yaml
git commit -q -m "feat(monitoring): mount node_exporter textfile collector for comin_pending_confirmation"
```

### Task 7: Fleet-wide enablement + final verification

**Files:**
- Modify: none (module defaults already apply to all 12 hosts)

**Interfaces:**
- Consumes: all prior tasks.

- [ ] **Step 1: Confirm the confirmer modes and branches across the rings**

```bash
nix eval .#nixosConfigurations.k8s-node05.config.services.comin.deployConfirmer.mode --show-trace
nix eval .#nixosConfigurations.llm01.config.services.comin.deployConfirmer.mode --show-trace
nix eval .#nixosConfigurations.k8s-server03.config.services.comin.deployConfirmer.mode --show-trace
nix eval .#nixosConfigurations.k8s-node05.config.services.comin.remotes[0].branches.main.name --show-trace
nix eval .#nixosConfigurations.llm01.config.services.comin.remotes[0].branches.main.name --show-trace
nix eval .#nixosConfigurations.k8s-server03.config.services.comin.remotes[0].branches.main.name --show-trace
```
Expected: node05 and llm01 print `"auto"` + `"main"` (canaries); server03 prints `"manual"` + `"stable"` (fleet). Also confirm build mode:
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
Expected: all evaluate without error.

- [ ] **Step 3: Format + commit**

```bash
cd ~/code/nixos-configurations
nixfmt modules/nixos/comin.nix modules/nixos/comin-health-gate.nix
git add -A
git commit -q -m "feat(comin): branch-based hard-gate rollout (canary ring on main, fleet on stable, health gate, pending metric, approve script)"
```

### Task 8: Document the rollout in AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add a "Branch-Based Rollout" subsection**

In `AGENTS.md`, after the existing **GitOps with Comin** section, add:

```markdown
### Branch-Based Rollout (2026-08)

Two rings, two branches:

- **Canary ring (branch `main`, auto-deploy):** `k8s-node05` + `llm01`.
  Every commit to `main` auto-deploys to both (`deployConfirmer.mode =
  "auto"`), exercising the health-gate rollback path with a two-host blast
  radius.
- **Fleet ring (branch `stable`, manual-confirm):** `k8s-node01..04`,
  `k8s-server01..03`, `k8s-pi01..03` (`deployConfirmer.mode = "manual"`).
  They fetch/build automatically but pause before
  `switch-to-configuration switch` until `comin confirmation accept` runs
  on that host (local unix socket only — never from the Mac).

Promotion is a manual git merge — the human gate:
```bash
git checkout stable && git merge main && git push origin stable
```

Manual fleet order (least -> most critical): `k8s-node04 -> k8s-node03 ->
k8s-node02 -> k8s-node01 -> k8s-pi01 -> k8s-pi02 -> k8s-pi03 ->
k8s-server01 -> k8s-server02 -> k8s-server03`.

Gatekeeper:
```bash
./scripts/comin-approve.sh
```
Run 1 waits for both canaries to converge (deploy done **and** not
suspended, node Ready where applicable) and prints "merge main -> stable".
Run it again after the merge: it verifies canaries again, then auto-accepts
the fleet in order with a `kubectl get node` wait between hosts. Aborts if
a canary (or any host) is suspended — the health gate rolled it back.

Health gate (`postDeploymentCommand`, all 12 hosts): per-host `checks`.
k3s hosts (node05 + fleet) check the default route, the k3s service, and
that `/run/current-system` matches the switched generation's `out_path`.
`llm01` checks current-system plus llama-cpp-server (active **and** listening
on `:8001`, with a warmup retry for model reloads). Auto-heal (restore route
from the SOPS `network_env` / restart k3s) and on persistent failure roll back
the comin profile (`/nix/var/nix/profiles/system-profiles/comin`, NOT
`nixos-rebuild --rollback`) and suspend comin. On `COMIN_STATUS=failed` it
suspends comin. Note: after a rollback `deployer.deployment.status` stays
`"done"` — the approve script detects rollback via `is_suspended`, not status.

Metric: `comin_pending_confirmation` is written to
`/var/lib/node-exporter/textfiles/comin.prom` every 60s and scraped by the
cluster Prometheus via the DS node_exporter textfile mount.

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
- [ ] Migrate remaining hosts to 26.05: pi02 -> pi03; final sweep.
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
git commit -q -m "docs(AGENTS): document branch-based comin rollout and deferred TODOs"
```
