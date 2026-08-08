# Podman/Docker-provider compatibility evidence

> **Status:** PASS — recorded 2026-08-08 against the live llm01 mTLS Podman API.

**Date:** 2026-08-08

## Pinned versions (actual, from lock file)

| Component | Version | Source |
|-----------|---------|--------|
| NixOS | 25.11 (Xantusia) | `/etc/os-release` on llm01 |
| nixpkgs rev | `c0b0e0fddf73fd517c3471e546c0df87a42d53f4` | flake.lock |
| Podman | 5.7.0 | deployed on llm01 (`podman system service`) |
| Docker provider | `kreuzwerker/docker` **3.9.0** (constraint `~> 3.6`) | `.terraform.lock.hcl` |
| Terraform | 1.15.8 | local CLI |
| Coder chart | 2.35.1 | `../k8s-casa/apply/50-apps/casa/coder.yaml` |
| Workspace image | `registry.l.arrieta.eu/coder-workspace:compat-gate` | built on llm01, pushed via podman |

**Note:** nixpkgs 25.11 ships podman 5.7.0 (`pkgs.podman` at eval), not 5.8.4 as
predicted earlier. The lock file and evidence doc are authoritative.

## Terraform source

`coder/templates/llm01-podman/compatibility/main.tf`

- `host = "tcp://192.168.0.29:2376"`
- `cert_path` = dir with `ca.pem`, `cert.pem`, `key.pem` (mTLS bundle)
- provider `registry_auth` for `registry.l.arrieta.eu` (pull user `coder`)
- `docker_volume` local bind → `/srv/coder/workspaces/coder-compat-gate`
- `docker_container` with `memory = 4096`, `cpus = "4"`, `user = "1000:1000"`
- `command = ["sh", "-c", "id; mount | grep ' /home/coder '; sleep 300"]`

## Commands

```bash
terraform init            # provider 3.9.0
terraform apply -auto-approve
terraform destroy -auto-approve
```

## Results

### mTLS certificate validation

- [x] PASS. Authenticated request `curl --cert client.crt --key client.key --cacert ca.pem https://192.168.0.29:2376/_ping` → `OK`.
- [x] PASS. No client cert → connection closed (curl http_code `000`).
- [x] PASS. Self-signed bad client cert → connection closed (`000`).

### Private registry pull

- [x] PASS. `docker_image` resource pulled `registry.l.arrieta.eu/coder-workspace:compat-gate` through the mTLS API in 5s using provider-supplied `registry_auth` (pull user `coder`). Verified in registry catalog + tags via API with credentials; `401` without.

### docker_volume local bind options

- [x] PASS. `docker_volume` with `driver=local`, `driver_opts{type=none,o=bind,device=/srv/coder/workspaces/coder-compat-gate}` created a bind mount. Container `Mounts` shows source `/home/coder/.local/share/containers/storage/volumes/coder-compat-gate-home/_data` → `/home/coder`; host mountinfo confirms `/srv/coder/workspaces/coder-compat-gate ... /home/coder/.../coder-compat-gate-home/_data rw,relatime ... ext4`.

### Non-root access to the bind mount (uid 1000)

- [x] PASS. Container runs as `user = "1000:1000"`; `id` → `uid=1000(coder) gid=1000(coder)`. Wrote `persist-test.txt` inside `/home/coder` successfully; file lands on host bind dir owned by subuid `100999` (rootless mapping of container uid 1000). No host UID/GID 1000 assumption.

### memory + cpus cgroup v2 enforcement

- [x] PASS. Container `HostConfig.Memory = 4294967296` (4 GiB), `NanoCpus = 4000000000` (4). In-container `/sys/fs/cgroup/memory.max = 4294967296`, `/sys/fs/cgroup/cpu.max = 400000 100000`.

### Restart / destroy

- [x] PASS. `podman stop`/`start` (docker provider restart pattern) preserved `persist-test.txt` on the bind volume. `terraform destroy` removed container, volume, and image; `podman ps -a`, `podman volume ls`, `podman images` all empty afterward.

### No host devices / GPU exposure

- [x] PASS. `HostConfig.Devices = []`, `Privileged = false`, `securityOpt` default. No `/dev/dri` inside container.

## Verdict

- [x] PASS — all seven compatibility items verified against the pinned provider 3.9.0 / Podman 5.7.0 / NixOS 25.11. No later task is blocked by this gate.
