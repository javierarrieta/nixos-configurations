# Design: Add dev tooling packages to the coder-workspace image

Date: 2026-08-16
Status: Approved (per conversation)
Related repos:
- `nixos-configurations` (image build): `~/code/nixos-configurations`
- `coder-templates` (template): `~/code/coder-templates/templates/podman-template`

## Goal

Add the `sops` and `age` CLIs plus project-stack tooling to the `coder-workspace` container image, so workspaces can decrypt sops-encrypted secrets (with age keys supplied at runtime via Coder secrets/mounts) and develop the user's projects (Rust, Python, Scala, TypeScript/React, K8s). No key material is baked into the image.

## Scope

- In scope: add packages to the image to cover the user's recent projects (see "Package selection" below).
- Out of scope: key management, sops-nix (a NixOS config tool, not applicable to a container image), pinning specific upstream versions, baked-in key files, per-project `node_modules` (handled by `npm install` in each project).

## Project stack → image coverage

- `investment-portfolio-manager` (Rust) → `rustc`/`cargo`/`clippy` already in image.
- `mnemosyne` (Python, SQLite-backed) → `python3` in image; needs `sqlite` client.
- `k8s-casa` (K8s) → `curl`/`git` in image; needs `kubectl`/`go`/`skopeo`.
- `promsafe4s` (Scala) → needs `scala`/`sbt`.
- NixOS configs → `nix` CLI in image; needs `nixd`/`nixfmt-tree`.
- `investment-portfolio-manager` frontend + `mnemosyne` extensions (TypeScript/React, Vite, ESLint, vitest) → needs `nodejs` (node/npm/npx); per-project `devDependencies` provide `typescript`/`tsx`/`eslint`/`prettier`/`vite`/`vitest`.

## Package selection

Add the following entries to the existing `copyToRoot` `buildEnv` `paths` list in `pkgs/coder-workspace/default.nix`:

```nix
sops
age
scala
sbt
postgresql
sqlite
nixd
nixfmt-tree
go
skopeo
kubectl
nodejs
```

### Rationale

- `pkgs.sops` (Go binary, native age support) + `pkgs.age` (`age`/`age-keygen`): original request.
- `scala` + `sbt`: `promsafe4s` is Scala.
- `postgresql` + `sqlite`: DB clients for local dev/testing (mnemosyne is SQLite-backed; K8s apps often need `psql`).
- `nixd` + `nixfmt-tree`: Nix LSP + the formatter the repo already uses (`formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree`).
- `go`: K8s/Go tooling and `skopeo`.
- `skopeo`: push images to `registry.l.arrieta.eu` without a daemon.
- `kubectl`: work with `k8s-casa`.
- `nodejs`: node/npm/npx for TypeScript projects; per-project `npm install` brings `typescript`/`tsx`/`eslint`/`prettier`/`vite`/`vitest` at the right versions.
- `nvim` + `vim`: editor (none was present before); `vim` as a classic fallback. Per-project dotfiles (`init.lua`/`init.vim`) in the shared `/home/coder` are used if present.
- All are nixpkgs packages in the flake's pinned nixpkgs (rev `c0b0e0f`), matching the image's convention and reproducibility.

## Build / deploy host

The image is `x86_64-linux`. The local Mac is `aarch64-darwin` with no x86_64-linux remote builder, so the build runs on `llm01` (192.168.0.29, user `javier`), a Linux x86_64 host with nix 2.34.8, docker, and podman, and a checkout of `nixos-configurations` at `~/code/nixos-configurations`.

## Steps

1. **Edit** `~/code/nixos-configurations/pkgs/coder-workspace/default.nix`: add the package entries listed above to `paths = with pkgs; [...]` (grouped logically: keep the existing toolchain group, add the new packages).
2. **Commit + push** to GitHub (`origin main`).
3. **Build** on llm01 (192.168.0.29, user `javier`):
   ```sh
   ssh javier@192.168.0.29 'cd ~/code/nixos-configurations && git pull && nix build .#coder-workspace'
   ```
   Produces `result` (a docker-archive tarball).
4. **Load, tag, push** on llm01:
   ```sh
   SHORT_SHA=$(ssh javier@192.168.0.29 'cd ~/code/nixos-configurations && git rev-parse --short HEAD')
   ssh javier@192.168.0.29 "docker load -i result && docker tag coder-workspace:pinned registry.l.arrieta.eu/coder-workspace:${SHORT_SHA} && docker push registry.l.arrieta.eu/coder-workspace:${SHORT_SHA}"
   ```
   (Registry credential supplied interactively at the `docker push` prompt; not recorded.)
5. **Update template default** `coder-templates/templates/podman-template/main.tf:134`:
   ```
   default = "registry.l.arrieta.eu/coder-workspace:<short-sha>"
   ```
   Commit in `coder-templates`.
6. **Push template** and **update + restart** the workspace:
   ```sh
   coder templates push podman-template --directory coder/templates/podman-template --yes
   coder update <workspace>
   # then restart for the new image/cmd to take effect
   ```

## Verification

On llm01 (or any host with docker):
```sh
IMG=registry.l.arrieta.eu/coder-workspace:<short-sha>
docker run --rm "$IMG" sops --version
docker run --rm "$IMG" age --version
docker run --rm "$IMG" scala -version
docker run --rm "$IMG" sbt --version
docker run --rm "$IMG" psql --version
docker run --rm "$IMG" sqlite3 --version
docker run --rm "$IMG" nixd --version
docker run --rm "$IMG" go version
docker run --rm "$IMG" skopeo --version
docker run --rm "$IMG" kubectl version --client
docker run --rm "$IMG" node --version && npm --version
```
Re-confirm the bash/fish interactive guards are unaffected (the image's `/etc/bashrc` and `/etc/profile` are not touched by this change), and that the new tag ends in the short sha.

## Risk / rollback

- The change only adds packages; no existing behavior is modified.
- Rollback: revert the nix edit, rebuild, retag, and point `workspace_image` back to the previous tag.
