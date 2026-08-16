# coder-workspace dev tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `sops`, `age`, and project-stack tooling (`scala`, `sbt`, `postgresql`, `sqlite`, `nixd`, `nixfmt-tree`, `go`, `skopeo`, `kubectl`, `nodejs`) to the `coder-workspace` Docker image, build it on `llm01`, push to the private registry under a new short-sha tag, and point the podman template at it.

**Architecture:** Edit the single Nix file `pkgs/coder-workspace/default.nix` to add packages to the `copyToRoot` `buildEnv` `paths` list. Build the image on `llm01` (192.168.0.29, user `javier`, Linux x86_64 with nix/docker/podman), load it, retag with `git rev-parse --short HEAD`, push to `registry.l.arrieta.eu/coder-workspace:<short-sha>`, then bump the `workspace_image` default in `coder-templates/.../main.tf` and push the template.

**Tech Stack:** Nix (flakes, `dockerTools.buildImage`), Docker, bash, the `coder` CLI, GitHub.

## Global Constraints

- Build host is `llm01` (192.168.0.29, user `javier`); the Mac (`aarch64-darwin`) cannot build the x86_64-linux image.
- nixpkgs revision pinned by `flake.lock` (`c0b0e0f`); all added packages must exist in that revision (verified).
- No key material baked into the image; `sops`/`age` keys come from Coder secrets/mounts at runtime.
- Registry credential supplied interactively at `docker push`; never recorded.
- `disk_gb` is immutable after workspace creation; `workspace_image` is mutable.
- After changing the template or image, must `coder update <workspace>` + restart (a plain restart keeps the old image).
- Verify the bash/fish interactive guards still behave (`/etc/bashrc`, `/etc/profile` are not touched by this change).

---

### Task 1: Add packages to the image

**Files:**
- Modify: `pkgs/coder-workspace/default.nix:35-79` (the `paths = with pkgs; [...]` list)

**Interfaces:**
- Produces: a `coder-workspace` image derivation whose `copyToRoot` includes the new packages.

- [ ] **Step 1: Add the new package entries**

Add the following entries to the `paths` list in `pkgs/coder-workspace/default.nix`. Insert them after `procps` (the last entry, line 78), before the closing `];`:

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

- [ ] **Step 2: Commit the nix change**

```bash
cd ~/code/nixos-configurations
git add pkgs/coder-workspace/default.nix
git commit -q -m "feat(coder-workspace): add sops, age, scala, sbt, postgresql, sqlite, nixd, nixfmt-tree, go, skopeo, kubectl, nodejs"
git push
```

### Task 2: Build the image on llm01

**Files:**
- Builds: `result` (docker-archive tarball) on llm01

**Interfaces:**
- Consumes: the pushed nix change.
- Produces: `result` tarball + the short-sha tag.

- [ ] **Step 1: Pull the change and build on llm01**

```bash
ssh javier@192.168.0.29 'cd ~/code/nixos-configurations && git pull && nix build .#coder-workspace'
```
Expected: `result` symlink appears, pointing to a `.tar.gz` docker-archive.

- [ ] **Step 2: Capture the short-sha**

```bash
SHORT_SHA=$(ssh javier@192.168.0.29 'cd ~/code/nixos-configurations && git rev-parse --short HEAD')
echo "$SHORT_SHA"
```

### Task 3: Load, tag, and push the image

**Files:**
- Pushes: `registry.l.arrieta.eu/coder-workspace:<short-sha>`

**Interfaces:**
- Consumes: `result` tarball + short-sha from Task 2.
- Produces: the published image tag.

- [ ] **Step 1: Load, tag, and push**

```bash
ssh javier@192.168.0.29 "docker load -i result && docker tag coder-workspace:pinned registry.l.arrieta.eu/coder-workspace:${SHORT_SHA} && docker push registry.l.arrieta.eu/coder-workspace:${SHORT_SHA}"
```
Expected: `docker push` prompts for registry credentials (supplied interactively); then uploads layers; finishes with `latest: digest: sha256:... status: pushed`.

- [ ] **Step 2: Confirm the tag exists in the registry**

```bash
ssh javier@192.168.0.29 "skopeo inspect docker://registry.l.arrieta.eu/coder-workspace:${SHORT_SHA} | head -5"
```

### Task 4: Update the template default and push

**Files:**
- Modify: `coder-templates/templates/podman-template/main.tf:134`

**Interfaces:**
- Consumes: the short-sha from Task 2.
- Produces: the updated template pushed to Coder.

- [ ] **Step 1: Update the `workspace_image` default**

Edit `coder-templates/templates/podman-template/main.tf` line 134:

```diff
-   default      = "registry.l.arrieta.eu/coder-workspace:6fd2505"
+   default      = "registry.l.arrieta.eu/coder-workspace:<short-sha>"
```
Replace `<short-sha>` with the actual value from Task 2.

- [ ] **Step 2: Commit and push the template**

```bash
cd ~/code/coder-templates
git add templates/podman-template/main.tf
git commit -q -m "fix(podman-template): point workspace_image to dev-tooling build <short-sha>"
git push
```

- [ ] **Step 3: Push the template to Coder**

```bash
coder login <coder url>
coder templates push podman-template --directory coder/templates/podman-template --yes
```

### Task 5: Update and restart the workspace

**Files:**
- Updates the running workspace

**Interfaces:**
- Consumes: the pushed template from Task 4.
- Produces: the workspace running the new image.

- [ ] **Step 1: Update and restart the workspace**

```bash
coder update <workspace>
coder restart <workspace>
```
A plain restart keeps the old image; the `update` applies the new template version, then `restart` applies the new image.

### Task 6: Verify the new image

**Files:**
- Verifies: the published image

**Interfaces:**
- Consumes: the published image tag.

- [ ] **Step 1: Run version checks against the new image**

```bash
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
docker run --rm "$IMG" node --version
docker run --rm "$IMG" npm --version
```
Expected: every command prints a version with no errors.

- [ ] **Step 2: Re-confirm the bash/fish interactive guards**

```bash
docker run --rm --entrypoint sh "$IMG" -c 'echo hi | bash -c "echo running:\$0; type -t command"'   # expect: running:bash
docker run --rm -it --entrypoint bash "$IMG" -c 'echo $0'                                            # expect: fish
```
