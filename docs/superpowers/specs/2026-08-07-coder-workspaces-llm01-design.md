# Coder Workspaces on llm01 — Design

Date: 2026-08-07

## Context

Coder OSS runs in the k3s cluster and provisions workspaces as Kubernetes pods via the kubernetes provider. The user wants workspaces provisioned on `llm01` instead for **better local performance** (CPU/RAM/disk) than the shared cluster nodes.

Constraints gathered during brainstorming:

- **No GPU access needed** in workspaces — the AMD GPU stays reserved for host llama.cpp services.
- **Direct on host OS** — zero container/VM overhead; no isolation between workspaces.
- **Single shared user** — all workspaces run as one `coder` user on llm01, sharing `/home/coder`.

## Approach (selected: #1 — Coder VM template over SSH)

A new Coder template connects to llm01 over SSH and runs a `coder agent` directly on the host OS as a shared `coder` user, reverse-tunneling to the existing Coder server in k3s.

### Components

1. **New Coder template `llm01-host`** (Terraform):
   - `coder_agent` resource with `os = "linux"`, `arch = "amd64"`, `dir = "/home/coder"`.
   - A `terraform_data` resource whose SSH connection (`host`, `user = "coder"`, `private_key`) runs `coder_agent.main.init_script` via `remote-exec` on workspace start. The init script starts the agent (backgrounded), which reverse-tunnels to the Coder server.
   - Template variables: `host` (llm01 IP), `ssh_private_key` (marked secret, stored encrypted in Coder DB).
   - On stop, the workspace/agent tears down naturally.

2. **llm01 NixOS changes** (`hosts/llm01/configuration.nix`):
   - New system user `coder` (home `/home/coder`, group `coder`).
   - Add the `coder` user's SSH **public** key to `users.users.coder.openssh.authorizedKeys.keys` (public keys are safe to commit).
   - Add `pkgs.coder` to `systemPackages` so the init script finds the agent binary on PATH.
   - Shell/git basics for the `coder` user (minimal — no home-manager needed).

3. **Secrets split**:
   - **Public key** → committed in llm01 NixOS config.
   - **Private key** → stored as a secret template variable in Coder (never in git, never in this repo).

4. **Networking**: Coder's provisioner pod must reach llm01:22 (LAN) — normal for this setup. Agent reaches the Coder server via the reverse tunnel, so no llm01 inbound ports beyond SSH.

### Concurrency

Multiple workspaces = multiple agents on the same host, all as `coder`, sharing `/home/coder`. Resources are contended; each workspace still gets a separate agent port/tunnel. Matches the "single shared user" choice.

## Data Flow (workspace start)

1. User clicks "Create workspace" on `llm01-host` template.
2. Coder's provisioner (in the k8s pod) runs Terraform: uses `host` + `ssh_private_key` to SSH into llm01 as `coder`.
3. `remote-exec` runs `coder_agent.main.init_script` → starts `coder agent` on llm01, backgrounded via nohup/systemd-run, writing logs to `/home/coder/.cache/coder/agent.log`.
4. Agent dials the Coder server → workspace shows "Running". VS Code via `coder-remote` connects through the tunnel.

## Error Handling

- **SSH failure** (wrong key, user missing): template apply fails with the SSH error — visible in workspace build logs.
- **Agent crash mid-session**: Coder shows "agent lost connection"; next `coder` CLI / IDE reconnect restarts the tunnel. Supervision handled by the init script's `systemd-run --user` or nohup loop.
- **llm01 reboot**: workspace state = stopped/off; agent not running. Rebuild restarts it. No persistent containers to resync.
- **Port collision**: each agent uses a unique reverse-tunnel port allocated by the Coder server — no manual port management.

## llm01 NixOS Config Sketch

```nix
users.users.coder = {
  isSystemUser = true;
  group = "coder";
  home = "/home/coder";
  openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... coder-llm01" ];
};
users.groups.coder = {};
systemPackages.extraPackages = [ pkgs.coder ];
```

Plus `/home/coder` dir creation via tmpfiles, and a `.bashrc`/git config for the user.

## Verification

1. `nixos-rebuild switch --flake .#llm01` → confirm `coder` user + `coder` binary exist, SSH key works (`ssh coder@llm01`).
2. Push template to Coder; create a test workspace; confirm it reaches Running.
3. `coder ssh` into it, run a heavy build to confirm bare-metal speed.
4. Optionally wire a hostname entry / template default `host` variable so users don't type the IP.

## Out of Scope

GPU access, per-workspace users, isolation, resource quotas.
