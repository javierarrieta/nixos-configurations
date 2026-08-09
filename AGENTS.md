# NixOS Configuration Agent Guidelines

## Infrastructure Overview

### Host Inventory (16 hosts)

**K3s Servers (3):**
- `k8s-server01`, `k8s-server02`, `k8s-server03` - Control plane nodes with etcd

**K3s Nodes (4):**
- `k8s-node01`, `k8s-node02`, `k8s-node03`, `k8s-node04` - Worker nodes

**Raspberry Pi Nodes (3):**
- `k8s-pi01`, `k8s-pi02`, `k8s-pi03` - ARM64 worker nodes

**Special Purpose (2):**
- `llm01` - LLM server with ComfyUI (NVIDIA GPU, CUDA)
- `ryzen7` - Workstation (AMD CPU, development machine)

### Module Architecture

**NixOS Modules (`modules/nixos/`):**
| Module | Purpose |
|--------|--------|
| `base.nix` | Base NixOS configuration, system settings |
| `system-packages.nix` | Common system packages across all hosts |
| `ssh.nix` | SSH server with host key configuration (includes defaults) |
| `static-network.nix` | Static network configuration |
| `prometheus.nix` | Prometheus node exporter |
| `rsyslog.nix` | Rsyslog configuration for log forwarding |
| `openiscsi.nix` | iSCSI initiator configuration |
| `sops-base.nix` | SOPS base configuration |
| `k3s.nix` | Unified k3s module (handles both server and agent roles) |
| `k8s-network.nix` | Kubernetes network configuration |
| `comin.nix` | GitOps with Comin |
| `nix-sweep.nix` | Nix garbage collection |
| `minimal-image.nix` | Minimal image for Raspberry Pi bootstrap |
| `raspberry-pi.nix` | Raspberry Pi specific configuration |

**Home Manager Modules (`modules/home-manager/`):**
| Module | Purpose |
|--------|--------|
| `base.nix` | Entry point importing all submodules |
| `host-common.nix` | User options and base settings |
| `shell.nix` | Shell configuration (fish, zsh, starship, fzf, zoxide, git, tmux) |
| `dev-tools.nix` | Development tools |
| `python.nix` | Python configuration |
| `k8s.nix` | Kubernetes tools |
| `llm.nix` | LLM-related configuration |

---

## Commands

### Configuration Management
- **Apply Config**: `nixos-rebuild switch --flake .#<hostname>`
- **Test Config (NixOS)**: `nixos-rebuild test --flake .#<hostname>`
- **Test Evaluation (macOS)**: `nix eval .#nixosConfigurations.<hostname>.config.system.build.toplevel --show-trace`
- **Format**: `nixfmt .`

### Secrets (SOPS)
- **Edit**: `sops secrets.yaml` (opens editor, encrypts on save)
- **Decrypt**: `sops -d secrets.yaml`
- **Verify Encryption**: `cat secrets.yaml` (must show `ENC[...]`)
- **Update Keys**: `sops updatekeys secrets.yaml`

---

## Code Style & Conventions

### Formatting
- Indent with **2 spaces**
- Align `=` in sets when readable
- Use `inherit (pkgs) ...` for brevity
- Prefer `let ... in` for local variables

### Modularity
- Keep `configuration.nix` minimal - only module imports and host-specific overrides
- Put host-specific variables in `vars.nix`
- Create new modules in `modules/nixos/` for reusable configurations
- Use `modules/home-manager/` for user environment modules

### Secrets
- NEVER commit plaintext secrets
- Use `config.sops.secrets."path"` for secret files
- Add trailing newline to SSH private keys

### Comments
- Explain *why*, not *what*
- Document unusual hardware quirks in `hardware-configuration.nix`

---

## Critical Safety Rules

1. **Always read** `secrets.yaml` (via `sops -d`) before adding keys
2. **Always verify** `secrets.yaml` is encrypted before committing
3. **Do not change** `system.stateVersion` unless performing full release upgrade
4. **Clean up** temporary files after operations (secrets.dec.yaml, *_host_key*)

---

## Creating a New Host

### Complete Checklist

1. **Create host directory structure**:
   ```bash
   mkdir -p hosts/<hostname>
   ```

2. **Create required files**:
   - `configuration.nix` - Main NixOS configuration
   - `default.nix` - Required by NixOS for host lookup
   - `hardware-configuration.nix` - Hardware scan results
   - `vars.nix` - Host-specific variables
   - `users.nix` - User accounts and SSH keys

3. **Generate SSH host keys**:
   ```bash
   ssh-keygen -t ed25519 -f <hostname>_host_key -N "" -C "<hostname>"
   ```

4. **Add to `secrets.yaml`**:
   ```yaml
   <hostname>/network_env: |
     IP_ADDRESS=192.168.0.X
     DEFAULT_GATEWAY=192.168.0.1
     DNS1=192.168.0.1
     DNS2=192.168.0.41
   
   ssh_keys/<hostname>_host_private: |
     -----BEGIN OPENSSH PRIVATE KEY-----
     ... (with trailing newline)
     -----END OPENSSH PRIVATE KEY-----
   ssh_keys/<hostname>_host_public: ssh-ed25519 ... <hostname>
   ```

5. **Add host public key to `.sops.yaml`** recipients list

6. **Add to `flake.nix`** with correct modules

7. **Track with Git**: `git add hosts/<hostname>` before evaluation

### Required Files Template

**`default.nix`** (mandatory):
```nix
{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware-configuration.nix
  ];
}
```

**`vars.nix`** (host-specific variables):
```nix
{ config, pkgs }:
{
  hostname = "<hostname>";
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];

  k3s = {
    enable = true;
    role = "server";  # or "agent"
    serverAddr = "https://<server-ip>:6443";
    tokenFile = config.sops.secrets."k3s_token".path;
    disable = [ "traefik" "servicelb" ];
  };
}
```

**Note**: Network placeholders (`$IP_ADDRESS`, etc.) are ignored during evaluation. The actual values come from the SOPS secret `secrets.yaml#<hostname>/network_env` at runtime via the `network-addresses-<interface>` service.

**`configuration.nix`** (minimal, use modules):
```nix
{ config, pkgs, lib, hostVars, ... }:
{
  imports = [
    ../../modules/nixos/base
    ../../modules/nixos/ssh
    # ... other modules
  ];

  networking.hostName = "<hostname>";
}
```

### Important Notes
- **default.nix is mandatory** - NixOS requires it for host lookup
- **vars.nix is mandatory** - Used for host-specific configuration
- **No home-manager.nix needed** - Home manager is configured globally in modules/
- **git add before evaluation** - Untracked directories cause "path does not exist" errors

---

## Lessons Learned & Troubleshooting

### SOPS & Secrets Management

**Key Location**: If decryption fails, ensure `SOPS_AGE_KEY_FILE` is set:
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

**Agent Decryption Limitations**: When SSH key has a passphrase, `sops updatekeys` fails non-interactively. Solution:
1. Add public keys to `.sops.yaml` manually
2. Ask user to run `sops updatekeys secrets.yaml -y` in their terminal

**Manual Workflow**:
```bash
# Decrypt
sops -d secrets.yaml > secrets.dec.yaml

# Edit secrets.dec.yaml

# Encrypt
sops -e secrets.dec.yaml > secrets.yaml

# CLEANUP - critical security step
rm secrets.dec.yaml
```

**In-place Encryption**: `sops -e -i secrets.yaml` - useful after accidental plaintext overwrite

### SOPS Chicken-and-Egg Problem

**Issue**: If you add `age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]` to `sops-base.nix`, SOPS will fail to decrypt because the SSH key is provisioned BY SOPS.

**Solution**: Remove `age.sshKeyPaths` from `sops-base.nix`. The age key alone is sufficient for SOPS decryption.

**Lesson learned**: During `nixos-anywhere` bootstrap, the age key is provisioned to `/var/lib/sops-nix/key.txt` before SOPS tries to decrypt secrets. Don't create circular dependencies.

### SSH Keys

**Trailing Newline Required**: SSH private keys MUST end with newline:
- **Check**: `cat -e keyfile` should show `-----END OPENSSH PRIVATE KEY-----$`
- **Fix**: Ensure secret value ends with `\n`

### Tool Quirks

**yq Version**: Older version (3.4.3) lacks `-i` flag:
```bash
# Workaround
yq . file.yaml > file.json
jq '.key = "value"' file.json > new.json
yq -y . new.json > file.yaml
```

---

## Kubernetes (k3s) Configuration

### Unified k3s Module

The `k3s.nix` module handles both server and agent roles. Configuration goes in `vars.nix`:

```nix
hostVars = {
  k3sOptions = {
    enable = true;
    role = "server";  # or "agent"
    serverUrl = "https://192.168.0.10:6443";  # for agents
    token = "K10...";  # for agents
    extraFlags = toString [
      "--kubelet-arg pod-max-pids=500"
    ];
  };
}
```

### Module Options
| Option | Description |
|--------|------------|
| `enable` | Enable k3s service |
| `role` | `"server"` or `"agent"` |
| `serverUrl` | Control plane URL (agents only) |
| `token` | Join token (agents only) |
| `extraFlags` | Additional k3s flags |

### Important Settings

**Kernel Parameters** (for cgroup support):
```nix
boot.kernelParams = [
  "overlay.override_cgroup=1"
  "cgroup.no_restrict=1"
];
```

**SMART Monitoring**:
```nix
services.smartd.enable = true;
```

**Firewall**: Keep disabled on Kubernetes nodes with MetalLB

---

## Raspberry Pi Configuration

### Platform Setup
```nix
{ config, pkgs, lib, ... }:
{
  imports = [
    ../../modules/nixos/raspberry-pi
  ];

  boot.kernelPackages = pkgs.linuxPackages_rpi4;
}
```

### Key Settings
- **System**: `aarch64-linux`
- **Bootloader**: `boot.loader.generic-extlinux-compatible.enable = true`
- **Kernel Params**: `8250.nr_uarts=1`, `console=ttyAMA0,115200`, `console=tty1`
- **Filesystem**: Label-based `/dev/disk/by-label/NIXOS_SD`

### SD Image Building

**Recommended approach**: Use bootstrap image + Comin

**Bootstrap image** (no SOPS dependencies):
```bash
nixos-rebuild build-image --flake .#k8s-pi01-minimal --image-variant sd-card
```

**Full image** (requires SOPS access, build on Linux):
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
nixos-rebuild build-image --flake .#k8s-pi01 --image-variant sd-card
```

---

## Services Configuration

### SSH Server
Defaults in `modules/nixos/ssh.nix`:
- `PermitRootLogin = "no"`
- `PasswordAuthentication = yes`

Override in `vars.nix` if needed:
```nix
hostVars = {
  sshOverrides = {
    services.openssh.settings.PermitRootLogin = "prohibit-password";
  };
}
```

### Prometheus Node Exporter
Enabled via `modules/nixos/prometheus.nix`, default port 9100

### Rsyslog
Use `modules/nixos/rsyslog.nix` for log forwarding:
```nix
hostVars = {
  rsyslogTarget = "192.168.0.41:514";
}
```

### ComfyUI (LLM Server)
```nix
services.comfyui = {
  enable = true;
  gpuSupport = "cuda";  # or "rocm"
  enableManager = true;
  listenAddress = "0.0.0.0";
  openFirewall = true;
};
```

---

## Coder Workspaces (llm01)

### Overview

Coder OSS runs in the Kubernetes cluster (`casa` namespace) using its built-in
provisioner. Workspaces are rootless Podman containers on `llm01` with
iSCSI-backed home directories (TrueNAS zvols) and an in-cluster Docker registry.

### Architecture

- **Coder server**: v2.35.1 at `https://coder.home.arrietta.eu`, backed by a
  Postgres instance (`postgres-18` database `coder`).
- **Built-in provisioner**: runs Terraform in the Coder pod. The Docker provider
  talks to `llm01`'s rootless Podman API over mTLS (`tcp://192.168.0.29:2376`).
- **Podman API**: `systemd.services.podman-api` on `llm01` (UID/GID 27003),
  mTLS with certs from `coder-podman-client-secrets`.
- **iSCSI helper**: `coder-iscsi-helper` (root service on `llm01`) handles
  privileged iSCSI operations (TrueNAS zvol create/delete, login/logout,
  mount/umount). Provisioner calls it over mTLS (`https://192.168.0.29:2377`)
  with per-workspace capabilities.
- **Workspace image**: `registry.l.arrietta.eu/coder-workspace:<sha>` (Nix-built,
  includes `/etc/os-release` for the Coder agent's `clistat`).
- **Registry**: `registry.l.arrietta.eu` (nginx + Docker registry), TLS via
  Traefik. Push user `push`, pull user `coder`.

### Template

- Location: `https://github.com/javierarrieta/coder-templates` (repo `coder-templates`, template `llm01-podman`)
- `main.tf`: Coder `~>0.17`, Docker `~>3.6`, `llm01_workspace_target` provider.
- Resources: `llm01_workspace_target.workspace` (lease acquire/provision/attach),
  `docker_volume.home` (count = start_count), `docker_container` (count = start_count).
- Workspace naming: `coder-<ws>`, IQN: `iqn.2005-10.org.freenas.ctl:coder-<ws>`.

### Commands

```bash
# Login (no OIDC; API key in /tmp/coder_session_token.txt)
export CODER_URL=https://coder.home.arrietta.eu
export CODER_SESSION_TOKEN="$(cat /tmp/coder_session_token.txt)"

# Workspace lifecycle
coder create llm01-podman <name> --yes
coder start <name>
coder stop <name> --yes
coder delete <name> --yes
coder ssh <name>

# Template management
coder templates push llm01-podman   # must clear stale provider cache first

# Clear stale provisioner cache (after provider rebuild)
kubectl exec -n casa deploy/coder -- rm -rf /home/coder/.cache/coder/provisioner-2/tf/registry.l.arrietta.eu
```

### TrueNAS Helper Flow

1. **Provision**: acquire global lease → create zvol (`tank/iscsi/k8s/<ws>`) →
   create iSCSI target/extent → login → format ext4 → mount at
   `/srv/coder/workspaces/coder-<ws>` → chown to coder.
2. **Attach** (start): login → mount → chown.
3. **Detach** (stop): unmount → logout. Lease released by Terraform.
4. **Destroy** (delete): detach → delete TrueNAS target/extent/zvol.
5. **Lease**: global, one active workspace at a time. Conflicting acquire
   returns HTTP 409. Capabilities are per-workspace, passed via
   `X-Coder-Capability` header, never logged or sent to TrueNAS.

### Notes

- The helper caches lease state in memory; restart `coder-iscsi-helper` to
  clear a stuck lease.
- Workspace size: 10–200 GiB.
- The provisioner pod's Docker provider reads the read-only pull credential
  from `/run/secrets/coder-registry-pull/{username,password}` via `file()`.
- llm01's `coder` home must NOT contain a registry auth file (pulls use the
  provisioner-supplied credential).

---

## GitOps with Comin

### Configuration
```nix
services.comin = {
  enable = true;
  remotes = [
    {
      name = "origin";
      url = "git@github.com:user/infra.git";
      branches.main.name = "main";
      poller.period = 900;  # 15 minutes
    }
  ];
};
```

### Options Reference
| Option | Description |
|--------|------------|
| `enable` | Enable comin service |
| `remotes` | List of Git repositories |
| `remotes.*.url` | Repository URL |
| `remotes.*.branches.main.name` | Branch to deploy |
| `remotes.*.poller.period` | Poll interval (seconds, default 60) |
| `hostname` | Machine name (defaults to `networking.hostName`) |

---

## Host Management

### Renaming a Host
1. Update `flake.nix`: `nixosConfigurations.oldname` → `nixosConfigurations.newname`
2. Rename host directory: `mv hosts/oldname hosts/newname`
3. Update `networking.hostName` in `configuration.nix`
4. Update secrets keys if needed
5. Update `.sops.yaml` recipients if SSH key changes

### Common Operations

**List all hosts**:
```bash
nix flake show | grep nixosConfigurations
```

**Evaluate specific host**:
```bash
nix eval .#nixosConfigurations.<hostname>.config.system.build.toplevel --show-trace
```

**Build without activating**:
```bash
nixos-rebuild build --flake .#<hostname>
```

---

## Architecture Decisions

### Why Unified k3s Module?
- Single source of truth for k3s configuration
- Reduces duplication between server/agent configs
- Easier to maintain and update
- Configuration driven by `vars.nix` per host

### Why vars.nix Pattern?
- Clear separation of module logic vs host configuration
- Easier to compare hosts
- Reduces duplication in `configuration.nix`
- Follows DRY principle

### Network Configuration with SOPS

**Important**: Network configuration uses a placeholder pattern that is replaced at runtime via SOPS:

1. `vars.nix` contains placeholders like `"$IP_ADDRESS"`, `"$DEFAULT_GATEWAY"`, `"$DNS1"`, `"$DNS2"`
2. Sops provisions `secrets.yaml#<hostname>/network_env` to `/run/secrets/<hostname>/network_env`
3. `k8s-network.nix` (line 30) sets `EnvironmentFile` for the `network-addresses-<interface>` systemd service to that sops secret path
4. The service script reads `$IP_ADDRESS` from the environment and applies it to the network interface

**This means**:
- Placeholders in `vars.nix` are **ignored** for actual network configuration
- The actual IP comes from the SOPS secret at runtime
- Each host must have a `secrets.yaml#<hostname>/network_env` entry with the correct values

**Example `secrets.yaml` entry**:
```yaml
k8s-server03:
    network_env: |
        IP_ADDRESS=192.168.0.13
        DEFAULT_GATEWAY=192.168.0.1
        DNS1=192.168.0.1
        DNS2=192.168.0.41
```

### Why No Host-Level home-manager.nix?
- Home manager configuration is generic across hosts
- Per-user customization via `modules/home-manager/`
- Reduces maintenance burden
- Consistent user experience across infrastructure

---

## Quick Reference

### File Locations
| Purpose | Location |
|---------|----------|
| NixOS Modules | `modules/nixos/` |
| Home Manager Modules | `modules/home-manager/` |
| Host Configurations | `hosts/<hostname>/` |
| User Definitions | `common/users.nix` |
| Secrets | `secrets.yaml` |
| SOPS Config | `.sops.yaml` |

### Common Commands
```bash
# Apply configuration
sudo nixos-rebuild switch --flake .#<hostname>

# Test evaluation
nix eval .#nixosConfigurations.<hostname>.config.system.build.toplevel --show-trace

# Format code
nixfmt .

# Decrypt secrets
sops -d secrets.yaml

# List hosts
nix flake show | grep nixosConfigurations
```
