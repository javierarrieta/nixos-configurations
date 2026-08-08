# Podman/Docker-provider compatibility evidence

> **Status:** PENDING — the spike requires the deployed llm01 mTLS Podman API
> (Task 1 + Task 2 secrets) and the in-cluster registry (Task 4). Until llm01
> is reachable and the registry is up, this gate cannot be executed.

**Date:** 2026-08-08

## Pinned versions

| Component | Version | Source |
|-----------|---------|--------|
| NixOS | 25.11 (`26.11.20260806.70ce234`) | flake.lock |
| Podman | 5.8.4 | nixpkgs (x86_64-linux) |
| Docker provider | `kreuzwerker/docker` `~> 3.6` (latest 3.x: 3.6.2) | registry.terraform.io |
| Coder chart | 2.35.1 | `../k8s-casa/apply/50-apps/casa/coder.yaml` |

## Terraform source

`coder/templates/llm01-podman/compatibility/main.tf`

- `host = "tcp://llm01:2376"`
- `cert_path = "/run/secrets/coder-podman-client"` (three-file mTLS bundle)
- provider `registry_auth` for `registry.l.arrieta.eu`
- `docker_volume` local bind → `/srv/coder/workspaces/coder-compat-gate`
- `docker_container` with `memory = 4096`, `cpus = "4"`, `user = "1000:1000"`

## Commands

```bash
terraform init
terraform apply -auto-approve
terraform destroy -auto-approve
```

## Results

### mTLS certificate validation

- [ ] Pending

### Private registry pull

- [ ] Pending

### docker_volume local bind options

- [ ] Pending

### Non-root access to the bind mount (uid 1000)

- [ ] Pending

### memory + cpus cgroup v2 enforcement

- [ ] Pending

### Restart / destroy

- [ ] Pending

### No host devices / GPU exposure

- [ ] Pending

## Verdict

- [ ] PASS — record exact versions, Terraform source, commands, and results
- [ ] FAIL — a failure blocks all later tasks (stop implementation)
