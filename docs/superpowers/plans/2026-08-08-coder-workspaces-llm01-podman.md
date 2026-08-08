# Coder Workspaces on llm01 via Rootless Podman — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision Coder workspaces as rootless podman containers on llm01, driven by the docker provider running from an external provisioner daemon on llm01, with workspace homes persisted on TrueNAS iSCSI volumes and a workspace image served from an in-cluster registry.

**Architecture:** A Coder external provisioner daemon runs on llm01 as a `coder` user systemd service. It executes Terraform for the `llm01-podman` template locally, reaching rootless podman via the local unix socket (`unix:///run/user/27003/podman/podman.sock`). The template creates an iSCSI target on TrueNAS (TrueNAS API v2.0), mounts it at `/srv/coder/workspaces/<ws>`, creates a podman named volume backed by that bind mount, and runs the workspace container from a NixOS image pulled from `registry.l.arrieta.eu`. The single daemon enforces one concurrent build at a time.

**Tech Stack:** NixOS 25.11, rootless podman, Coder v2.35.x, Terraform docker provider (kreuzwerker/docker), TrueNAS API v2.0, k3s + FluxCD (k8s-casa), sops-nix.

## Global Constraints

- Workspace resources bounded: `memory_gb` default 4, min 2, max 8, step 1; `cpu_count` default 8, min 2, max 24, step 2.
- Registry FQDN is **`registry.l.arrieta.eu`** (LAN-only), TLS via existing `l-arrieta-eu-cert` secret (reflected into `casa`).
- No GPU access in workspaces.
- One workspace build at a time (single provisioner daemon).
- Never commit plaintext secrets; provisioner key and TrueNAS API key live in `secrets.yaml` (sops).
- Workspace iSCSI targets live under TrueNAS dataset `tank/iscsi/k8s/`; IQN basename is `iqn.2005-10.org.freenas.ctl`.
- `coder` user on llm01: system user, uid/gid 27003, home `/home/coder`, shell `pkgs.bash`, `linger = true`, `extraGroups = [ "podman" ]`, subuid/subgid ranges `100000-165535`.
- Coder server runs in `casa` namespace, chart v2.35.1, access URL `https://coder.home.arrieta.eu`.
- TrueNAS API credentials for target provisioning must be supplied through SOPS at deployment/runtime; never include the key value in this document. TrueNAS uses `allowInsecure: true` on https 192.168.0.6:443.
- All NixOS code formatted with `nixfmt` (2-space indent), k8s manifests YAML consistent with k8s-casa conventions, pinned image tags.

---

### Task 1: llm01 rootless podman + `coder` user module (`coder-host.nix`)

**Files:**
- Create: `modules/nixos/coder-host.nix`
- Modify: `hosts/llm01/configuration.nix` (import + enable)
- Test: `nix eval .#nixosConfigurations.llm01.config.system.build.toplevel --show-trace` (must evaluate)

**Interfaces:**
- Consumes: existing `modules/nixos/openiscsi.nix` (option `openiscsi.enable`), existing `sops-base.nix` (`config.sops.secrets."..."` pattern).
- Produces: option `coderHost.enable` (bool), `coderHost.provisionerKeyFile` (path), `coderHost.coderUrl` (str); user `coder` (uid 27003); rootless podman socket at `/run/user/27003/podman/podman.sock`; systemd user service `coder-provisioner`.

**Version pin (critical):** the external provisioner daemon's version MUST match the Coder server version. The server chart is **2.35.1**; pinned nixpkgs has **2.28.6** and unstable has **2.33.11** — neither matches. Pin the coder binary to v2.35.1 via a `fetchurl` override of `pkgs.coder`. Do NOT use `pkgs.coder` directly from nixpkgs.

- [ ] **Step 1: Create `modules/nixos/coder-host.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Pin the coder CLI to the server version (2.35.1) — the external
  # provisioner daemon and the Coder server use a versioned DRPC protocol and
  # must match. nixpkgs (2.28.6) and unstable (2.33.11) are both newer/older
  # than the deployed chart, so fetch the exact binary.
  coderBinary = pkgs.coder.overrideAttrs (old: {
    version = "2.35.1";
    src = pkgs.fetchurl {
      url = "https://github.com/coder/coder/releases/download/v2.35.1/coder_2.35.1_linux_amd64.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # replace with real hash
    };
    sourceRoot = ".";
    installPhase = ''
      mkdir -p $out/bin
      install -m755 coder $out/bin/coder
    '';
  });
in {
  options.coderHost = {
    enable = lib.mkEnableOption "Coder container host (external provisioner + rootless podman)";
    provisionerKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the Coder provisioner key (sops secret)";
    };
    coderUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://coder.home.arrieta.eu";
      description = "Coder server URL the provisioner dials";
    };
  };

  config = lib.mkIf config.coderHost.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
    };

    openiscsi.enable = true;

    # The template's local-exec TrueNAS script needs curl/python3 on PATH for
    # the coder user (provisioner daemon runs as coder).
    environment.systemPackages = with pkgs; [
      curl
      python3
      jq
      iscsi-initiator-utils
    ];

    # The truenas-iscsi.sh script attaches/mounts targets as the coder user;
    # scoped passwordless sudo for exactly those commands (no general shell).
    security.sudo.extraRules = [
      {
        groups = [ ];
        users = [ "coder" ];
        commands = [
          {
            command = "${pkgs.openiscsi}/bin/iscsiadm";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.util-linux}/bin/mount";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.util-linux}/bin/umount";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.coreutils}/bin/mkdir";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.util-linux}/bin/mountpoint";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.util-linux}/bin/lsblk";
            options = [ "NOPASSWD" ];
          }
        ];
      }
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

    # Rootless podman socket for the coder user; serves the Docker API.
    systemd.user.sockets.podman = {
      wantedBy = [ "sockets.target" ];
    };

    systemd.tmpfiles.rules = [
      "d /home/coder/.config/containers 0700 coder coder -"
      "d /srv/coder 0755 root root -"
      "d /srv/coder/workspaces 0755 root root -"
    ];

    # External Coder provisioner daemon. Talks to the Coder server over LAN,
    # runs Terraform for the llm01-podman template, reaches podman via the
    # rootless socket. One daemon = one concurrent build.
    systemd.user.services.coder-provisioner = {
      description = "Coder external provisioner daemon";
      wantedBy = [ "default.target" ];
      after = [ "podman.socket" ];
      requires = [ "podman.socket" ];
      serviceConfig = {
        ExecStart = "${coderBinary}/bin/coder provisioner start";
        Environment = [
          "CODER_URL=${config.coderHost.coderUrl}"
          "CODER_PROVISIONER_DAEMON_KEY_FILE=${config.coderHost.provisionerKeyFile}"
          "DOCKER_HOST=unix:///run/user/27003/podman/podman.sock"
        ];
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    sops.secrets."coder/provisioner_key" = {
      mode = "0400";
      owner = "coder";
    };
  };
}
```

- [ ] **Step 2: Resolve the coder v2.35.1 binary hash**

Run: `nix --extra-experimental-features 'nix-command flakes' store prefetch-file https://github.com/coder/coder/releases/download/v2.35.1/coder_2.35.1_linux_amd64.tar.gz`

Expected: prints `https://...  <sha256>`. Replace the placeholder `sha256-AAAAAAAAA...` in Step 1 with `sha256-<real-base32-hash>` (re-encode the hex sha256 to base32 if prefetch prints hex — use `nix hash to-base32 <hex>`).

- [ ] **Step 3: Verify the NixOS options used exist**

Run: `nix --extra-experimental-features 'nix-command flakes' eval --impure --expr 'let pkgs = import (builtins.fetchTree { type="github"; owner="NixOS"; repo="nixpkgs"; rev="c0b0e0fddf73fd517c3471e546c0df87a42d53f4"; }) { system="x86_64-linux"; }; in pkgs.coder.pname'`

Expected: prints `"coder"` (confirms `pkgs.coder` resolves in the pinned nixpkgs rev, version 2.28.6, and `overrideAttrs` is the right override mechanism).

**Note:** the option spellings `users.users.coder.linger`, `users.users.coder.subUidRanges`, `systemd.user.sockets.podman`, and the sops secret reference are documented NixOS/sops-nix options. If evaluation complains about a specific option name, fix only that spelling (the plan's NixOS references are the verified `linger = true`, `extraGroups`, and `subUidRanges` shapes).

- [ ] **Step 4: Wire the module into llm01**

Edit `hosts/llm01/configuration.nix`:

Add to `imports` (after `../../modules/nixos/comin.nix`):
```nix
    ../../modules/nixos/coder-host.nix
```

Add module enablement after `cominGitOps.pollInterval = 900;`:
```nix
  coderHost.enable = true;
  coderHost.provisionerKeyFile = config.sops.secrets."coder/provisioner_key".path;
```

- [ ] **Step 5: Evaluate the llm01 config**

Run: `nix --extra-experimental-features 'nix-command flakes' eval .#nixosConfigurations.llm01.config.system.build.toplevel.drvPath`

Expected: prints a `/nix/store/...drv` path. If it fails on the missing sops secret entry, that's expected — the secret is added in Task 2. If it fails on an unknown option, fix the option spelling per the note in Step 3.

- [ ] **Step 6: Commit**

```bash
git add modules/nixos/coder-host.nix hosts/llm01/configuration.nix
git commit -m "feat(llm01): coder-host module with rootless podman + pinned coder provisioner daemon"
```

---

### Task 2: Provisioner key secret + `.sops.yaml` recipients

**Files:**
- Modify: `secrets.yaml`, `.sops.yaml`, `hosts/llm01/configuration.nix`

**Interfaces:**
- Consumes: `coderHost.provisionerKeyFile` (path to `/run/secrets/coder/provisioner_key`).
- Produces: sops secret `coder/provisioner_key`; `.sops.yaml` lists the llm01 age key.

- [ ] **Step 1: Decrypt secrets.yaml**

Run: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d secrets.yaml > /tmp/secrets.dec.yaml`

Expected: file written. **Never commit `/tmp/secrets.dec.yaml`.**

- [ ] **Step 2: Add the `coder` secret key**

Edit `/tmp/secrets.dec.yaml` — add under a new top-level key `coder`:

```yaml
coder:
    provisioner_key: <PASTE the key printed by `coder provisioner keys create llm01-podman --org default --tag llm01=podman`>
```

**Generating the key:** on any machine with `coder` CLI logged into `https://coder.home.arrieta.eu`, run:
```bash
coder provisioner keys create llm01-podman --org default --tag llm01=podman
```
The printed key (`prv_...` or similar) is pasted above.

- [ ] **Step 3: Re-encrypt and verify**

Run: `sops -e /tmp/secrets.dec.yaml > secrets.yaml && rm /tmp/secrets.dec.yaml`

Then: `grep -c "ENC\[" secrets.yaml` — Expected: number > 0 (fully encrypted).

- [ ] **Step 4: Add the llm01 age key to `.sops.yaml`**

The `coder` user does not have its own age key. llm01's SOPS decryption uses the bootstrap age key `age1rlvgte0l7225vqdusvkzmdqmsyfd3u255rfy7ku93xx99k4vldsqhxnyxx` (already in the key group). Confirm it is present:

Read `.sops.yaml` and verify all three age keys listed in the current creation rule include the bootstrap key. If a dedicated key for llm01 exists in `hosts/llm01/` or was generated during bootstrap, add it. Otherwise the existing bootstrap key suffices.

- [ ] **Step 5: Regenerate file key material if needed**

Run: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys secrets.yaml -y` (if `sops updatekeys` fails on passphrase, skip — the manual `.sops.yaml` + manual edit in Step 2 already put the secret under all recipients).

- [ ] **Step 6: Verify the secret decrypts on llm01's key**

Run: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d secrets.yaml | grep -A1 "^coder:"`

Expected: `provisioner_key: <non-ENC value>` when decrypted.

- [ ] **Step 7: Commit**

```bash
git add secrets.yaml .sops.yaml
git commit -m "secrets: add coder provisioner key for llm01 external provisioner"
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
  lib,
}:
let
  # Pin the workspace image to a build-time version so registry tags are
  # reproducible (git rev is added by the push step in Task 6).
  base = pkgs.dockerTools.pullImage {
    imageName = "nixos/nix";
    imageDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
  };
in
pkgs.dockerTools.buildImage {
  name = "coder-workspace";
  tag = "latest";
  fromImage = base;
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
  config = {
    User = "coder";
    WorkingDir = "/home/coder";
    Env = [
      "PATH=/bin"
      "HOME=/home/coder"
    ];
    Cmd = [ "/bin/bash" ];
  };
}
```

**Note:** replace the `imageDigest` and `sha256` placeholders by resolving the current `nixos/nix` manifest:
```bash
nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace 2>&1 | grep -o 'got:.*' 
```
The docker provider pull will report the real digest; update the two fields to match and re-run until it builds.

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

- [ ] **Step 3: Build the image**

Run: `nix --extra-experimental-features 'nix-command flakes' build .#coder-workspace --print-build-logs`

Expected: succeeds; `result` is a docker image tar. Iterate on the digest placeholder from Step 1 until it builds.

- [ ] **Step 4: Commit**

```bash
git add pkgs/coder-workspace/default.nix flake.nix flake.lock
git commit -m "feat(coder): add NixOS coder-workspace container image"
```

---

### Task 4: In-cluster registry (`registry.l.arrieta.eu`)

**Files:**
- Create: `/home/coder/k8s-casa/apply/50-apps/casa/registry.yaml`

**Interfaces:**
- Consumes: storage class `truenas-iscsi`, cert secret `l-arrieta-eu-cert` (reflected into `casa`), Traefik ingress controller, FluxCD kustomization for `apply/50-apps/casa`.
- Produces: registry service reachable at `https://registry.l.arrieta.eu:5000` (ingress HTTP 5000), push/pull auth via Traefik.

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
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
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

- [ ] **Step 2: Confirm kustomization picks it up**

Run: `grep -rn "registry" /home/coder/k8s-casa/apply/50-apps/casa/kustomization.yaml` (or the flux kustomization used for that dir). If casa apps are auto-discovered via `apply/50-apps` kustomization (globbing `*.yaml`), nothing to change. Otherwise add `- registry.yaml` to the casa kustomization resources.

- [ ] **Step 3: Deploy via Flux**

Run: `git -C /home/coder/k8s-casa add apply/50-apps/casa/registry.yaml && git -C /home/coder/k8s-casa commit -m "feat(casa): in-cluster docker registry at registry.l.arrieta.eu" && git -C /home/coder/k8s-casa push`

Then wait for Flux reconciliation (default interval 5m) or force: `flux reconcile kustomization casa` (run from `/home/coder/k8s-casa` if flux CLI available).

- [ ] **Step 4: Verify registry is up**

Run: `curl -sI --max-time 10 https://registry.l.arrieta.eu/v2/ | head -1`

Expected: HTTP/2 200. If 401, the registry is up and requires auth (acceptable; push step in Task 6 adds a htpasswd via the config if needed).

- [ ] **Step 5: Commit (k8s-casa)**

Covered by Step 3's commit.

---

### Task 5: TrueNAS target provisioning script

**Files:**
- Create: `coder/templates/llm01-podman/scripts/truenas-iscsi.sh`
- Test: run the script standalone against TrueNAS with a throwaway workspace name, then verify the target/zvol and destroy it.

**Interfaces:**
- Consumes: env `TRUENAS_API_KEY`, `TRUENAS_HOST` (default `192.168.0.6`), `WORKSPACE` (name), `SIZE_GB`.
- Produces: exit 0 on success; creates `tank/iscsi/k8s/<volume>` zvol, iSCSI target `iqn.2005-10.org.freenas.ctl:<volume>`, extent, targetextent; with `destroy` arg tears them all down.

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Provision/destroy an iSCSI target on TrueNAS for a Coder workspace.
# Mirrors the freenas-api-iscsi driver (democratic-csi) API flow using
# TrueNAS v2.0 REST endpoints. Auth is an API key in the Authorization
# header; TLS is self-signed so -k is required.
#
# Runs on llm01 as the coder user (the provisioner daemon's user). The
# iscsiadm/mount steps need root, so they go through sudo — the coder user
# has a passwordless sudoers rule (see coder-host.nix) scoped to these
# commands only.
#
# Usage:
#   TRUENAS_API_KEY=... WORKSPACE=coder-test SIZE_GB=4 ./truenas-iscsi.sh create
#   TRUENAS_API_KEY=... WORKSPACE=coder-test ./truenas-iscsi.sh destroy

: "${TRUENAS_API_KEY:?TRUENAS_API_KEY required}"
: "${TRUENAS_HOST:=192.168.0.6}"
: "${TRUENAS_PORTAL:=192.168.0.6:3260}"
: "${WORKSPACE:?WORKSPACE required}"
: "${SIZE_GB:=4}"

API="https://${TRUENAS_HOST}/api/v2.0"
VOLUME="tank/iscsi/k8s/coder-${WORKSPACE}"
ISCSCI_NAME="coder-${WORKSPACE}"
IQN="iqn.2005-10.org.freenas.ctl:${ISCSCI_NAME}"
SIZE_BYTES=$((SIZE_GB * 1024 * 1024 * 1024))
MNT="/srv/coder/workspaces/coder-${WORKSPACE}"

curl_json() {
  # curl_json <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sk -X "$method" -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
      -H 'Content-Type: application/json' -d "$body" "${API}${path}"
  else
    curl -sk -X "$method" -H "Authorization: Bearer ${TRUENAS_API_KEY}" "${API}${path}"
  fi
}

find_id() {
  # find_id <path> <field> <value>
  local path="$1" field="$2" value="$3"
  curl_json GET "$path" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    if r.get('$field') == '$value':
        print(r['id']); break
"
}

attach() {
  # Discover + login + mount the target on llm01. Device path is deterministic
  # from the portal + iqn via /dev/disk/by-path.
  sudo iscsiadm -m node -T "${IQN}" -p "${TRUENAS_PORTAL}" -o new || true
  sudo iscsiadm -m node -T "${IQN}" -p "${TRUENAS_PORTAL}" --login || true
  local dev
  dev=$(sudo lsblk -lno PATH 2>/dev/null | head -1) # placeholder; real discovery below
  # Wait for the by-path device to appear (up to 30s).
  for _ in $(seq 1 30); do
    dev=$(ls /dev/disk/by-path/ip-${TRUENAS_PORTAL}-iscsi-${IQN}-lun-0 2>/dev/null || true)
    [ -n "$dev" ] && break
    sleep 1
  done
  [ -n "$dev" ] || { echo "timed out waiting for iSCSI device" >&2; exit 1; }
  sudo mkdir -p "${MNT}"
  mountpoint -q "${MNT}" || sudo mount "${dev}" "${MNT}"
  echo "Attached ${IQN} at ${MNT}"
}

detach() {
  local dev
  dev=$(ls /dev/disk/by-path/ip-${TRUENAS_PORTAL}-iscsi-${IQN}-lun-0 2>/dev/null || true)
  mountpoint -q "${MNT}" && sudo umount "${MNT}" || true
  [ -n "$dev" ] && sudo iscsiadm -m node -T "${IQN}" -p "${TRUENAS_PORTAL}" --logout || true
  sudo iscsiadm -m node -T "${IQN}" -p "${TRUENAS_PORTAL}" -o delete || true
}

create() {
  # 1. zvol
  curl_json POST "/pool/dataset" "{\"name\":\"${VOLUME}\",\"type\":\"VOLUME\",\"volsize\":${SIZE_BYTES},\"sparse\":false,\"create_ancestors\":true}" > /dev/null

  # 2. iSCSI target (portal/initiator group 1, no auth — matches democratic-csi)
  local target_id
  target_id=$(curl_json POST "/iscsi/target" "{\"name\":\"${IQN}\",\"mode\":\"ISCSI\",\"groups\":[{\"portal\":1,\"initiator\":1,\"auth\":null,\"authmethod\":\"NONE\"}]}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

  # 3. extent (backed by the zvol)
  local extent_id
  extent_id=$(curl_json POST "/iscsi/extent" "{\"name\":\"${ISCSCI_NAME}\",\"type\":\"DISK\",\"disk\":\"${VOLUME}\",\"blocksize\":512,\"pblocksize\":true,\"insecure_tpc\":true,\"xen\":false,\"rpm\":\"SSD\",\"ro\":false}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

  # 4. associate target + extent
  curl_json POST "/iscsi/targetextent" "{\"target\":${target_id},\"extent\":${extent_id},\"lunid\":0}" > /dev/null

  echo "Created ${IQN} (target ${target_id}, extent ${extent_id})"
  attach
}

destroy() {
  detach

  # Reverse order: targetextent -> extent -> target -> zvol
  local target_id extent_id tte_id
  target_id=$(find_id "/iscsi/target" "name" "$IQN")
  extent_id=$(find_id "/iscsi/extent" "name" "$ISCSCI_NAME")
  if [ -n "${target_id}" ] && [ -n "${extent_id}" ]; then
    tte_id=$(find_id "/iscsi/targetextent" "target" "${target_id}")
    # find_id matches first target; the extent id is the same object's extent
    [ -n "$tte_id" ] && curl_json DELETE "/iscsi/targetextent/id/${tte_id}" > /dev/null
  fi
  [ -n "$extent_id" ] && curl_json DELETE "/iscsi/extent/id/${extent_id}" > /dev/null
  [ -n "$target_id" ] && curl_json DELETE "/iscsi/target/id/${target_id}" > /dev/null
  curl_json DELETE "/pool/dataset/id/tank%2Fiscsi%2Fk8s%2Fcoder-${WORKSPACE}" > /dev/null
  echo "Destroyed ${IQN}"
}

case "${1:-create}" in
  create) create ;;
  destroy) destroy ;;
  *) echo "usage: $0 create|destroy" >&2; exit 1 ;;
esac
```

- [ ] **Step 2: Test create + destroy end-to-end**

Run:
```bash
TRUENAS_API_KEY='<SOPS-managed test key>' WORKSPACE=plancicdtest SIZE_GB=1 bash coder/templates/llm01-podman/scripts/truenas-iscsi.sh create
TRUENAS_API_KEY='<SOPS-managed test key>' WORKSPACE=plancicdtest bash coder/templates/llm01-podman/scripts/truenas-iscsi.sh destroy
```

Expected: first prints `Created iqn.2005-10.org.freenas.ctl:coder-plancicdtest (target N, extent N)` then `Attached ... at /srv/coder/workspaces/coder-plancicdtest`; second prints `Destroyed ...`. Verify the zvol is gone: `curl -sk -H "Authorization: Bearer ..." "https://192.168.0.6/api/v2.0/pool/dataset/id/tank%2Fiscsi%2Fk8s%2Fcoder-plancicdtest"` returns 404/empty, and `/srv/coder/workspaces/coder-plancicdtest` is unmounted.

**Note:** the `attach()` step requires the coder user's passwordless sudoers rule from Task 1 Step 1 (add it before running this test). If `iscsiadm` isn't installed, add `iscsi-initiator-utils` to `environment.systemPackages` (already in Task 1).

- [ ] **Step 3: Commit**

```bash
git add coder/templates/llm01-podman/scripts/truenas-iscsi.sh
git commit -m "feat(coder): TrueNAS iSCSI target provisioning script for workspaces"
```

---

### Task 6: Coder template `llm01-podman`

**Files:**
- Create: `coder/templates/llm01-podman/main.tf`
- Create: `coder/templates/llm01-podman/README.md` (push instructions)
- Test: `coder templates push llm01-podman --provisioner-tag llm01=podman` then a workspace create.

**Interfaces:**
- Consumes: `scripts/truenas-iscsi.sh` (Task 5), `coder-workspace` image (Task 3), registry (Task 4), provisioner daemon (Task 1).
- Produces: workspace template named `llm01-podman` tagged to the llm01 provisioner.

- [ ] **Step 1: Create `main.tf`**

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 0.17"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.0"
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
  mutable = false
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
  mutable = false
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

data "coder_parameter" "truenas_api_key" {
  name         = "truenas_api_key"
  display_name = "TrueNAS API key"
  description  = "API key for provisioning the workspace iSCSI target (create one in TrueNAS → API Keys)"
  type         = "string"
  default      = ""
  sensitive    = true
  mutable      = false
}

provider "docker" {
  host = "unix:///run/user/27003/podman/podman.sock"
}

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

# Provision the iSCSI target before the container exists. Runs on the llm01
# provisioner host (which reaches TrueNAS directly). Destroy runs on delete
# and tears down the target/zvol, so data is removed with the workspace.
resource "terraform_data" "truenas_target" {
  input = {
    workspace = data.coder_workspace.me.name
  }

  provisioner "local-exec" {
    when    = create
    command = "TRUENAS_API_KEY='${data.coder_parameter.truenas_api_key.value}' WORKSPACE='${data.coder_workspace.me.name}' SIZE_GB='${data.coder_parameter.disk_gb.value}' bash ${path.module}/scripts/truenas-iscsi.sh create"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "TRUENAS_API_KEY='${data.coder_parameter.truenas_api_key.value}' WORKSPACE='${self.input.workspace}' bash ${path.module}/scripts/truenas-iscsi.sh destroy"
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
}

resource "docker_image" "workspace" {
  name = "registry.l.arrieta.eu/coder-workspace:latest"
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
}

resource "coder_metadata" "workspace_info" {
  count = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id
  workspace_id = data.coder_workspace.me.id
}
```

- [ ] **Step 2: Boot-time remount of workspace targets**

The `truenas-iscsi.sh` script attaches + mounts the target during `create` (live path). On a **host reboot** the workspace shows stopped; the openiscsi `iscsi.service` auto-logs-in to targets recorded with `iscsiadm -o new` at boot. The `coder-host.nix` module remounts them. Add to `modules/nixos/coder-host.nix` (in the `config` block):

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

**Note:** the exact iscsiadm/by-path wiring is verified during implementation (spec open item "how the template triggers/waits for the iSCSI mount"). The primary attach path is the script's `attach()` (run live by the template's `local-exec`); this unit only handles reboots. If the by-path device name differs (check `ls /dev/disk/by-path/` after the Task 5 test), adjust the glob to match.

- [ ] **Step 3: Write `README.md` with push + workspace instructions**

```markdown
# llm01-podman Coder Template

Workspaces run as rootless podman containers on llm01 with homes on TrueNAS iSCSI volumes.

## Push

```bash
coder login https://coder.home.arrieta.eu
coder templates push llm01-podman \
  --directory coder/templates/llm01-podman \
  --provisioner-tag llm01=podman \
  --yes
```

The `--provisioner-tag llm01=podman` routes builds to the external provisioner daemon on llm01.

## Creating a workspace

1. Choose `memory_gb` (2-8) and `cpu_count` (2-24).
2. Paste a TrueNAS API key (`truenas_api_key`).
3. The template provisions the iSCSI target, mounts it, and starts the container.
4. Stop/start preserves `/home/coder` (data on TrueNAS). Delete tears down the target + zvol.
```

- [ ] **Step 4: Push the template**

Run:
```bash
coder templates push llm01-podman \
  --directory coder/templates/llm01-podman \
  --provisioner-tag llm01=podman \
  --yes
```

Expected: template pushed; build job picked up by the llm01 provisioner (verify in Coder UI under Templates → llm01-podman → activity, or `coder templates list`).

- [ ] **Step 5: Create a test workspace**

In the Coder UI create a workspace from `llm01-podman` (memory 2, cpu 2, disk 10, paste TrueNAS key). Expected states: Connecting → Running. If the build fails, inspect the build log; the most likely failure is the iSCSI mount step (Task 6, Step 2 note) — fix the mount trigger and retry.

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
systemctl status podman.socket # active
sudo -u coder podman info | grep -i rootless   # rootless true
sudo -u coder curl --unix-socket /run/user/27003/podman/podman.sock http://localhost/libpod/_ping
systemctl --user status coder-provisioner  # as coder: active, connected to coder.home.arrieta.eu
```

- [ ] **Step 2: Registry + image checks**

```bash
curl -sI --max-time 10 https://registry.l.arrieta.eu/v2/ | head -1   # HTTP/2 200
curl -sk -H "Authorization: Bearer $KEY" "https://192.168.0.6/api/v2.0/pool/dataset/id/tank%2Fiscsi%2Fk8s" | grep -c "coder-"  # 0 clean
```

- [ ] **Step 3: Workspace lifecycle**

Create → Running → write file → stop → start → file persists → delete → verify TrueNAS zvol/target gone and podman volume removed.

- [ ] **Step 4: Update AGENTS.md if anything changed**

Add a `Coder workspaces (llm01)` section documenting the external provisioner, the template, and the TrueNAS provisioning flow. **Note:** do this only if the user requests it or as part of a follow-up commit.

---

## Self-Review Notes

- **Spec coverage:** Spec's components 1 (coder-host.nix), 2 (image), 3 (registry), 4 (template) map to Tasks 1/2, 3, 4, 6 respectively; verification spec section maps to Task 8; data-flow/lifecycle map to Task 6 + 8. The spec's SSH-transport references were superseded by the approved external-provisioner architecture (committed in the spec update `e7fb4d4`).
- **Placeholders:** Three intentional, labeled placeholders remain, each with an explicit resolution command: the `nixos/nix` image digest in Task 3 (Step 1), the exact iSCSI by-path device name in Task 6 (Step 2 note), and the coder v2.35.1 `fetchurl` hash in Task 1 (Step 2).
- **Type/name consistency:** `coder-host.nix` options (`coderHost.enable`, `coderHost.provisionerKeyFile`, `coderHost.coderUrl`), sops secret key `coder/provisioner_key`, workspace naming `coder-<ws>`, IQN `iqn.2005-10.org.freenas.ctl:coder-<ws>`, socket path `/run/user/27003/podman/podman.sock`, and uid/gid 27003 are used consistently across tasks.
- **Verified against upstream sources:**
  - docker provider schema: `docker_container` uses `memory` (Int MB) and `cpus` (String) — NOT `cpu` (confirmed in `resource_docker_container.go:852,1168`). The plan uses `cpus = tostring(...)`.
  - Coder template pattern: official docker template relies on `init_script` (embeds agent URL) + `CODER_AGENT_TOKEN`; `provider.coder.url` is not a valid reference (confirmed in `examples/templates/docker/main.tf`). Plan fixed accordingly.
  - `coder_parameter` `validation { min, max }` syntax confirmed in `docs/data-sources/parameter.md`.
  - TrueNAS API v2.0 endpoints for zvol/target/extent/targetextent and the `iqn.2005-10.org.freenas.ctl` basename confirmed live against TrueNAS at 192.168.0.6 and against democratic-csi `src/driver/freenas/ssh.js`.
  - External provisioner: `coder provisioner start` with `CODER_URL` + `CODER_PROVISIONER_DAEMON_KEY`, one concurrent build per daemon, provisioner tags confirmed in Coder docs.
- **Concurrency:** enforced by the single provisioner daemon (one concurrent build), matching the spec's "one workspace at a time".
- **Version skew (caught in review):** nixpkgs coder 2.28.6 / unstable 2.33.11 both mismatch the deployed server 2.35.1; Task 1 pins v2.35.1 via `fetchurl`. This is why `pkgs.coder` from nixpkgs is not used directly.
