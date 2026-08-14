# bash Login Shell with exec-fish Handoff — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set `/bin/bash` as the `coder` user's login shell in the `coder-workspace` image and `exec fish` only for interactive TTY sessions, so VS Code Remote-SSH's non-interactive piped-stdin connection stops timing out (microsoft/vscode-remote-release#2509) while interactive sessions keep fish.

**Architecture:** All changes live in `pkgs/coder-workspace/default.nix` (image build) because the template mounts `/home/coder` from an external bind volume that shadows image-baked home files — the handoff must go in `/etc/bashrc` (bash's `SYS_BASHRC`). After the code change: build the image, push it to the private registry under a new short-sha tag, point the podman-template `workspace_image` at it, update the workspace, and verify VS Code connects.

**Tech Stack:** Nix (dockerTools.buildImage), bash/fish, Coder podman-template (HCL), private registry `registry.l.arrieta.eu`.

## Global Constraints

- Only edit `pkgs/coder-workspace/default.nix` in `/Users/javier/code/nixos-configurations`; do NOT touch the fish package override (lines 1-28) or any other image content.
- The fish handoff guard MUST be `[[ -o interactive ]] && [[ -t 0 ]] && command -v fish >/dev/null 2>&1` — it must never `exec fish` for non-interactive piped-stdin shells (that is the VS Code path).
- Do NOT add a musl loader at `/lib` (existing constraint; the VS Code CLI's musl probe would select the Alpine server). Leave the glibc wiring untouched.
- In the Nix `''...''` string, avoid `${` inside the bash heredoc (Nix interpolation); the guard uses none.
- The login shell change is `--shell /bin/fish` → `--shell /bin/bash` for `useradd coder`.
- `/etc/shells` must contain both `/bin/bash` and `/bin/fish`.
- `config.Env` `SHELL=/bin/fish` → `SHELL=/bin/bash`.

---
### Task 1: Edit the image definition (bash login shell + /etc/bashrc handoff)

**Files:**
- Modify: `pkgs/coder-workspace/default.nix:88` (login shell)
- Modify: `pkgs/coder-workspace/default.nix:90` (`/etc/shells`)
- Modify: `pkgs/coder-workspace/default.nix` (add `/etc/bashrc` in `runAsRoot`)
- Modify: `pkgs/coder-workspace/default.nix:149` (`Env.SHELL`)

**Interfaces:**
- Consumes: existing `runAsRoot` block and `config` block in `default.nix`.
- Produces: an image whose `/etc/passwd` gives `coder` shell `/bin/bash`, whose `/etc/shells` lists bash and fish, whose `/etc/bashrc` hands interactive TTY sessions to fish, and whose `Env.SHELL` is `/bin/bash`.

- [ ] **Step 1: Change the login shell**

In `runAsRoot`, change line 88:

```nix
useradd --uid 1000 --gid 1000 --create-home --home-dir /home/coder --shell /bin/fish coder
```

to:

```nix
useradd --uid 1000 --gid 1000 --create-home --home-dir /home/coder --shell /bin/bash coder
```

- [ ] **Step 2: Register both shells in `/etc/shells`**

Change line 90:

```nix
echo /bin/fish >> /etc/shells
```

to:

```nix
echo /bin/bash >> /etc/shells
echo /bin/fish >> /etc/shells
```

- [ ] **Step 3: Add `/etc/bashrc` with the fish handoff**

In `runAsRoot`, immediately after the `echo /bin/fish >> /etc/shells` line (before `mkdir -p /tmp /run /etc`), add a heredoc writing bash's system rc. Use `''...''`-safe content (no `${`):

```nix
    cat > /etc/bashrc <<'EOF'
# Hand off interactive TTY sessions to fish; VS Code Remote-SSH spawns a
# non-interactive piped-stdin shell and must stay on bash.
if [[ -o interactive ]] && [[ -t 0 ]] && command -v fish >/dev/null 2>&1; then
  exec fish
fi
EOF
```

The 4-space Nix `''...''` indentation applies to the whole `runAsRoot` string; the heredoc body is indented 4 spaces like the other `cat > ... <<'EOF'` blocks.

- [ ] **Step 4: Change `Env.SHELL`**

In the `config` block, change line 149:

```nix
"SHELL=/bin/fish"
```

to:

```nix
"SHELL=/bin/bash"
```

- [ ] **Step 5: Sanity-check the Nix string escaping**

Run:

```bash
grep -n 'cat > /etc/bashrc' -A8 pkgs/coder-workspace/default.nix
```

Expected: the heredoc contains no `${` and no `\$`; the guard reads `[[ -o interactive ]] && [[ -t 0 ]] && command -v fish >/dev/null 2>&1`.

- [ ] **Step 6: Commit**

```bash
git add pkgs/coder-workspace/default.nix
git commit -m "fix(coder-workspace): bash login shell with exec-fish handoff for interactive TTYs"
```

---
### Task 2: Build the image and verify the shell wiring in the layer

**Files:**
- Test: `nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace`

**Interfaces:**
- Consumes: Task 1 changes.
- Produces: a verified image tarball at `result` with correct `/etc/passwd`, `/etc/shells`, `/etc/bashrc`, and `Env.SHELL`.

- [ ] **Step 1: Build the image**

Run (on a machine able to build `x86_64-linux` — the same host used for the previous image builds):

```bash
nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace --print-build-logs
```

Expected: build succeeds, `result` symlink points to the image tarball.

- [ ] **Step 2: Load and inspect the layer**

```bash
docker load -i result
docker run --rm --entrypoint sh coder-workspace:pinned -c \
  'grep coder /etc/passwd; echo "--- shells:"; cat /etc/shells; echo "--- bashrc:"; cat /etc/bashrc; echo "--- env:"; env | grep ^SHELL='
```

Expected output:
- passwd: `coder:x:1000:1000::/home/coder:/bin/bash`
- shells: contains both `/bin/bash` and `/bin/fish`
- bashrc: the guard block
- env: `SHELL=/bin/bash`

(If `docker` isn't available, use `podman load -i result` / `podman run` or `skopeo copy docker-archive:result docker://...`.)

- [ ] **Step 3: Verify non-interactive piped shell stays bash (the VS Code path)**

```bash
docker run --rm --entrypoint sh coder-workspace:pinned -c 'echo hi | bash -c "echo running:\$0; type -t command"'
```

Expected: prints `running:bash` and `builtin` — bash, no fish handoff (no TTY, non-interactive).

- [ ] **Step 4: Verify interactive TTY shell execs fish**

```bash
docker run --rm -it --entrypoint bash coder-workspace:pinned -c 'echo \$0; command -v fish; echo $$'
```

Expected: `$0` prints `fish` (bash exec'd fish). If `-it` is unavailable in the environment, confirm instead with `docker run --rm -e PS1=x --entrypoint bash coder-workspace:pinned -ic 'echo \$0'` expecting `fish`.

- [ ] **Step 5: Commit nothing further** (image is untracked build output; `result` is gitignored) — confirm with `git status` that only the Task 1 commit exists.

---
### Task 3: Push the image, point the template at it, update the workspace

**Files:**
- Modify: `/Users/javier/code/coder-templates/templates/podman-template/main.tf:134` (`workspace_image` default)
- Test: push to registry, `coder template push`, `coder update`, VS Code reconnect.

**Interfaces:**
- Consumes: Task 2 verified image.
- Produces: `registry.l.arrieta.eu/coder-workspace:<short-sha>` tag in use by the running workspace.

- [ ] **Step 1: Determine the tag**

Run: `git rev-parse --short HEAD` in `/Users/javier/code/nixos-configurations`. Use the output as `<short-sha>`.

- [ ] **Step 2: Load and push the image**

Authenticate to the registry with the dedicated push credential before pushing; do not record it in shell history or the plan.

```bash
nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace
docker load -i result
docker tag coder-workspace:pinned registry.l.arrieta.eu/coder-workspace:<short-sha>
docker push registry.l.arrieta.eu/coder-workspace:<short-sha>
```

(If the local docker daemon isn't configured, use `podman load`/`podman push` or `skopeo copy docker-archive:result docker://registry.l.arrieta.eu/coder-workspace:<short-sha>`.)

- [ ] **Step 3: Update the template image reference**

Edit `/Users/javier/code/coder-templates/templates/podman-template/main.tf:134`:

```hcl
  default      = "registry.l.arrieta.eu/coder-workspace:<short-sha>"
```

- [ ] **Step 4: Push the template and update the workspace**

```bash
coder templates push podman-template --directory templates/podman-template --yes
coder update llm01
```

(Push alone does not upgrade existing workspaces; the workspace must be updated — a plain restart keeps the old image.)

- [ ] **Step 5: Verify the container uses the new image**

On the Podman host:

```sh
podman inspect coder-llm01 --format '{{json .Config.Image}}'
podman inspect coder-llm01 --format '{{json .Config.Env}}'
```

Expected: image ends in `<short-sha>`; `Env` contains `SHELL=/bin/bash`.

- [ ] **Step 6: Commit the template bump**

```bash
git -C /Users/javier/code/coder-templates add templates/podman-template/main.tf
git -C /Users/javier/code/coder-templates commit -m "fix(podman-template): point workspace_image to bash-login-shell build <short-sha>"
```

---
### Task 4: Verify VS Code Remote-SSH connects

**Files:**
- Test: VS Code Remote-SSH connection to the updated workspace.

**Interfaces:**
- Consumes: Task 3 updated workspace.
- Produces: a passing end-to-end check that the original timeout is gone.

- [ ] **Step 1: Verify interactive shell still yields fish**

```sh
ssh coder-vscode.coder.home.arrieta.eu--javierarrieta--llm01.main -t 'echo $0'
```

Expected: prints `fish` (interactive TTY → bash → exec fish).

- [ ] **Step 2: Verify the VS Code path stays bash (non-interactive)**

```sh
ssh coder-vscode.coder.home.arrieta.eu--javierarrieta--llm01.main 'echo $0'
```

Expected: prints `bash` — the piped-stdin/non-interactive path must NOT exec fish.

- [ ] **Step 3: Reconnect VS Code Remote-SSH**

Open the workspace in VS Code via Remote-SSH. Expected: the `Connecting with SSH timed out` error is gone and the window opens. Confirm the integrated terminal opens fish.

- [ ] **Step 4: Commit any follow-up doc note (if README should mention the fish handoff)**

If the README in `coder-templates` should note the login-shell behavior, add a short paragraph to `templates/podman-template/README.md` and commit it. Otherwise skip.
