# Zero-Downtime Halogen-Flash Weights Bumps

**Date:** 2026-10-15
**Problem statement:** `problems/zero-downtime-weights-bump.md`
**Status:** Approved. Implementation plan:
`docs/superpowers/plans/2026-10-15-zero-downtime-weights-bump.md`

## 1. Problem

A halogen-flash weights bump takes the serving stack down for the length of a
~112 GiB HuggingFace fetch plus a weight load — 12 minutes to hours.

The module in `halogen-flash-flake/nixos/module.nix` already implements the
*serving-side* half of the fix. `halogen-flash-weights.service` is a `oneshot`
(`RemainAfterExit`) that fetches into `versions/<rev>`, flips the `current`
symlink atomically, and only then `try-restart`s the role units. The role units
mount the constant `current` path, so the old tree stays valid for a running
container until it is restarted. The fetch-while-old-serves logic exists and is
correct.

The downtime comes from the deploy path, not the script. `halogen-flash-weights.service`
bakes `${targetRevision}` into its `description`, so a revision bump **rewrites
the unit text**. `switch-to-configuration` therefore stops and re-starts the
unit on every bump, and because the role unit carries
`After=halogen-flash-weights.service`, the server is held behind the fetch. The
server is stopped before the fetch begins and stays down until the new tree
lands.

Downstream consequences of that coupling:

- The switch is "in progress" for the whole transfer, leaving the system in a
  partial-activation state — the state behind this repo's earlier
  partial-switch/GC-dangling-binaries incident.
- The comin health gate runs after the switch, so it inherits the wait. That is
  why `cominGitOps.healthGate.halogenWarmupSec` is set to 14400 (4h) on llm01.
- A fetch failure (HF 5xx, disk full, reboot) fails *the deploy*, even though the
  running server is healthy on the old revision. An unrelated config change is
  rolled back because a download had a bad afternoon.

## 2. Goal

Make a weights bump a non-event for the running server and for the deploy:

- The server answers `/health` throughout the entire fetch.
- The deploy returns in seconds and is not affected by fetch success or failure.
- Exactly one restart of the server, after the new tree is on disk, marker
  written, and symlink flipped.
- A failed fetch is visibly failed, and does not roll back or block a deploy.

**Non-goal:** the weight *load* after the single restart still takes minutes and
is still a brief interruption. Reducing that is out of scope.

## 3. Design decisions

Decisions were taken one at a time during design review. They are recorded here
as the binding interface for implementation.

| # | Decision | Choice |
|---|---|---|
| 1 | Deploy behaviour | **A** — deploy returns immediately; fetch is decoupled entirely |
| 2 | Fetch ownership | **A1 + (a)** — constant unit text; desired revision read from a file |
| 3 | Trigger | **T1** — a `.path` unit watching the target-revision file |
| 4 | Role-unit coupling | **R1** — no ordering or dependency edge in either direction |
| 5 | Observability | **S2** — marker file plus a node-exporter textfile |
| 6 | Retry policy | **a** — bounded unit restarts, 5 attempts in 1 hour |

## 4. Architecture

The fetch moves from "part of the deploy" to "a background reconciler watching a
declared intent". Three facts become independently observable instead of one
deploy outcome:

| Fact | Today | After |
|---|---|---|
| Config deployed | switch returns | switch returns (seconds) |
| New weights on disk | implied by deploy | weights unit state + marker + textfile |
| New revision serving | implied by deploy | `current` symlink + exactly one restart |

Unit graph after the change:

```
environment.etc."halogen-flash/target-revision"   (declared intent)
        |
        v
halogen-flash-weights.path                        (PathChanged watch)
        |
        v
halogen-flash-weights.service                     (reconcile -> fetch -> marker
                                                   -> flip symlink -> RESTART)

halogen-flash.service                             (no edge to any of the above;
                                                   ExecStartPre guards the tree)
```

The role unit keeps exactly one guard: `ExecStartPre` asserting `current`
resolves to a directory. Nothing orders it behind the fetch.

## 4a. Corrections found during planning

Two things written above are wrong and were caught while writing the
implementation plan. The plan implements the corrected version.

**C1 — `RemainAfterExit` must be removed, not kept.** Section 5.1 changes the
description but leaves `RemainAfterExit = true` in place. A `PathUnit` activates
its `Unit=` with `StartUnit`; starting an already-active `Type=oneshot` with
`RemainAfterExit=yes` is a no-op, so `ExecStart` never re-runs and the **second**
bump silently does nothing. `RemainAfterExit` must be dropped so the unit returns
to `inactive`. That is safe only because decision R1 already removed the role
unit's `After=` edge — nothing needs the unit to stay active any more.

**C2 — llm01's host node_exporter does not read the textfile directory.**
`hosts/llm01/configuration.nix` sets `prometheus.nodeExporter.collectors = [
"drm" ]`, which replaces the module default `[ "systemd" ]`, and nothing sets
`--collector.textfile.directory`. The only module that enables the textfile
collector is `modules/nixos/k3s-snapshot-monitor.nix`, which llm01 does not
enable. So Section 7 as written would produce a file nobody scrapes. Enabling
the collector and the directory on llm01 is part of this work, not a follow-up.

## 5. Components

### 5.1 `halogen-flash-weights.service` — unit text becomes revision-independent

- `description` becomes a fixed string. It **must not** interpolate
  `${targetRevision}`. This is the single change that stops
  `switch-to-configuration` from rewriting and restarting the unit on a bump.
- `ExecStart` runs a script that reads the desired revision from
  `/etc/halogen-flash/target-revision` at run time. The revision is **not**
  interpolated by Nix anywhere in the unit or the script, so both the unit text
  and the script's store path are identical across revisions.
- No `After=`/`Requires=` relationship with the role units, in either direction.
- `RemainAfterExit` is **not** set (correction C1).
- Bounded retry policy (Section 6).

### 5.2 `halogen-flash-weights.path` — new

- `PathChanged=/etc/halogen-flash/target-revision`
- `Unit=halogen-flash-weights.service`
- `WantedBy=multi-user.target`
- `PathChanged` rather than `PathExists`: the file exists after the first
  activation, so what matters is a change to its contents.
- Only materialised when `versionedActive`.

### 5.3 `halogen-flash` role unit — couplings removed

- Remove the `After=halogen-flash-weights.service` clause.
- Keep `ExecStartPre` = test that `current` is a directory. It is the only
  guard, and it covers the "fresh boot with no weights" case by failing the unit
  loudly rather than waiting behind a background download.
- Everything else unchanged: `Restart`, `LimitMEMLOCK`, podman argv, image,
  `TimeoutStartSec`.

### 5.4 The sync script — three edits

- Read `targetRevision` from `/etc/halogen-flash/target-revision` instead of
  Nix interpolation.
- Keep the `try-restart` and make it the sole restart path. Nothing else in the
  system restarts the server for weights reasons.
- Write the S2 textfile (Section 7).
- Unchanged: the legacy-flat-weights migration guard, the pre-fetch prune that
  bounds disk to two versions, the marker contents (`rev=…|excl=…`), the
  `ln -s` + `mv -T` atomic flip, the `hf download` invocation and exclude flags.

### 5.5 `environment.etc."halogen-flash/target-revision"` — new

- Contents: the pinned revision, with a trailing newline.
- Written on every activation; bytes change only when the revision is bumped.
  Because the path unit uses `PathChanged`, a no-change deploy fires nothing.
- Only materialised when `versionedActive`.
- `environment.etc` is chosen over a tmpfiles rule because it gives the atomic
  rename and the "always exists after activation" property that `PathChanged`
  depends on.

## 6. Retry, error handling, and rollback

### 6.1 Retry policy

The sync unit moves from unbounded retries to bounded ones. The fetch is no
longer a deploy, so a permanently-failing fetch must stop and be visible rather
than churn forever.

- `StartLimitBurst = 5`, `StartLimitIntervalSec = 3600`: five attempts in one
  hour, then the unit settles in a stable `failed` state.
- `Restart = on-failure`, `RestartSec = 60` retained inside that bound.
- Within a single attempt, `hf download` keeps its existing resume/re-verify
  behaviour; a transient HF error is ridden out by the burst allowance.

### 6.2 Failure paths

| Failure | Result |
|---|---|
| Fetch fails (HF 5xx, disk full, network) | Unit ends `failed`, textfile says `failed`. Server still serves the old revision. Deploy unaffected. |
| Reboot mid-fetch | `hf` resumes. Marker was never written, so the partial tree is re-verified rather than trusted. |
| Bump reverted in git before fetch completes | `target-revision` reverts, path unit fires, script compares against `current` (still the old tree) and does nothing. An in-flight fetch is not cancelled; it completes into a tree pruned on the next reconciliation. Known, harmless. |

### 6.3 Rollback

Two meanings, both preserved:

- **Roll back the weights:** write the older sha to
  `/etc/halogen-flash/target-revision` and let the path unit act, or point
  `current` at the older tree and restart. The first is the declared-intent path
  and the one to document.
- **Roll back the config:** unchanged comin mechanism. It no longer drags a
  weights fetch with it, because the two no longer share a unit.

## 7. Observability (S2)

The sync unit writes a node-exporter textfile alongside the existing
`comin_pending_confirmation` pattern.

- Path: `/var/lib/node-exporter/textfiles/halogen-weights.prom` (same directory
  and mechanism as `comin.prom`).
- Metrics: at minimum
  - `halogen_weights_desired_revision_info{revision="<sha>"} 1`
  - `halogen_weights_current_revision_info{revision="<sha>"} 1`
  - `halogen_weights_state{state="fetching|complete|failed"} 1`
- Written at each state transition and periodically while fetching.

**Scope note.** This repo writes the file. Scraping llm01 is configured by the
cluster's static target list in the separate `k8s-casa` repository, and any
alert on `desired != current` for more than N hours is a change there, not here.
That alert is an explicit follow-up for a separate PR, not part of this change.

## 8. Migration

The transition deploy is **not free** and must be sequenced deliberately.

The currently-deployed weights unit embeds `${targetRevision}` in its
`description`, and the role unit carries `After=halogen-flash-weights.service`.
The first deploy of this change therefore rewrites the weights unit and may order
the server behind it once.

Plan:

1. **PR 1 — config-only, revision unchanged.** Land the module changes with
   `defaultWeightsRevision` untouched. The weights unit text still changes, so it
   restarts, but it exits immediately (revision matches `current`, nothing to
   fetch) and the server is untouched. Deploy and verify.
2. **PR 2 — the bump.** Change `defaultWeightsRevision` and observe the new
   behaviour cleanly. This also provides a clean before/after for verification.

## 9. Verification

There is no automated test for this. The module runs on one host with a 112 GiB
dependency and there is no SSH from this workspace. The following are specified
instead.

**Proves the fix (runs anywhere, no llm01 access):**

- **Unit-text invariance.** Evaluate the generated unit text at two different
  values of `defaultWeightsRevision` and diff them. The claim under test is that
  the weights unit text, the path unit text, and the script's store path are all
  byte-identical across revisions. This is the one test that actually
  demonstrates the downtime is designed out, and it must be part of the plan.
- **Evaluation and dry-run build** of `llm01` to catch Nix-level errors. This
  file has previously shipped a `\${revision}`-inside-indented-string eval bug;
  a plain eval catches that class.

**On the host, after PR 2 (operator-run):**

- `/health` answers continuously across the whole fetch window.
- `systemctl show -p NRestarts halogen-flash` advances by **exactly 1**.
- `systemctl show -p NRestarts halogen-flash-weights` shows the bounded retry
  policy in effect.
- The textfile reflects `complete` with `desired == current` once the bump lands.

**Discrimination requirement.** The first two host checks must be observed over
a fetch that is genuinely long (hours). A fetch that happens to complete in
minutes does not distinguish the fix from the bug, because the old design is also
invisible if the transfer is fast enough to finish inside the health-gate window.

## 10. Files touched

| File | Change |
|---|---|
| `halogen-flash-flake/nixos/module.nix` | weights unit text made revision-independent; path unit added; role-unit `After=` removed; `environment.etc` target-revision added; script reads the file and writes the textfile; bounded retry |
| `nixos-configurations/hosts/llm01/configuration.nix` | enable the node_exporter textfile collector and directory (correction C2); take the new module. `halogenWarmupSec` stays at 14400 — see Section 11 |

The module lives in a separate repository (`halogen-flash-flake`), so the module
change is one PR there. The PR 1 / PR 2 sequencing in Section 8 is two PRs in
that repository (config-only, then the bump). This repository needs its own PR
for the collector enablement and the flake input bump.

## 11. Open follow-ups (not in this change)

- **`halogenWarmupSec`.** llm01 sets 14400 because a revision change makes the
  role unit's `ExecStartPre` a multi-hour fetch under the unversioned path, and
  because today's versioned path blocks the switch. Once this change lands the
  halogen `/health` check should pass in minutes. Reducing the value is safe but
  is deliberately left as a separate, later change so it cannot mask a regression
  during the migration deploy.
- **Alert on `desired != current`** in `k8s-casa` (Section 7). Note that
  enabling the collector on llm01 is *not* a follow-up — see correction C2.
- **Prometheus scrape of the new textfile** is assumed to work via the existing
  node_exporter textfile mount; confirm the mount covers the whole directory
  rather than only `comin.prom`.
