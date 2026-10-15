# Problem Statement: Zero-Downtime Weights Bumps for Halogen-Flash

## 1. Current Behavior
- **Weights bump process**: `halogen-flash-weights.service` (oneshot) fetches the new HuggingFace checkpoint (~112 GiB), writes the completion marker (`$targetDir/.halogen-weights-complete`), flips the `current` symlink from the old revision to the new one, and then executes `systemctl try-restart $restartUnits` to restart the role units.
- **Downtime**: The old halogen server is stopped **before** the weights fetch begins as part of the `nixos-reload switch`. The server remains unavailable until the weights unit completes, the symlink flips, and the role units restart on the new revision. This gap is typically 12min–hours (download time + restart).
- **Artifact consistency**: The `current` symlink (`/opt/llm/models/halogen/current → /opt/llm/models/halogen/versions/<revision>`) is the single source of truth for the container’s mount. The old version’s files are pruned after the fetch; the new version appears atomically via `ln -sf` + `mv -T`.

## 2. Desired Behavior
- **Zero‑downtime weights bumps**: The halogen service should remain available on the **old** revision throughout the entire fetch. After the new weights are confirmed on disk and the marker is written, a **single halogen service restart** should apply the new version. The switch should not require a full stop‑start cycle of the halogen service.
- **Success metrics**:
  - Halogen service uptime: 100% during the weights fetch period.
  - Service restart count: exactly 1 (after download completes), not 2 (stop + start).
  - No `halogen-flash-weights.service` exit‑127 or crash‑loop incidents.
  - Exclude list auto‑updated on each bump (handled by bump-image.sh re‑derive feature).

## 3. Constraints & Context
- **Module locations**: 
  - `halogen-flash-flake/nixos/module.nix` — `options.exclude`, `defaultWeightsRevision`, `default`, `modelsDir`, `targetRevision`, `versionsDir`, `currentLink`.
  - `nixos-configurations/hosts/llm01/configuration.nix` — pins `image`, `pull.enable`, `enableVision`; previously had hardcoded `download.exclude` (now inherited from flake default).
- **No SSH to llm01** from workspace; all changes must be PR’d and merged via GitHub.
- **Exclude list**: Currently `w4b*, ht43*` (default, inherited from flake). Auto‑re‑derived on each bump by `bump-image.sh` (PR #30).
- **Fixed bug**: The `exclusionsStr` quoting bug (unquoted `|` → `command not found` → crash‑loop) is fixed in flake main `8fadd92`. The current deployment (`cf41ff9`) fetches cleanly.

## 3. Desired Outcome (Formal)
A redesigned `halogen-flash` module where a weights bump triggers:
1. **Fetch** the new checkpoint in the background (the `current` symlink keeps pointing at the old revision, so the running halogen serves the old version uninterrupted).
2. **Marker + symlink flip** atomically after the fetch succeeds.
3. **Exactly one** `systemctl restart halogen-flash` (or equivalent) to apply the new version — no prior stop‑start cycle.

## 4. Constraints
- Module lives in `halogen-flash-flake/nixos/module.nix`; llm01 config in `nixos-configurations/hosts/llm01/configuration.nix`.
- No SSH to llm01 from workspace; all changes must be PR’d and merged via GitHub.
- Exclude list default lives beside `defaultRepo`/`defaultWeightsRevision` in the flake; auto‑re‑derived by `bump-image.sh`.
- The `exclusionsStr` quoting bug is resolved; the current fetch (`cf41ff9`) fetches cleanly.

---

*Problem statement generated on 2026-10-15. For redesign conversation.*
