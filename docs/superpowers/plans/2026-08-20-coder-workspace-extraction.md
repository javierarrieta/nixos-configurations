# Extract coder-workspace image to separate repo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `coder-workspace` container image out of `nixos-configurations` into a new self-contained repo `github.com/javierarrieta/coder-workspaces` with its own flake, GHCR-only CI, and tag history; then remove every touchpoint from the infra repo.

**Architecture:** New repo holds the derivation (`image.nix`), a minimal flake exposing `packages.x86_64-linux.coder-workspace`, a GitHub Actions workflow that builds the image and pushes `YYYYMMDD-<short-sha>` + `latest` to `ghcr.io/javierarrieta/coder-workspace`, and a fresh `IMAGE_TAGS.md`. Infra repo deletes `pkgs/coder-workspace/`, the old workflow, `IMAGE_TAGS.md`, and the flake entry. Consumer repoint (`coder-templates`) is a flagged follow-up, not part of this repo's change.

**Tech Stack:** Nix flake, `dockerTools.buildImage`, GitHub Actions (DeterminateSystems actions), GHCR, git/gh CLI.

**Spec:** `docs/superpowers/specs/2026-08-20-coder-workspace-extraction-design.md`

## Global Constraints

- New GitHub repo: `github.com/javierarrieta/coder-workspaces` (plural).
- Canonical publish target: GHCR only — `ghcr.io/javierarrieta/coder-workspace`. No LAN registry pushes.
- New repo local path: `/home/coder/coder-workspaces`.
- Seed new `flake.lock` nixpkgs to infra's current rev: `c0b0e0fddf73fd517c3471e546c0df87a42d53f4` (`github:NixOS/nixpkgs/nixos-unstable` ref).
- Derivation `image.nix` copied verbatim from `pkgs/coder-workspace/default.nix` (takes `{ pkgs }`).
- Infra repo: remove ALL touchpoints in one commit on branch `feat/coder-workspace-extraction` (`git rm pkgs/coder-workspace/`, `.github/workflows/workspace-image.yml`, `IMAGE_TAGS.md`; drop `flake.nix` package entry; update `AGENTS.md`).
- `docs/superpowers/*` in the infra repo stay as history (do NOT delete).
- No `nixfmt` binary in PATH — use the flake formatter (`nix run .#formatter`).

---

### Task 1: Scaffold new repo, flake, and seeded lock; local build

**Files:**
- Create: `/home/coder/coder-workspaces/flake.nix`
- Create: `/home/coder/coder-workspaces/image.nix`
- Create: `/home/coder/coder-workspaces/.gitignore`
- Create: `/home/coder/coder-workspaces/flake.lock` (generated, seeded)
- Create: GitHub repo `javierarrieta/coder-workspaces`

**Interfaces:**
- Consumes: `nixos-configurations/pkgs/coder-workspace/default.nix` (moved verbatim).
- Produces: flake with `packages.x86_64-linux.coder-workspace` and `packages.x86_64-linux.default` (Task 2's workflow builds `.#coder-workspace`).

- [ ] **Step 1: Create the GitHub repo**

```bash
mkdir -p /home/coder/coder-workspaces
cd /home/coder/coder-workspaces
git init -b main
gh repo create javierarrieta/coder-workspaces --private --source .
```

Expected: remote `origin` set to `https://github.com/javierarrieta/coder-workspaces.git` (created but nothing pushed — Step 7 pushes).

- [ ] **Step 2: Copy the derivation verbatim**

```bash
cp /home/coder/nixos-configurations/pkgs/coder-workspace/default.nix \
   /home/coder/coder-workspaces/image.nix
```

Expected: `image.nix` byte-identical to the source (`diff` returns 0).

- [ ] **Step 3: Write `flake.nix`**

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
      packages.x86_64-linux.coder-workspace = self.packages.x86_64-linux.default;
      formatter.x86_64-linux = pkgs.nixfmt-tree;
    };
}
```

- [ ] **Step 4: Write `.gitignore`**

```gitignore
/result
```

- [ ] **Step 5: Seed the lock to infra's nixpkgs rev**

```bash
cd /home/coder/coder-workspaces
nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/c0b0e0fddf73fd517c3471e546c0df87a42d53f4
```

Expected: `flake.lock` created; `grep -A5 '"nixpkgs"' flake.lock` shows `"rev": "c0b0e0fddf73fd517c3471e546c0df87a42d53f4"`.

- [ ] **Step 6: Verify the build locally**

```bash
cd /home/coder/coder-workspaces
nix build .#coder-workspace
file result
```

Expected: build succeeds (store paths largely cached — same derivation and nixpkgs as the infra-era build); `file result` reports a tar/gzip archive. If the build fails, debug the derivation here before proceeding.

- [ ] **Step 7: Commit and push initial files**

```bash
cd /home/coder/coder-workspaces
git add flake.nix flake.lock image.nix .gitignore
git commit -m "feat: initial coder-workspace image flake"
git push -u origin main
```

Expected: `git log --oneline -1` shows the commit; push succeeds.

---

### Task 2: CI workflow, tag history, README; push and verify GHCR

**Files:**
- Create: `/home/coder/coder-workspaces/.github/workflows/build.yml`
- Create: `/home/coder/coder-workspaces/IMAGE_TAGS.md`
- Create: `/home/coder/coder-workspaces/README.md`

**Interfaces:**
- Consumes: Task 1's flake (`.#coder-workspace`), GHCR namespace `ghcr.io/javierarrieta/coder-workspace`.
- Produces: GHCR images tagged `YYYYMMDD-<short-sha>` + `latest`; `IMAGE_TAGS.md` history rows.

- [ ] **Step 1: Write `.github/workflows/build.yml`**

```yaml
name: build-image

on:
  push:
    branches: [main]
    paths:
      - "image.nix"
      - "flake.lock"
      - ".github/workflows/build.yml"
  workflow_dispatch:

permissions:
  contents: write
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: DeterminateSystems/nix-installer-action@v22
      - uses: DeterminateSystems/magic-nix-cache-action@v14

      - name: Build image
        run: |
          nix build .#coder-workspace \
            --option system-features "benchmark big-parallel kvm nixos-test uid-range"

      - name: Compute tag
        id: tag
        run: |
          SHA=$(git rev-parse --short HEAD)
          DATE=$(date -u +%Y%m%d)
          echo "tag=${DATE}-${SHA}" >> "$GITHUB_OUTPUT"
          echo "date=$(date -u +%Y-%m-%d)" >> "$GITHUB_OUTPUT"

      - name: Load and tag
        run: |
          docker load -i result
          docker tag coder-workspace:pinned ghcr.io/javierarrieta/coder-workspace:${{ steps.tag.outputs.tag }}
          docker tag ghcr.io/javierarrieta/coder-workspace:${{ steps.tag.outputs.tag }} ghcr.io/javierarrieta/coder-workspace:latest

      - name: Push to GHCR
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
          docker push ghcr.io/javierarrieta/coder-workspace:${{ steps.tag.outputs.tag }}
          docker push ghcr.io/javierarrieta/coder-workspace:latest

      - name: Record tag in IMAGE_TAGS.md
        run: |
          PREV=$(grep -oP '^\| [0-9]{8}-[0-9a-f]{7} \| [0-9]{4}-[0-9]{2}-[0-9]{2} \| \K[0-9a-f]{40}' IMAGE_TAGS.md | head -1)
          if [ -n "$PREV" ]; then
            CHANGES=$(git log --oneline --no-merges "$PREV"..HEAD | cut -d' ' -f2- | paste -sd'; ')
          else
            CHANGES="initial build"
          fi
          printf '| %s | %s | %s | %s |\n' \
            "${{ steps.tag.outputs.tag }}" \
            "${{ steps.tag.outputs.date }}" \
            "${{ github.sha }}" \
            "$CHANGES" >> IMAGE_TAGS.md
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add IMAGE_TAGS.md
          git commit -m "docs: record workspace image tag ${{ steps.tag.outputs.tag }}"
          git push
```

Note: `IMAGE_TAGS.md` is deliberately NOT in the trigger `paths`, so the workflow's own tag-record commit does not re-trigger a build (no loop).

- [ ] **Step 2: Write `IMAGE_TAGS.md` (fresh history)**

```markdown
# Workspace image tags

Immutable tags are pushed to `ghcr.io/javierarrieta/coder-workspace` as
`YYYYMMDD-<short-sha>`; the `latest` tag points at the newest build. Tags are
never overwritten, so pinning `workspace_image` to an older row rolls back.

Note: pre-2026-08 builds lived in the `javierarrieta/nixos-configurations` repo
and were pushed to `registry.l.arrieta.eu`; those tags are orphaned here.

| tag | date | commit | changes |
|---|---|---|---|
```

- [ ] **Step 3: Write `README.md`**

```markdown
# coder-workspaces

Nix-built Coder workspace container images.

## Current image: coder-workspace

`ghcr.io/javierarrieta/coder-workspace` — immutable tags `YYYYMMDD-<short-sha>`
plus `latest` (see IMAGE_TAGS.md).

## Build locally

    nix build .#coder-workspace

## Publish

Pushes to `main` touching `image.nix`, `flake.lock`, or
`.github/workflows/build.yml` trigger a GHCR push (GitHub Actions).

## Consume

The `coder-templates` repo's `llm01-podman` template pins `workspace_image`.
Repoint it to `ghcr.io/javierarrieta/coder-workspace:<tag>`. Cluster pulls
need the GHCR image public-readable (or `registry_auth` in the template).
```

- [ ] **Step 4: Commit and push**

```bash
cd /home/coder/coder-workspaces
git add .github/workflows/build.yml IMAGE_TAGS.md README.md
git commit -m "ci: GHCR build-and-push workflow, tag history, README"
git push
```

- [ ] **Step 5: Verify the CI run goes green**

```bash
cd /home/coder/coder-workspaces
gh run list --limit 1
gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: run completes with success. If the "Push to GHCR" step fails with `denied: permission_denied`, confirm the package is writable by the repo's default `GITHUB_TOKEN` (it is, via the `packages: write` permission) and re-run with `gh run rerun`.

- [ ] **Step 6: Confirm the tag exists on GHCR**

```bash
cd /home/coder/coder-workspaces
gh api user/packages/container/coder-workspace/versions --jq '.[0].name, .[0].metadata.container.tags[]'
```

Expected: prints the latest version's tag `YYYYMMDD-<sha>` and `latest`.

Note (follow-up, not blocking CI): make the GHCR package public so cluster
pulls work — GitHub UI: Packages → `coder-workspace` → Package settings →
Change visibility → Public. Only needed when `coder-templates` actually pulls
from GHCR.

---

### Task 3: Clean up the infra repo (remove all touchpoints)

**Files:**
- Delete: `pkgs/coder-workspace/` (whole dir)
- Delete: `.github/workflows/workspace-image.yml`
- Delete: `IMAGE_TAGS.md`
- Modify: `flake.nix` (remove the `packages.x86_64-linux.coder-workspace` block, lines 560-562)
- Modify: `AGENTS.md` (Workspace image bullet)
- Test: `nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace`

**Interfaces:**
- Consumes: Task 1 + Task 2 verified the image builds/pushes from the new repo.
- Produces: `feat/coder-workspace-extraction` branch commit removing the old image from the infra repo.

- [ ] **Step 1: Work on the feat branch**

```bash
cd /home/coder/nixos-configurations
git checkout feat/coder-workspace-extraction
```

Expected: branch `feat/coder-workspace-extraction` checked out (it already holds the design-doc commit `647d8fb`).

- [ ] **Step 2: Remove the old touchpoints**

```bash
git rm -r pkgs/coder-workspace
git rm .github/workflows/workspace-image.yml
git rm IMAGE_TAGS.md
```

Expected: three deletions staged, `git status` shows them.

- [ ] **Step 3: Remove the flake entry**

Edit `flake.nix`, delete these lines (560-562):

```nix
      packages.x86_64-linux.coder-workspace = import ./pkgs/coder-workspace {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      };
```

Expected: `grep -n 'coder-workspace' flake.nix` returns nothing.

- [ ] **Step 4: Update `AGENTS.md`**

Find the bullet (line ~441):

```markdown
- **Workspace image**: `registry.l.arrieta.eu/coder-workspace:<sha>` (Nix-built,
  includes `/etc/os-release` for the Coder agent's `clistat`).
```

Replace with:

```markdown
- **Workspace image**: `ghcr.io/javierarrieta/coder-workspace:<tag>` (built in
  the `javierarrieta/coder-workspaces` repo, includes `/etc/os-release` for the
  Coder agent's `clistat`).
```

- [ ] **Step 5: Format**

```bash
cd /home/coder/nixos-configurations
nix run .#formatter -- flake.nix
```

Expected: `flake.nix` reformatted in place (if the formatter rejects a bare file path, run `nix fmt` and revert any files beyond `flake.nix` with `git checkout -- <file>`).

- [ ] **Step 6: Verify the flake still evaluates**

```bash
cd /home/coder/nixos-configurations
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
```

Expected: evaluates to a store path without `coder-workspace` references. This is the AGENTS.md-documented eval test; use a different host name if `llm01` is unavailable.

- [ ] **Step 7: Commit on the feat branch**

```bash
cd /home/coder/nixos-configurations
git add -A
git commit -m "refactor: extract coder-workspace image to coder-workspaces repo"
```

Expected: commit created on `feat/coder-workspace-extraction`. Do NOT push/merge to `main` — that is a separate decision (branch-rollout ring).

---

## Follow-ups (NOT in this plan — flagged for the `coder-templates` repo)

1. Repoint `workspace_image` default in `coder-templates` `llm01-podman` template from `registry.l.arrieta.eu/coder-workspace:6fd2505` to `ghcr.io/javierarrieta/coder-workspace:<first-new-tag>`.
2. Ensure GHCR image is public-readable (or `registry_auth` in template) and llm01 has internet egress for pulls.
3. Old `registry.l.arrieta.eu/coder-workspace:*` tags become orphaned (harmless).