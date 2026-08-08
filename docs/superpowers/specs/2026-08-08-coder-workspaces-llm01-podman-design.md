# Coder Workspaces on llm01 via Podman — Design

Date: 2026-08-08

## Context

Coder OSS runs in the k3s cluster (`k8s-casa`) and provisions workspaces as Kubernetes pods via the kubernetes provider. The user wants workspaces provisioned on `llm01` instead for **better local performance** (CPU/RAM/disk) than the shared cluster nodes.

A prior attempt ran Coder agents directly on the llm01 host OS as a shared `coder` user over SSH. That approach produced a series of failures:

- Non-interactive SSH shell chained `bashrc -> exec fish` recursively, fork-bombing the host (`fenv` foreign-env plugin spawns bash, which execs fish again).
- The `coder` user's shell defaulted to `nologin`, breaking the file provisioner.
- Leftover files/directories at `/home/coder/.cache/coder` from old template versions blocked provisioning.
- Shared-home concurrency and per-workspace teardown were fragile.

This design replaces the SSH-on-host approach with **containerized workspaces** on llm01 via **rootless podman**, driven by Coder's **docker provider**. Each workspace is an isolated container; the agent runs inside it. The entire class of host-shell/shared-home problems disappears.

## Constraints

- **No GPU access** in workspaces — the AMD GPU stays reserved for host llama.cpp/ComfyUI services.
- **Full container per workspace** — isolated filesystem/user, no shared-home conflicts.
- **Podman** (rootless) as the container engine on llm01.
- **One workspace at a time** on llm01 (enforced via Coder template concurrency limit).
- **NixOS-based workspace image**, built in the flake, served from a registry in the k3s cluster.
- **TrueNAS iSCSI-backed volumes** for workspace home persistence, mounted on llm01 and bind-mounted into the container as podman named volumes. democratic-csi provisions k8s PVCs only; the workspace volumes are provisioned directly via the TrueNAS API.
- **Resource limits** on containers (generous but bounded) so a runaway workspace can't starve host LLM services.
- Agent binary **downloaded via init_script** (server-version-matched), not baked into the image.

## Approach (selected)

A new Coder template (`llm01-podman`) uses the **docker provider** pointed at llm01's rootless podman via **SSH** (`docker_host = ssh://coder@llm01`). The provider creates a container from the NixOS image (pulled from the k8s registry) and runs the Coder agent inside it.

### Components

1. **llm01 NixOS changes** (`modules/nixos/coder-host.nix`, imported by `hosts/llm01/configuration.nix`):
   - Enable rootless `virtualisation.podman` with the docker-compatible socket.
   - System user `coder` (home `/home/coder`, group `coder`), SSH-authorized key for the docker provider transport. POSIX login shell (bash) but no interactive use — SSH is transport-only.
   - Systemd user **linger** for the `coder` user so the rootless podman socket survives without an interactive login.
   - Subuid/subgid ranges for the `coder` user (rootless podman requirement).
   - `DOCKER_HOST` for the SSH session pointing at `/run/user/<uid>/docker.sock` (via the docker provider's SSH `env` or the user's SSH environment).
   - Enable **openiscsi** (reuse existing `modules/nixos/openiscsi.nix`) so llm01 can connect the TrueNAS workspace targets.
   - Mount target: workspace iSCSI targets mount at `/srv/coder/workspaces/<ws>` (root-owned systemd `.mount`).

2. **NixOS workspace image** (flake package `coder-workspace`):
   - Built with `pkgs.dockerTools.buildImage` from a pinned `nixos/nix` base.
   - Runs as a non-root `coder` user inside the container.
   - Minimal packages: `bash`, `git`, `curl`, build essentials.
   - Agent binary downloaded by Coder's generated `init_script` at container start (no bake step).
   - Pushed to the k8s registry as a pinned tag.

3. **Registry in k3s** (`k8s-casa/apply/50-apps/casa/registry.yaml`):
   - Docker registry Deployment + Service + PVC (truenas-iscsi) + Traefik Ingress.
   - FQDN `registry.l.arrieta.eu` — LAN-only, covered by the existing `*.l.arrieta.eu` wildcard Certificate (ClusterIssuer `le-prod`, secret `l-arrieta-eu-cert` reflected into `casa`). No new cert/issuer.
   - Deployed via FluxCD (commit to `k8s-casa`, no imperative kubectl).
   - **Pinned image tag** (no `:latest`) per k8s-casa conventions.
   - Podman on llm01 pulls over the LAN using trusted LE TLS (no insecure-registry config).

4. **Coder template `llm01-podman`** (`coder/templates/llm01-podman/`):
   - `coder_parameter` `docker_host` (default `ssh://coder@192.168.0.29`), `ssh_private_key` (secret, `form_type = "textarea"`), and `truenas_api_key` (secret) for target provisioning.
   - `coder_parameter` `memory_gb` (default 4, min 2, max 8, step 1) and `cpu_count` (default 8, min 2, max 24, step 2) — bounded so a workspace can't starve host LLM services. Values chosen at creation; immutable per workspace, changed via workspace update.
   - `provider "docker"` with `host`, `ssh_key`, `ssh_opts` from the parameters. Key material written via Coder's mkfile mechanism so it stays out of state.
   - `docker_image` pulls the workspace image from the registry.
   - **Target provisioning** via a TrueNAS API script (create zvol + iSCSI target + extent + association) run through `local-exec` before the container; destroys on teardown.
   - `docker_volume` per workspace = podman named volume backed by the iSCSI mount:
     ```hcl
     driver     = "local"
     driver_opts = {
       type   = "none"
       o      = "bind"
       device = "/srv/coder/workspaces/coder-${data.coder_workspace.me.name}"
     }
     ```
   - `docker_container` (count = `data.coder_workspace.me.start_count`) creates the container:
     - mounts the iSCSI-backed volume at `/home/coder`.
     - `memory = data.coder_parameter.memory_gb.value * 1024` (MB), `cpu = data.coder_parameter.cpu_count.value`.
     - Env `CODER_AGENT_TOKEN`, `CODER_AGENT_URL`.
     - `command` runs `coder_agent.main.init_script`.
   - `coder_metadata` for display.
   - Template **concurrency limit** enforces one-workspace-at-a-time.

## Data Flow (workspace start)

1. User clicks "Create workspace" on `llm01-podman`; pastes `ssh_private_key` and `truenas_api_key`, picks `docker_host`.
2. Provisioner pod runs Terraform:
   - `local-exec` calls TrueNAS API → creates zvol + iSCSI target + extent + association for `coder-<workspace>`.
   - docker provider authenticates to `ssh://coder@llm01` with the key, sets `DOCKER_HOST=/run/user/<uid>/docker.sock`.
   - (llm01) systemd mounts the new target at `/srv/coder/workspaces/coder-<workspace>`; the docker provider's SSH session discovers/attaches the mount.
   - `docker_image` pulls `registry.l.arrieta.eu/coder-workspace:<tag>` (valid TLS via ingress).
   - `docker_volume` creates the podman named volume as a bind mount of the iSCSI-mounted host dir.
   - `docker_container` creates the container with limits + iSCSI-backed volume.
   - Container runs `init_script` → downloads agent → agent reverse-tunnels to Coder server.
3. Workspace shows "Running"; VS Code via `coder-remote` connects through the tunnel.

## Lifecycle

- **Start**: provision target → attach mount → create container + image + volume.
- **Stop**: `start_count = 0` destroys the container; iSCSI target + mount + volume persist.
- **Restart**: apply re-attaches mount, recreates container, remounts volume; `$HOME` intact.
- **Delete**: full destroy removes container + volume + target + mount; data removed from TrueNAS.
- **Host reboot**: workspace shows stopped; user starts it; mount re-attached on boot via systemd, container recreated. Data safe on TrueNAS.
- **Concurrency**: Coder template concurrency limit = 1.

## Error Handling

- **SSH/docker_host failure** (bad key, missing user, socket down): docker provider errors fast; message visible in build logs.
- **Image pull failure** (registry down, tag missing): `docker_image` errors; retry on re-start.
- **Target provisioning failure** (TrueNAS API, target already exists, zvol conflict): `local-exec` errors before the container is created; workspace build fails with the API error.
- **Mount failure** (iscsiadm/session, fs type): container create fails; destroy-then-retry cleans leftovers.
- **Container create failure** (limits, volume conflict): apply fails; destroy-then-retry cleans leftovers.
- **Agent crash mid-session**: Coder shows "agent lost connection"; reconnect restarts tunnel; container stays up.
- **Leaked target/volume** (delete didn't clean): TrueNAS API cleanup script + podman `prune` tracked in implementation.

## llm01 NixOS Config Sketch

```nix
# modules/nixos/coder-host.nix
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.coderHost = {
    enable = lib.mkEnableOption "Coder container host on llm01";
    dockerHostKey = lib.mkOption { type = lib.types.str; };  # ssh-ed25519 public key
  };

  config = lib.mkIf config.coderHost.enable {
    virtualisation.podman = {
      enable = true;
      dockerSocket.enable = true;
    };
    openiscsi.enable = true;   # reuse existing module; iSCSI initiator for workspace targets
    users.users.coder = {
      isSystemUser = true;
      group = "coder";
      home = "/home/coder";
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = [ config.coderHost.dockerHostKey ];
    };
    users.groups.coder = {};
    systemd.user.linger = [ "coder" ];   # subject to option shape
    # subuid/subgid for coder
    # workspace targets mount via per-target systemd .mount at /srv/coder/workspaces/<ws>
  };
}
```

## Registry Manifest Sketch

```yaml
# k8s-casa/apply/50-apps/casa/registry.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: registry-pv-claim, namespace: casa }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: truenas-iscsi
  resources: { requests: { storage: 20Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: registry, namespace: casa }
spec:
  replicas: 1
  selector: { matchLabels: { app: registry } }
  template:
    metadata: { labels: { app: registry } }
    spec:
      containers:
        - name: registry
          image: registry:2.8.3
          ports: [{ containerPort: 5000 }]
          volumeMounts: [{ name: data, mountPath: /var/lib/registry }]
          resources:
            limits: { memory: 512Mi, cpu: 500m }
            requests: { memory: 128Mi, cpu: 100m }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: registry-pv-claim }
---
apiVersion: v1
kind: Service
metadata: { name: registry, namespace: casa }
spec:
  selector: { app: registry }
  ports: [{ protocol: TCP, port: 5000, targetPort: 5000 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: registry-ingress, namespace: casa }
spec:
  rules:
    - host: registry.l.arrieta.eu
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: registry, port: { number: 5000 } } }
  tls:
    - hosts: [registry.l.arrieta.eu]
      secretName: l-arrieta-eu-cert
```

## Verification

1. `nixos-rebuild switch --flake .#llm01` → confirm podman running, `coder` user exists, rootless socket answers the docker API, openiscsi active.
2. `nix build .#coder-workspace`, push to registry; `curl -I https://registry.l.arrieta.eu/v2/` returns 200.
3. Standalone TrueNAS API script run: create + destroy a test target/zvol end-to-end.
4. Standalone docker-provider terraform run from the provisioner path confirms SSH → podman create.
5. Push template `llm01-podman`; create workspace; confirm Running; confirm the iSCSI target is mounted and visible in the container at `/home/coder`.
6. `coder ssh` into workspace, write a file, stop/start the workspace, confirm the file persists (data on TrueNAS).

## Open Items (confirm during implementation)

- Exact `dockerSocket.enable` socket path and DOCKER_HOST wiring for the SSH session.
- Linger option shape (`systemd.user.linger` vs `users.users.*.linger`).
- Coder template concurrency-limit option name in provider v2.18.0.
- Existing ClusterIssuer name (`le-prod`) and cert reflection namespace list.
- Registry image version pin (e.g. `registry:2.8.3`).
- TrueNAS API auth: token vs basic auth; endpoint paths for zvol/target/extent/association creation (TrueNAS `freenas-api-iscsi` style, matching democratic-csi's secret usage).
- How the docker provider's SSH session triggers/waits for the iSCSI mount on llm01 (systemd `iscsi` units vs explicit `iscsiadm` in the template).
- Rootless podman access to a root-owned mount at `/srv/coder/workspaces/<ws>` (permissions/ownership strategy for the bind-mounted volume).

## Out of Scope

- GPU access in workspaces.
- Multi-workspace concurrency.
- Home-manager / per-user customization inside the image (minimal image only).
- Auto-scaling or image versioning beyond a pinned tag.
