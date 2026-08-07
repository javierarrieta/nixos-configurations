# Coder Workspaces on llm01 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Coder (running in k3s) to provision workspaces that run directly on the llm01 host OS via SSH, as a shared `coder` user.

**Architecture:** A new Coder template `llm01-host` connects to llm01 over SSH and runs `coder_agent.main.init_script` on the host, starting a `coder agent` process that reverse-tunnels to the existing Coder server. llm01 gets a `coder` system user, an SSH authorized key, and the `coder` CLI package so the agent binary is available on PATH.

**Tech Stack:** NixOS (flake, home-manager, comin), Terraform (Coder `coder/coder` provider), Coder OSS, systemd-tmpfiles.

## Global Constraints

- No GPU access in workspaces — AMD GPU stays reserved for host llama.cpp services.
- Workspaces run directly on host OS — no containers, no isolation, no resource quotas.
- All workspaces share one `coder` user on llm01 and share `/home/coder`.
- Never commit the SSH **private** key to this repo. Only the public key is committed.
- SSH private key is stored as a secret template variable in Coder (sensitive = true).
- Clean up temporary key files after use (`rm` them).
- Follow repo Nix style: 2-space indent, `inherit` for brevity, host-specific config in `hosts/llm01/configuration.nix`.
- `system.stateVersion` unchanged.
- Follow the design in `docs/superpowers/specs/2026-08-07-coder-workspaces-llm01-design.md`.

---

### Task 1: Generate the coder SSH keypair (not committed)

**Files:**
- Create: `/tmp/coder-llm01` (private key, temporary)
- Create: `/tmp/coder-llm01.pub` (public key, value pasted into Task 2)

**Interfaces:**
- Produces: `coder-llm01` private key (used later by Task 4 at Coder-template push time) and `coder-llm01.pub` public key string, e.g. `ssh-ed25519 AAAA... coder-llm01`.

- [ ] **Step 1: Generate the keypair**

```bash
ssh-keygen -t ed25519 -f /tmp/coder-llm01 -N "" -C "coder-llm01"
```

- [ ] **Step 2: Verify the keypair**

```bash
ssh-keygen -y -f /tmp/coder-llm01
cat /tmp/coder-llm01.pub
```

Expected: the `-y` command prints a public key identical to `/tmp/coder-llm01.pub`, ending in `coder-llm01`.

- [ ] **Step 3: Note the public key value**

The full single-line value of `/tmp/coder-llm01.pub` (starting `ssh-ed25519 AAAA...` and ending `coder-llm01`) is required as the literal in Task 2, Step 1. Keep `/tmp/coder-llm01` (private) around — Task 4 references it.

No commit — these files are outside the repo by design.

---

### Task 2: Add coder user and tooling to llm01

**Files:**
- Modify: `hosts/llm01/configuration.nix`

**Interfaces:**
- Consumes: public key string from Task 1 (`ssh-ed25519 ... coder-llm01`).
- Produces: system user `coder` (group `coder`, home `/home/coder`), `pkgs.coder` in system packages, tmpfiles rules creating `/home/coder`, `.bashrc`, and `.gitconfig`.

- [ ] **Step 1: Add a `let` block for the user dotfiles**

In `hosts/llm01/configuration.nix`, extend the existing `let` block (currently `models` and `llamaPackage`, lines 12-13) with two store files. Replace lines 11-14 with:

```nix
let
  models = import ./llm-models.nix;
  llamaPackage = unstablePkgs.llama-cpp-vulkan;

  # Shared-home dotfiles for the Coder workspace user (no home-manager user).
  # Copy rules (`C`) are idempotent: no-op if the destination already exists.
  coderBashrc = pkgs.writeText "coder-bashrc" ''
    if command -v fish > /dev/null; then exec fish; fi
  '';
  coderGitconfig = pkgs.writeText "coder-gitconfig" ''
    [user]
      name = Coder Workspaces
      email = coder@llm01
    [init]
      defaultBranch = main
  '';
in
```

- [ ] **Step 2: Add the coder user and group**

Insert after the existing `users.groups` block (line 158) and before the `# Services` comment (line 160):

```nix
  # Coder workspace host: workspaces run directly as this user via SSH
  users.users.coder = {
    isSystemUser = true;
    group = "coder";
    home = "/home/coder";
    # Explicit shell: without it nixpkgs assigns nologin and SSH login fails
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... coder-llm01"
    ];
  };
  users.groups.coder = { };
```

Replace `ssh-ed25519 AAAA... coder-llm01` with the exact value from Task 1 Step 3.

- [ ] **Step 3: Add the coder CLI to system packages**

In the existing `systemPackages.extraPackages` list (lines 120-135), add `pkgs.coder` to the `(with pkgs; [ ... ])` section, e.g. after `nix-index`:

```nix
      nix-index
      qemu
      coder
```

(It belongs to the `pkgs` section, not `unstablePkgs`.)

- [ ] **Step 4: Add tmpfiles rules for the coder home**

Insert alongside the existing `systemd.tmpfiles.rules` (lines 228-233):

```nix
  # Coder workspace shared home
  "d /home/coder 0755 coder coder -"
  "C /home/coder/.bashrc 0644 coder coder - ${coderBashrc}"
  "C /home/coder/.gitconfig 0644 coder coder - ${coderGitconfig}"
```

Resulting block:

```nix
  systemd.tmpfiles.rules = [
    "d /opt/llm 0755 ollama ollama -"
    "d /opt/llm/models 0755 ollama ollama -"
    "d /opt/llm/models/llama-cpp 0755 ollama ollama -"
    "Z /opt/llm - ollama ollama -"
    "d /home/coder 0755 coder coder -"
    "C /home/coder/.bashrc 0644 coder coder - ${coderBashrc}"
    "C /home/coder/.gitconfig 0644 coder coder - ${coderGitconfig}"
  ];
```

- [ ] **Step 5: Verify evaluation**

```bash
nixfmt hosts/llm01/configuration.nix
nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace
```

Expected: format clean (no diff output from `git diff`), evaluation succeeds, no errors.

- [ ] **Step 6: Commit**

```bash
git add hosts/llm01/configuration.nix
git commit -m "feat(llm01): add coder workspace user and shared home"
```

---

### Task 3: Create the llm01-host Coder template

**Files:**
- Create: `coder/templates/llm01-host/main.tf`
- Create: `coder/templates/llm01-host/variables.tf`
- Create: `coder/templates/llm01-host/README.md`

**Interfaces:**
- Consumes: SSH private key value from Task 1 (`/tmp/coder-llm01`).
- Produces: a Coder template pushable with `coder templates push llm01-host`; workspaces connect to llm01 as user `coder`.

- [ ] **Step 1: Create the directory and `variables.tf`**

```bash
mkdir -p coder/templates/llm01-host
```

`coder/templates/llm01-host/variables.tf`:

```hcl
variable "host" {
  description = "SSH host of llm01 (IP or resolvable hostname)"
  type        = string
}

variable "ssh_private_key" {
  description = "SSH private key for the coder user on llm01"
  type        = string
  sensitive   = true
}
```

- [ ] **Step 2: Create `main.tf`**

`coder/templates/llm01-host/main.tf`:

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 0.17"
    }
  }
}

provider "coder" {}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace.me.owner_name
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_NAME  = data.coder_workspace.me.owner_name
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }
}

resource "terraform_data" "install_agent" {
  depends_on = [coder_agent.main]

  # Destroy-time provisioners and their connection may only reference the
  # resource's own attributes (self), so capture everything needed at
  # destroy here and read it back via self.input.
  input = {
    host        = var.host
    user        = "coder"
    private_key = var.ssh_private_key
    owner       = data.coder_workspace.me.owner_name
    workspace   = data.coder_workspace.me.name
  }

  connection {
    type        = "ssh"
    host        = self.input.host
    user        = self.input.user
    private_key = self.input.private_key
  }

  # Each workspace runs its own agent in its own session/process group, so
  # tearing down one workspace kills only its own agent on the shared host.
  # setsid makes the agent a new session leader; the backgrounded PID is the
  # process-group id, so `kill -- -PID` targets just that workspace's agent.
  # The idempotent kill guard also cleans up an orphaned agent from a prior
  # stop/restart (stop is terraform apply, so the destroy provisioner only
  # runs on delete, not on stop).
  provisioner "remote-exec" {
    inline = [
      "PID=/home/coder/.cache/coder/agent-${self.input.owner}-${self.input.workspace}.pid",
      "if [ -f $PID ]; then kill -TERM -- -$(cat $PID) 2>/dev/null || true; rm -f $PID; fi",
      "mkdir -p /home/coder/.cache/coder",
      "setsid sh -c '${coder_agent.main.init_script}' > /home/coder/.cache/coder/agent-${self.input.owner}-${self.input.workspace}.log 2>&1 & echo $! > /home/coder/.cache/coder/agent-${self.input.owner}-${self.input.workspace}.pid",
    ]
  }

  # Tear down only this workspace's agent (shared host; other workspaces'
  # agents must keep running).
  provisioner "remote-exec" {
    when   = destroy
    inline = [
      "PID=/home/coder/.cache/coder/agent-${self.input.owner}-${self.input.workspace}.pid",
      "if [ -f $PID ]; then kill -TERM -- -$(cat $PID) 2>/dev/null || true; rm -f $PID; fi",
      "true",
    ]
  }
}

resource "coder_metadata" "llm01_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = coder_agent.main.id

  item {
    key   = "host"
    value = var.host
  }
}
```

- [ ] **Step 3: Create `README.md`**

`coder/templates/llm01-host/README.md`:

```markdown
# llm01-host

Coder workspace that runs **directly on the llm01 host OS** as the shared
`coder` user. No containers — full CPU/RAM/disk speed of llm01.

- **User**: `coder` (shared home `/home/coder`)
- **Connection**: SSH from the Coder provisioner to llm01, then the agent
  reverse-tunnels back to the Coder server.
- **Isolation**: none between workspaces; resources are contended. Teardown is
  per-workspace (each agent runs in its own process group).
- **GPU**: not exposed; the AMD GPU stays reserved for host llama.cpp.

## Build variables

| Variable           | Required | Notes                                    |
|--------------------|----------|------------------------------------------|
| `host`             | yes      | llm01 IP or resolvable hostname          |
| `ssh_private_key`  | yes      | secret; key for the `coder` user on llm01 |
```

- [ ] **Step 4: Format and validate the template**

If `terraform` is available locally:

```bash
terraform fmt -check coder/templates/llm01-host/
```

If Terraform is not installed, skip this and rely on the push-time validation in Task 4.

- [ ] **Step 5: Commit**

```bash
git add coder/templates/llm01-host/
git commit -m "feat(coder): add llm01-host template for bare-metal workspaces"
```

---

### Task 4: Deploy config, push template, verify end-to-end (manual ops)

**Files:**
- Uses: `/tmp/coder-llm01` (private key, from Task 1), `coder/templates/llm01-host/` (from Task 3).

**Interfaces:**
- Consumes: llm01 config from Task 2, template from Task 3, private key from Task 1.
- Produces: a working Coder workspace on llm01, verifiable with `coder ssh`.

- [ ] **Step 1: Deploy the llm01 config**

On llm01 (or via comin after merging to main):

```bash
sudo nixos-rebuild switch --flake .#llm01
```

Expected: rebuild completes; `coder` user exists.

- [ ] **Step 2: Verify the user, home, and SSH login**

```bash
id coder
ls -ld /home/coder
ssh -i /tmp/coder-llm01 coder@<llm01-ip> 'echo ok'
```

Expected: `id coder` shows `coder` group and `/home/coder`; dir exists owned by `coder`; SSH prints `ok`. If SSH fails, confirm the public key in Task 2 Step 2 matches `/tmp/coder-llm01.pub`.

- [ ] **Step 3: Push the template to Coder**

From a machine with `coder` CLI authenticated to the server:

```bash
cd coder/templates/llm01-host
coder templates push llm01-host
```

Expected: template version uploaded successfully. Note the two build variables shown in the UI: `host` and `ssh_private_key` (sensitive).

- [ ] **Step 4: Create a test workspace**

In the Coder UI: **New workspace** → template `llm01-host` → set `host` to the llm01 IP and paste the contents of `/tmp/coder-llm01` into `ssh_private_key`. Create.

Expected: workspace reaches **Running**.

- [ ] **Step 5: Connect and confirm bare-metal speed**

```bash
coder ssh <workspace-name> --template llm01-host
```

Inside the shell:

```bash
whoami   # -> coder
pwd      # -> /home/coder
nproc    # should reflect llm01's CPU count, not a k8s node's
```

Run a heavy local build (e.g. `nix build` or a big `make`) and confirm it completes much faster than on the k8s nodes. If it hangs, check the per-workspace agent log `/home/coder/.cache/coder/agent-<owner>-<workspace>.log` on llm01.

- [ ] **Step 6: Stop/delete the workspace and confirm teardown**

Stop the test workspace (Coder stop = `terraform apply` with start_count 0). On stop the agent self-shuts down when coderd closes the tunnel; the destroy provisioner (setsid process-group kill) runs on delete. Restarts clean up any orphan via the start-time guard. After delete, check on llm01:

```bash
ls /home/coder/.cache/coder/agent-* 2>/dev/null || echo "no agent pid files"
```

Expected: no pid file remains for the deleted workspace (kill ran on destroy). Other workspaces' agents, if any, must still be running — this is the whole point of the per-workspace teardown.

- [ ] **Step 7: Clean up temporary key material**

```bash
rm -f /tmp/coder-llm01 /tmp/coder-llm01.pub
```

The private key should only live in Coder's secret template variable from now on. If you want it recoverable, store it in `secrets.yaml` via `sops` under `coder/llm01_private` — otherwise rely on Coder.
