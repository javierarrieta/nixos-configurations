# Coder Workspace Home-Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply a home-manager configuration to the `coder` user in coder workspace containers automatically on workspace start.

**Architecture:** Standalone home-manager (`homeConfigurations.coder-workspace`, no NixOS). The Coder template's `startup_script` applies the flake directly from GitHub on every start/recreate. Three repos change: `nixos-configurations` (HM config), `coder-workspaces` (image: writable `/nix`, `home-manager` binary, PATH), `coder-templates` (startup script).

**Tech Stack:** Nix flakes, home-manager standalone, dockerTools image, Terraform/Coder template.

**Spec:** `docs/superpowers/specs/2026-08-21-coder-workspace-home-manager-design.md`

## Global Constraints

- No `nixosConfigurations`, no NixOS modules anywhere in the HM path
- Container user is uid/gid **1000**, home `/home/coder`; only `/home/coder` persists
- HM config must work via existing shared modules (`modules/home-manager/base.nix` and children) — no forks
- `hostname` extraArg must be `"coder-workspace"` (not a Pi name → full dev modules load)
- Repo for flake URL: `github:javierarrieta/nixos-configurations`
- This repo branch: `feature/coder-workspace-home-manager`; templates branch: `feature/home-manager-startup`

---

### Task 1: Home-manager host files (nixos-configurations)

**Files:**
- Create: `home/hosts/coder-workspace/userOptions.nix`
- Create: `home/hosts/coder-workspace/home.nix`

**Interfaces:**
- Consumes: `mkHomeConfig` (`flake.nix:59`) expects exactly these two files under `home/hosts/<hostname>/`; `base.nix` consumes `userOptions.username`, `userOptions.userHome`, plus specialArgs `hostname`, `unstablePkgs`
- Produces: `home/hosts/coder-workspace/{userOptions.nix,home.nix}` consumed by Task 2

- [ ] **Step 1: Create `userOptions.nix`**

```nix
{
  username = "coder";
  userHome = "/home/coder";
  gitName = "Javier Arrieta";
  gitEmail = "javier@techdelivery.es";
  gitDefaultBranch = "main";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  homeManagerConfigDir = "/home/coder/code/nixos-configurations";
}
```

- [ ] **Step 2: Create `home.nix`**

```nix
{
  imports = [
    ../../modules/home-manager/base.nix
  ];

  home.stateVersion = "25.11";

  home.sessionVariables = {
    NIX_CONFIG = "experimental-features = nix-command flakes";
  };
}
```

Note: `shell.nix:46-47` sources `~/.venv/default/bin/activate.fish` unconditionally. If fish errors on fresh home during Task 5 testing, fix here (guard the source) as part of this task's follow-up — do not modify shared `shell.nix`.

- [ ] **Step 3: Verify files tracked**

Run: `git status --short`
Expected: both new files listed (git add before eval — untracked paths break flake eval).

```bash
git add home/hosts/coder-workspace
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: add coder-workspace home-manager host config"
```

### Task 2: Flake output + eval/build verification (nixos-configurations)

**Files:**
- Modify: `flake.nix:78-89` (`homeConfigurations` block)

**Interfaces:**
- Consumes: `mkHomeConfig { hostname; system; }`, Task 1 files
- Produces: `homeConfigurations.coder-workspace` — consumed by startup script (`github:javierarrieta/nixos-configurations#coder-workspace`) and by Task 5 testing

- [ ] **Step 1: Add entry to `homeConfigurations`**

```nix
      homeConfigurations = {
        oracle = mkHomeConfig {
          hostname = "oracle";
        };
        macbookair = mkHomeConfig {
          hostname = "macbookair";
        };
        vps = mkHomeConfig {
          hostname = "vps";
          system = "x86_64-linux";
        };
        coder-workspace = mkHomeConfig {
          hostname = "coder-workspace";
          system = "x86_64-linux";
        };
      };
```

- [ ] **Step 2: Eval check**

Run: `nix eval .#homeConfigurations.coder-workspace.activationPackage --show-trace`
Expected: store path printed, no errors.

- [ ] **Step 3: Build check**

Run: `nix build .#homeConfigurations.coder-workspace.activationPackage`
Expected: `result` symlink created. On macOS this may fail for linux-only packages — eval (Step 2) is the gate; build on llm01 if needed.

- [ ] **Step 4: Format + commit**

```bash
nixfmt .
git add flake.nix
git commit -m "feat: add coder-workspace homeConfiguration"
```

### Task 3: Image changes (coder-workspaces)

**Files:**
- Modify: `../coder-workspaces/image.nix` (`copyToRoot.paths`, `runAsRoot`, `config.Env`)

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: image with `home-manager` on PATH and coder-writable `/nix` — hard prerequisite of Tasks 4/5

- [ ] **Step 1: Add `home-manager` to `copyToRoot` paths**

In the `paths = with pkgs; [...]` list, next to `nix`:

```nix
      nix
      home-manager
```

- [ ] **Step 2: Make `/nix` writable by uid 1000 in `runAsRoot`**

Append before the closing of `runAsRoot` (after the existing `/etc/nix/nix.conf` heredoc):

```
    # Single-user nix: HM switch must write new store paths as uid 1000.
    # Store contents are re-fetched per switch; dies on workspace recreate,
    # which is acceptable (only /home/coder persists).
    chown -R 1000:1000 /nix
```

- [ ] **Step 3: Reorder PATH so HM profile wins**

Replace the `PATH` env entry:

```nix
      "PATH=/home/coder/.nix-profile/bin:/bin:/usr/bin:/home/coder/.cargo/bin:/home/coder/.local/bin:/home/coder/.bun/bin"
```

- [ ] **Step 4: Local build smoke test**

Run (on Linux with nix):
```bash
cd ../coder-workspaces && nix build .#default
docker load < result
docker run --rm --user 1000 coder-workspaces-nix:pinned sh -c 'touch /nix/write-test && rm /nix/write-test && home-manager --version'
```
Expected: no permission error; version prints.

- [ ] **Step 5: Commit + push, wait for CI tag**

```bash
cd ../coder-workspaces
git checkout -b feature/hm-support
git add image.nix
git commit -m "feat: support home-manager activation in workspace image"
git push -u origin feature/hm-support
```
Merge PR to `main`. CI publishes GHCR tag `<date>-<sha>`. Record the new tag — Task 4 Step 3 needs it.

### Task 4: Template startup script + image tag (coder-templates)

**Files:**
- Modify: `../coder-templates/templates/podman-template/main.tf` (`coder_agent.main`, `coder_parameter.workspace_image`)

**Interfaces:**
- Consumes: image tag from Task 3; flake ref from Task 2
- Produces: startup behavior exercised in Task 5

Note: `startup_script` already implemented and committed on branch `feature/home-manager-startup` (`3998ebd`). This task verifies it and updates the image tag.

- [ ] **Step 1: Verify startup script present**

Confirm `coder_agent.main` contains:

```hcl
  startup_script = <<-EOT
    #!/bin/bash
    set -uo pipefail
    home-manager switch \
      --flake github:javierarrieta/nixos-configurations#coder-workspace \
      > /home/coder/.hm-switch.log 2>&1 || echo "hm-switch failed, see ~/.hm-switch.log" >&2
  EOT
```

If missing, apply it (see spec §Activation on workspace start).

- [ ] **Step 2: Update image default tag**

Set the Task 3 tag in:

```hcl
data "coder_parameter" "workspace_image" {
  ...
  default      = "ghcr.io/javierarrieta/coder-workspaces-nix:<TASK3-TAG>"
  ...
}
```

(Adjust current default name `coder-workspace:...` to the `coder-workspaces-nix` repo name used by GHCR.)

- [ ] **Step 3: Validate HCL**

terraform not installed locally — minimum check: balanced braces/heredoc via `nix` unrelated tooling is not possible; do visual diff review. If terraform available anywhere (llm01): `terraform fmt -check && terraform validate`.

- [ ] **Step 4: Commit + push**

```bash
cd ../coder-templates
git add templates/podman-template/main.tf
git commit -m "feat(podman-template): point workspace at hm-capable image"
git push -u origin feature/home-manager-startup
```
Merge PR, then `coder templates push llm01-podman` (clear stale provisioner cache first per AGENTS.md).

### Task 5: End-to-end test (live workspace)

**Files:** none

**Interfaces:**
- Consumes: all previous tasks merged and deployed

- [ ] **Step 1: Recreate workspace**

Delete + create a test workspace (`llm01-podman` template) so fresh image + volume.

- [ ] **Step 2: Check activation log**

```bash
coder ssh <test-ws>
cat ~/.hm-switch.log
```
Expected: successful switch output, generation linked.

- [ ] **Step 3: Verify environment**

```bash
fish
# starship prompt renders
k9s version
kubectl version --client
nvim --version | head -1
git config user.email   # javier@techdelivery.es
type eza                # resolves
```
Expected: all resolve; prompt correct; no double zoxide/fzf init warnings.

- [ ] **Step 4: Restart resilience**

Stop + start workspace. Check `~/.hm-switch.log` shows fast no-op switch; environment intact without manual action.

- [ ] **Step 5: Recreate resilience**

Recreate workspace again. Startup script must fully restore env (stale profile healed). If fish venv error appears (`shell.nix:46-47`), fix guard in `home/hosts/coder-workspace/home.nix`, push, restart, re-verify.

- [ ] **Step 6: Merge order**

Merge `nixos-configurations` branch first (spec + config), then `coder-workspaces`, then `coder-templates`. All three must be on `main` before any real workspace relies on startup behavior.
