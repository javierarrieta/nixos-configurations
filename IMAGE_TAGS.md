# Workspace image tags

Immutable tags are pushed to `ghcr.io/javierarrieta/coder-workspace` as
`YYYYMMDD-<short-sha>`; the `latest` tag points at the newest build. Tags are
never overwritten, so pinning `workspace_image` to an older row rolls back.

| tag | date | commit | changes |
|---|---|---|---|