# CI Verify Workflow Plan

> Status: planned (workflow exists; plan unifies with actual workflow)

## Problem
The workflow `.github/workflows/verify.yml` and plan expectations diverged:
- Smoke test path in plan used `.#k8s-node01...` (missing `nixosConfigurations.` prefix); the workflow uses `.#nixosConfigurations.k8s-node01...`.
- Plan said "Create workflow file" though it already existed.
- No plan file in `docs/superpowers/plans/` captured the CI verification work.

## Files

| File | Role |
|---|---|
| `.github/workflows/verify.yml` | Source of truth — actual GitHub Actions workflow |
| `docs/superpowers/plans/2026-09-02-ci-verify-workflow.md` | This plan file |

## Workflow (`verify.yml`)

Single job `verify` on `ubuntu-latest`, triggered on `push`/`pull_request` to `main` and `stable`:

1. `actions/checkout@v4`
2. `DeterminateSystems/nix-installer-action@v14`
3. `nix flake check --no-build` — flake evaluation (syntax/validation)
4. `nix fmt --check` — formatting (modern replacement for standalone `nixfmt`)
5. `nix build .#nixosConfigurations.k8s-node01.config.system.build.toplevel` — host smoke test

## Verification Criteria

- `nix flake check --no-build` exits 0 (syntax/validation)
- `nix fmt --check` exits 0 (formatting)
- `nix build .#nixosConfigurations.k8s-node01.config.system.build.toplevel` exits 0 (build smoke test)
- All three steps run in the GitHub Actions `verify` job; any non-zero exit fails the workflow

## Notes

- **SOPS validation excluded from CI**: `sops -d secrets.yaml` requires an age key not present in CI; SOPS validation is local only.
- **Experimental features**: `nix-command` and `flakes` must be enabled (`NIX_CONFIG` env var or `nix.conf`).
- **Host selection**: `k8s-node01` (first x86_64 host). Expanding to other hosts is a follow-up.
- **Failure handling**: all steps fail fast (default Nix behavior); GitHub Actions auto-fails on non-zero exit.
- **No secrets required in CI**: the workflow uses no secrets.

## Dependencies / Order

1. Ensure `.github/workflows/verify.yml` has correct steps (done)
2. Verify `nix flake check --no-build` works on the repo root
3. Verify `nix fmt --check` works on the repo root
4. Verify smoke test build on `k8s-node01` host config
5. Commit plan file + workflow

## Risk Mitigation

- Start with `nix flake check` to validate syntax first (lowest risk)
- Run format check independently; `nix fmt --check` may flag style differences
- Smoke test on one host (`k8s-node01`); expand to other hosts as follow-up
- Keep workflow simple (3 checks, no secrets)