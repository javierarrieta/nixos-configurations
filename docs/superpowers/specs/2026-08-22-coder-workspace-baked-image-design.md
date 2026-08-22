# Coder Workspace: Baked Image Software + Config-Only Home-Manager Design

**Date:** 2026-08-22
**Supersedes:** `2026-08-21-coder-workspace-home-manager-design.md` (full-HM runtime switch)

## Background

The original approach (home-manager installing packages + config at workspace
start) failed repeatedly:

| Attempt | Failure |
|---------|---------|
| VS Code extension installs | `vsce-sign` SIGABRT: image lacked libssl in FHS paths |
| HM switch #1 | `/nix/var` absent from image → nix fell back to an empty `$HOME` chroot store → local builds without stdenv bash → ENOENT |
| In-build `/nix` chown (recursive AND targeted) | crashes the CI builder VM (`/nix/store` is a read-only virtiofs share during image build) |
| `sudo` fallback | nix store binaries are never setuid; image sudo inert |

Root pattern: **installing packages through nix inside a rootless container on
an immutable image store is slow and fragile.**

## Decision

1. **All software is baked into the workspace image** (`coder-workspaces`). The
   image is the single software source; its package list is a superset of what
   the HM modules used to install.
2. **Home-manager stays, but config-only**: it manages dotfiles and program
   settings (fish, starship, git, tmux, zoxide, fzf, zsh, neovim), installs
   **zero** packages. Config changes ship by git push + workspace restart.
3. **`nix-shell -p <pkg>` must work** for temporary packages. The store ships
   root-owned (in-build chown impossible on the virtiofs share), so the
   container starts as root, grants uid 1000 ownership of the store
   *directories*, and drops privileges before running the agent.
4. Store downloads (nix-shell) are ephemeral — they die on workspace recreate.
   Acceptable for temporary packages.

## Architecture

```
nixos-configurations                          coder-workspaces
├── flake.nix                                  └── image.nix
│     └── homeConfigurations.coder-workspace         (all software incl. hm CLI)
├── modules/home-manager/*                     (config-only gating)
└── home/hosts/coder-workspace/
      ├── home.nix        (configOnly = true)
      └── userOptions.nix

coder-templates/templates/podman-template/main.tf
├── container boots as root → store setup → setpriv drop → agent init
└── startup_script = home-manager switch --flake github:...#coder-workspace
```

### Startup flow (every start/recreate)

1. Container starts as **root** (`user = "0:0"`); entrypoint command:
   ```sh
   chown 1000:1000 /nix /nix/store
   chmod u+rwx /nix/store
   mkdir -p /nix/var/nix
   chown -R 1000:1000 /nix/var/nix
   exec setpriv --reuid=1000 --regid=1000 --init-groups /tmp/agent-init.sh
   ```
   (`/tmp/agent-init.sh` = coder agent init script, written by the command
   wrapper before exec; failures in store setup are logged loudly but do not
   block agent start.)
2. Agent starts (uid 1000, cwd `/home/coder`)
3. `startup_script`:
   ```sh
   home-manager switch --flake github:javierarrieta/nixos-configurations#coder-workspace \
     > /home/coder/.hm-switch.log 2>&1 || echo "hm-switch failed, see ~/.hm-switch.log" >&2
   ```
   Config-only closure: no downloads beyond the flake itself; local builds are
   small generated files (seconds).

### Config-only gating

Shared modules gain `userOptions.configOnly` (default `false` via `or false`;
other hosts unaffected — same pattern as existing Pi gating):

- `shell.nix`: wrap `home.packages` in `mkIf (!configOnly)`; gate the
  `unstablePkgs.fish` package override — image ships its own patched fish
- `dev-tools.nix`: wrap `home.packages`; gate `programs.neovim.enable`
  (image provides nvim; enable had no extra config)
- `python.nix`: wrap `home.packages`; gate `programs.pyenv`
- `k8s.nix`: wrap `home.packages`

coder-workspace sets `configOnly = true`. What HM still manages: fish program
config (interactiveShellInit, functions, aliases), starship settings, fzf,
zoxide, tmux settings, git settings, zsh settings, session variables.

## Image deltas (`coder-workspaces`, release v0.0.4)

| Change | Why |
|--------|-----|
| **Re-add** rustc, cargo, rustfmt, clippy, nodejs_24 | image is sole software source; undoes PR #7 premise |
| **Replace** generic `python3` with `python312` | HM pinned 3.12; single python on PATH; nothing else in the image needs an interpreter |
| **Add** starship, ncdu, zsh | formerly HM shell module packages |
| **Add** btop, lsd, difftastic, dyff, fastfetch, kubernetes-helm, scala-cli, kubectx, k9s | formerly HM dev-tools/k8s packages |
| **Add** pipenv, virtualenv, pylint, oci, huggingface-hub (python312Packages) | formerly HM python packages |
| **Keep** home-manager package | needed for the config-only switch |
| **Remove** `/etc/sudoers.d/coder` | abandoned hack |
| **Keep** openssl/libcrypto FHS symlinks | fixes VS Code extension signature verification |
| **Add** `util-linux` (setpriv) | privilege drop after root-phase store setup |
| **Add** symlink `/etc/ssl/certs/ca-certificates.crt → ca-bundle.crt` | nix TLS for cache downloads |
| **Remove** baked fish `conf.d/00-coder-workspace.fish` alias block | repo fish config owns interactive config; keep bash→fish handoff in /etc/bashrc + /etc/profile |
| **Clean** PATH env | drop `~/.nix-profile/bin`? No — keep it: HM profile is real again (config-only links into it) |

Not ported: `hugo`, `pyenv`, rustup (direct toolchain instead), tide/fzf-fish
plugins (starship + `fzf --fish` init in shell.nix config replace them).

## Changes in this repository

1. `home/hosts/coder-workspace/userOptions.nix`: add `configOnly = true`
2. Shared modules: configOnly gates listed above (~6 sites)
3. Update 2026-08-21 docs (superseded) and this spec travels with the plan

## Changes in coder-templates

1. Container `user = "0:0"`; init command wrapped in root-phase setup +
   `setpriv` drop (see startup flow); `chown_home` init container unchanged
2. `startup_script` = the one-line home-manager switch
3. `workspace_image` default → `ghcr.io/javierarrieta/coder-workspaces-nix:0.0.4`

## Cleanup

- Close PR #7 (`fix/trim-hm-overlaps`) — superseded (packages stay in image)
- Delete branch `fix/nix-var-setpriv` (half-done edit)
- Tear down failed `llm01-test`; recreate after rollout
- Restart `llm01` on the new template/image afterwards

## Error handling

- hm-switch failure: non-fatal — shell falls back to image defaults; log at
  `~/.hm-switch.log`
- Root-phase store setup failure: logged loudly, does not block agent;
  consequence limited to broken nix-shell
- Flake fetch failure (GitHub unreachable): same non-fatal path
- Store downloads ephemeral across recreates

## Testing

1. **Spike first**: validate root-phase chown of `/nix/store` + setpriv drop at
   container runtime. If it fails → drop `nix-shell` support and revert to
   `user = "1000:1000"`; rest of design unaffected
2. Image CI green → release v0.0.4 → GHCR manifest check
3. Template fmt green → push `podman-template-test`
4. Fresh workspace: tools resolve (`rustc`, `node`, `python`, `k9s`, `starship`,
   `nvim`); VS Code extension install works
5. `~/.hm-switch.log`: switch success; `~/.nix-profile/bin` contains only
   wrappers/no large packages (config-only proof)
6. `nix-shell -p hello --run hello` works; second run cached
7. Fish prompt/starship, `git config user.email`, tmux settings; no
   zoxide/fzf double-init
8. Restart + recreate resilience

## Success criteria

- Fresh workspace fully usable shortly after agent start; no package downloads
- VS Code extension installation works
- `nix-shell -p <pkg>` works
- Config changes propagate: edit repo → push → restart workspace
- HM installs zero packages (image is the software source)
