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

**Provisioner architecture**: Coder OSS's built-in provisioner runs the Docker provider from the Coder provisioner pod in k3s. It reaches rootless Podman on llm01 through a Docker-compatible API exposed over **mutually authenticated TLS**. llm01 firewall rules restrict the API to the Coder provisioner network. No external provisioner daemon or local Unix socket is used.

The Docker provider cannot execute llm01 host commands from the in-cluster provisioner. Workspace iSCSI lifecycle operations therefore use a small, root-owned, mutually authenticated helper service on llm01. The template calls that helper for create, attach, detach, and destroy; the helper validates workspace names and sizes and performs the privileged `iscsiadm`, filesystem, and mount operations.

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

A new Coder template (`llm01-podman`) uses the **docker provider** running from Coder OSS's built-in provisioner. The provider connects to rootless Podman on llm01 through its mTLS-protected Docker-compatible TCP API and creates a container from the NixOS image pulled from the k8s registry.

### Components

1. **llm01 NixOS changes** (`modules/nixos/coder-host.nix`, imported by `hosts/llm01/configuration.nix`):
   - Enable rootless `virtualisation.podman` with a Docker-compatible TLS API service.
   - System user `coder` (home `/home/coder`, group `coder`) owns the rootless Podman service and storage.
   - Systemd user service for the `coder` user with **linger** (`users.users.coder.linger = true`) so Podman survives without an interactive login.
   - Subuid/subgid ranges for the `coder` user (rootless podman requirement).
   - TLS server certificate, private key, and client-CA configuration for the Podman API. The Coder provisioner client bundle is stored as the SOPS-encrypted `k8s-casa/apply/01-secrets/casa/coder-podman-client-secrets.yaml` and mounted into the Coder pod by Helm at `/run/secrets/coder-podman-client`.
   - A root-owned iSCSI helper service/API with a narrow operation surface and mTLS authentication.
   - Enable **openiscsi** (reuse existing `modules/nixos/openiscsi.nix`) so llm01 can connect the TrueNAS workspace targets.
   - Mount target: workspace iSCSI targets mount at `/srv/coder/workspaces/<ws>` through the root-owned helper; the bind mount uses an explicit filesystem ownership strategy.

2. **NixOS workspace image** (flake package `coder-workspace`):
   - Built reproducibly with `pkgs.dockerTools.buildImage` without a remote base-image dependency.
   - Explicitly creates and runs as non-root `coder` UID/GID 1000 inside the container.
   - Creates `/home/coder` with ownership and permissions suitable for the iSCSI-backed bind mount.
   - Minimal packages: `bash`, `git`, `curl`, build essentials.
   - Agent binary downloaded by Coder's generated `init_script` at container start (no bake step).
   - Pushed to the k8s registry as a pinned tag.

3. **Registry in k3s** (`k8s-casa/apply/50-apps/casa/registry.yaml`):
   - Docker registry Deployment + Service + PVC (truenas-iscsi) + Traefik Ingress.
   - FQDN `registry.l.arrieta.eu` — LAN-only, covered by the existing `*.l.arrieta.eu` wildcard Certificate (ClusterIssuer `le-prod`, secret `l-arrieta-eu-cert` reflected into `casa`). No new cert/issuer.
   - Deployed via FluxCD (commit to `k8s-casa`, no imperative kubectl).
   - **Pinned image tag** (no `:latest`) per k8s-casa conventions.
   - Registry uses basic authentication backed by a SOPS-encrypted Kubernetes Secret. Podman on llm01 pulls over the LAN using trusted LE TLS; no insecure-registry config is used.
   - The registry Secret contains only the htpasswd record. llm01's `coder` Podman service receives a separate read-only pull credential through SOPS; push credentials stay on the image-build machine.

4. **Coder template `llm01-podman`** (`coder/templates/llm01-podman/`):
   - No provisioner tag is required. No TrueNAS API key is a template parameter; the template calls the authenticated iSCSI helper.
   - `coder_parameter` `memory_gb` (default 4, min 2, max 8, step 1) and `cpu_count` (default 8, min 2, max 24, step 2) — bounded so a workspace can't starve host LLM services. Values are mutable through a workspace update and applied by Terraform to the container limits.
   - `provider "docker"` with `host = "tcp://llm01:2376"` and `cert_path = "/run/secrets/coder-podman-client"`. The mounted bundle contains only `ca.pem`, `cert.pem`, and `key.pem`; no secret is a template parameter.
   - `docker_image` pulls the workspace image from `https://registry.l.arrieta.eu` using the Podman user's provisioned registry credentials.
   - **Target provisioning** via the llm01 iSCSI helper, which calls the TrueNAS API and performs local attach/mount operations before the container; destroys on teardown. The in-cluster provisioner never receives host-level mount privileges.
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
   - Workspace resource bounds are enforced by the template. Build serialization is provided by the built-in provisioner, but this does not limit the number of already-running workspaces; an explicit workspace-count policy is required if only one active workspace is allowed.

### iSCSI Helper Contract

The helper listens on llm01 at `https://<llm01>:2377`, with a server certificate and client-CA verification. The llm01 firewall permits port 2377 only from the Coder provisioner network. The helper's TrueNAS API credential is available only to the root-owned service through SOPS.

Requests use JSON and a workspace identifier matching `^[a-z0-9][a-z0-9-]{0,62}$`. Disk sizes are integers from 10 to 200 GiB. Subprocesses receive validated argument arrays; the helper never constructs shell commands from request values.

Endpoints:

- `POST /v1/workspaces/<workspace>/provision` with `{ "size_gb": N }`: create or reconcile the TrueNAS zvol, iSCSI target, extent, target association, filesystem, login, and mount. It is idempotent for the same workspace and size.
- `POST /v1/workspaces/<workspace>/attach`: log in and mount an existing target, waiting for the device and mount readiness. It does not format an existing filesystem.
- `POST /v1/workspaces/<workspace>/detach`: stop using the mount, unmount it, and log out without deleting TrueNAS data.
- `DELETE /v1/workspaces/<workspace>`: detach first, then remove target association, extent, target, and zvol. It is idempotent when the workspace is already absent.

The helper serializes operations per workspace and reports structured errors. Provisioning formats a new blank zvol exactly once (ext4 with a stable label); it refuses to format a non-empty or unknown device. The bind-mounted filesystem is prepared for the container's fixed `coder` UID/GID, rather than relying on rootless subuid mapping to grant access.

## Data Flow (workspace start)

1. User clicks "Create workspace" on `llm01-podman` and picks `memory_gb`/`cpu_count`/`disk_gb`.
2. Coder's built-in provisioner runs Terraform in the provisioner pod:
   - The iSCSI helper calls the TrueNAS API, attaches the target, formats a new filesystem when necessary, and mounts it at `/srv/coder/workspaces/coder-<workspace>`.
   - The Docker provider talks to rootless Podman over the mTLS-protected Docker-compatible API on llm01.
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
- **Concurrency**: the built-in provisioner serializes builds according to its configured concurrency, but running-workspace count must be controlled separately.

## Error Handling

- **Provisioner/API failure** (mTLS invalid, Podman API down, helper unavailable): the build fails or remains pending in Coder; inspect Coder provisioner logs and llm01 helper/Podman service logs.
- **Image pull failure** (registry down, tag missing): `docker_image` errors; retry on re-start.
- **Target provisioning failure** (TrueNAS API, target already exists, zvol conflict): the helper rejects the operation before the container is created; workspace build fails with the helper error.
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
    podmanApiAddress = lib.mkOption { type = lib.types.str; default = "0.0.0.0:2376"; };
  };

  config = lib.mkIf config.coderHost.enable {
    virtualisation.podman = {
      enable = true;
      dockerSocket.enable = false;
      dockerCompat = true;
    };
    openiscsi.enable = true;   # reuse existing module; iSCSI initiator for workspace targets
    users.users.coder = {
      isSystemUser = true;
      group = "coder";
      uid = 27003;
      home = "/home/coder";
      shell = pkgs.bash;
      linger = true;
      extraGroups = [ "podman" ];
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
    };
    users.groups.coder = { gid = 27003; };
    # A systemd user service runs `podman system service` with mTLS.
    # A separate root-owned helper handles iSCSI lifecycle operations.
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
          env:
            - name: REGISTRY_AUTH
              value: htpasswd
            - name: REGISTRY_AUTH_HTPASSWD_REALM
              value: Registry Realm
            - name: REGISTRY_AUTH_HTPASSWD_PATH
              value: /auth/htpasswd
          volumeMounts:
            - name: auth
              mountPath: /auth
              readOnly: true
            - name: data
              mountPath: /var/lib/registry
          resources:
            limits: { memory: 512Mi, cpu: 500m }
            requests: { memory: 128Mi, cpu: 100m }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: registry-pv-claim }
        - name: auth
          secret:
            secretName: registry-auth-secrets
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

1. `nixos-rebuild switch --flake .#llm01` → confirm podman running, `coder` user exists (uid 27003), the mTLS Docker API is reachable only from the Coder provisioner network, the iSCSI helper is active, and openiscsi is active.
2. `nix build .#coder-workspace`, push to registry; unauthenticated `curl -I https://registry.l.arrieta.eu/v2/` returns 401 and authenticated access succeeds.
3. Standalone iSCSI helper run: create + destroy a test target/zvol end-to-end.
4. Standalone docker-provider Terraform run from the Coder provisioner pod confirms container creation over the mTLS Podman API.
5. Push template `llm01-podman`; create workspace; confirm Running; confirm the iSCSI target is mounted and visible in the container at `/home/coder`.
6. `coder ssh` into workspace, write a file, stop/start the workspace, confirm the file persists (data on TrueNAS).

## Open Items (confirm during implementation)

- Exact NixOS Podman TLS service options and certificate paths.
- Kubernetes Secret mounting and Docker provider TLS attribute names.
- iSCSI helper API authentication, authorization, and retry/idempotency behavior.
- Existing ClusterIssuer name (`le-prod`) and cert reflection namespace list.
- Registry image version pin (e.g. `registry:2.8.3`).
- TrueNAS API auth: token vs basic auth; endpoint paths for zvol/target/extent/association creation (TrueNAS `freenas-api-iscsi` style, matching democratic-csi's secret usage — API key + `allowInsecure: true` confirmed).
- How the template calls and waits for the iSCSI helper (including mount readiness).
- Rootless Podman access to the mounted filesystem (ownership/UID strategy for the bind-mounted volume).

## Out of Scope

- GPU access in workspaces.
- Multi-workspace concurrency.
- Home-manager / per-user customization inside the image (minimal image only).
- Auto-scaling or image versioning beyond a pinned tag.

## Future Improvements

- **Optional single-active-workspace lease:** The llm01 iSCSI helper can later enforce a global active-workspace lease. A workspace start would claim the lease and return a conflict if another workspace is active; stop/delete would release it. A boot reconciliation job would inspect Podman containers and clear stale leases. This is intentionally not required for the initial implementation.
