# NIXOS Configuration Test Plan

## Goal
Add automated tests to GitHub Actions to verify every change passes:
1. Flake evaluation (syntax/validation)
2. Code formatting (`nix fmt`)
3. Host build smoke test

## Current State
- 117 `.nix` files across 16 hosts
- `.github/workflows/verify.yml` exists with 3 checks
- Only existing test: `pkgs/coder-iscsi-helper/tests/test_contract.py`

## Plan
### 1. Create `.github/workflows/verify.yml` (3 checks)
- **Flake eval**: `nix flake check --no-build` (no `--flake` needed if in repo root)
- **Format check**: `nix fmt --check` (exit code 0 = valid)
- **Host smoke test**: `nix build .#k8s-node01.config.system.build.toplevel`

### 2. GitHub Actions workflow
`.github/workflows/verify.yml` with:
- Triggers: `push`, `pull_request`
- Jobs: `verify` (runs on `ubuntu-latest`)
- Steps:
  1. Checkout code
  2. Setup Nix (use `DeterminateSystems/nix-installer-action@v14`)
  3. Run `nix flake check --no-build`
  4. Run `nix fmt --check`
  5. Run smoke test on `k8s-node01`

### 3. Notes
- **SOPS validation removed**: Cannot run `sops -d secrets.yaml` in CI without adding an age key to the workflow. SOPS validation is done locally only.
- **Experimental features**: `nix-command` and `flakes` experimental features must be enabled (set via `NIX_CONFIG` env var or `nix.conf`).
- `nix fmt --check` is the modern replacement for standalone `nixfmt`.

### 4. Host selection
- Uses `k8s-node01` for smoke test (first x86_64 host)

### 5. Failure handling
- All steps fail fast on error (default Nix behavior)
- GitHub Actions will auto-fail workflow on non-zero exit

## Timeline
- Day 1: Create workflow file
- Day 2: Test locally
- Day 3: Commit and verify GitHub Actions runs

## Risk Mitigation
- Start with smoke test on one host
- Use `nix flake check` to validate syntax first
- Keep workflow simple (3 steps)
- No secrets required in CI
