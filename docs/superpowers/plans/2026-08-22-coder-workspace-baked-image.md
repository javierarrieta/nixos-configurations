# Coder Workspace Baked-Image + Config-Only HM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake all workspace software into the coder-workspaces image; reduce home-manager to a config-only switch (`nix-shell` support included); simplify the Coder template to root-boot store setup + privilege drop.

**Architecture:** Image owns every package (incl. `home-manager` CLI). The workspace container boots as root, grants uid 1000 ownership of the nix store *directories*, drops to coder via `setpriv`, starts the agent; a one-line `startup_script` applies the config-only HM flake from GitHub.

**Tech Stack:** Nix flakes, dockerTools image, home-manager, Terraform/Coder template.

**Spec:** `docs/superpowers/specs/2026-08-22-coder-workspace-baked-image-design.md`

## Global Constraints

- Image is sole software source; HM installs **zero** packages except its own shell (`unstablePkgs.fish` stays HM-managed)
- Build-time `chown` under `/nix` is forbidden (virtiofs share crashes builder VM); ownership granted only at container start
- Other hosts (oracle, macbookair, vps, NixOS hosts) must evaluate unchanged: gating reads `userOptions.configOnly or false`
- Store downloads ephemeral across workspace recreates — acceptable, documented
- Kill-switch: if runtime chown of `/nix/store` fails, drop `nix-shell` support and revert container to `user = "1000:1000"` without HM switch; rest of design proceeds
- Repos/branches: `coder-workspaces` off `main`; `nixos-configurations` off `main`; `coder-templates` branch `feature/home-manager-startup`
- Never merge with red CI; never push without explicit user instruction

---

### Task 1: Image v0.0.4 (coder-workspaces)

**Files:**
- Modify: `image.nix` (`copyToRoot.paths`, fish `overrideAttrs`, `runAsRoot`)

**Interfaces:**
- Produces: GHCR `ghcr.io/javierarrieta/coder-workspaces-nix:0.0.4` — consumed by Tasks 2/5
- Prereq for everything downstream

- [ ] **Step 0: Re-add rust stack + nodejs (PR #7 was merged)**

Where `image.nix` says `# Rust toolchain comes via rustup (home-manager), not baked in.` restore above it:

```nix
      rustc
      cargo
      rustfmt
      clippy
```

and where it says `# nodejs comes via home-manager (nodejs_24), not baked in.` replace with:

```nix
      nodejs_24
```

- [ ] **Step 1: Swap python, add missing tools**

In `copyToRoot.paths`: replace the line `python3` with `python312`; after `kubectl` add:

```nix
      starship
      btop
      lsd
      difftastic
      dyff
      fastfetch
      kubernetes-helm
      scala-cli
      kubectx
      k9s
      python312Packages.pipenv
      python312Packages.virtualenv
      python312Packages.pylint
      python312Packages.oci
      python312Packages.huggingface-hub
```

Note: if `python312Packages.X` attributes fail to eval on this nixpkgs rev,
fall back to top-level `pipenv` / `virtualenv` / `pylint` / `oci` /
`huggingface-hub` (they track the default python; acceptable deviation,
recorded in report).

- [ ] **Step 2: Add setpriv provider**

Next to `procps` add:

```nix
      procps
      util-linux
```

- [ ] **Step 3: Remove sudoers rule**

Delete from `runAsRoot`:

```nix
    # Passwordless chown for the workspace user: ...
    echo 'coder ALL=(root) NOPASSWD: /bin/chown' > /etc/sudoers.d/coder
    chmod 0440 /etc/sudoers.d/coder
```

- [ ] **Step 4: Add ca-certificates symlink + /nix/var/nix**

In `runAsRoot`, next to the other `/etc` writes:

```nix
    # nix verifies TLS against the standard path, not SSL_CERT_FILE.
    ln -sfn /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
    # nix needs a writable var dir (db, profiles); /nix/store stays untouched.
    mkdir -p /nix/var/nix
```

- [ ] **Step 5: Strip baked fish aliases**

Replace the whole `fish = pkgs.fish.overrideAttrs (old: { ... });` block with:

```nix
  # tests fail in the container build env (indent/cd/path check scripts)
  fish = pkgs.fish.overrideAttrs (old: {
    doCheck = false;
  });
```

(the interactive alias/conf.d block moves to the HM-managed fish config)

- [ ] **Step 6: Verify + commit + push + PR**

```bash
nix-instantiate --parse image.nix >/dev/null && echo OK
git checkout -b fix/image-v0.0.4 && git add image.nix
git commit -m "feat: bake all workspace software, prepare for config-only HM"
git push -u origin fix/image-v0.0.4
gh pr create --base main --fill
```

Watch checks to green BEFORE merging (user gate). After merge: tag + publish
release `v0.0.4` (notes: baked software superset, hm CLI kept, openssl/setpriv
wiring, sudoers removed), watch release workflow, verify manifest:

```bash
TOK=$(curl -s "https://ghcr.io/token?scope=repository:javierarrieta/coder-workspaces-nix:pull" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -H "Authorization: Bearer $TOK" -o /dev/null -w "%{http_code}\n" \
  https://ghcr.io/v2/javierarrieta/coder-workspaces-nix/manifests/0.0.4   # expect 200
```

### Task 2: SPIKE — runtime store chown + setpriv (kill-switch)

**Files:**
- Modify (throwaway): `coder-templates/templates/podman-template/main.tf`

**Interfaces:**
- Consumes: image `0.0.4` from Task 1
- Produces: GO / NO-GO verdict recorded in this plan's checkbox; NO-GO ⇒ skip
  root-boot in Task 4 and drop nix-shell acceptance criterion

- [ ] **Step 1: Temporary template variant**

On a throwaway branch off `feature/home-manager-startup`, set
`docker_container.workspace`:

```hcl
  user        = "0:0"
  userns_mode = "keep-id:uid=1000,gid=1000"

  command = ["sh", "-c", "chown 1000:1000 /nix /nix/store && chmod u+rwx /nix/store && mkdir -p /nix/var/nix && chown -R 1000:1000 /nix/var/nix && exec setpriv --reuid=1000 --regid=1000 --init-groups sh -c ${jsonencode(coder_agent.main.init_script)}"]
```

and point `workspace_image` default at `...:0.0.4`. Do not include the HM
startup_script yet.

- [ ] **Step 2: Validate live**

Push to the `-test` template, start a workspace, then via `coder ssh llm01-test`:

```sh
ls -ld /nix/store                      # expect owner 1000:1000, mode drwxr-xr-x-ish
ls -ld /nix/var/nix                    # owner 1000:1000
touch /nix/store/.wtest && rm /nix/store/.wtest && echo WRITABLE
id                                     # uid=1000 (drop worked)
nix-shell -p hello --run hello         # downloads + runs; second call cached
ps aux | grep -c "^coder.*1000"        # agent processes run as uid 1000
```

- [ ] **Step 3: Record verdict**

GO: check this box, delete throwaway branch.
NO-GO: check box with note, inform user, apply kill-switch in Task 4
(`user = "1000:1000"`, plain init command, no HM switch, no nix-shell claims).

- [ ] **Step 4: Teardown**

`coder delete llm01-test --yes` (frees global lease for later tasks).

### Task 3: Config-only gating (nixos-configurations)

**Files:**
- Modify: `modules/home-manager/base.nix`, `modules/home-manager/shell.nix`,
  `modules/home-manager/dev-tools.nix`, `modules/home-manager/python.nix`,
  `modules/home-manager/k8s.nix`
- Modify: `home/hosts/coder-workspace/userOptions.nix`

**Interfaces:**
- Consumes: nothing new
- Produces: `userOptions.configOnly` semantics — all hosts eval unchanged when
  key absent (Task 3 Step 4 proves); coder-workspace profile contains no
  packaged software except `unstablePkgs.fish`

- [ ] **Step 1: Gate shell.nix**

Top of the module's `let` (it already binds `userOptions`):

```nix
  configOnly = userOptions.configOnly or false;
```

Wrap the packages list:

```nix
  home.packages =
    (lib.mkIf (!configOnly) (with pkgs; [
      starship
      zoxide
      fishPlugins.tide
      fishPlugins.fzf
      ncdu
    ]));
```

Gate the fish package override (keep HM managing fish itself — the shell must
match the config):

```nix
  programs.fish = {
    enable = true;
    package = if configOnly then pkgs.fish else unstablePkgs.fish;
```

(leave every other `programs.*` block untouched)

- [ ] **Step 2: Gate dev-tools.nix**

Add `userOptions, lib` to the module args if missing; define `configOnly`
identically. Wrap:

```nix
  home.packages = lib.mkIf (!configOnly) (with pkgs; [
    htop
    # ... unchanged list ...
    hugo
  ]);

  programs.neovim = lib.mkIf (!configOnly) {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    withPython3 = false;
    withRuby = false;
  };
```

- [ ] **Step 3: Gate base.nix, python.nix and k8s.nix**

base.nix — gate the nixd package (image provides nixd):

```nix
  home.packages = lib.mkIf (!isPiNode && !(userOptions.configOnly or false))
    (with pkgs; [ nixd ]);
```

python.nix:

```nix
  home.packages = lib.mkIf (!configOnly) (with pkgs; [
    python
    pipenv
    pythonPackages.virtualenv
    pythonPackages.uv
    pythonPackages.pylint
    pythonPackages.oci
    pythonPackages.huggingface-hub
  ]);
```

k8s.nix (whole module body):

```nix
{ config, pkgs, lib, userOptions, ... }:

let
  configOnly = userOptions.configOnly or false;
in
{
  home.packages = lib.mkIf (!configOnly) (with pkgs; [
    kubectl
    kubectx
    k9s
  ]);
}
```

python.nix additionally:

```nix
  programs.pyenv = lib.mkIf (!configOnly) {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
```

- [ ] **Step 4: Prove other hosts unchanged + coder-workspace empty**

```bash
nix eval .#homeConfigurations.oracle.activationPackage --show-trace | tail -1
nix eval .#homeConfigurations.macbookair.activationPackage | tail -1
nix eval .#homeConfigurations.vps.activationPackage | tail -1
nix eval .#homeConfigurations.coder-workspace.activationPackage | tail -1
```

All four must succeed. Then confirm coder-workspace carries no bulk packages:

```bash
nix build .#homeConfigurations.coder-workspace.activationPackage 2>/dev/null || true
find result/home-files -name "*.conf*" 2>/dev/null | head   # config files exist
readlink result/home-path                                   # small env
```

(oracle/macbookair are darwin — build may fail locally per known env limit;
eval is the gate, record it.)

- [ ] **Step 5: Set the flag**

`home/hosts/coder-workspace/userOptions.nix` gains:

```nix
  # HM manages dotfiles only; all software comes from the workspace image.
  configOnly = true;
}
```

- [ ] **Step 6: Commit + push + PR**

```bash
nixfmt . 2>/dev/null || true
git checkout -b feat/config-only-hm && git add -A
git commit -m "feat: config-only home-manager for coder workspace"
git push -u origin feat/config-only-hm
gh pr create --base main --fill
```

Merge after user review (no CI gates exist here; eval evidence in Step 4).

### Task 4: Final template (coder-templates)

**Files:**
- Modify: `templates/podman-template/main.tf`

**Interfaces:**
- Consumes: image `0.0.4` (Task 1), merged flake output on `main`
  (Task 3 merged), spike verdict (Task 2)
- Produces: production-shaped template pushed as `podman-template-test`

- [ ] **Step 1: Apply final container definition**

On `feature/home-manager-startup`, replace the workspace container block:

```hcl
resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  name  = "coder-${data.coder_workspace.me.name}"
  image = docker_image.workspace.image_id

  memory = data.coder_parameter.memory_gb.value * 1024
  cpus   = tostring(data.coder_parameter.cpu_count.value)

  mounts {
    target = "/home/coder"
    source = "/srv/coder/workspaces/coder-${data.coder_workspace.me.name}"
    type   = "bind"
  }

  # Boots as root solely to grant the nix store dirs to uid 1000 (in-build
  # chown crashes the image builder VM; runtime chown is cheap). Then drops
  # privileges and hands over to the agent init script.
  user        = "0:0"
  userns_mode = "keep-id:uid=1000,gid=1000"

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  # NOTE (kill-switch): if Task 2 recorded NO-GO, replace user/command with
  # user = "1000:1000", plain init command, and drop the HM startup_script.
  command = ["sh", "-c",
    "chown 1000:1000 /nix /nix/store || echo 'store setup failed'; "
    + "chmod u+rwx /nix/store || true; "
    + "mkdir -p /nix/var/nix && chown -R 1000:1000 /nix/var/nix || true; "
    + "exec setpriv --reuid=1000 --regid=1000 --init-groups "
    + "sh -c ${jsonencode(coder_agent.main.init_script)}"]

  depends_on = [
    llm01_workspace_target.workspace,
    docker_container.chown_home,
  ]
}
```

- [ ] **Step 2: Startup script = config-only switch**

```hcl
  # Config-only home-manager: dotfiles from github main; software comes from
  # the image. Requires image >= 0.0.4 and the flake merged to main.
  startup_script = <<-EOT
    #!/bin/bash
    set -uo pipefail
    home-manager switch \
      --flake github:javierarrieta/nixos-configurations#coder-workspace \
      > /home/coder/.hm-switch.log 2>&1 || echo "hm-switch failed, see ~/.hm-switch.log" >&2
  EOT
```

- [ ] **Step 3: Image tag**

```hcl
  default      = "ghcr.io/javierarrieta/coder-workspaces-nix:0.0.4"
```

- [ ] **Step 4: fmt, commit, push, PR, green, merge**

```bash
NIXPKGS_ALLOW_UNFREE=1 nix-shell -p terraform --run "terraform fmt templates/podman-template/"
git add templates/podman-template/main.tf
git commit -m "feat(podman-template): root-boot store setup, config-only HM, image 0.0.4"
git push origin feature/home-manager-startup
gh pr create --base main --fill
gh pr checks --watch   # merge only when green
```

### Task 5: E2E validation (live)

**Files:** none

- [ ] **Step 1: Deploy + create**

User or controller (with session token):

```bash
yes | coder templates push podman-template-test --directory <clean-checkout>/templates/podman-template
printf '8\n50\n4\n\n' | coder create llm01-test -t podman-template-test --yes
```

(prompt order: CPU, disk, memory, image; stop `llm01` first — global lease)

- [ ] **Step 2: Startup correctness**

```bash
coder ssh llm01-test -- cat /home/coder/.hm-switch.log          # success
coder ssh llm01-test -- ls -ld /nix/store                       # owner 1000
coder ssh llm01-test -- ls /nix/var/nix                         # db/ present
```

- [ ] **Step 3: Environment**

```bash
rustc --version; node --version; python --version               # 3.12.x
k9s version; kubectx; nvim --version | head -1
starship --version
git config user.email                                           # javier@techdelivery.es
fish -c 'echo $EUID; type eza'                                  # aliases present via config
```

- [ ] **Step 4: nix-shell**

```bash
nix-shell -p hello --run hello       # works; second invocation cached
```

- [ ] **Step 5: VS Code extensions**

Install an extension from VS Code UI → no signature error (openssl wiring).

- [ ] **Step 6: Resilience**

```bash
coder stop llm01-test --yes && coder start llm01-test    # idempotent reapply
# recreate via template update or delete/create; same result expected
```

- [ ] **Step 7: Cleanup + rollout**

```bash
gh pr close 7 --comment "Superseded by baked-image design." --delete-branch   # coder-workspaces
git push origin --delete fix/nix-var-setpriv 2>/dev/null                       # stale branch
coder delete llm01-test --yes
# user: push template to PRODUCTION name and update llm01 workspace image param
```

Update docs: mark 2026-08-21 spec/plan superseded by the 2026-08-22 spec.
