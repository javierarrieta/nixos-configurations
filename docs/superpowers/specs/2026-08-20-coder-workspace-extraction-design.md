# Design: Extract coder-workspace image generation to a separate project

Date: 2026-08-20

## Problem

The `coder-workspace` container image (NixOS-based dev workspace for Coder
podman workspaces on llm01) is defined inside the `nixos-configurations`
infrastructure repo as `pkgs/coder-workspace/default.nix`. It is
self-contained — it only needs `nixpkgs` — yet it is coupled to the infra
repo's `flake.lock`, CI, and tag history. It is the only infra package whose
output is a Docker image, and its rebuild cadence is unrelated to host
configuration. Extract it to its own GitHub repo with its own flake, CI, and
tag history.

## Decisions (agreed with user)

- New GitHub repo: `github.com/javierarrieta/coder-workspaces` (plural — room for
  more workspace images).
- Canonical publish target: GHCR only, image name **`coder-workspaces-nix`**
  (`ghcr.io/javierarrieta/coder-workspaces-nix`). Renamed from the original
  `coder-workspace` so the new repo's package does not collide with the infra
  repo's still-live `coder-workspace` GHCR package until the infra workflow is
  removed. The private LAN registry (`registry.l.arrieta.eu`) is NOT used by the
  new project; the podman template consumer must be repointed (follow-up, out
  of scope for this repo).
- Remove all touchpoints from `nixos-configurations` in the same change.

## Current state

Coupling points in `nixos-configurations`:

| Touchpoint | Path | Action |
|---|---|---|
| Derivation | `pkgs/coder-workspace/default.nix` | Move to new repo as `image.nix` |
| Flake entry | `flake.nix:560-562` | Remove |
| CI workflow | `.github/workflows/workspace-image.yml` | Remove (ported to new repo) |
| Tag history | `IMAGE_TAGS.md` | Remove (start fresh in new repo) |
| Docs | `AGENTS.md` workspace-image bullet | Update |
| Specs/plans | `docs/superpowers/*` | Keep as history |

The derivation only consumes `pkgs` (via `import ./pkgs/coder-workspace { pkgs = nixpkgs.legacyPackages.x86_64-linux; }`). No SOPS, no host modules, no
other infra packages. Copied verbatim — the internal docker image name stays
`coder-workspace`; the external GHCR package is published as `coder-workspaces-nix`.

## New repo layout

```
coder-workspaces/
├── flake.nix
├── flake.lock
├── image.nix          # moved pkgs/coder-workspace/default.nix verbatim ({ pkgs }: ...)
├── .github/workflows/build.yml
├── IMAGE_TAGS.md
├── README.md
└── .gitignore         # /result
```

The repo is created at `gh repo create javierarrieta/coder-workspaces` and worked
on in a clone at `/home/coder/.cache/coder-workspaces` (the sandbox uid cannot
write under `/home/coder` directly; `.cache` is writable).

### flake.nix

```nix
{
  description = "Coder workspace container images";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      packages.x86_64-linux.default = import ./image.nix { inherit pkgs; };
      packages.x86_64-linux.coder-workspaces-nix = self.packages.x86_64-linux.default;
      formatter.x86_64-linux = pkgs.nixfmt-tree;
    };
}
```

### Lock seeding

Seed `flake.lock` to the infra repo's current nixpkgs rev so the first build
is byte-identical to the infra-era image:

```bash
nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/c0b0e0fddf73fd517c3471e546c0df87a42d53f4
```

The `nixos-unstable` ref remains floating (matches infra behavior); future
drift is controlled by `nix flake update`.

### CI workflow (`build.yml`)

Ported from the current `workspace-image.yml`:

- Triggers: push to `main` touching `image.nix`, `flake.lock`, or the workflow;
  plus `workflow_dispatch`.
- Permissions: `contents: write`, `packages: write`.
- Steps:
  1. `actions/checkout@v4` with `fetch-depth: 0`
  2. `DeterminateSystems/nix-installer-action@v22`
  3. `DeterminateSystems/magic-nix-cache-action@v14`
  4. `nix build .#coder-workspaces-nix --option system-features "benchmark big-parallel kvm nixos-test uid-range"`
  5. Compute tag `YYYYMMDD-<short-sha>` (SHA of the new repo commit)
  6. `docker load -i result`; tag `coder-workspace:pinned` → `ghcr.io/javierarrieta/coder-workspaces-nix:$TAG` and `:latest`
  7. `docker login ghcr.io` with `GITHUB_TOKEN`; push both tags
  8. Append row to `IMAGE_TAGS.md`, commit `docs: record workspace image tag ...` via `github-actions[bot]`, push

### IMAGE_TAGS.md

Start fresh. Old rows reference infra-repo SHAs and LAN-registry tags, which
have no rollback value in the GHCR world. Note in the README that pre-2026-08
builds lived in the infra repo.

## Infra repo changes (single commit)

1. `git rm pkgs/coder-workspace/` (whole dir)
2. `git rm .github/workflows/workspace-image.yml`
3. `git rm IMAGE_TAGS.md`
4. `flake.nix`: remove the `packages.x86_64-linux.coder-workspaces-nix = ...` block
5. `AGENTS.md`: update the Coder "Workspace image" bullet to point at
   `ghcr.io/javierarrieta/coder-workspaces-nix` and the new repo
6. Verify: `nix flake check` (or eval of `.#nixosConfigurations.<host>`) still
   evaluates; run `nixfmt .`

## Follow-ups (not in this repo)

1. `coder-templates` podman-template: repoint `workspace_image` default from
   `registry.l.arrieta.eu/coder-workspace:6fd2505` to
   `ghcr.io/javierarrieta/coder-workspaces-nix`, using the first tag produced by the
   new repo's CI run. Requires:
   - internet egress from llm01 (rootless podman pulls via Docker provider)
   - GHCR image readable (public visibility, or `registry_auth` in the
     template pointing at GHCR)
2. Old private-registry tags remain but become orphaned.

## Risks / mitigations

| Risk | Mitigation |
|---|---|
| nixpkgs drift between image and infra hosts | Lock seeded to same rev; both float on `nixos-unstable`; parity checked on image rebuilds |
| fish alias config duplicated across repos | README note; aliases are stable shell niceties, low drift sensitivity |
| GHCR egress/auth unknown for cluster | Flagged as consumer follow-up decision |
| Broken infra flake after removal | `nix flake check` before commit; removal is additive-free (no consumer in infra repo) |