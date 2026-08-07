# llm01-host

Coder workspace that runs **directly on the llm01 host OS** as the shared
`coder` user. No containers — full CPU/RAM/disk speed of llm01.

- **User**: `coder` (shared home `/home/coder`)
- **Connection**: SSH from the Coder provisioner to llm01, then the agent
  reverse-tunnels back to the Coder server.
- **Isolation**: none between workspaces; resources are contended.
- **GPU**: not exposed; the AMD GPU stays reserved for host llama.cpp.

## Build variables

| Variable           | Required | Notes                                    |
|--------------------|----------|------------------------------------------|
| `host`             | yes      | llm01 IP or resolvable hostname          |
| `ssh_private_key`  | yes      | secret; key for the `coder` user on llm01 |
