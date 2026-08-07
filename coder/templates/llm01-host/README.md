# llm01-host

Coder workspace that runs **directly on the llm01 host OS** as the shared
`coder` user. No containers — full CPU/RAM/disk speed of llm01.

- **User**: `coder` (shared home `/home/coder`)
- **Connection**: SSH from the Coder provisioner to llm01, then the agent
  reverse-tunnels back to the Coder server.
- **Isolation**: none between workspaces; resources are contended.
- **GPU**: not exposed; the AMD GPU stays reserved for host llama.cpp.

## Workspace parameters

| Parameter         | Required | Notes                                    |
|-------------------|----------|------------------------------------------|
| `host`            | yes      | llm01 IP or resolvable hostname          |
| `ssh_private_key` | yes      | secret; key for the `coder` user on llm01 |

These are **workspace-level** `coder_parameter` inputs, entered per-workspace
in the Coder UI at creation time (not at template push). Note: the current
provider (`coder/coder` v2.x) does not support hiding `coder_parameter` values,
so anyone with view access to the workspace can see the pasted key — treat it
as a low-privilege key. Never commit the private key to this repo.

## Pushing the template

From a machine with the `coder` CLI logged in (`coder login <url>`):

```bash
cd coder/templates/llm01-host
coder templates push llm01-host
```

No push-time variables are required.

