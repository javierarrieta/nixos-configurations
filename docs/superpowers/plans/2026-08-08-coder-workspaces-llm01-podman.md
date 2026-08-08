# Coder Workspaces on llm01 via Rootless Podman — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision Coder OSS workspaces as rootless Podman containers on llm01, driven by the built-in Coder provisioner through the Docker provider's mutually authenticated TLS API, with workspace homes persisted on TrueNAS iSCSI volumes and a workspace image served from an in-cluster registry.

**Architecture:** Coder OSS's built-in provisioner runs Terraform in the Coder provisioner pod. The Docker provider reaches rootless Podman on llm01 through a mutually authenticated TLS Docker-compatible API. A root-owned, mTLS-protected iSCSI helper on llm01 handles TrueNAS API calls, iSCSI attach/detach, filesystem creation, and mounts. The template creates an iSCSI-backed Podman named volume and runs the workspace container from a NixOS image pulled from `registry.l.arrieta.eu`.

**Tech Stack:** NixOS 25.11, rootless podman, Coder v2.35.x, Terraform docker provider (kreuzwerker/docker), TrueNAS API v2.0, k3s + FluxCD (k8s-casa), SOPS.

## Global Constraints

- Workspace resources bounded: `memory_gb` default 4, min 2, max 8, step 1; `cpu_count` default 8, min 2, max 24, step 2.
- Registry FQDN is **`registry.l.arrieta.eu`** (LAN-only), TLS via existing `l-arrieta-eu-cert` secret (reflected into `casa`).
- No GPU access in workspaces.
- Running workspace count must be explicitly limited if only one active workspace is allowed; provisioner build concurrency is not an active-workspace limit.
- Never commit plaintext secrets; Podman TLS credentials, helper credentials, and TrueNAS API credentials live in SOPS/Kubernetes Secrets.
- Workspace iSCSI targets live under TrueNAS dataset `tank/iscsi/k8s/`; IQN basename is `iqn.2005-10.org.freenas.ctl`.
- `coder` user on llm01: system user, uid/gid 27003, home `/home/coder`, shell `pkgs.bash`, `linger = true`, `extraGroups = [ "podman" ]`, subuid/subgid ranges `100000-165535`; owns rootless Podman.
- Coder server runs in `casa` namespace, chart v2.35.1, access URL `https://coder.home.arrieta.eu`.
- TrueNAS API credentials for target provisioning must be supplied through SOPS at deployment/runtime; never include the key value in this document. TrueNAS uses `allowInsecure: true` on https 192.168.0.6:443.
- All NixOS code formatted with `nixfmt` (2-space indent), k8s manifests YAML consistent with k8s-casa conventions, pinned image tags.

---

### Task 1: llm01 rootless Podman TLS API + `coder` user module (`coder-host.nix`)

**Files:**
- Create: `modules/nixos/coder-host.nix`
- Modify: `hosts/llm01/configuration.nix` (import + enable)
- Test: `nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace` (must evaluate)

**Interfaces:**
- Consumes: existing `modules/nixos/openiscsi.nix` (option `openiscsi.enable`), existing `sops-base.nix` (`config.sops.secrets."..."` pattern).
- Produces: option `coderHost.enable` (bool), a TLS-protected rootless Podman Docker API, user `coder` (uid 27003), and a privileged iSCSI helper service.

No Coder CLI, external provisioner key, or external provisioner daemon is installed on llm01; Terraform execution remains in Coder's built-in provisioner.

- [ ] **Step 1: Create `modules/nixos/coder-host.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.coderHost = {
    enable = lib.mkEnableOption "Coder container host (rootless Podman API + iSCSI helper)";
    podmanApiAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:2376";
      description = "TLS Podman API listen address; restrict access with firewall rules";
    };
  };

  config = lib.mkIf config.coderHost.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = false;
    };

    openiscsi.enable = true;

    # Runtime dependencies for the root-owned iSCSI helper.
    environment.systemPackages = with pkgs; [
      curl
      python3
      jq
      iscsi-initiator-utils
    ];

    users.groups.coder = {
      gid = 27003;
    };

    users.users.coder = {
      isSystemUser = true;
      group = "coder";
      uid = 27003;
      home = "/home/coder";
      shell = pkgs.bash;
      linger = true;
      extraGroups = [ "podman" ];
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };

    # Run Podman's Docker-compatible API as the coder user with mTLS. The
    # server certificate/key and client CA are provisioned through SOPS.
    systemd.user.services.podman-api = {
      description = "Rootless Podman Docker API";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.podman}/bin/podman system service --time=0 --tls-cert=/run/secrets/podman/server.crt --tls-key=/run/secrets/podman/server.key --tls-client-ca=/run/secrets/podman/client-ca.crt tcp://${config.coderHost.podmanApiAddress}";
        Environment = "REGISTRY_AUTH_FILE=/run/secrets/registry/coder-auth.json";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.tmpfiles.rules = [
      "d /home/coder/.config/containers 0700 coder coder -"
      "d /srv/coder 0755 root root -"
      "d /srv/coder/workspaces 0755 root root -"
    ];

    # The iSCSI helper is root-owned and exposes only authenticated lifecycle
    # operations; it is not invoked through Terraform local-exec on the host.
    systemd.services.coder-iscsi-helper = {
      description = "Coder workspace iSCSI helper";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "/run/current-system/sw/bin/coder-iscsi-helper";
        User = "root";
        Restart = "on-failure";
      };
    };
  };
}
```

- [ ] **Step 2: Define the Podman mTLS and iSCSI helper interfaces**

Generate a dedicated CA, llm01 server certificate, and Coder provisioner client certificate. Store private material in SOPS/Kubernetes Secrets. Define the helper's authenticated `create`, `attach`, `detach`, and `destroy` operations, including validation, idempotency, filesystem formatting, mount readiness, and error responses.

- [ ] **Step 3: Verify the NixOS options used exist**

Run NixOS evaluation and verify the Podman user service, TLS credentials, firewall rules, openiscsi module, and helper service all evaluate.

**Note:** explicitly import `modules/nixos/openiscsi.nix`; it is not automatically imported by enabling `openiscsi.enable`.

- [ ] **Step 4: Wire the module into llm01**

Edit `hosts/llm01/configuration.nix`:

Add to `imports` (after `../../modules/nixos/comin.nix`):
```nix
    ../../modules/nixos/coder-host.nix
```

Add module enablement after `cominGitOps.pollInterval = 900;`:
```nix
  coderHost.enable = true;
```

Do not configure a Coder provisioner key or external provisioner service on llm01.

- [ ] **Step 5: Evaluate the llm01 config**

Run: `nix --extra-experimental-features 'nix-command flakes' eval .#nixosConfigurations.llm01.config.system.build.toplevel.drvPath`

Expected: prints a `/nix/store/...drv` path. If it fails on an unknown option, fix the option spelling before continuing.

- [ ] **Step 6: Commit**

```bash
git add modules/nixos/coder-host.nix hosts/llm01/configuration.nix
git commit -m "feat(llm01): rootless Podman TLS API and iSCSI helper"
```

---

### Task 2: Podman mTLS, helper credentials, and Kubernetes Secret wiring

**Files:**
- Modify: `secrets.yaml`, `.sops.yaml`, `hosts/llm01/configuration.nix`, `../k8s-casa/apply/01-secrets/casa/coder-podman-client-secrets.yaml`, `../k8s-casa/apply/50-apps/casa/coder.yaml`

**Interfaces:**
- Produces: Podman server TLS credentials and iSCSI-helper credentials on llm01, plus a SOPS-encrypted Kubernetes Secret containing the Coder provisioner's Podman client bundle. No Coder external-provisioner key or TrueNAS credential is required.

- [ ] **Step 1: Decrypt secrets.yaml**

Run: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d secrets.yaml > /tmp/secrets.dec.yaml`

Expected: file written. **Never commit `/tmp/secrets.dec.yaml`.**

- [ ] **Step 2: Add only runtime credentials**

Edit `/tmp/secrets.dec.yaml` — add dedicated llm01-only keys for the Podman server certificate/private key, client CA, and iSCSI helper authentication. The Coder provisioner client bundle is managed separately in `../k8s-casa/apply/01-secrets/casa/coder-podman-client-secrets.yaml`; do not add a TrueNAS key to the Coder template or Kubernetes Secret.

```yaml
coder:
    podman_server_key: <SOPS value>
    podman_server_cert: <SOPS value>
    podman_client_ca: <SOPS value>
    iscsi_helper_key: <SOPS value>
```

Create the Kubernetes Secret with `data.ca.pem`, `data.cert.pem`, and `data.key.pem`, encrypt it with the existing k8s-casa SOPS workflow, and place it under `apply/01-secrets/casa/` with the `-secrets.yaml` naming convention.

Add these values to the existing Coder HelmRelease in `../k8s-casa/apply/50-apps/casa/coder.yaml`:

```yaml
      volumes:
        - name: coder-podman-client
          secret:
            secretName: coder-podman-client-secrets
      volumeMounts:
        - name: coder-podman-client
          mountPath: /run/secrets/coder-podman-client
          readOnly: true
```

The Docker provider uses `cert_path = "/run/secrets/coder-podman-client"`; it must find exactly `ca.pem`, `cert.pem`, and `key.pem`. The Secret is mounted into the Coder server/provisioner pod, never into workspace containers.

- [ ] **Step 3: Re-encrypt and verify**

Run: `sops -e /tmp/secrets.dec.yaml > secrets.yaml && rm /tmp/secrets.dec.yaml`

Then: `grep -c "ENC\[" secrets.yaml` — Expected: number > 0 (fully encrypted).

- [ ] **Step 4: Add the llm01 age key to `.sops.yaml`**

The `coder` user does not have its own age key. llm01's SOPS decryption uses the bootstrap age key `age1rlvgte0l7225vqdusvkzmdqmsyfd3u255rfy7ku93xx99k4vldsqhxnyxx` (already in the key group). Confirm it is present:

Read `.sops.yaml` and verify all three age keys listed in the current creation rule include the bootstrap key. If a dedicated key for llm01 exists in `hosts/llm01/` or was generated during bootstrap, add it. Otherwise the existing bootstrap key suffices.

- [ ] **Step 5: Regenerate file key material if needed**

Run: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys secrets.yaml -y` (if `sops updatekeys` fails on passphrase, skip — the manual `.sops.yaml` + manual edit in Step 2 already put the secret under all recipients).

- [ ] **Step 6: Mount and verify credentials only at intended consumers**

Run the NixOS secret verification for llm01, then from `../k8s-casa` run `make validate` and inspect the rendered Coder Deployment to confirm the Secret is mounted only at `/run/secrets/coder-podman-client`.

Expected: llm01 decrypts only its own runtime credentials; Kubernetes decrypts only the client bundle; no Coder template parameter, Terraform command, or Git-tracked plaintext contains a credential.

- [ ] **Step 7: Commit**

```bash
git add secrets.yaml .sops.yaml
git commit -m "secrets: add Podman and iSCSI helper credentials"
```

---

### Task 3: NixOS workspace image (`coder-workspace` package)

**Files:**
- Create: `pkgs/coder-workspace/default.nix`
- Modify: `flake.nix` (add `packages.x86_64-linux.coder-workspace`)
- Test: `nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace`

**Interfaces:**
- Consumes: `nixpkgs` (pinned, x86_64-linux).
- Produces: Docker image tarball at `result`; pushed to registry as `registry.l.arrieta.eu/coder-workspace:<tag>`.

- [ ] **Step 1: Create `pkgs/coder-workspace/default.nix`**

```nix
{
  pkgs,
}:
pkgs.dockerTools.buildImage {
  name = "coder-workspace";
  tag = "latest";
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = with pkgs; [
      bash
      bashInteractive
      coreutils
      git
      curl
      cacert
      gcc
      gnumake
      binutils
      findutils
      grep
      sed
      which
      openssh
    ];
    pathsToLink = [ "/bin" ];
  };
  runAsRoot = ''
    ${pkgs.dockerTools.shadowSetup}
    groupadd --gid 1000 coder
    useradd --uid 1000 --gid 1000 --create-home --home-dir /home/coder --shell /bin/bash coder
    chmod 0755 /home/coder
    chown 1000:1000 /home/coder
  '';
  config = {
    User = "1000:1000";
    WorkingDir = "/home/coder";
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=/home/coder"
    ];
    Cmd = [ "/bin/bash" ];
  };
}
```

The image is built from the pinned flake inputs, so there are no mutable remote base-image digests to resolve. The fixed UID/GID must remain aligned with the iSCSI helper's filesystem ownership strategy.

- [ ] **Step 2: Register the package in `flake.nix`**

After the last `packages.*` entry (near line 558), add:

```nix
      packages.x86_64-linux.coder-workspace =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        import ./pkgs/coder-workspace { inherit pkgs lib; };
```

(`lib` is available in the `outputs` function scope as `nixpkgs.lib`.)

- [ ] **Step 3: Build and inspect the image**

Run: `nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace --print-build-logs`

Expected: succeeds; `result` is a Docker image tar. Load it into a local Podman/Docker engine and verify `/etc/passwd`, `/home/coder`, UID/GID 1000, non-root execution, and shell startup.

- [ ] **Step 4: Commit**

```bash
git add pkgs/coder-workspace/default.nix flake.nix flake.lock
git commit -m "feat(coder): add NixOS coder-workspace container image"
```

---

### Task 4: In-cluster registry (`registry.l.arrieta.eu`)

**Files:**
- Create: `../k8s-casa/apply/50-apps/casa/registry.yaml`
- Create: `../k8s-casa/apply/01-secrets/casa/registry-auth-secrets.yaml`

**Interfaces:**
- Consumes: storage class `truenas-iscsi`, cert secret `l-arrieta-eu-cert` (reflected into `casa`), Traefik ingress controller, SOPS, and the cluster-side Flux Kustomizations.
- Produces: authenticated registry service reachable at `https://registry.l.arrieta.eu` (Ingress terminates TLS and forwards to Service port 5000).

- [ ] **Step 1: Create `registry.yaml`** (mirrors the spec's manifest sketch, fixed for k8s-casa conventions)

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pv-claim
  namespace: casa
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: truenas-iscsi
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: casa
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
        - name: registry
          image: registry:2.8.3
          ports:
            - containerPort: 5000
          env:
            - name: REGISTRY_AUTH
              value: htpasswd
            - name: REGISTRY_AUTH_HTPASSWD_REALM
              value: Registry Realm
            - name: REGISTRY_AUTH_HTPASSWD_PATH
              value: /auth/htpasswd
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
            - name: auth
              mountPath: /auth
              readOnly: true
          resources:
            limits:
              memory: 512Mi
              cpu: 500m
            requests:
              memory: 128Mi
              cpu: 100m
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: registry-pv-claim
        - name: auth
          secret:
            secretName: registry-auth-secrets
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: casa
spec:
  selector:
    app: registry
  ports:
    - protocol: TCP
      port: 5000
      targetPort: 5000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: registry-ingress
  namespace: casa
spec:
  rules:
    - host: registry.l.arrieta.eu
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: registry
                port:
                  number: 5000
  tls:
    - hosts: [registry.l.arrieta.eu]
      secretName: l-arrieta-eu-cert
```

- [ ] **Step 2: Confirm the cluster-side Flux Kustomizations pick it up**

Run: `flux get kustomizations -A` and inspect the `k8s-casa-secrets` and `k8s-casa-apps` paths. This repository does not use a local `kustomization.yaml` glob for these directories; verify the cluster-side Kustomizations include `apply/01-secrets` and `apply/50-apps`.

- [ ] **Step 3: Deploy via Flux**

Run: `git -C ../k8s-casa add apply/01-secrets/casa/registry-auth-secrets.yaml apply/50-apps/casa/registry.yaml && git -C ../k8s-casa commit -m "feat(casa): authenticated in-cluster docker registry" && git -C ../k8s-casa push`

Then wait for Flux reconciliation or reconcile the actual `k8s-casa-secrets` and `k8s-casa-apps` Kustomizations.

- [ ] **Step 4: Verify registry is up**

Run: `curl -sI --max-time 10 https://registry.l.arrieta.eu/v2/ | head -1`

Expected: `HTTP/2 401` without credentials, proving the registry and TLS ingress are up. Verify authenticated access separately with the provisioned registry credentials.

Create the SOPS-encrypted `registry-auth-secrets.yaml` with a `data.htpasswd` entry containing the bcrypt/Apache htpasswd record. Provision a matching read-only pull credential to llm01's `coder` Podman auth file; the image-push credential is kept separately on the image-build machine. Do not put registry credentials in the Coder template parameters or Terraform source.

- [ ] **Step 5: Commit (k8s-casa)**

Covered by Step 3's commit.

---

### Task 5: Root-owned llm01 iSCSI helper and client

**Files:**
- Create: `coder/templates/llm01-podman/scripts/truenas-iscsi-helper-client.sh` and the root-owned llm01 helper service
- Test: run the script standalone against TrueNAS with a throwaway workspace name, then verify the target/zvol and destroy it.

**Interfaces:**
- Consumes: mTLS helper endpoint, operation, workspace name, and size. TrueNAS credentials remain only on llm01.
- Produces: authenticated helper requests for create/attach/detach/destroy; the helper creates `tank/iscsi/k8s/<volume>` zvols, iSCSI targets, extents, filesystems, and mounts.

The helper API listens on `https://llm01:2377` and requires a client certificate issued by the private Coder-provisioner CA. llm01 firewall rules allow this port only from the Coder provisioner network. The root-owned service reads the TrueNAS API credential from SOPS; no Coder parameter carries it.

Contract:

- `POST /v1/workspaces/<workspace>/provision` with `{ "size_gb": N }`
- `POST /v1/workspaces/<workspace>/attach`
- `POST /v1/workspaces/<workspace>/detach`
- `DELETE /v1/workspaces/<workspace>`

The helper validates workspace names with `^[a-z0-9][a-z0-9-]{0,62}$`, accepts 10–200 GiB, uses argument-vector subprocess execution, serializes operations per workspace, and returns structured JSON errors. New zvols are formatted exactly once as ext4 and assigned ownership compatible with the image's fixed `coder` UID/GID. Existing or unknown filesystems are never reformatted.

- [ ] **Step 1: Implement the helper service and client**

Create a small Python standard-library HTTPS service installed on llm01 as a root-owned systemd unit. Use `ThreadingHTTPServer` with an `ssl.SSLContext` configured for server certificate, private key, and required client certificate verification. The handler must:

1. Validate the mTLS peer, HTTP method/path, workspace-name regex, and 10–200 GiB size range.
2. Acquire a per-workspace lock before any lifecycle operation.
3. Invoke `iscsiadm`, `mkfs.ext4`, `mount`, `umount`, and TrueNAS API calls with argument arrays or structured HTTP requests—never shell interpolation.
4. Reconcile existing TrueNAS objects by name and refuse to reformat a non-empty or unknown block device.
5. Return JSON `{ "ok": true, ... }` on success and `{ "ok": false, "error": "..." }` with an appropriate 4xx/5xx status on failure.

Create `truenas-iscsi-helper-client.sh` for the Coder provisioner pod. It validates its inputs, calls the four helper endpoints with the mounted client certificate, waits for a successful response, and exits non-zero on structured helper errors. It must not contain or receive the TrueNAS API credential.

- [ ] **Step 2: Test helper create + destroy end-to-end**

Run:
```bash
CODER_HELPER_URL=https://llm01:2377 CODER_HELPER_CERT_DIR=/run/secrets/coder-podman-client WORKSPACE=plancicdtest SIZE_GB=10 bash coder/templates/llm01-podman/scripts/truenas-iscsi-helper-client.sh provision
CODER_HELPER_URL=https://llm01:2377 CODER_HELPER_CERT_DIR=/run/secrets/coder-podman-client WORKSPACE=plancicdtest bash coder/templates/llm01-podman/scripts/truenas-iscsi-helper-client.sh destroy
```

Expected: the helper returns success for provision and destroy; the zvol, target, extent, and mount are present after provision and absent after destroy. Verify cleanup from llm01 using the helper's structured status endpoint or direct root-only diagnostics. Do not place a TrueNAS API key in the test command.

- [ ] **Step 3: Commit**

```bash
git add modules/nixos/coder-host.nix coder/templates/llm01-podman/scripts/truenas-iscsi-helper-client.sh
git commit -m "feat(coder): add llm01 iSCSI helper and client"
```

---

### Task 6: Coder template `llm01-podman`

**Files:**
- Create: `coder/templates/llm01-podman/main.tf`
- Create: `coder/templates/llm01-podman/.terraform.lock.hcl`
- Create: `coder/templates/llm01-podman/README.md` (push instructions)
- Test: `coder templates push llm01-podman` then a workspace create.

**Interfaces:**
- Consumes: the mTLS iSCSI helper client (Task 5), `coder-workspace` image (Task 3), registry (Task 4), and Coder's built-in provisioner.
- Produces: workspace template named `llm01-podman` using the built-in provisioner.

- [ ] **Step 1: Create `main.tf`**

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.17"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
  }
}

provider "coder" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "Memory (GB)"
  description  = "Container memory limit in GB (2-8)"
  type         = "number"
  default      = 4
  validation {
    min = 2
    max = 8
  }
  mutable = true
}

data "coder_parameter" "cpu_count" {
  name         = "cpu_count"
  display_name = "CPU count"
  description  = "Container CPU limit (2-24)"
  type         = "number"
  default      = 8
  validation {
    min = 2
    max = 24
  }
  mutable = true
}

data "coder_parameter" "disk_gb" {
  name         = "disk_gb"
  display_name = "Disk size (GB)"
  description  = "Size of the workspace home volume on TrueNAS (10-200)"
  type         = "number"
  default      = 20
  validation {
    min = 10
    max = 200
  }
  mutable = false
}

provider "docker" {
  host      = "tcp://llm01:2376"
  cert_path = "/run/secrets/coder-podman-client"
}

# Run `terraform init` in the template directory and commit the generated
# `.terraform.lock.hcl`; provider checksums are part of the template input.

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }
}

# Request iSCSI lifecycle operations from the helper on llm01. This client runs
# inside the Coder provisioner pod; TrueNAS credentials never enter Terraform.
resource "terraform_data" "truenas_target" {
  input = {
    workspace = data.coder_workspace.me.name
  }

  provisioner "local-exec" {
    when    = create
    command = "CODER_HELPER_URL=https://llm01:2377 CODER_HELPER_CERT_DIR=/run/secrets/coder-podman-client WORKSPACE='${data.coder_workspace.me.name}' SIZE_GB='${data.coder_parameter.disk_gb.value}' bash ${path.module}/scripts/truenas-iscsi-helper-client.sh provision"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "CODER_HELPER_URL=https://llm01:2377 CODER_HELPER_CERT_DIR=/run/secrets/coder-podman-client WORKSPACE='${self.input.workspace}' bash ${path.module}/scripts/truenas-iscsi-helper-client.sh destroy"
  }
}

resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.name}-home"

  driver = "local"
  driver_opts = {
    type   = "none"
    o      = "bind"
    device = "/srv/coder/workspaces/coder-${data.coder_workspace.me.name}"
  }
  depends_on = [terraform_data.truenas_target]
}

resource "docker_image" "workspace" {
  # Podman uses the read-only registry auth file provisioned for coder on
  # llm01; no registry credential is embedded in this template.
  name = "registry.l.arrieta.eu/coder-workspace:<pinned-tag>"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  name  = "coder-${data.coder_workspace.me.name}"
  image = docker_image.workspace.image_id

  memory = data.coder_parameter.memory_gb.value * 1024
  cpus   = tostring(data.coder_parameter.cpu_count.value)

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
  }

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  # init_script embeds the agent URL and token wiring; the container runs it
  # directly (official Coder docker template pattern).
  command = ["sh", "-c", coder_agent.main.init_script]
  depends_on = [terraform_data.truenas_target]
}

resource "coder_metadata" "workspace_info" {
  count = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id
  item {
    key   = "workspace"
    value = data.coder_workspace.me.name
  }
}
```

- [ ] **Step 2: Boot-time remount of workspace targets**

The helper attaches and mounts the target during `provision` (live path). On a **host reboot**, the helper's boot reconciliation logs in to known Coder targets and remounts them before a workspace restart. Keep this logic inside the root-owned helper/service boundary; do not expose `iscsiadm` to the Coder provisioner pod. Add the helper's boot reconciliation unit to `modules/nixos/coder-host.nix` (in the `config` block):

```nix
    # After openiscsi auto-logs-in recorded targets at boot, mount every coder
    # workspace target back to its /srv/coder/workspaces path.
    systemd.services.iscsi-mount-workspaces = {
      description = "Mount Coder workspace iSCSI targets";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "iscsi.service" ];
      requires = [ "iscsi.service" ];
      script = ''
        for target in $(iscsiadm -m session -o table 2>/dev/null | awk '$2 ~ /iqn.2005-10.org.freenas.ctl:coder-/ {print $2}'); do
          ws=${target#*:coder-}
          dev=/dev/disk/by-path/ip-192.168.0.6:3260-iscsi-${target}-lun-0
          [ -e "$dev" ] || continue
          mkdir -p "/srv/coder/workspaces/coder-${ws}"
          mountpoint -q "/srv/coder/workspaces/coder-${ws}" || mount "$dev" "/srv/coder/workspaces/coder-${ws}"
        done
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };
```

**Note:** the helper owns iscsiadm/by-path wiring and mount readiness. The Terraform client waits for the helper's success response; no host mount commands run in `local-exec`. The unit shown is a boot-time helper reconciliation service and must invoke the same validated code path as the HTTPS API.

- [ ] **Step 3: Write `README.md` with push + workspace instructions**

```markdown
# llm01-podman Coder Template

Workspaces run as rootless podman containers on llm01 with homes on TrueNAS iSCSI volumes.

## Push

```bash
coder login https://coder.home.arrieta.eu
coder templates push llm01-podman \
  --directory coder/templates/llm01-podman \
  --yes
```

The built-in Coder provisioner runs the template and reaches llm01 through the configured mTLS Podman API.

## Creating a workspace

1. Choose `memory_gb` (2-8) and `cpu_count` (2-24).
2. The template requests iSCSI provisioning through the authenticated llm01 helper.
3. The helper provisions the target, mounts it, and the Docker provider starts the container.
4. Stop/start preserves `/home/coder` (data on TrueNAS). Delete tears down the target + zvol.
```

- [ ] **Step 4: Push the template**

Run:
```bash
coder templates push llm01-podman \
  --directory coder/templates/llm01-podman \
  --yes
```

Expected: template pushed; the built-in provisioner runs the build (verify in Coder UI under Templates → llm01-podman → activity).

- [ ] **Step 5: Create a test workspace**

In the Coder UI create a workspace from `llm01-podman` (memory 2, cpu 2, disk 10). Expected states: Connecting → Running. If the build fails, inspect the Coder build log and llm01 helper/Podman logs.

- [ ] **Step 6: Verify persistence**

```bash
coder ssh <workspace-name> -- touch /home/coder/persist-test.txt
coder stop <workspace-name>
coder start <workspace-name>
coder ssh <workspace-name> -- test -f /home/coder/persist-test.txt && echo PERSISTS
```

Expected: `PERSISTS`.

- [ ] **Step 7: Commit**

```bash
git add coder/templates/llm01-podman
git commit -m "feat(coder): llm01-podman template with iSCSI-backed podman volumes"
```

---

### Task 7: Push workspace image + smoke-test registry pull

**Files:**
- Modify: `pkgs/coder-workspace/default.nix` (pinned tag)
- Test: push to registry, pull from llm01 as the `coder` user.

**Interfaces:**
- Consumes: Task 3 image build, Task 4 registry.
- Produces: `registry.l.arrieta.eu/coder-workspace:<short-sha>` pinned tag used by the template.

- [ ] **Step 1: Determine the image tag**

Run: `git rev-parse --short HEAD` — use the output as the tag.

- [ ] **Step 2: Load and push the image**

Authenticate to the registry on the image-build machine with the dedicated push credential before pushing. Do not record the credential in shell history or the plan.

```bash
nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace
docker load -i result
docker tag coder-workspace:latest registry.l.arrieta.eu/coder-workspace:<short-sha>
docker push registry.l.arrieta.eu/coder-workspace:<short-sha>
```

(If the local docker daemon isn't configured, use `podman load`/`podman push` or `skopeo copy docker-archive:result docker://registry.l.arrieta.eu/coder-workspace:<short-sha>`.)

- [ ] **Step 3: Update the template image reference**

Edit `coder/templates/llm01-podman/main.tf`:
```hcl
  name = "registry.l.arrieta.eu/coder-workspace:<short-sha>"
```
Then push the template again (Task 6, Step 4).

- [ ] **Step 4: Pull smoke test as the coder user on llm01**

Run (on llm01):
```bash
sudo -u coder podman pull registry.l.arrieta.eu/coder-workspace:<short-sha>
```

Expected: pulls over LAN with valid LE TLS (no insecure-registry config).

- [ ] **Step 5: Commit**

```bash
git add coder/templates/llm01-podman/main.tf
git commit -m "feat(coder): pin workspace image to registry tag <short-sha>"
```

---

### Task 8: Full system verification

**Files:** none (verification only)

**Interfaces:** consumes all prior tasks.

- [ ] **Step 1: llm01 NixOS checks**

Run on llm01:
```bash
sudo nixos-rebuild switch --flake .#llm01
id coder                       # uid=27003
 systemctl --user status podman-api # active as coder
sudo -u coder podman info | grep -i rootless   # rootless true
sudo -u coder curl --unix-socket /run/user/27003/podman/podman.sock http://localhost/libpod/_ping
curl --cert /run/secrets/coder-podman-client/cert.pem --key /run/secrets/coder-podman-client/key.pem --cacert /run/secrets/coder-podman-client/ca.pem https://llm01:2376/_ping
```

- [ ] **Step 2: Registry + image checks**

```bash
curl -sI --max-time 10 https://registry.l.arrieta.eu/v2/ | head -1   # HTTP/2 401 without credentials
curl -sk -H "Authorization: Bearer $KEY" "https://192.168.0.6/api/v2.0/pool/dataset/id/tank%2Fiscsi%2Fk8s" | grep -c "coder-"  # 0 clean
```

- [ ] **Step 3: Workspace lifecycle**

Create → Running → write file → stop → start → file persists → delete → verify TrueNAS zvol/target gone and podman volume removed.

- [ ] **Step 4: Update AGENTS.md if anything changed**

Add a `Coder workspaces (llm01)` section documenting the built-in provisioner, mTLS Podman API, template, and TrueNAS helper flow.

---

## Self-Review Notes

- **Spec coverage:** Spec's components 1 (coder-host.nix/helper), 2 (image), 3 (registry), 4 (template) map to Tasks 1/2, 3, 4, 6 respectively; verification spec section maps to Task 8; data-flow/lifecycle map to Task 6 + 8.
- **Placeholders:** Three intentional, labeled placeholders remain, each with an explicit resolution command: the `nixos/nix` image digest in Task 3 (Step 1), the exact iSCSI by-path device name in Task 6 (Step 2 note), and the coder v2.35.1 `fetchurl` hash in Task 1 (Step 2).
- **Type/name consistency:** `coder-host.nix` options (`coderHost.enable`, `coderHost.podmanApiAddress`), helper endpoint, workspace naming `coder-<ws>`, IQN `iqn.2005-10.org.freenas.ctl:coder-<ws>`, TLS API endpoint, and uid/gid 27003 are used consistently across tasks.
- **Verified against upstream sources:**
  - docker provider schema: `docker_container` uses `memory` (Int MB) and `cpus` (String) — NOT `cpu` (confirmed in `resource_docker_container.go:852,1168`). The plan uses `cpus = tostring(...)`.
  - Coder template pattern: official docker template relies on `init_script` (embeds agent URL) + `CODER_AGENT_TOKEN`; `provider.coder.url` is not a valid reference (confirmed in `examples/templates/docker/main.tf`). Plan fixed accordingly.
  - `coder_parameter` `validation { min, max }` syntax confirmed in `docs/data-sources/parameter.md`.
  - TrueNAS API v2.0 endpoints for zvol/target/extent/targetextent and the `iqn.2005-10.org.freenas.ctl` basename confirmed live against TrueNAS at 192.168.0.6 and against democratic-csi `src/driver/freenas/ssh.js`.
  - Built-in provisioner runs Terraform in the Coder pod; Docker provider uses the mTLS Podman API and the helper handles privileged iSCSI operations.
- **Concurrency:** provisioner build concurrency does not enforce a one-running-workspace policy; add an explicit policy if required.
- **Version skew (caught in review):** nixpkgs coder 2.28.6 / unstable 2.33.11 both mismatch the deployed server 2.35.1; Task 1 pins v2.35.1 via `fetchurl`. This is why `pkgs.coder` from nixpkgs is not used directly.
