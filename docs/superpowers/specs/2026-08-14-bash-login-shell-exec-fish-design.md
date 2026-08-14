# Design: bash as login shell, exec fish for interactive sessions

Date: 2026-08-14

## Problem

VS Code Remote-SSH fails to connect to coder-workspace workspaces with
`Connecting with SSH timed out`. Root cause: the workspace image sets `/bin/fish`
as the `coder` user's login shell (`/etc/passwd`). VS Code's `local-server` path
spawns the login shell with a **piped script on stdin and no TTY**; fish ignores
input piped to a non-TTY shell, so the bootstrap script never runs and VS Code
hits its connect timeout. This is a known VS Code Remote-SSH regression
(microsoft/vscode-remote-release#2509): non-`sh`-compatible login shells break
the local-server connection. Manual `ssh host 'cmd'` works because the command is
passed as an argument, not over stdin.

Verified evidence on the failing workspace:

- `ssh -v -T -D <port> coder-... 'echo HI'` completes instantly (proxy, agent,
  dynamic forwarding all fine).
- Agent log shows the session created, then zero output for ~16s, then EOF at
  the 17s connect timeout; `~/.vscode-server/.cli.*.log` never touched (CLI
  never launched).
- `coder ssh llm01 -- echo hi` works (exec path), and `fish -l -c "echo ok"`
  runs fine interactively.

## Goal

Keep fish as the interactive shell for real terminal sessions while making the
SSH/login shell POSIX-`sh`-compatible so VS Code Remote-SSH works. Concretely:
set bash as the login shell and `exec fish` only when an interactive session
(with a TTY) starts in bash.

## Design

File: `pkgs/coder-workspace/default.nix` (image build, `runAsRoot` + config).

1. **Login shell** — `useradd` for `coder` uses `--shell /bin/bash` instead of
   `/bin/fish`.
2. **`/etc/shells`** — add `/bin/bash` alongside the existing `/bin/fish`.
3. **`config.Env.SHELL`** — change from `/bin/fish` to `/bin/bash`.
4. **New `/etc/bashrc`** — bash's `SYS_BASHRC` (Nix bash is compiled with
   `-DSYS_BASHRC="/etc/bashrc"`). Source a fish handoff guarded so only real
   interactive TTY sessions exec fish:

   ```sh
   # Hand off interactive TTY sessions to fish; VS Code Remote-SSH spawns a
   # non-interactive piped-stdin shell and must stay on bash.
   if [[ -o interactive ]] && [[ -t 0 ]] && command -v fish >/dev/null 2>&1; then
     exec fish
   fi
   ```

   - Interactive login + TTY (Coder web terminal, `ssh` with TTY, VS Code
     integrated terminal) → bash starts → `exec fish` → fish with its baked
     aliases config (`conf.d/00-coder-workspace.fish`, already gated on
     `status is-interactive`).
   - VS Code Remote-SSH (piped stdin, no TTY) → bash is non-interactive → stays
     on bash → #2509 hang resolved.

## Why /etc/bashrc and not ~/.bashrc

The template mounts `/home/coder` from an external bind volume
(`docker_volume.home`), which **shadows** whatever is baked into the image at
`/home/coder`. A handoff in `~/.bashrc` would be invisible at runtime. `/etc` is
part of the image layer and survives, so the hook lives in `/etc/bashrc`.

## Implications

- Interactive shells are fish; bash's own `~/.bashrc` never runs for interactive
  sessions (fish is the interactive shell of record). Users can still reach bash
  with `bash --norc`.
- Existing fish `conf.d` config (aliases, zoxide, fzf, direnv) is unchanged and
  still applied because fish is interactive after the `exec`.
- `exec` replaces bash, so there is no nested shell and no recursion.

## Verification

Build the image, push to the registry under a new pinned tag, set
`workspace_image` to it, push the template, and **update** the workspace, then on
the Podman host:

```sh
# login shell is bash
podman exec coder-llm01 sh -c 'grep coder /etc/passwd; cat /etc/shells'

# non-interactive piped shell stays bash (VS Code path)
podman exec coder-llm01 sh -c 'echo hi | bash -c "echo shell:\$0"'

# interactive TTY session execs fish
podman exec -it coder-llm01 bash -c 'echo $0; command -v fish'
```

Then reconnect VS Code Remote-SSH and confirm the connection completes.
