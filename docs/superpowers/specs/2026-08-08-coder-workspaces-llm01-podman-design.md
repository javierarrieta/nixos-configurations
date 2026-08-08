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

**Provisioner architecture**: The docker provider runs from a **Coder external provisioner daemon on llm01 itself** (started with `coder provisioner start` as a systemd user service), NOT from the in-cluster provisioner pod. This was chosen after research showed the kreuzwerker docker provider shells out to the *system `ssh` binary on the provisioner host*, so running it in the cluster pod would require installing an ssh client there and provisioning key material into the pod (which lands in Terraform state). Running the provisioner on llm01 means the docker provider reaches rootless podman via the **local unix socket** (`unix:///run/user/<uid>/podman/podman.sock`) — no SSH, no key material, no state exposure. An additional bonus: **each provisioner daemon runs only one concurrent workspace build**, which enforces one-workspace-at-a-time for free.

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

A new Coder template (`llm01-podman`) uses the **docker provider** running from an **external provisioner daemon on llm01**, pointed at the local rootless podman unix socket. The provider creates a container from the NixOS image (pulled from the k8s registry) and runs the Coder agent inside it.

### Components

1. **llm01 NixOS changes** (`modules/nixos/coder-host.nix`, imported by `hosts/llm01/configuration.nix`):
   - Enable rootless `virtualisation.podman` with the docker-compatible socket.
   - System user `coder` (home `/home/coder`, group `coder`). POSIX login shell (bash) but no interactive use — it exists only to own the provisioner daemon and the rootless podman storage.
   - Systemd **user** services for the `coder` user with **linger** (`users.users.coder.linger = true`) so the rootless podman socket and the Coder provisioner daemon survive without an interactive login.
   - Subuid/subgid ranges for the `coder` user (rootless podman requirement).
   - The **Coder external provisioner daemon** as a systemd user service: runs `coder provisioner start` with `CODER_URL=https://coder.home.arrieta.eu` and a scoped provisioner key (created via `coder provisioner keys create llm01-podman --org default --tag llm01=podman`, stored in `secrets.yaml`). The daemon dials the Coder server over the LAN.
   - `DOCKER_HOST=unix:///run/user/<uid>/podman/podman.sock` for the `coder` user so the docker provider (running in the daemon) reaches rootless podman.
   - Enable **openiscsi** (reuse existing `modules/nixos/openiscsi.nix`) so llm01 can connect the TrueNAS workspace targets.
   - Mount target: workspace iSCSI targets mount at `/srv/coder/workspaces/<ws>` (root-owned systemd `.mount`); the podman bind mount resolves permissions via subuid/subgid mapping.

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
   - Provisioner **tags** route jobs to the llm01 external provisioner: `coder_workspace_tags` (or `--provisioner-tag llm01=podman` on push).
   - `coder_parameter` `truenas_api_key` (secret) for target provisioning. No `docker_host`/`ssh_private_key` parameters — the provider uses the local unix socket via `DOCKER_HOST`/`host`.
   - `coder_parameter` `memory_gb` (default 4, min 2, max 8, step 1) and `cpu_count` (default 8, min 2, max 24, step 2) — bounded so a workspace can't starve host LLM services. Values chosen at creation; immutable per workspace, changed via workspace update.
   - `provider "docker"` with `host = "unix:///run/user/<uid>/podman/podman.sock"` (uid resolved from the provisioner's runtime). No SSH, no key material.
   - `docker_image` pulls the workspace image from the registry.
   - **Target provisioning** via a TrueNAS API script (create zvol + iSCSI target + extent + association) run through `local-exec` before the container; destroys on teardown. Runs on llm01 (the provisioner host), which reaches TrueNAS at `192.168.0.6:443` directly.
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
   - **One workspace at a time** enforced by the single external provisioner daemon (one concurrent build per daemon), no template-level limit needed.

## Data Flow (workspace start)

1. User clicks "Create workspace" on `llm01-podman`; pastes `truenas_api_key`, picks `memory_gb`/`cpu_count`.
2. Coder server queues the job with tag `llm01=podman`; the **external provisioner daemon on llm01** picks it up and runs Terraform locally:
   - `local-exec` calls TrueNAS API → creates zvol + iSCSI target + extent + association for `coder-<workspace>`.
   - llm01 systemd mounts the new target at `/srv/coder/workspaces/coder-<workspace>` (via `iscsiadm` triggered by the template or a mount helper unit).
   - docker provider talks to rootless podman over `unix:///run/user/<uid>/podman/podman.sock`.
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
- **Concurrency**: single external provisioner daemon = one concurrent build at a time.

## Error Handling

- **Provisioner/daemon failure** (key invalid, daemon down, can't reach Coder): build job stays Pending in the Coder UI; logs on llm01 (`journalctl --user -u coder-provisioner`) show the daemon error.
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
    provisionerKeyFile = lib.mkOption { type = lib.types.path; };  # sops secret with coder provisioner key
    coderUrl = lib.mkOption { type = lib.types.str; };            # https://coder.home.arrieta.eu
  };

  config = lib.mkIf config.coderHost.enable {
    virtualisation.podman = {
      enable = true;
      dockerSocket.enable = true;
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
    # systemd user service: coder-provisioner running:
    #   coder provisioner start
    #     CODER_URL=https://coder.home.arrieta.eu
    #     CODER_PROVISIONER_DAEMON_KEY=<contents of provisionerKeyFile>
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

1. `nixos-rebuild switch --flake .#llm01` → confirm podman running, `coder` user exists (uid 27003), rootless socket answers the docker API at `unix:///run/user/27003/podman/podman.sock`, openiscsi active, `coder-provisioner` user service connected to Coder.
2. `nix build .#coder-workspace`, push to registry; `curl -I https://registry.l.arrieta.eu/v2/` returns 200.
3. Standalone TrueNAS API script run: create + destroy a test target/zvol end-to-end.
4. Standalone docker-provider terraform run as the `coder` user on llm01 confirms container create over the local unix socket.
5. Push template `llm01-podman`; create workspace; confirm Running; confirm the iSCSI target is mounted and visible in the container at `/home/coder`.
6. `coder ssh` into workspace, write a file, stop/start the workspace, confirm the file persists (data on TrueNAS).

## Open Items (confirm during implementation)

- Exact `dockerSocket.enable` socket path and DOCKER_HOST wiring for the `coder` user session (root-level `/run/podman/podman.sock` vs rootless `/run/user/<uid>/podman/podman.sock`).
- `users.users.*.linger` option shape (confirmed to exist in NixOS; exact spelling `linger = true`).
- Provisioner key provisioning via sops (key created via `coder provisioner keys create`, never stored plaintext).
- Existing ClusterIssuer name (`le-prod`) and cert reflection namespace list.
- Registry image version pin (e.g. `registry:2.8.3`).
- TrueNAS API auth: token vs basic auth; endpoint paths for zvol/target/extent/association creation (TrueNAS `freenas-api-iscsi` style, matching democratic-csi's secret usage — API key + `allowInsecure: true` confirmed).
- How the template's `local-exec` triggers/waits for the iSCSI mount on llm01 (systemd `iscsi` units vs explicit `iscsiadm` in the template).
- Rootless podman access to a root-owned mount at `/srv/coder/workspaces/<ws>` (permissions/ownership strategy for the bind-mounted volume).

## Out of Scope

- GPU access in workspaces.
- Multi-workspace concurrency.
- Home-manager / per-user customization inside the image (minimal image only).
- Auto-scaling or image versioning beyond a pinned tag.
