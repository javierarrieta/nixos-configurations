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

1. Choose `memory_gb` (2-8), `cpu_count` (2-24), and `disk_gb` (10-200; immutable after creation).
2. The template acquires the single-workspace lease and requests iSCSI provisioning through the capability-authenticated llm01 helper.
3. The helper provisions/attaches the target, and the Docker provider starts the container with provider-supplied registry auth.
4. Stop/start preserves `/home/coder` (data on TrueNAS). Delete tears down the target + zvol.

## Providers

- `coder/coder` and `kreuzwerker/docker` come from `registry.terraform.io`.
- `registry.l.arrieta.eu/infra/llm01` is the pinned helper-client provider published to the in-cluster registry; checksums are committed in `.terraform.lock.hcl`.
