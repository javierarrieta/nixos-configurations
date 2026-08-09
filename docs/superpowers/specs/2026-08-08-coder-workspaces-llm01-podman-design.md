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

### Repository boundaries and delivery

This checkout owns only the llm01 NixOS changes and the design documentation. The implementation spans three independently deployed repositories: this `nixos-configurations` repository for `modules/nixos/coder-host.nix`, the llm01 host import, the helper service, and the `coder-workspace` flake package; the `k8s-casa` repository for the registry manifests and SOPS/Helm Secret mounts; and the Coder template repository for the pinned Docker/helper-client providers and `llm01-podman` Terraform template. The implementation plan must link the exact repository and path for each change rather than assuming those trees are present here.

Delivery is ordered so each dependency is verifiable before the next is enabled: (1) land and test the llm01 host/helper changes without opening the APIs broadly; (2) deploy the registry and provisioner Secrets through Flux/Helm; (3) run the compatibility and helper-client spikes; (4) publish the pinned workspace image; (5) deploy the template disabled or to an administrator-only group; and (6) perform the end-to-end workspace test. Rollback is the reverse: disable/delete the template, stop and clean workspaces, remove the registry workload/Secret mounts, then revert the llm01 module. SOPS-encrypted secrets are created or rotated only in their owning repository; no plaintext secret or private key is copied between repositories.

## Constraints

- **No GPU access** in workspaces — the AMD GPU stays reserved for host llama.cpp/ComfyUI services.
- **Full container per workspace** — isolated filesystem/user, no shared-home conflicts.
- **Podman** (rootless) as the container engine on llm01.
- **One active workspace at a time** on llm01 (enforced by an atomic helper lease; provisioner build concurrency alone is insufficient).
- **NixOS-based workspace image**, built in the flake, served from a registry in the k3s cluster.
- **TrueNAS iSCSI-backed volumes** for workspace home persistence, mounted on llm01 and bind-mounted into the container as podman named volumes. democratic-csi provisions k8s PVCs only; the workspace volumes are provisioned directly via the TrueNAS API.
- **Resource limits** on containers (generous but bounded) so a runaway workspace can't starve host LLM services.
- Agent binary **downloaded via init_script** (server-version-matched), not baked into the image.

## Approach (selected)

A new Coder template (`llm01-podman`) uses the **docker provider** running from Coder OSS's built-in provisioner. The provider connects to rootless Podman on llm01 through its mTLS-protected Docker-compatible TCP API and creates a container from the NixOS image pulled from the k8s registry.

### Compatibility gate

Before implementing the iSCSI helper or publishing the template, run a disposable compatibility spike using the exact pinned NixOS/Podman release and exact pinned `kreuzwerker/docker` provider version. From a Coder-like provisioner pod, the spike must demonstrate: mTLS client and server certificate validation; private-registry image pull with provider-supplied read-only credentials; `docker_volume` creation with the local bind driver options; bind mounting an iSCSI-like filesystem into a rootless container; enforcement of `memory` and `cpus` limits under cgroup v2; container restart and destroy; and absence of host GPU/device access. The result, including provider and Podman versions and the Terraform configuration used, is checked into the implementation evidence before the remaining components proceed. A failure blocks implementation rather than becoming an undocumented compatibility workaround.

The Podman API client certificate is a high-privilege credential: the Docker-compatible API grants the `coder` user full control of its rootless containers and permits arbitrary code execution as that user. Restrict the certificate to the Coder provisioner, limit firewall source ranges, rotate it through SOPS, and do not reuse it for the iSCSI helper or registry authentication.

### Components

1. **llm01 NixOS changes** (`modules/nixos/coder-host.nix`, imported by `hosts/llm01/configuration.nix`):
   - Enable rootless `virtualisation.podman` with a Docker-compatible TLS API service.
   - System user `coder` (home `/home/coder`, group `coder`) owns the rootless Podman service and storage.
   - Systemd user service for the `coder` user with **linger** (`users.users.coder.linger = true`) so Podman survives without an interactive login.
   - Subuid/subgid ranges for the `coder` user (rootless podman requirement).
   - TLS server certificate, private key, and client-CA configuration for the Podman API. The Coder provisioner client bundle is stored as the SOPS-encrypted `k8s-casa/apply/01-secrets/casa/coder-podman-client-secrets.yaml` and mounted into the Coder pod by Helm at `/run/secrets/coder-podman-client`.
   - A separate read-only registry pull credential is mounted into the Coder provisioner pod at a dedicated path. It is not provisioned to llm01's `coder` account; the Docker provider runs in the provisioner pod and must supply registry authentication in its remote image-pull request.
   - A root-owned iSCSI helper service/API with a narrow operation surface and mTLS authentication.
   - Enable **openiscsi** (reuse existing `modules/nixos/openiscsi.nix`) so llm01 can connect the TrueNAS workspace targets.
   - Mount target: workspace iSCSI targets mount at `/srv/coder/workspaces/<ws>` through the root-owned helper. After mounting, the helper runs a narrowly scoped command as `coder` via `podman unshare` to set the workspace root to container UID/GID `1000:1000` in the active rootless namespace. It must not chown to host UID/GID `1000:1000`, because container UID 1000 maps to a subordinate host ID.

2. **NixOS workspace image** (flake package `coder-workspace`):
   - Built reproducibly with `pkgs.dockerTools.buildImage` without a remote base-image dependency.
   - Explicitly creates and runs as non-root `coder` UID/GID 1000 inside the container.
   - Creates `/home/coder`; the iSCSI helper assigns its ownership from inside the `coder` user's rootless namespace before exposing the bind mount.
   - Minimal runtime contract: provide a real `/bin/sh` (backed by the pinned Bash package), `bash`, `git`, `curl`, build essentials, `cacert`, and a deterministic `PATH`; do not assume that adding a Nix store package automatically creates FHS `/bin` symlinks.
   - Create writable `/tmp`, `/run`, and `/home/coder` directories with appropriate modes, set `USER` to `coder:coder`, set `HOME=/home/coder`, and use an explicit shell entrypoint that keeps the container alive for Coder's command. No root entrypoint, privileged mode, host PID/network mode, device mounts, or GPU requests are permitted.
   - Agent binary downloaded by Coder's generated `init_script` at container start (no bake step).
   - Pushed to the k8s registry as a pinned tag.

3. **Registry in k3s** (`k8s-casa/apply/50-apps/casa/registry.yaml`):
   - Docker registry Deployment + Service + PVC (truenas-iscsi) + Traefik Ingress.
   - FQDN `registry.l.arrieta.eu` — LAN-only, covered by the existing `*.l.arrieta.eu` wildcard Certificate (ClusterIssuer `le-prod`, secret `l-arrieta-eu-cert` reflected into `casa`). No new cert/issuer.
   - Deployed via FluxCD (commit to `k8s-casa`, no imperative kubectl).
   - **Pinned image tag** (no `:latest`) per k8s-casa conventions.
   - Registry uses basic authentication backed by a SOPS-encrypted Kubernetes Secret. The Docker provider supplies a separate read-only pull credential from the Coder provisioner pod when requesting the remote Podman image pull; no insecure-registry config is used.
   - The registry Secret contains only the htpasswd record. Pull credentials are scoped to the provisioner and push credentials stay on the image-build machine; no registry credential is stored in llm01's `coder` home or Podman auth file.

4. **Coder template `llm01-podman`** ([`coder-templates`](https://github.com/javierarrieta/coder-templates), `llm01-podman/`):**
   - No provisioner tag is required. No TrueNAS API key is a template parameter; the template calls the authenticated iSCSI helper.
   - `coder_parameter` `memory_gb` (default 4, min 2, max 8, step 1), `cpu_count` (default 8, min 2, max 24, step 2), and `disk_gb` (default 50, min 10, max 200, step 10) — bounded so a workspace can't starve host LLM services or exhaust TrueNAS capacity. Memory/CPU values are mutable through a workspace update; disk size is immutable after creation and requires delete/recreate to change.
   - Pin the `kreuzwerker/docker` provider version and use `provider "docker"` with `host = "tcp://llm01:2376"` and `cert_path = "/run/secrets/coder-podman-client"`. The mounted bundle contains only `ca.pem`, `cert.pem`, and `key.pem`; no secret is a template parameter.
   - `docker_image` pulls the workspace image from `registry.l.arrieta.eu` using an explicit read-only `registry_auth` configuration (or the pinned provider's equivalent) backed by the provisioner-mounted secret. The image name contains no URL scheme.
   - **Target provisioning** via a pinned Terraform helper-client resource. The persistent target resource calls `provision` on create/update and `DELETE` on destroy; a separate start-counted mount resource acquires the workspace capability and calls `attach`, then calls `detach` and releases the capability on destroy. Terraform dependencies force target → mount → volume → container creation and container → volume → mount → target destruction. The in-cluster provisioner never receives host-level mount privileges.
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
     - `memory = data.coder_parameter.memory_gb.value * 1024` (MB), `cpus = tostring(data.coder_parameter.cpu_count.value)`.
     - `cpus` is the Docker provider's CPU-count limit; do not use `cpu` or `cpu_shares`, which either are not valid for this resource or provide only relative weighting rather than a hard cap.
     - Env `CODER_AGENT_TOKEN`, `CODER_AGENT_URL`.
     - `command` runs `coder_agent.main.init_script`.
   - `coder_metadata` for display.
   - Workspace resource bounds are enforced by the template. Build serialization is provided by the built-in provisioner, while the helper's global active-workspace lease limits already-running workspaces to one.

### iSCSI Helper Contract

The helper listens on llm01 at `https://<llm01>:2377`, with a server certificate and client-CA verification. The llm01 firewall permits port 2377 only from the Coder provisioner network. The helper's TrueNAS API credential is available only to the root-owned service through SOPS. mTLS identifies the Coder provisioner as the sole caller; it is not, by itself, authorization to operate on an arbitrary workspace.

Requests use JSON and a workspace identifier matching `^[a-z0-9][a-z0-9-]{0,62}$`. Disk sizes are integers from 10 to 200 GiB. Subprocesses receive validated argument arrays; the helper never constructs shell commands from request values.

Endpoints:

- `POST /v1/workspaces/<workspace>/provision` with `{ "size_gb": N }`: create or reconcile the TrueNAS zvol, iSCSI target, extent, target association, filesystem, login, and mount. It is idempotent for the same workspace and size.
- `POST /v1/workspaces/<workspace>/attach`: log in and mount an existing target, waiting for the device and mount readiness. It does not format an existing filesystem.
- `POST /v1/workspaces/<workspace>/detach`: stop using the mount, unmount it, and log out without deleting TrueNAS data.
- `DELETE /v1/workspaces/<workspace>`: detach first, then remove target association, extent, target, and zvol. It is idempotent when the workspace is already absent.

The helper also maintains a durable global active-workspace lease. `POST /v1/lease/<workspace>/acquire` atomically claims the lease for the named workspace or returns a structured conflict identifying the current holder. A successful claim returns an opaque, high-entropy capability; acquiring it again for the same workspace requires the existing capability and is idempotent. `POST /v1/lease/<workspace>/release` requires that capability and releases only that workspace's lease; it is idempotent when already released. The template passes the capability to every provision, attach, detach, and delete request in an authorization header. The helper stores only a hash of the capability, compares it in constant time, never logs it, and invalidates it on release. The template acquires the lease before provisioning/attaching and releases it only after the container has been destroyed and the mount detached. Delete always attempts release, including cleanup after a failed build.

The helper serializes operations per workspace and the global lease operations, and reports structured errors. Lease state, including the capability hash and workspace identity, is stored on llm01 using an atomic lock/state file owned by the root service. A boot reconciliation step inspects Coder-owned Podman containers and clears a lease whose holder has no corresponding running container; it must fail closed when inspection is unavailable. Provisioning, attach, detach, and delete reject missing, malformed, or mismatched capabilities before contacting TrueNAS or changing mounts. Provisioning formats a new blank zvol exactly once (ext4 with a unique label derived from the validated workspace identifier); it refuses to format a non-empty or unknown device. The helper then runs `podman unshare chown 1000:1000` as the `coder` user against the verified workspace mount. This avoids assuming container UID 1000 equals host UID 1000 or hardcoding a subuid offset; `podman unshare` uses the active `/etc/subuid` and `/etc/subgid` mappings. Ownership preparation is idempotent.

The template must use a pinned helper-client Terraform provider (or an equivalent resource implementation with the same semantics), not ad-hoc shell calls whose destroy ordering is implicit. The client treats the capability as sensitive state, sends it only over the mTLS connection, and implements bounded retries for idempotent operations. A failed create/update must be safe to retry; a failed destroy must remain visible as a failed Terraform resource and must not silently release the lease before detach/delete has completed.

## Data Flow (workspace start)

1. User clicks "Create workspace" on `llm01-podman` and picks `memory_gb`/`cpu_count`/`disk_gb`.
2. Coder's built-in provisioner runs Terraform in the provisioner pod:
   - The persistent target resource calls the helper to reconcile the TrueNAS target and filesystem.
   - The start-counted mount resource acquires the capability, attaches the target, waits for `/srv/coder/workspaces/coder-<workspace>` to be mounted, and passes the capability to dependent resources.
   - The Docker provider talks to rootless Podman over the mTLS-protected Docker-compatible API on llm01.
   - `docker_image` pulls `registry.l.arrieta.eu/coder-workspace:<tag>` (valid TLS via ingress).
   - `docker_volume` creates the podman named volume as a bind mount of the iSCSI-mounted host dir.
   - `docker_container` creates the container with limits + iSCSI-backed volume.
   - Container runs `init_script` → downloads agent → agent reverse-tunnels to Coder server.
3. Workspace shows "Running"; VS Code via `coder-remote` connects through the tunnel.

## Lifecycle

- **Start**: provision target → attach mount → create container + image + volume.
- **Stop**: `start_count = 0` destroys the container and volume, then the mount resource detaches the iSCSI filesystem and releases the capability; the persistent iSCSI target and data remain.
- **Restart**: apply re-attaches mount, recreates container, remounts volume; `$HOME` intact.
- **Delete**: full destroy removes container + volume, detaches and releases the mount capability, then removes the persistent target and filesystem; data is removed from TrueNAS.
- **Host reboot**: workspace shows stopped; the helper's boot reconciliation clears only stale leases and does not mount or start workspaces. When the user starts the workspace, Terraform re-acquires the lease, re-attaches the existing target, waits for mount readiness, and recreates the container. Data remains safe on TrueNAS.
- **Concurrency**: the built-in provisioner serializes builds according to its configured concurrency, and the helper lease rejects a second active workspace even when separate builds complete successfully.

## Error Handling

- **Provisioner/API failure** (mTLS invalid, Podman API down, helper unavailable): the build fails or remains pending in Coder; inspect Coder provisioner logs and llm01 helper/Podman service logs.
- **Image pull failure** (registry down, tag missing): `docker_image` errors; retry on re-start.
- **Target provisioning failure** (TrueNAS API, target already exists, zvol conflict): the helper rejects the operation before the container is created; workspace build fails with the helper error.
- **Mount failure** (iscsiadm/session, fs type): the mount resource fails before the volume/container resources are created; Terraform destroy releases the capability and leaves the persistent target for an explicit retry or cleanup.
- **Container create failure** (limits, volume conflict): dependent resources are destroyed in reverse order, then the mount detaches and releases its capability; target data remains unless the workspace itself is deleted.
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

0. Complete and record the compatibility gate before implementing the helper or template.
1. Record the implementation commit IDs and repository paths for the NixOS, k8s-casa, and Coder-template changes; verify each repository's deployment/rollback owner before enabling the integration.
2. `nixos-rebuild switch --flake .#llm01` → confirm podman running, `coder` user exists (uid 27003), the mTLS Docker API is reachable only from the Coder provisioner network, the iSCSI helper is active, and openiscsi is active.
3. `nix build .#coder-workspace`; run the image locally as UID/GID 1000 and verify `/bin/sh -c`, `curl` against a TLS endpoint, CA validation, writable `/tmp` and `/home/coder`, `HOME`, `PATH`, and absence of host devices/GPU access. Execute the actual generated Coder `init_script` in this image and confirm the agent download starts successfully.
4. Push the image to the registry; unauthenticated `curl -I https://registry.l.arrieta.eu/v2/` returns 401, the provisioner-mounted read-only credential succeeds through `docker_image`, and a push attempt with that credential is rejected.
5. Standalone iSCSI helper run: acquire a lease, create + destroy a test target/zvol end-to-end, verify requests without the capability are rejected, and confirm the capability is not present in helper logs.
6. Standalone helper-client and docker-provider Terraform run from the Coder provisioner pod confirms the target → mount → volume → container graph, reverse-order stop/delete behavior, mTLS access, and that the pinned provider accepts `cpus` and Podman enforces the requested cgroup CPU limit.
7. Start two workspaces concurrently; confirm exactly one acquires the lease and the other receives a structured conflict without creating a container or deleting the first workspace's volume.
8. Push template `llm01-podman`; create workspace; confirm Running; confirm the iSCSI target is mounted and visible in the container at `/home/coder`.
9. `coder ssh` into workspace, write a file, stop/start the workspace, confirm the file persists (data on TrueNAS), verify `id -u`/`id -g` reports `1000:1000` while the host mount ownership resolves through the `coder` rootless mapping, and confirm stop releases the lease.
10. Reboot or restart the helper with a running container; confirm reconciliation preserves the valid lease, while a stale lease is cleared only when no matching running container exists.

## Open Items (confirm during implementation)

- Exact NixOS Podman TLS service options and certificate paths, resolved by the compatibility gate before implementation.
- Kubernetes Secret mounting and Docker provider TLS attribute names.
- iSCSI helper API authentication, authorization, and retry/idempotency behavior.
- Existing ClusterIssuer name (`le-prod`) and cert reflection namespace list.
- Registry image version pin (e.g. `registry:2.8.3`).
- TrueNAS API auth: token vs basic auth; endpoint paths for zvol/target/extent/association creation (TrueNAS `freenas-api-iscsi` style, matching democratic-csi's secret usage — API key + `allowInsecure: true` confirmed).
- Exact helper-client Terraform provider/resource implementation, capability handling, retry policy, and dependency graph for create, stop, restart, failed apply, and destroy.
- Rootless Podman access is resolved by the `podman unshare` ownership-preparation step above; implementation must test this on the pinned Podman/NixOS versions.
- Exact `kreuzwerker/docker` provider version; pin it before template deployment and test its `cpus` behavior against the pinned Podman version.
- Exact provider registry-auth configuration and provisioner Secret mount path; verify remote Podman pulls succeed without any credential in llm01's `coder` home.

## Out of Scope

- GPU access in workspaces.
- Multi-workspace concurrency.
- Home-manager / per-user customization inside the image (minimal image only).
- Auto-scaling or image versioning beyond a pinned tag.
