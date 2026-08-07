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
in the Coder UI at creation time (not at template push). The private key is
marked sensitive and stored encrypted in Coder — never commit it.

## Pushing the template

From a machine with the `coder` CLI logged in (`coder login <url>`):

```bash
cd coder/templates/llm01-host
coder templates push llm01-host
```

No push-time variables are required.

