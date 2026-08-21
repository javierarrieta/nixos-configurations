# Coder Workspace Home-Manager Integration Design

## Overview

Configure the `coder` user environment inside the coder workspace container using
**standalone home-manager** (not the NixOS module). The workspace is NOT a NixOS
host: it is a `dockerTools.buildImage` container (`../coder-workspaces/image.nix`)
with no systemd, no NixOS activation system, and a root-owned `/nix/store`.
Only `/home/coder` persists across workspace reboots/recreates; everything else
comes from the image generated in the sibling repo `../coder-workspaces`.

### Constraints discovered during review

| Fact | Consequence |
|------|-------------|
| Container has no systemd | No `nixos-rebuild`, no NixOS modules (`base`, `ssh`, `sops-base`, `nix-sweep`) |
| User `coder` exists via `useradd`, uid **1000** (`image.nix:118`) | 27003 is llm01's *host-side* podman user — irrelevant here |
| `/nix/store` root-owned read-only (`image.nix:186-189`) | `home-manager switch` cannot write store paths until image makes `/nix` writable by uid 1000 |
| Only `/home/coder` persists | HM generation lives in `~/.local/state/nix/profiles` (persists) but its store-path targets die on workspace recreate → re-run switch after every workspace rebuild |
| Image env `PATH=/bin:/usr/bin:...` first (`image.nix:194`) | Image tools in `/bin` can shadow HM profile binaries; PATH ordering must be verified/handled |
| Image bakes fish aliases + zoxide/fzf/direnv init into fish `conf.d` (`image.nix:10-28`) | HM must own the interactive fish layer or duplication/double-init results |

## Objectives

1. Add `homeConfigurations.coder-workspace` to this flake, reusing the existing
   `mkHomeConfig` helper (`flake.nix:59`)
2. Reuse existing home-manager modules: `base.nix`, `dev-tools.nix`, `python.nix`, `k8s.nix`
3. Make the minimal image changes in `../coder-workspaces` so HM can activate:
   writable `/nix`, `home-manager` binary present, sane PATH
4. Document bootstrap and per-recreate workflow (fully automatic via startup script)

## Architecture

```
nixos-configurations/flake.nix
  └── homeConfigurations.coder-workspace        # via mkHomeConfig { hostname = "coder-workspace"; system = "x86_64-linux"; }
        └── home/hosts/coder-workspace/home.nix
              ├── ../../modules/home-manager/base.nix
              │     ├── host-common.nix          # username/userHome from userOptions
              │     └── shell.nix                # fish, starship, zoxide, fzf...
              ├── dev-tools.nix                  # trimmed: see "Module trimming"
              ├── python.nix
              └── k8s.nix

coder-workspaces/image.nix   (sibling repo, separate change)
  └── writable /nix + home-manager package + PATH fix
```

### Activation on workspace start (`../coder-templates/templates/podman-template/main.tf`)

The template's `coder_agent.main` gets a `startup_script` — runs as uid 1000 in
`/home/coder` on every workspace start, visible in the Coder UI:

```hcl
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  startup_script = <<-EOT
    #!/bin/bash
    set -uo pipefail
    home-manager switch \
      --flake github:javierarrieta/nixos-configurations#coder-workspace \
      > /home/coder/.hm-switch.log 2>&1 || echo "hm-switch failed, see ~/.hm-switch.log" >&2
  EOT

  env = { ... }
}
```

Design notes:
- Flake applied **directly from GitHub** — no local clone in the startup path.
  Deploys exactly what is on pushed `main`; no repo-state drift between the
  volume and remote.
- Chosen over a terraform-side init container (à la `chown_home`): re-runs on every
  start (not just apply), logs land in Coder UI, does not delay agent start by the
  full first HM build.
- Idempotent: after first run, switch converges to no-op within seconds.
- First-ever switch downloads/builds the HM closure (minutes) but runs async — shell usable meanwhile; log at `~/.hm-switch.log`.
- No SOPS dependency in activation: image `/etc/nix/nix.conf` already sets
  `experimental-features = nix-command flakes`; these modules touch no secrets.

### Activation flow

**Automatic on workspace start.** The template's `startup_script`
(above) applies the flake from GitHub on every workspace start/recreate. No
user action needed. To change the configuration: edit, commit, push to `main`,
restart the workspace (or run the switch manually with the same github flake URL).

## Components

### 1. `home/hosts/coder-workspace/userOptions.nix`

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

### 2. `home/hosts/coder-workspace/home.nix`

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

Note: `base.nix` requires `hostname` and `userOptions` in `extraSpecialArgs`;
`mkHomeConfig` already passes both (`flake.nix:70-74`). The Pi-gating logic in
`base.nix` keys off `hostname` — `"coder-workspace"` is not a Pi name, so all
dev modules load by default (trimming handled below).

### 3. Flake change

```nix
homeConfigurations = {
  oracle = mkHomeConfig { hostname = "oracle"; };
  macbookair = mkHomeConfig { hostname = "macbookair"; };
  vps = mkHomeConfig { hostname = "vps"; system = "x86_64-linux"; };
  coder-workspace = mkHomeConfig {
    hostname = "coder-workspace";
    system = "x86_64-linux";
  };
};
```

No `nixosConfigurations.coder-workspace`. No NixOS modules anywhere in this path.

### 4. Image changes (`../coder-workspaces/image.nix`, separate PR/repo)

1. **Writable store** — in `runAsRoot`, after image assembly the store is
   root-owned; make single-user nix usable as uid 1000:

   ```dockerfile
   mkdir -p /nix/var/nix/profiles/per-user/coder
   chown -R 1000:1000 /nix/var/nix/profiles/per-user/coder
   chmod -R a+w /nix/store /nix/var/nix   # or chown -R 1000:1000 /nix
   ```

   Simplest correct option: `chown -R 1000:1000 /nix`. Store grows on every
   HM switch and dies on workspace recreate — acceptable, documented below.

2. **Add `home-manager`** to `copyToRoot` paths (from the same nixpkgs the
   image builds with, `nixos-unstable`).

3. **PATH**: reorder image env to put HM profile ahead of `/bin`:

   ```
   PATH=/home/coder/.nix-profile/bin:/bin:/usr/bin:/home/coder/.cargo/bin:/home/coder/.local/bin:/home/coder/.bun/bin
   ```

   Note HM-managed fish also sets PATH at session init; this covers non-fish
   (bash/VS Code Remote-SSH) shells.

### 5. Module trimming (in `home/hosts/coder-workspace/home.nix`)

Image already ships most tools in `/bin` (nodejs, gh, kubectl, rustc/cargo,
uv, bun, go, scala, sbt, postgresql, neovim, tmux, eza, bat, fzf, zoxide,
direnv, sops, age...). Duplicates from HM are harmless once PATH is ordered,
but heavy/pointless items should be excluded to cut build time and closure
size. Trim in `dev-tools.nix` consumers via `disabledPackages`-style list or
override in `home.nix` — decide at implementation time; candidates to drop:
anything already in the image AND large (e.g. duplicate nodejs/python if
versions match).

Keep from HM regardless of image overlap: starship, tide/fish plugins,
ncdu, nixd, k9s/kubectx (not in image), git config, aliases, session vars.

### 6. Fish layer ownership

Decision: **HM owns interactive fish config**. Remove the baked
`00-coder-workspace.fish` alias block from `image.nix` OR accept temporary
duplication and remove after HM switch works. Do not leave both long-term:
zoxide/fzf/direnv would double-init. Image keeps only the bash→fish exec
handoff logic in `/etc/bashrc` and `/etc/profile` (that part must stay —
HM does not manage login shells here).

### 7. Secrets

None. HM modules use no sops-nix options; `sops`/`age` appear only as CLI
packages in `dev-tools.nix`/`llm.nix`. Any secret usage (e.g. decrypting
`secrets.yaml` with the sops CLI) is a manual, per-user concern — out of scope.

## Persistence Semantics

| Event | What survives | Action needed |
|-------|--------------|---------------|
| Workspace stop/start | Everything (volume intact) | Nothing |
| Workspace recreate (new image) | Only `/home/coder`: dotfiles, HM generations (broken symlinks) | Startup script re-runs `home-manager switch` automatically |
| Image update | Only `/home/coder` | Same as recreate |

The stale-generation problem is self-healing: next successful switch replaces
the broken generation link.

## Error Handling

- Read-only `/nix` → `home-manager switch` fails with permission error → means image not rebuilt with change #4
- Stale profile after recreate → commands fail with "file not found" → re-run switch

## Testing

1. Eval: `nix eval .#homeConfigurations.coder-workspace.activationPackage --show-trace` (from any machine)
2. Build: `nix build .#homeConfigurations.coder-workspace.activationPackage`
3. In-container apply (manual): `home-manager switch --flake github:javierarrieta/nixos-configurations#coder-workspace`;
   or just recreate the workspace and let the startup script do it
4. Verify: fresh fish shell shows starship prompt, aliases work, `k9s`,
   `kubectl`, `nvim` resolve; `git config user.email` correct
5. Recreate workspace → startup script auto-reapplies; check `~/.hm-switch.log` and verify again

## Scope Boundaries

**In scope:**
- `homeConfigurations.coder-workspace` + `home/hosts/coder-workspace/{home.nix,userOptions.nix}`
- `startup_script` addition in `../coder-templates/templates/podman-template/main.tf`
- Minimal trims to shared HM modules if needed (via host-level overrides only)
- Documented image changes for `../coder-workspaces` (implemented in that repo)

**Out of scope:**
- Any `nixosConfigurations` entry or NixOS module usage
- `coder-host.nix` (podman API, iSCSI) — host-side, unrelated
- Other users' home configs

## Success Criteria

- `nix eval .#homeConfigurations.coder-workspace.activationPackage` succeeds
- After workspace create/recreate: coder shell has full HM-managed env
  (fish/starship/git config/nvim/k9s/etc.) applied by the template startup script
- Shared modules remain untouched except optional host-level overrides in
  `home/hosts/coder-workspace/`
