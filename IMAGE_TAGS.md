# Workspace image tags

Immutable tags are pushed to `ghcr.io/javierarrieta/coder-workspace` as
`YYYYMMDD-<short-sha>`; the `latest` tag points at the newest build. Tags are
never overwritten, so pinning `workspace_image` to an older row rolls back.

| tag | date | commit | changes |
|---|---|---|---|| 20260818-0dce5e8 | 2026-08-18 | 0dce5e8b3a5f1fac848a32a5b5c234d32270b868 | initial build |
