# Zero-Downtime Halogen-Flash Weights Bump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a halogen-flash weights bump leave the running inference server untouched — the deploy returns in seconds, the ~112 GiB fetch runs in the background, and exactly one restart applies the new revision.

**Architecture:** The fetch stops being part of the deploy and becomes a background reconciler. The deploy writes a declared target revision to `/etc/halogen-flash/target-revision`; a `PathChanged` unit starts the weights service, which compares that file against the live `current` symlink, fetches if they differ, flips the symlink atomically, and issues the single restart. The weights unit's generated text is byte-identical across revisions, which is what stops `switch-to-configuration` from touching it.

**Tech Stack:** NixOS module (`halogen-flash-flake/nixos/module.nix`), systemd service + path units, `hf download` (huggingface-hub), rootless podman, Prometheus node_exporter textfile.

**Spec:** `docs/superpowers/specs/2026-10-15-zero-downtime-weights-bump-design.md` (in the `nixos-configurations` repo).

## Global Constraints

- Module file: `halogen-flash-flake/nixos/module.nix`. Host config: `nixos-configurations/hosts/llm01/configuration.nix`. Two separate repositories, two separate PRs.
- No SSH to llm01 from the workspace. Every change is PR'd and merged via GitHub; nothing here can be verified on the host by the implementer.
- `main` is PR-only in both repos (ruleset `default`, `required_linear_history`). Branch, then `gh pr create`; merge with `gh pr merge --squash` or `--rebase`. Never `git push origin main`.
- The weights unit's generated text and its `ExecStart` script store path must be **byte-identical** across values of the pinned revision. This is the property the whole change rests on.
- Disk stays bounded at two version trees: the pre-fetch prune that keeps only the live tree and the incoming one is load-bearing and must not be weakened.
- The completion marker format `rev=<sha>|excl=<pipe-joined-excludes>` is existing on-disk state. Do not change its format; a format change invalidates every already-complete tree and forces a re-download.
- `halogenWarmupSec` on llm01 stays at `14400` in this work (spec §11). Lowering it is a later change so it cannot mask a regression during the migration deploy.
- Formatting: 2-space indent, `nixfmt` clean.

## Two Corrections to the Spec

Discovered while writing this plan. Both are implemented below; the spec should be amended to match.

**C1 — `RemainAfterExit = true` on the weights unit breaks the path trigger.** A `PathUnit` activates its `Unit=` with `StartUnit`. For a `Type=oneshot` with `RemainAfterExit=yes`, the unit stays `active (exited)` after a successful run, so every subsequent `StartUnit` is a no-op and `ExecStart` never re-runs. The **second** bump would silently do nothing. Fix: drop `RemainAfterExit` (default `false` for oneshot) so the unit returns to `inactive` and the path trigger works repeatedly. This is safe only because decision R1 already removed the role unit's `After=` edge — nothing needs the unit to stay active any more. Task 3 does this, and Task 1's test pins it.

**C2 — llm01's host node_exporter does not read the textfile directory.** `hosts/llm01/configuration.nix:44` sets `prometheus.nodeExporter.collectors = [ "drm" ]`, which replaces the module default `[ "systemd" ]`, and nothing sets `--collector.textfile.directory`. `modules/nixos/k3s-snapshot-monitor.nix:132-134` is the only place that enables the textfile collector, and it is not enabled on llm01. So S2 as specced would write a file nobody scrapes. Task 7 enables the collector and the directory on llm01, following that existing precedent.

## Review Focus

Failure modes the spec implies that the per-task tests do not directly exercise. Each line gets a check in the task that owns the code.

0. **A non-root service user.** The test harness evaluates with the module default `user = "root"`, while llm01 runs as `ollama`. The rootless path adds `HOME`/`XDG_RUNTIME_DIR` to `unitEnvironment` and a block of tmpfiles and setuid-wrapper rules, none of which reference the revision. Expected: the invariance property holds identically for a rootless host. If a future change interpolates the revision into any rootless-only attr, the root-only test stays green while llm01 regresses.
1. **A bump that changes nothing.** Every non-bump deploy rewrites `target-revision` with identical bytes. Expected: `PathChanged` does not fire, no fetch, no restart, the server is untouched. A spurious restart here means the design has leaked back into the deploy path.
2. **A fresh boot with no weights tree at all.** With R1 there is no ordering edge, so the role unit must fail loudly on its `ExecStartPre` guard and retry, rather than starting a container against an empty bind mount. Expected: `podman run` is never reached with a missing `current`.
3. **The transition deploy.** The first deploy of this change rewrites the weights unit and drops `After=halogen-flash-weights.service` from the role unit, while the revision is unchanged. Expected: the weights unit restarts and exits immediately because desired equals live, **and the server also restarts exactly once** — removing `After=` changes the role unit's own text, which is what `switch-to-configuration` restarts on. One weight-load on the transition deploy is correct and unavoidable; zero on every bump after it is the property under test.
4. **A failed fetch must not look like a healthy deploy.** Expected: the weights unit settles in `failed` after the bounded retries, the textfile says `state="failed"`, the server keeps serving the old revision, and the comin deploy is unaffected.
5. **Repeat bumps.** The first bump must not be the only one that works (see C1). Expected: a second bump to a third revision behaves exactly like the first.

---

## File Structure

**`halogen-flash-flake` repo:**

| File | Responsibility |
|---|---|
| `nixos/module.nix` | The only product file. Weights unit made revision-independent, path unit added, role-unit edge removed, `environment.etc` target revision, script reads the file and emits the metric, bounded retry. |
| `tests/unit-invariance.nix` | Test harness: evaluates the module at a given revision and renders the weights unit + path unit + role-unit edges + etc content as one comparable string. |
| `tests/test-unit-invariance.sh` | Runs the harness at two revisions and asserts invariance where required and difference where intended. |

**`nixos-configurations` repo:**

| File | Responsibility |
|---|---|
| `hosts/llm01/configuration.nix` | Enable the node_exporter textfile collector and directory (C2); bump the `halogen-flash` flake input once the module PR merges. |

---

### Task 1: Failing invariance test

Establishes the gate before any module change. This test **must fail** when committed, and Task 3 turns it green.

**Files:**
- Create: `tests/unit-invariance.nix`
- Create: `tests/test-unit-invariance.sh`

**Interfaces:**
- Consumes: `nixos/module.nix` as a NixOS module; `services.halogenFlash.download.revision` as the knob that varies the pinned revision without editing the file.
- Produces: `tests/test-unit-invariance.sh` exiting 0 when the weights unit text, the weights script store path, and the path unit text are identical across revisions while `environment.etc` content differs. Later tasks use this as their pass gate.

- [ ] **Step 1: Write the harness**

Create `tests/unit-invariance.nix`:

```nix
# Test harness: render the parts of the generated systemd units that must NOT
# depend on the pinned weights revision, as one comparable string.
#
# `rev` is fed through the public `download.revision` option rather than by
# editing the module, so the harness tests the same interface a host uses.
#
# Why this exists: switch-to-configuration stops and restarts any unit whose
# generated text changed. If the weights unit's text embeds the revision, a
# weights bump restarts it, and the server (ordered behind it) waits for the
# whole ~112 GiB fetch. Byte-identical unit text across revisions is what makes
# a bump a non-event for the running server.
{ rev }:
let
  mod = import ../nixos/module.nix;
  ev = import (toString <nixpkgs> + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      mod
      {
        services.halogenFlash = {
          enable = true;
          download.enable = true;
          download.revision = rev;
        };
      }
    ];
  };
  svc = ev.config.systemd.services."halogen-flash-weights";
  path = ev.config.systemd.paths."halogen-flash-weights" or { };
  role = ev.config.systemd.services."halogen-flash" or { };
  svcCfg = svc.serviceConfig or { };
  pathCfg = path.pathConfig or { };
  keys = builtins.attrNames svcCfg;
  pkeys = builtins.attrNames pathCfg;
in
''
WEIGHTS_DESCRIPTION=${svc.description}
WEIGHTS_AFTER=${toString (svc.after or [ ])}
WEIGHTS_WANTS=${toString (svc.wants or [ ])}
WEIGHTS_WANTEDBY=${toString (svc.wantedBy or [ ])}
WEIGHTS_EXECSTART=${toString (svcCfg.ExecStart or "<none>")}
${builtins.concatStringsSep "\n"
  (map (k: "WEIGHTS_CFG_${k}=${toString svcCfg.${k}}") (builtins.sort builtins.lessThan keys))}
PATH_DESCRIPTION=${path.description or "<none>"}
PATH_UNIT=${toString (pathCfg.Unit or "<none>")}
PATH_CHANGED=${toString (pathCfg.PathChanged or "<none>")}
PATH_WANTEDBY=${toString (path.wantedBy or [ ])}
ROLE_AFTER=${toString (role.after or [ ])}
ROLE_EXECSTARTPRE=${toString (role.serviceConfig.ExecStartPre or [ ])}
ETC_TARGET=${ev.config.environment.etc."halogen-flash/target-revision".text or "<none>"}
''
```

- [ ] **Step 2: Write the test script**

Create `tests/test-unit-invariance.sh`:

```bash
#!/usr/bin/env bash
# Assert the weights unit is revision-independent (must be identical) and that
# the declared-intent file does change with the revision (must differ).
#
# Run from the repo root: ./tests/test-unit-invariance.sh
set -uo pipefail
cd "$(dirname "$0")/.."

REV_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REV_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

render() {
  nix-instantiate --eval --raw \
    --expr "import ./tests/unit-invariance.nix { rev = \"$1\"; }" 2>/dev/null
}

A="$(render "$REV_A")"
B="$(render "$REV_B")"

if [ -z "$A" ] || [ -z "$B" ]; then
  echo "FAIL: harness failed to evaluate" >&2
  nix-instantiate --eval --raw \
    --expr "import ./tests/unit-invariance.nix { rev = \"$REV_A\"; }"
  exit 1
fi

status=0

# Must be identical: anything switch-to-configuration would notice.
for prefix in WEIGHTS_ PATH_; do
  a="$(printf '%s\n' "$A" | grep "^$prefix")"
  b="$(printf '%s\n' "$B" | grep "^$prefix")"
  if [ "$a" = "$b" ]; then
    echo "ok: ${prefix%_} unit text identical across revisions"
  else
    echo "FAIL: ${prefix%_} unit text changes with the revision"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
    status=1
  fi
done

# Must exist and be wired: otherwise the invariance checks above pass vacuously
# on a module that simply has no path unit.
if printf '%s\n' "$A" | grep -qx 'PATH_CHANGED=/etc/halogen-flash/target-revision' \
   && printf '%s\n' "$A" | grep -qx 'PATH_UNIT=halogen-flash-weights.service'; then
  echo "ok: path unit watches the intent file and activates the weights service"
else
  echo "FAIL: path unit missing or not wired to the intent file"
  printf '%s\n' "$A" | grep '^PATH_'
  status=1
fi

# Must be identical: the role unit must not be ordered behind the fetch.
a="$(printf '%s\n' "$A" | grep '^ROLE_')"
b="$(printf '%s\n' "$B" | grep '^ROLE_')"
if [ "$a" = "$b" ]; then
  echo "ok: role unit text identical across revisions"
else
  echo "FAIL: role unit text changes with the revision"
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
  status=1
fi

if printf '%s\n' "$A" | grep -q 'halogen-flash-weights.service' <<<"$(printf '%s\n' "$A" | grep '^ROLE_AFTER')"; then
  echo "FAIL: role unit is still ordered after halogen-flash-weights.service"
  status=1
else
  echo "ok: role unit has no ordering edge on the weights unit"
fi

# Must differ: this is the trigger, so it has to change on a bump.
a="$(printf '%s\n' "$A" | grep '^ETC_TARGET')"
b="$(printf '%s\n' "$B" | grep '^ETC_TARGET')"
if [ "$a" != "$b" ]; then
  echo "ok: target-revision content changes with the revision"
else
  echo "FAIL: target-revision content does not change with the revision"
  status=1
fi

exit "$status"
```

- [ ] **Step 3: Make it executable and run it to verify it fails**

```bash
chmod +x tests/test-unit-invariance.sh
./tests/test-unit-invariance.sh
```

Expected: exit 1, with a diff showing exactly the two revision leaks that exist today —

```
FAIL: WEIGHTS unit text changes with the revision
< WEIGHTS_DESCRIPTION=Sync halogen-flash weights to aaaa...
> WEIGHTS_DESCRIPTION=Sync halogen-flash weights to bbbb...
< WEIGHTS_EXECSTART=/nix/store/<hash>-halogen-weights-sync
> WEIGHTS_EXECSTART=/nix/store/<otherhash>-halogen-weights-sync
```

plus `FAIL: path unit missing or not wired to the intent file`,
`FAIL: role unit is still ordered after halogen-flash-weights.service` and
`FAIL: target-revision content does not change with the revision`. Note that
`ok: PATH unit text identical across revisions` also prints at this stage and is
**vacuously true** — there is no path unit yet, so both renders are `<none>`. The
wiring assertion added above is what makes that check meaningful. If the harness
fails to evaluate at all rather than producing these diffs, fix the harness
before continuing — a red test that is red for the wrong reason proves nothing.

- [ ] **Step 4: Commit**

```bash
git checkout -b fix/zero-downtime-weights-bump
git add tests/unit-invariance.nix tests/test-unit-invariance.sh
git commit -m "test: pin weights-unit invariance across revisions

The weights unit bakes the pinned revision into its description and its
ExecStart script, so a bump rewrites the unit text and switch-to-configuration
restarts it; the server, ordered behind it, waits for the whole fetch. This
asserts the unit text is revision-independent and the declared target file is
not. Red until the module stops interpolating the revision into the unit."
```

---

### Task 2: Declare the target revision as intent, read it at run time

Moves the revision out of the unit and script text and into a file the deploy writes.

**Files:**
- Modify: `nixos/module.nix` — `weightsSyncScript` (the `revision=`/`targetDir=` lines near the top of the script), and a new `environment.etc` entry in the `config` merge.

**Interfaces:**
- Consumes: `targetRevision` (existing `let` binding, `module.nix:66-68`) for the file's *content* only.
- Produces: `/etc/halogen-flash/target-revision` containing `<sha>\n`. Task 3's path unit watches it; the sync script reads it into a shell variable named `revision`.

- [ ] **Step 1: Add the declared-intent file**

In `nixos/module.nix`, inside the `lib.mkIf (cfg.enable && versionedActive)` block that defines `systemd.services."halogen-flash-weights"` (around line 706), add alongside it:

```nix
    (lib.mkIf (cfg.enable && versionedActive) {
      # The declared intent. Written on every activation; its bytes change only
      # when the pinned revision is bumped, so a no-change deploy fires nothing.
      # environment.etc (not tmpfiles) because it renames into place atomically
      # and always exists after activation, which is what PathChanged needs.
      environment.etc."halogen-flash/target-revision".text = "${targetRevision}\n";
    })
```

- [ ] **Step 2: Make the script read it**

In `weightsSyncScript`, replace these two lines near the top of the script body:

```nix
    targetDir=${targetDir}
    repo=${cfg.download.repo}
    revision=${targetRevision}
```

with:

```nix
    repo=${cfg.download.repo}
    targetRevisionFile=/etc/halogen-flash/target-revision
```

and add, immediately after the existing `mkdir -p "$versionsDir"` line:

```sh
    # The revision is run-time state, not build-time text: baking it into the
    # script made every bump rewrite the unit's ExecStart path, which is exactly
    # the restart we are trying to avoid.
    if [ ! -r "$targetRevisionFile" ]; then
      echo "halogen-weights: $targetRevisionFile not readable; nothing to do" >&2
      exit 1
    fi
    revision="$(tr -d '[:space:]' < "$targetRevisionFile")"
    if [ -z "$revision" ]; then
      echo "halogen-weights: $targetRevisionFile is empty; refusing to guess" >&2
      exit 1
    fi
    targetDir="$versionsDir/$revision"
```

- [ ] **Step 3: Drop the now-unused binding**

`targetDir` in the `let` block (around line 69) is no longer referenced by the script. Confirm before removing:

```bash
grep -n 'targetDir' nixos/module.nix
```

Expected: only the shell-script occurrences (`targetDir="$versionsDir/$revision"`, and the later `$targetDir` uses inside the script body). Delete the `let`-bound `targetDir` line only if no Nix-level reference remains. Leave `targetRevision` — it is now used for the `etc` content.

- [ ] **Step 4: Verify the script store path stopped depending on the revision**

```bash
./tests/test-unit-invariance.sh
```

Expected: still exit 1, but `WEIGHTS_EXECSTART` no longer appears in the diff — only `WEIGHTS_DESCRIPTION` and the `WEIGHTS_CFG_*` lines that still embed the revision. If `WEIGHTS_EXECSTART` still differs, a revision reference survives somewhere in the script; grep for `targetRevision` inside the `weightsSyncScript` string.

- [ ] **Step 5: Commit**

```bash
git add nixos/module.nix
git commit -m "refactor(module): read the target weights revision at run time

The revision moves from Nix-interpolated script text to
/etc/halogen-flash/target-revision, written by environment.etc on activation.
The sync script compares it against the live 'current' symlink as before.
This is the declared-intent half of decoupling the fetch from the deploy."
```

---

### Task 3: Make the weights unit text constant, add the path trigger, drop the role edge

The task that turns the gate green. All three changes are one deliverable: the unit is inert across bumps *and* still gets triggered.

**Files:**
- Modify: `nixos/module.nix` — weights unit definition (around lines 706-727), new `systemd.paths` entry, `mkRoleUnit`'s `after` list (around lines 370-385).

**Interfaces:**
- Consumes: `/etc/halogen-flash/target-revision` from Task 2.
- Produces: `halogen-flash-weights.service` with a constant `description`, no `RemainAfterExit`, bounded retries; `halogen-flash-weights.path` with `PathChanged=/etc/halogen-flash/target-revision` and `Unit=halogen-flash-weights.service`; a role unit with no `halogen-flash-weights.service` in its `after`.

- [ ] **Step 1: Constant description, drop RemainAfterExit, bound the retries**

Replace the weights unit body. The `description` must be a fixed string, `RemainAfterExit` must go (correction C1), and the retry must be bounded:

```nix
    (lib.mkIf (cfg.enable && versionedActive) {
      systemd.services."halogen-flash-weights" = {
        # Constant on purpose. switch-to-configuration restarts units whose
        # generated text changed, so naming the revision here would stop the
        # fetch unit on every bump and hold the server behind it. The revision
        # is read from /etc/halogen-flash/target-revision at run time instead.
        description = "Sync halogen-flash weights to the declared revision";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          # RemainAfterExit deliberately NOT set: a PathUnit activates this unit
          # with StartUnit, and starting an already-active RemainAfterExit oneshot
          # is a no-op -- the second bump would silently do nothing. Leaving the
          # unit inactive after a run is what makes repeat bumps work. Nothing
          # orders off this unit any more, so nothing needs it to stay active.
          # root, not cfg.user: the unit restarts the server units after
          # flipping the symlink, which a non-root user cannot do.
          User = "root";
          # Same hub cache location the role units use, under the BASE dir
          # so pruning a version never throws away resumable metadata.
          Environment = [ "HF_HOME=${cfg.modelsDir}/.cache" ];
          ExecStart = weightsSyncScript;
          # A revision bump is a fresh ~112 GiB transfer.
          TimeoutStartSec = "2d";
          Restart = "on-failure";
          RestartSec = "60";
          # Bounded: the fetch is no longer a deploy, so a permanently failing
          # download must settle in a visible `failed` state rather than churn
          # forever. Five attempts in an hour rides out an HF blip.
          StartLimitBurst = 5;
          StartLimitIntervalSec = 3600;
        };
      };

      # The trigger. The deploy only rewrites the intent file; this notices.
      systemd.paths."halogen-flash-weights" = {
        description = "Watch the declared halogen-flash weights revision";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = "/etc/halogen-flash/target-revision";
          Unit = "halogen-flash-weights.service";
        };
      };
    })
```

- [ ] **Step 2: Remove the role unit's ordering edge**

In `mkRoleUnit`, delete the weights clause from `after` so it reads:

```nix
    after =
      # The pull unit is a hard dependency: no image, no server. It exits 0
      # when the pinned artifact is already local, so this does not make
      # boot contingent on the registry being reachable.
      (lib.optionals cfg.pull.enable [ "halogen-flash-pull.service" ])
      # No edge on halogen-flash-weights.service: the fetch is a background
      # reconciler now, and ordering here would let a multi-hour download delay
      # a server restart. ExecStartPre's `test -d` is the only guard -- on a
      # fresh host with no weights the unit fails loudly and retries, which is
      # the same contract the pull unit has for a missing image.
      ++ (lib.optionals (cfg.download.enable && !versionedActive) [ "network-online.target" ])
      # split mode: don't race the engine to boot; its weight load takes
      # minutes and an API that starts first crash-loops until it is ready.
      ++ lib.optional (cfg.mode == "split" && roleName == "api") "halogen-flash-engine.service";
```

- [ ] **Step 3: Run the gate**

```bash
./tests/test-unit-invariance.sh
```

Expected: exit 0, all lines `ok:` —

```
ok: WEIGHTS unit text identical across revisions
ok: PATH unit text identical across revisions
ok: path unit watches the intent file and activates the weights service
ok: role unit text identical across revisions
ok: role unit has no ordering edge on the weights unit
ok: target-revision content changes with the revision
```

- [ ] **Step 4: Verify the bounded retry and the absence of RemainAfterExit actually landed**

```bash
nix-instantiate --eval --raw \
  --expr 'import ./tests/unit-invariance.nix { rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }' \
  | grep -E 'WEIGHTS_CFG_(RemainAfterExit|StartLimit|Restart)|PATH_CHANGED|PATH_UNIT'
```

Expected: `StartLimitBurst=5`, `StartLimitIntervalSec=3600`, **no** `RemainAfterExit` line, `PATH_CHANGED=/etc/halogen-flash/target-revision`, `PATH_UNIT=halogen-flash-weights.service`. This pins correction C1; without it the first bump works and every later one silently does not.

- [ ] **Step 5: Commit**

```bash
git add nixos/module.nix
git commit -m "fix(module): stop the weights unit text depending on the revision

Three coupled changes that make a weights bump inert for the running server:

- constant unit description, so switch-to-configuration does not restart the
  fetch unit on a bump
- halogen-flash-weights.path watches /etc/halogen-flash/target-revision and
  starts the service when the declared intent changes
- the role unit loses its After= on the fetch unit; ExecStartPre's test -d is
  the only guard, so a background download can never delay a server restart

RemainAfterExit is dropped: a PathUnit's StartUnit is a no-op on an already
active RemainAfterExit oneshot, which would make every bump after the first do
nothing. Retries are bounded (5 in 1h) so a permanently failing fetch settles
in a visible failed state instead of churning."
```

---

### Task 4: Emit the Prometheus textfile

Makes a failed or stalled fetch visible without making it a deploy failure (spec §7).

**Files:**
- Modify: `nixos/module.nix` — new `metricsTextfileDir` option, and the `weightsSyncScript` body.

**Interfaces:**
- Consumes: `$revision` and `$active` already computed in the script.
- Produces: `<metricsTextfileDir>/halogen-weights.prom` with `halogen_weights_desired_revision_info`, `halogen_weights_current_revision_info`, `halogen_weights_state{state=…}`. Task 7 (other repo) makes node_exporter read that directory.

- [ ] **Step 1: Add the option**

In `options.services.halogenFlash`, after the `download` option block:

```nix
    metricsTextfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter/textfiles";
      example = "";
      description = ''
        Directory for the `halogen-weights.prom` node_exporter textfile, or ""
        to disable metric emission. The sync unit records the desired revision,
        the live revision, and its own state there at every transition.

        This exists because a decoupled fetch can fail long after the deploy
        that requested it reported success; without this the failure is
        invisible to monitoring. The directory must be one node_exporter
        actually reads -- enabling the textfile collector is the host's job,
        not this module's.
      '';
    };
```

- [ ] **Step 2: Add the writer to the script**

In `weightsSyncScript`, insert this block **after** the existing `active=""` / `readlink` block and **before** the `if [ "$active" = "$revision" ]` early-exit check. That position is required, not stylistic: `write_metric` reads both `$revision` (set just after `mkdir -p`, by Task 2) and `$active` (set by the readlink block), and the first early-exit branch needs the function to already exist.

```sh
    textfileDir=${lib.escapeShellArg cfg.metricsTextfileDir}
    write_metric() {
      # Empty dir means metrics disabled on this host.
      [ -n "$textfileDir" ] || return 0
      mkdir -p "$textfileDir"
      {
        printf 'halogen_weights_desired_revision_info{revision="%s"} 1\n' "$revision"
        printf 'halogen_weights_current_revision_info{revision="%s"} 1\n' "${active:-none}"
        printf 'halogen_weights_state{state="%s"} 1\n' "$1"
      } > "$textfileDir/halogen-weights.prom.tmp.$$"
      mv "$textfileDir/halogen-weights.prom.tmp.$$" "$textfileDir/halogen-weights.prom"
    }
```

- [ ] **Step 3: Call it at every transition**

Immediately after the `write_metric` definition, install the failure trap:

```sh
    # Any exit that is not an explicit success below is a failure worth
    # publishing: disk full, hf 5xx, network down. The success paths clear the
    # trap so they are not overwritten with `failed` on the way out.
    trap 'write_metric failed' EXIT
```

Then add the calls at these existing points:

- Both early-exit "already active" / "already complete" branches, and the adopt-without-marker branch: replace each bare `exit 0` with

```sh
      trap - EXIT
      write_metric complete
      exit 0
```

- Immediately before the `"$hf" download` line: `write_metric fetching`
- Immediately after the symlink flip `echo`, before the `try-restart`:

```sh
    trap - EXIT
    write_metric complete
```

The `trap - EXIT` before each `write_metric complete` is load-bearing: without it the EXIT trap fires on the successful exit and overwrites `complete` with `failed`.

- [ ] **Step 4: Verify the metric text is revision-independent in the unit but revision-aware at run time**

```bash
./tests/test-unit-invariance.sh
```

Expected: exit 0 — the script's store path must still be identical across revisions, because the revision is read from the file, not interpolated. If this regresses, a `${targetRevision}` slipped into the script body.

Then confirm the three metric names are present in the generated script, not just in the Nix source:

```bash
script="$(nix-instantiate --eval --raw --expr \
  '(import ./tests/unit-invariance.nix { rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; scriptPath = true; })')"
grep -c 'halogen_weights_' "$script"
```

Expected: `3`. If the harness does not expose the script path, add `SCRIPT=${weightsSyncScript}` to the rendered string in `tests/unit-invariance.nix` and grep the evaluated path out of that output instead — the point is to check the *built* script, so a metric name that only exists in a Nix comment does not pass.

- [ ] **Step 5: Commit**

```bash
git add nixos/module.nix
git commit -m "feat(module): publish weights sync state to a node_exporter textfile

A decoupled fetch can fail hours after the deploy that requested it reported
success, so the failure needs a surface of its own. The sync unit writes
desired revision, live revision, and state (fetching/complete/failed) to
halogen-weights.prom at every transition. Scraping is the host's concern."
```

---

### Task 5: Bring the module's own documentation in line

The module header and several option descriptions describe the old blocking behaviour as the design. Leaving them is a trap for the next reader.

**Files:**
- Modify: `nixos/module.nix` — header comment (lines 18-36), `download.toVersionedDir` description, `download` description, `user` description.

**Interfaces:**
- Consumes: nothing.
- Produces: documentation matching the implemented behaviour. No test.

- [ ] **Step 1: Update the header comment**

In the header block, the paragraph beginning "That is what makes a weights update non-blocking" must say that the trigger is the intent file and a path unit, that the unit text is revision-independent by design, and that `RemainAfterExit` is deliberately absent. Replace the "Disk is capped at TWO versions" paragraph's closing sentence to note the prune is unchanged.

- [ ] **Step 2: Update the option descriptions**

In `download.toVersionedDir`'s description, replace the sentence claiming the bump "downloads the new tree while the old server keeps serving, flips the symlink, and only then restarts" with text that also states the deploy returns immediately and the fetch is triggered by `halogen-flash-weights.path`. In the `download` option description, replace "A revision change is therefore a background download followed by a short reload" with the same framing. In the `user` option description, keep the note that the sync unit runs as root, and add that it is started by a path unit rather than by the switch.

- [ ] **Step 3: Verify no stale claim survives**

```bash
grep -n "blocks startup\|down for the whole transfer\|before each start\|to \${targetRevision}" nixos/module.nix
```

Expected: no matches for the first three. (`${targetRevision}` may legitimately appear once, as the `environment.etc` content.)

- [ ] **Step 4: Commit**

```bash
git add nixos/module.nix
git commit -m "docs(module): describe the path-triggered fetch, not the blocking one

The header and option text still described the revision bump as a switch-time
fetch. Update them, and record why the weights unit text must stay constant and
why RemainAfterExit is absent, so neither is 'helpfully' re-added."
```

---

### Task 6: Full-module verification gate

**Files:**
- Test: `tests/test-unit-invariance.sh` (existing), plus a fresh evaluation of the real host config.

**Interfaces:**
- Consumes: everything above.
- Produces: the evidence a reviewer needs, since nothing here can be tested on llm01.

- [ ] **Step 1: Re-run the gate from a clean tree**

```bash
./tests/test-unit-invariance.sh; echo "exit=$?"
```

Expected: all `ok:` lines, `exit=0`.

- [ ] **Step 2: Confirm the discriminating property directly**

Render at two revisions and diff the whole output, not just the grepped prefixes:

```bash
for r in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; do
  nix-instantiate --eval --raw \
    --expr "import ./tests/unit-invariance.nix { rev = \"$r\"; }" > "/tmp/inv.$r"
done
diff /tmp/inv.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa /tmp/inv.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

Expected: exactly one differing line, `ETC_TARGET=…`. Any other difference means a revision reference survived in unit text.

- [ ] **Step 3: Repeat the diff for a rootless host (Review Focus item 0)**

llm01 runs as `ollama`, not the harness default of `root`, and the rootless path adds `unitEnvironment` entries plus tmpfiles and setuid-wrapper rules. Temporarily change the harness config block to

```nix
        services.halogenFlash = {
          enable = true;
          download.enable = true;
          download.revision = rev;
          user = "ollama";
          podmanHome = "/opt/llm/halogen";
        };
        users.users.ollama = { isSystemUser = true; group = "ollama"; uid = 27002; };
        users.groups.ollama.gid = 27002;
```

re-run the two-revision diff, and confirm it still differs only on `ETC_TARGET`. Then revert the harness to the root default so the committed test matches the module's documented default. Record the rootless run in the PR body as performed evidence.

- [ ] **Step 4: Confirm the real host config still evaluates**

From `nixos-configurations`, after pointing the `halogen-flash` input at this branch:

```bash
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --dry-run
```

Expected: evaluation succeeds. A `fchmodat2 ... Operation not permitted` failure is the known Coder-workspace seccomp limit on *builds*, not a config error; evaluation is the gate.

- [ ] **Step 5: Format and lint**

```bash
nixfmt .
git diff --exit-code || { echo "nixfmt reformatted files; commit them"; git add -u; git commit -m "style: nixfmt"; }
```

- [ ] **Step 6: Open the PR**

```bash
git push -u origin fix/zero-downtime-weights-bump
gh pr create --base main --title "fix(module): zero-downtime weights bumps" --body "$(cat <<'EOF'
A weights bump currently stops the server for the whole ~112 GiB fetch, because
the weights unit bakes the pinned revision into its description and its
ExecStart script. switch-to-configuration restarts any unit whose text changed,
and the role unit is ordered behind it.

The revision is now declared in /etc/halogen-flash/target-revision and read at
run time; halogen-flash-weights.path triggers the fetch when it changes; the
role unit has no ordering edge on the fetch. The generated weights unit text is
byte-identical across revisions -- tests/test-unit-invariance.sh asserts it.

Two departures from the design doc:

- RemainAfterExit is removed from the weights unit. A PathUnit activates with
  StartUnit, which is a no-op on an already-active RemainAfterExit oneshot, so
  every bump after the first would silently do nothing.
- The node_exporter textfile collector is NOT enabled by this module. llm01's
  host exporter currently has only the drm collector and no textfile directory,
  so scraping is a separate change in nixos-configurations.

MERGE AND DEPLOY WITHOUT A REVISION CHANGE. This PR is the transition deploy:
the weights unit text still changes once, so it restarts, but it exits
immediately because desired equals live. Bump the revision in a follow-up PR.

Host-side verification (spec section 9) is operator-run and pending: no SSH to
llm01 from the authoring workspace.
EOF
)"
```

---

### Task 7: llm01 — enable the textfile collector and take the new module

**Files:**
- Modify: `nixos-configurations/hosts/llm01/configuration.nix` (around line 44)
- Modify: `nixos-configurations/flake.lock` (via `nix flake update`)

**Interfaces:**
- Consumes: the merged `halogen-flash-flake` module from Task 6, and its `metricsTextfileDir` default `/var/lib/node-exporter/textfiles`.
- Produces: llm01 actually scraping `halogen-weights.prom`.

- [ ] **Step 1: Enable the textfile collector**

`prometheus.nodeExporter.collectors = [ "drm" ]` replaces the module default, so `textfile` must be added explicitly and the directory passed. Replace line 44:

```nix
  prometheus.nodeExporter.collectors = [ "drm" "textfile" ];
  # The NixOS node_exporter does not read a textfile dir unless told to; the
  # halogen weights sync publishes desired/live/state there, and a fetch that
  # fails hours after its deploy reported success is otherwise invisible.
  # Same pattern as modules/nixos/k3s-snapshot-monitor.nix.
  services.prometheus.exporters.node.extraFlags = [
    "--collector.textfile.directory=/var/lib/node-exporter/textfiles"
  ];
```

- [ ] **Step 2: Verify the collector and directory land in the generated node_exporter args**

```bash
nix eval --raw --impure --expr \
  '(builtins.getFlake (toString ./.)).nixosConfigurations.llm01.config.services.prometheus.exporters.node.enabledCollectors' 
```

Expected: a list containing both `drm` and `textfile`.

- [ ] **Step 3: Bump the flake input to the merged module**

```bash
nix flake update halogen-flash
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --dry-run
```

Expected: evaluation succeeds. If the build itself fails with `fchmodat2 ... Operation not permitted`, that is the known Coder-workspace seccomp limitation, not a config error — evaluation is the gate here.

- [ ] **Step 4: Confirm the intent file is declared**

```bash
nix eval --raw --impure --expr \
  '(builtins.getFlake (toString ./.)).nixosConfigurations.llm01.config.environment.etc."halogen-flash/target-revision".text'
```

Expected: the pinned weights revision followed by a newline.

- [ ] **Step 5: Commit and open the PR**

```bash
git checkout -b fix/llm01-halogen-weights-textfile
git add hosts/llm01/configuration.nix flake.lock
git commit -m "feat(llm01): scrape halogen weights sync state; take zero-downtime module

The host node_exporter had only the drm collector and no textfile directory, so
the halogen-weights.prom metric would have been written and never read.
Also takes the halogen-flash module that decouples the weights fetch from the
deploy. Deploy this WITHOUT a weights revision change: the transition deploy
still rewrites the weights unit and must be observed doing nothing."
gh pr create --base main --head fix/llm01-halogen-weights-textfile
```

---

### Task 8: Operator verification after the migration deploy

Cannot be done from this workspace. Specified so the handoff is complete and so the fix is distinguished from "the download happened to be fast".

**Files:** none — this is a runbook.

- [ ] **Step 0: Prove the trigger actually fires (do this first, on any systemd host)**

`PathChanged=` is the one load-bearing assumption this repo cannot test: the intent
file is a symlink into the store that activation replaces by rename, and the
invariance test only asserts the path unit's *text*, not that the trigger works.
If it is inert, bumps silently do nothing until the next boot.

```bash
mkdir -p /tmp/probe && cd /tmp/probe
cat > probe.path <<'EOF'
[Unit]
Description=probe
[Path]
PathChanged=/etc/halogen-flash/target-revision
Unit=probe.service
[Install]
WantedBy=multi-user.target
EOF
cat > probe.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo PROBE-FIRED'
EOF
systemd-run --unit=probe-run --property=RuntimeMaxSec=120 systemd-analyze verify ./probe.path || true
sudo cp probe.path probe.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl start probe.path
ln -sfn /nix/store/some-other-path /etc/halogen-flash/target-revision   # rename-replace
sleep 2; journalctl -u probe -b --no-pager | grep PROBE-FIRED && echo "TRIGGER OK"
sudo systemctl stop probe.path; sudo rm /etc/systemd/system/probe.{path,service}
sudo systemctl daemon-reload
```

Expected: `PROBE-FIRED` then `TRIGGER OK`. If it does not fire, stop here — the
design does not work as specified and needs `PathModified=` or a timer instead.

- [ ] **Step 1: After the migration deploy (no revision change), confirm the expected one-off restart**

```bash
systemctl show -p ActiveState -p ExecMainStartTimestamp halogen-flash
journalctl -u halogen-flash --since "-2h" --no-pager \
  | grep -iE "Stopping|Stopped|Starting|Started" | tail -4
systemctl show -p ActiveState halogen-flash-weights
systemctl show -p StartLimitIntervalUSec -p StartLimitBurst halogen-flash-weights.service
systemctl status halogen-flash-weights.path
cat /var/lib/node-exporter/textfiles/halogen-weights.prom
curl -fsS http://127.0.0.1:8731/health
```

Expected: `halogen-flash` `ExecMainStartTimestamp` at the deploy time and
`ActiveState=active`, with a `Stopping`/`Stopped`/`Starting`/`Started` sequence
around it — the role unit's own text changed, so it restarted (see spec §8; this
is NOT a failed deploy). Do not use `NRestarts` here: `switch-to-configuration`
stops and starts the unit as separate jobs, which resets the counter, so it reads
`0` after a real restart. The weights unit is `inactive` (it ran and exited), the
path unit is `active`, and the textfile shows `state="complete"` with
`desired == current` because nothing was fetched. `StartLimitIntervalUSec` must
read `1h` and `StartLimitBurst` `5` — if the interval reads `10s` the start-limit
keys landed in `[Service]` again. Note the property name ends in `USec`; the
`Sec` spelling is the unit-file directive and `systemctl show` prints nothing
for it rather than an error. This is spec Review Focus item 3.

- [ ] **Step 2: Record the restart baseline, then do the bump PR**

```bash
systemctl show -p ExecMainStartTimestamp halogen-flash | tee /tmp/halogen-start.before
readlink /opt/llm/models/halogen/current
```

- [ ] **Step 3: During the bump's fetch, prove the server stayed up**

The fetch must be a genuinely long one (hours). A fast transfer does not distinguish this design from the old one.

```bash
systemctl is-active halogen-flash
curl -fsS http://127.0.0.1:8731/health
cat /var/lib/node-exporter/textfiles/halogen-weights.prom
```

Expected: `active`, `/health` answering, and the textfile showing `state="fetching"` with `desired != current`.

- [ ] **Step 4: After the fetch completes, prove exactly one restart**

```bash
systemctl show -p ExecMainStartTimestamp halogen-flash
readlink /opt/llm/models/halogen/current
cat /var/lib/node-exporter/textfiles/halogen-weights.prom
```

Expected: `ExecMainStartTimestamp` later than the `/tmp/halogen-start.before`
baseline and moved **exactly once** across the whole fetch — that single restart
is the sync script moving the server onto the new tree, which is the property
under test. `current` points at the new revision; textfile `state="complete"`
with `desired == current`. Compare against the Step 2 baseline rather than
reading `NRestarts`, which a stop/start resets.

- [ ] **Step 5: Prove repeat bumps work (correction C1)**

On the next real bump, repeat Step 4. The first bump working and every later one silently doing nothing is the specific failure C1 describes, so this check is not optional.

---

## Spec Coverage Map

| Spec section | Task |
|---|---|
| §5.1 revision-independent weights unit | Task 3 |
| §5.2 path unit | Task 3 |
| §5.3 role unit edge removal | Task 3 |
| §5.4 script edits (read file, sole restart, textfile) | Tasks 2, 4 |
| §5.5 `environment.etc` target revision | Task 2 |
| §6.1 bounded retry | Task 3 |
| §6.2 failure paths | Task 4 (state surface), Task 8 (observation) |
| §6.3 rollback | No code change; existing behaviour preserved and asserted by Task 6 Step 2 |
| §7 observability / S2 | Task 4 (write), Task 7 (scrape) |
| §8 migration sequencing | Task 6 PR body, Task 7 commit message, Task 8 Step 1 |
| §9 verification | Tasks 1, 6, 8 |
| §11 follow-ups | Not in this plan by design |
