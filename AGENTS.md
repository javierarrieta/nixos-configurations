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

### Longhorn iSCSI Disk Medium Errors (2026-08-26)

**Observed**: During `nixos-rebuild switch` on k8s-node03 (and node02), kernel logged critical medium errors on iSCSI devices (sdy, sdz - Longhorn volumes from TrueNAS):
```
critical medium error, dev sdz, sector 0 ...
Unrecovered read error
Buffer I/O error on dev sdz, logical block 0
```

**Impact**: Likely contributed to I/O slowness during switch, exacerbating dbus-broker reload timeout. Not the direct cause of exit 4 (that was dbus-broker), but a compounding factor.

**Investigation needed**:
1. Check TrueNAS SMART status for underlying zvols/disks
2. Check TrueNAS pool health (`zpool status`)
3. Check iSCSI network path (MTU, switch ports, cables)
4. Consider Longhorn replica rebuild if data integrity at risk

**Commands for investigation**:
```bash
# On TrueNAS
smartctl -a /dev/<disk>
zpool status <pool>
iscsiadm -m session -P 3

# On NixOS nodes
iscsiadm -m session
dmesg -T | grep -iE "medium error|unrecovered read|Buffer I/O"
```

**Workaround**: The dbus-broker timeout fix (Task 3) provides headroom. If disk errors persist, consider migrating Longhorn volumes to healthy storage.

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

### Package Slimming (2026-08)

Pis compile the RPi kernel **natively on-device** (~5h each) — that's the dominant
build cost and cannot be removed (custom `linuxPackages_rpi4` is not in the public
aarch64 binary cache). To keep everything else fast, the Pis exclude heavy common
tooling that has no value on a worker node:

- `systemPackages.excludePackages` (in each `hosts/k8s-piXX/configuration.nix`)
  removes `kubernetes-helm` and `tpm2-tss` from the common set. `nfs-utils` is
  deliberately kept (cluster uses NFS mounts).
- `modules/home-manager/base.nix` gates on `hostname`: `k8s-pi01..03` only import
  `host-common` + `shell`; the heavy `dev-tools`, `python`, and `k8s` home-manager
  modules (rustup, scala-cli, bun, nodejs_24, uv, k9s, …) are skipped.

### Pi Upgrade Pitfalls (learned 2026-08 — read before any Pi migration)

1. **No shared cache is configured.** All three Pis poll the same repo via comin
   and each compiles the kernel itself, in parallel. Pushing a config change costs
   a ~5h kernel build on **every** Pi. Identical flake lock ⇒ identical store paths,
   so a manual `nix copy --from ssh-ng://<pi1> --to ssh-ng://<pi2>` of the toplevel
   closure dedupes perfectly — but must be done **before** the slower Pis start
   building (i.e. comin stopped on them) or it's wasted.
2. **Cancelling a running Pi build** requires killing the process tree in stages:
   `systemctl stop comin` → kill `nixos-rebuild` → kill the reparented `nix build`
   process → `pkill -9` any lingering `make -j4`/`cc1` (these run under the *nix
   daemon* sandbox and survive killing the client).
3. **Fresh worker switches drop the default route** mid-activation despite the
   `network-runtime` ordering fix. Keep the gateway watchdog running through every
   build + switch:
   `sudo systemd-run --unit=routewatch --collect bash -c 'while true; do /run/current-system/sw/bin/ip route replace default via 192.168.0.1 dev eth0; sleep 10; done'`
   (stop after settle with `systemctl stop routewatch`).
4. Launch rebuilds as
   `sudo NIX_CONFIG="experimental-features = nix-command flakes" nixos-rebuild switch --flake /var/lib/comin/repository#k8s-piXX`
   (`nixos-rebuild --extra-experimental-features` flag does not exist).
5. Eval warning `linux-rpi series will be removed in a future release` is expected;
   the migration target is `nixos-hardware` eventually.

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

- **Coder server**: v2.35.1 at `https://coder.home.arrieta.eu`, backed by a
  Postgres instance (`postgres-18` database `coder`).
- **Built-in provisioner**: runs Terraform in the Coder pod. The Docker provider
  talks to `llm01`'s rootless Podman API over mTLS (`tcp://192.168.0.29:2376`).
- **Podman API**: `systemd.services.podman-api` on `llm01` (UID/GID 27003),
  mTLS with certs from `coder-podman-client-secrets`.
- **iSCSI helper**: `coder-iscsi-helper` (root service on `llm01`) handles
  privileged iSCSI operations (TrueNAS zvol create/delete, login/logout,
  mount/umount). Provisioner calls it over mTLS (`https://192.168.0.29:2377`)
  with per-workspace capabilities.
- **Workspace image**: `ghcr.io/javierarrieta/coder-workspaces-nix:<tag>` (built in the `javierarrieta/coder-workspaces` repo, includes `/etc/os-release` for the Coder agent's `clistat`).
- **Registry**: `registry.l.arrieta.eu` (nginx + Docker registry), TLS via
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
export CODER_URL=https://coder.home.arrieta.eu
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
kubectl exec -n casa deploy/coder -- rm -rf /home/coder/.cache/coder/provisioner-2/tf/registry.l.arrieta.eu
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

### Unsticking Comin after a force-push to `main` (learned 2026-08)

Comin (and pis run an older `v0.12.0` while x86 hosts run `0.14.0`) can end up in a
loop / never deploy after an interactive rebase or `git push --force` to `main`.
The two symptoms seen:

- **Stuck on unborn `master`**: `git -C /var/lib/comin/repository branch -a` shows
  only `master` with no commits, even though fetches succeed. Comin never switches
  the local branch and never builds (pis' `0.12.0` also never logs deploys, so no
  feedback). Fix: repoint the local checkout at upstream before deploying manually:
  ```bash
  sudo git -C /var/lib/comin/repository checkout -B main origin/main
  ```
- **Stuck in a build/apply loop after a force-push**: comin evaluates the *new*
  commit but its done-path never converges. Stop it, settle the machine, then let it
  poll the new main:
  ```bash
  sudo systemctl stop comin.service
  sudo ip route replace default via 192.168.0.1 dev <iface>   # see network section
  sudo systemctl reset-failed k3s.service
  sudo systemctl start k3s.service
  sudo systemctl start comin.service
  ```
  Verify convergence with:
  ```bash
  nix-env --list-generations
  readlink /run/current-system
  ```
  `generations[0].out_path` must equal `/run/current-system`; if not, apply a
  manual deploy (below).

**Manual deploy is the reliable path.** With comin stopped, run
`sudo NIX_CONFIG="experimental-features = nix-command flakes" nixos-rebuild switch
--flake /var/lib/comin/repository#<host>` (or `--flake .#<host>` from a checkout on
the host). Do this after any force-push rather than waiting out the loop.

#### Deployer Suspension After Restart (comin issue #159)

When the health gate calls `comin suspend` and comin then restarts (which happens
when the switch changes the comin unit file), the deployer restores `isSuspended =
true` from the persisted store but the manager does **not** restore its own
`isSuspended` (it stays `false`). The deployer's `Run()` goroutine receives the
pending-generation signal but then blocks on `<-d.resumeCh` — no "deployer:
deploying generation..." log appears. `comin resume` fails because the manager
thinks it's not suspended.

**Recovery:**
```bash
# 1. Sync the manager state so resume() will accept the call
comin suspend
# 2. Now clear both the manager and deployer suspension
comin resume
# 3. The pending generation will be picked up automatically
```

**Check if affected:**
```bash
# Manager state (false after restart even if deployer is suspended)
comin status --json | jq '.is_suspended'
# Deployer state (true if suspended from store restore)
comin status --json | jq '.deployer.is_suspended'
# Health gate logs for the cause
cat /var/log/comin-health-gate.log
journalctl -u comin -n 50 --no-pager | grep "deployer: suspended because of"
```

This is a known comin bug: https://github.com/nlewo/comin/issues/159. The
`scripts/comin-approve.sh` `is_suspended()` helper checks both `.is_suspended`
and `.deployer.is_suspended` to detect this state.

### Known Network Issues (learned 2026-08 during the 26.05 migration)

Static network is applied in two layers (see `modules/nixos/static-network.nix`):
`network-addresses-<iface>.service` from the interface config, plus a runtime
gateway/DNS layer from the SOPS `network_env` secret via the `network-runtime-config`
oneshot and the `network-runtime` activation script. These are the issues hit and the
known caveats:

1. **Fresh worker switches drop the default route mid-activation.** Despite the
   `network-runtime` activation script (depends on `setupSecrets`) and the
   `network-runtime-config` service, every *fresh* worker `nixos-rebuild switch`
   still loses the default route. Servers survive (persistent `EnvironmentFile` +
   interface ordering), Pis and freshly-switched workers do not. Until fixed
   properly, run the watchdog around any build/switch:
   ```bash
   sudo systemd-run --unit=routewatch --collect bash -c 'while true; do /run/current-system/sw/bin/ip route replace default via 192.168.0.1 dev <iface>; sleep 10; done'
   # stop after the switch settles:
   sudo systemctl stop routewatch
   ```
   If the route is already gone, re-add it and bounce k3s:
   `sudo ip route replace default via 192.168.0.1 dev <iface>` then
   `systemctl reset-failed k3s.service && systemctl start k3s.service`.

2. **`network-runtime-config` is not re-run on `switch`.** Because
   `switch-to-configuration` does not re-trigger units whose
   `WantedBy`/`OnlyBy` target (`network.target`) is already active, the oneshot only
   fires on a *fresh boot*. The `network-runtime` activation script was the
   workaround for switches — it is the correct layer but still insufficient on its
   own for workers (see above).

3. **`nixpkgs >= 26.05` parses addresses/gateways at eval time.** Placeholders like
   `$IP_ADDRESS`/`$DEFAULT_GATEWAY` can no longer be baked into
   `networking.defaultGateway`/`nameservers`; the module only sets those when the
   values are real, deferring everything to the runtime layers.

4. **open-iscsi 2.1.11 → 2.1.12 regression** (cluster-wide during the migration):
   stale `/etc/iscsi/nodes/*` records carry a `node.session.conn_reopen_log_freq`
   param that breaks `iscsiadm`, killing Longhorn engine frontends. **Since
   2026-08-26 this self-heals** (see `modules/nixos/openiscsi.nix`): `iscsid`
   preStart wipes `/etc/iscsi/nodes` + `/etc/iscsi/send_targets` only when
   `iscsiadm -m node` actually fails, and a tmpfiles rule ensures
   `/run/lock/iscsi` exists (2.1.12 expects it, upstream unit never creates
   it). The manual fix below is only needed on hosts running old code:
   `sudo iscsid stop`, `rm -rf /etc/iscsi/nodes /etc/iscsi/send_targets`,
   `sudo mkdir -p /etc/iscsi/nodes /etc/iscsi/send_targets`, `sudo iscsid start`,
   then verify `iscsiadm -m node` is clean.

### Branch-Based Rollout (2026-08)

Two rings, two branches:

- **Canary ring (branch `main`, auto-deploy):** `k8s-node05` + `llm01`.
  Every commit to `main` auto-deploys to both (`deployConfirmer.mode =
  "auto"`), exercising the health-gate rollback path with a two-host blast
  radius.
- **Fleet ring (branch `stable`, manual-confirm):** `k8s-node01..04`,
  `k8s-server01..03`, `k8s-pi01..03` (`deployConfirmer.mode = "manual"`).
  They fetch/build automatically but pause before
  `switch-to-configuration switch` until `comin confirmation accept` runs
  on that host (local unix socket only — never from the Mac).

Promotion is a manual git merge — the human gate:
```bash
git checkout stable && git merge main && git push origin stable
```

Manual fleet order (least -> most critical): `k8s-node04 -> k8s-node03 ->
k8s-node02 -> k8s-node01 -> k8s-pi01 -> k8s-pi02 -> k8s-pi03 ->
k8s-server01 -> k8s-server02 -> k8s-server03`.

Gatekeeper:
```bash
./scripts/comin-approve.sh
```
Run 1 waits for both canaries to converge (deploy done **and** not
suspended, node Ready where applicable) and prints "merge main -> stable".
Run it again after the merge: it verifies canaries again, then auto-accepts
the fleet in order with a `kubectl get node` wait between hosts. Aborts if
a canary (or any host) is suspended — the health gate rolled it back.

Runner requirements (portable since 2026-08-26, macOS optional):
ssh access to all 12 hosts by `<hostname>.casa.arrieta` (bind zone;
override the suffix with `COMIN_DOMAIN`), `jq`, `kubectl` with node
read access. Desktop notifications only fire when `osascript` exists.

#### Hermes rollout account (`modules/nixos/hermes-ssh.nix`)

Every comin host (`cominGitOps.enable`) gets a `hermes` user for the
hermes agent to run `scripts/comin-approve.sh`. Key-only login (locked
password), authorized key wrapped with an SSH forced command
(`/etc/hermes-allowlist`, `no-pty,no-port-forwarding,...`) that allows
**exactly** `comin status --json` and `comin confirmation accept`;
everything else is logged to `/var/log/hermes-ssh.log` and rejected.
Note: comin's grpc socket (`/var/lib/comin/grpc.sock`) is chmod 0777 by
the daemon itself, so host-side access control = SSH auth + this forced
command; keep the agent's private key restricted on the runner side.

Health gate (`postDeploymentCommand`, all 12 hosts): per-host `checks`.
k3s hosts (node05 + fleet) check the default route, the k3s service, and
that `/run/current-system` matches the switched generation's `out_path`.
`llm01` checks current-system plus llama-cpp-server (active **and** listening
on `:8001`, with a warmup retry for model reloads). Auto-heal (restore route
from the SOPS `network_env` / restart k3s) and on persistent failure roll back
the comin profile (`/nix/var/nix/profiles/system-profiles/comin`, NOT
`nixos-rebuild --rollback`) and suspend comin. On `COMIN_STATUS=failed` it
suspends comin. Note: after a rollback `deployer.deployment.status` stays
`"done"` — the approve script detects rollback via `is_suspended`, not status.

Metric: `comin_pending_confirmation` is written to
`/var/lib/node-exporter/textfiles/comin.prom` every 60s and scraped by the
cluster Prometheus via the DS node_exporter textfile mount.

#### Partial-Switch + GC Dangling Binaries (incident 2026-08-26, k8s-node05)

A switch that dies mid-activation leaves the system in a split state: home-manager
files are already updated (fish config sourced atuin hooks), but `/run/current-system`
never advances. The health gate then rolls back to the old generation, and the next
nix-sweep GC deletes the discarded generation's closure — so the *new* config now
references binaries that no longer exist (`which atuin` → not found on every prompt,
`ls` alias to eza broken). Recovery: fix the switch blocker (here: stale iscsi node
db + missing `/run/lock/iscsi`), manual deploy, verify `readlink /run/current-system`.

Hardening added 2026-08-26:

- `modules/nixos/openiscsi.nix`: iscsid `preStart` self-heals an unreadable node db
  (wipes `/etc/iscsi/nodes` + `send_targets` only when `iscsiadm -m node` fails) and
  creates `/run/lock/iscsi`; tmpfiles rule covers early boots. Removes the abort
  trigger at its source.
- `modules/nixos/comin-health-gate.nix`: new `iscsi` check (default-on for k3s hosts,
  no-op without `openiscsi.enable`) — heals once, rolls back if still broken.
- Lesson: any failed switch must be followed by a redeploy **before** nix-sweep's GC
  runs, or expect dangling binaries in per-user/HM profiles.

#### TODO features (not yet implemented)
- [ ] Alert rule `comin_pending_confirmation > 0` — blocked on enabling Alertmanager.
- [ ] Pi closure-copy: after package trims, build once on pi01 then
      `nix-copy-closure --to k8s-pi02 / --to k8s-pi03` (kernel drv
      unaffected by trims; pi01 kernel build currently running in
      background).
- [ ] Reboot watchdog (`modules/nixos/comin-reboot.nix` on k8s-server01):
      drain -> reboot -> uncordon per host when
      `/run/current-system/kernel` != `/run/booted-system/kernel`;
      skip servers, llm01 notify-only.
- [ ] Migrate remaining hosts to 26.05: pi02 -> pi03; final sweep.
- [ ] Replace the hardcoded `comin.devices` target list in
      `k8s-casa/apply/50-apps/monitoring/prom-scrapes.yaml` with k8s
      autodiscovery (`kubernetesSDConfigs.role: node`, relabel
      `__meta_kubernetes_node_address_InternalIP` -> `$IP:4243`, plus
      `instance`/`node`/`hostname` labels). Covers all cluster nodes
      automatically; non-node hosts (llm01, esphome) stay as a small
      static list.

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
