# Global instructions (Coder workspaces)

## Shell — the operator's interactive shell is fish

The agent's own `bash` tool runs bash, but every command **handed to the operator** is pasted into
fish. Written 2026-10-18 after a sequence of hand-over commands were bash-only and had to be
re-run. Bashisms fail in ways that look like the task failing, not the shell:

- `VAR=value cmd` and `VAR=$(...)` do not assign in fish. Use `set -x VAR value` on its own line,
  then use `$VAR`.
- `${VAR:0:8}` substring expansion does not exist. Use `string sub -l 8 -- "$VAR"`.
- **Heredocs do not exist.** `python3 - <<'PY'` and `cat <<EOF` are dead on arrival. Inline the
  program with `python3 -c '...'`, or write the file with the agent's own tools.
- `for i in $(seq 1 5); do ... done` is invalid. fish is `for i in (seq 1 5)` ... `end`.
- `read -rsp "prompt: " VAR` — fish has `read -s` but no `-p` with that shape and no variable
  assignment form. Prompt in the script being run, or use `set VAR (read -s)`.
- **`read -s -p "prompt: "` is not reliable either.** Measured 2026-10-18 on fish 4.7.1: it works
  under `fish -c` but in the operator's interactive shell it failed with `Unknown command: client`,
  i.e. the prompt text was executed. Use the prompt-free form and say what to type in prose:
  `echo "Type the secret, then Enter (input is hidden)."` then `set SECRET (read -s)`.
- `$(...)` command substitution, pipes, `||`, and `&&` are fine.

When a snippet genuinely needs bash (arrays, `[[ ]]`, associative arrays), say so on the line
above it — `bash -c '...'` or "run this under bash" — rather than letting it fail obscurely.
Prefer one-liners that work in both, and keep multi-step logic in a script file the agent wrote,
where the interpreter is explicit in the shebang.

## Git — read before any networked git command

GitHub access from these workspaces is brokered by **Coder external auth**. There is
no stored PAT and no usable SSH key on disk. Measured 2026-10-13 in the `dev.titan`
workspace; every bullet below was observed, not assumed.

- **Networked git blocks forever when unauthenticated.** `git fetch`, `git pull`,
  `git push`, `git ls-remote` print

  ```
  Open the following URL to authenticate with Git:
  https://coder.titan.arrieta.eu/external-auth/github
  ```

  and then wait for a browser flow. They do **not** fail fast — a hung git command is
  an auth state, not a slow network. Always wrap them: `timeout 30 git fetch ...`.

- **The agent cannot complete that browser flow.** Hand the URL to the operator and
  stop. Do not retry in a loop; each attempt hangs until it is killed.

- **Check auth state without leaking the token.** Exit 0 means the token is on stdout;
  exit 1 means stdout is the URL. Never `echo` the result unconditionally — on success
  it is a credential.

  ```sh
  OUT=$(coder external-auth access-token github 2>/dev/null); rc=$?
  echo "rc=$rc len=${#OUT}"; [ "$rc" -ne 0 ] && echo "$OUT"
  ```

- **Local git needs nothing.** `status`, `diff`, `log`, `show`, `branch`, `checkout`,
  `worktree add`, `commit` all work offline. Only commands that touch `origin`
  need auth, so a worktree off a *cached* `origin/main` is available immediately.

- **Never claim "off updated main" without evidence.** Show
  `git log -1 --oneline origin/main` and
  `git rev-list --left-right --count origin/main...HEAD`, and say plainly when the
  ref is the last-fetched state rather than the result of a fresh fetch. If a fetch
  is impossible, offer cached main and label it as such.

- **Coder external auth alone is not enough for private repos, even after the
  operator authenticates.** Measured 2026-10-13: after the browser flow completed
  (`coder external-auth access-token github` exits 0 with a 40-char token),
  `git fetch` on a private repo still fails with
  `remote: Write access to repository not granted` / `403`. The token Coder mints
  does not carry repo scope. Do not conclude the operator failed the auth — check
  which credential git is actually using.

- **`gh` is separately authenticated with a token that does have `repo` scope**, and
  that is the one git needs. Make it non-interactive:

  ```sh
  git config --global credential.https://github.com.helper \
    '!f() { echo username=x-access-token; echo "password=$(gh auth token)"; }; f'
  ```

  Verify before promising a push: `gh auth status` for scopes, and
  `curl -s -H "Authorization: token $(gh auth token)" https://api.github.com/repos/<owner>/<repo> | jq .permissions.push`.

- **A credential helper must swallow git's argument.** git appends `get`/`store`, so a
  bare `!coder external-auth access-token github` helper fails with
  `error: wanted 1 args but got 2 [github get]`. Wrap it in a shell function that
  ignores the argument, as above.

- Coder also has an SSH path (`coder publickey`, `GIT_SSH_COMMAND=coder gitssh --` with
  `git@github.com:` remotes). It needs the same external-auth grant, and these repos
  use HTTPS remotes, so it is not the fix here.

- **Pushing additionally requires explicit operator confirmation for each change**,
  per the repository's own AGENTS.md. Authentication is not authorization to push.

## Git — branch and PR, not a direct push to the default branch

Written 2026-10-16 after six commits went straight to `main` in a GitOps repo across
two agent sessions. The work was correct, CI was green on every commit, and the agent
had read the repo's AGENTS.md and followed it exactly — the file described
commit-then-push and never mentioned PRs, while every recent change in that repo had
in fact gone through a PR. The instruction was incomplete, not ignored.

- **Check the repo's actual convention before pushing to a default branch.** It is
  often a convention and not a rule anyone wrote down. Compare:

  ```sh
  gh pr list --state merged --limit 5 --json number,title,headRefName
  gh api 'repos/<owner>/<repo>/commits?per_page=10' --jq '.[].commit.message | split("\n")[0]'
  ```

  If recent commits correspond to merged PRs with `feat/`-`fix/`-`docs/` branch
  names, that is the workflow. Branch and open a PR even when nothing forbids a
  direct push.

- **A push to a default branch is frequently a deploy.** GitOps repos reconcile the
  default branch within about a minute, so the change is live before anyone looks.
  The point of a PR is review *before* the deploy; a CI run after the push confirms
  the deploy happened, it does not review it.

- **CI going green on a direct push is not evidence the workflow was followed.** Most
  workflows trigger on both `push: [main]` and `pull_request`, so a direct push runs
  the full set and passes. Absence of a failure means nothing here.

- **No enforcement does not mean no convention.** Private repos on the free GitHub
  plan cannot enable branch protection at all —
  `gh api repos/<owner>/<repo>/branches/main/protection` returns 403 *"Upgrade to
  GitHub Pro or make this repository public"*. Re-measured 2026-11-15 on
  `k8s-casa`, `k8s-techdelivery` and `architecture`: still true. **But that is a
  rule about repository visibility, not about these repos as a set, and reading it
  as one made an agent report that `k8s-titan` had no gate when it has one.**
  `k8s-titan` is public, and public repos on the free plan get protection in full.
  Ask the endpoint and read the status code; all three cases measured 2026-11-15:

  - `403` — the plan cannot protect this branch (`k8s-casa`, `architecture`).
  - `404` — eligible, no rule written (`portfolio-prism`, `restic-restore`).
  - `200` — a rule exists, so read it before describing the merge process.

  In the `403` case direct pushes succeed silently and nothing will ever tell you it
  was wrong. Ask when unclear; do not infer permission from silence.

- **`strict` is the "branch must be up to date before merging" knob**, and it is a
  field of `required_status_checks` rather than its own setting. That matters twice:
  a `PATCH` to that endpoint replaces the whole rule, so one that omits `contexts`
  silently drops the required check along with `strict`; and `strict: true` is what
  makes every branch cut before someone else's merge refuse to merge until `main` is
  pulled in. `k8s-titan` ran `strict: true` until 2026-11-15, when the operator had
  it turned off; the required check `Offline gate (no secrets, no cluster)` and
  `enforce_admins: true` are unchanged, and `enforce_admins` means the owner cannot
  bypass the required check either. Do not re-enable `strict` as a convenience fix
  without asking. While it is on — anywhere — `gh pr update-branch` merges the base
  into the head branch through the API with no local checkout, which is the
  painless version of the same thing.

- **Explicit operator confirmation is still required for each of them**: pushing a
  branch, opening the PR, and merging. Opening a PR does not satisfy the confirmation
  rule in advance, and urgency is not an exception.

## Git — one task, one fresh worktree

Written 2026-10-24, when a second task was opened in `k8s-titan` and the primary checkout turned
out to be sitting on `feat/sure-trial` with two files modified. Editing there would have mixed two
unrelated changes into one diff and made `git add -A` — which that repo's own `make check` tells you
to run first — a way to commit someone else's half-finished work.

- **Start each task in a fresh worktree based on `origin/main`.** Never edit in the primary checkout.
  You do not know what branch it is on or what is dirty in it, and finding out after the first edit
  is worse than asking now. `git status -sb` before anything else.
- **Name the base instead of inheriting it.** A worktree taken from the current HEAD silently inherits
  whatever branch the checkout happened to be on:

  ```sh
  git -C /path/to/repo worktree add -b feat/<topic> ../wt-<repo>-<topic> origin/main
  ```

  That form is shell-neutral — it works in bash and in fish unchanged.
- **A worktree off a *cached* `origin/main` needs no network** (see the external-auth section), so
  there is no reason to wait on auth to start work. Label the base when you report it: show
  `git log -1 --oneline origin/main` and say the ref is the last-fetched state unless a fetch proved
  otherwise.
- **Put the worktree outside the repo**, as a sibling: `../wt-<repo>-<topic>`. Precedent in these
  workspaces is `/home/coder/wt-titan-mealie`. A worktree nested inside the checkout gets walked by
  the repo's own gates — k8s-titan's `leak-check` scans untracked files and `kustomize-listing`
  globs the tree — so a nested worktree makes a gate read the same manifests twice and report
  whatever the duplicate implies.
- **One writer per worktree.** Concurrent tasks may share a worktree only for read-only review, and
  each agent gets its own for edits. This is the same rule the subagent guidance enforces; a worktree
  does not make it optional.
- **Throwaway probes may live in `/tmp`** — `/tmp/k8s-titan-gatus` is an existing one. Anything the
  operator may want should not go there: `/tmp` is not a place they will look.
- **Cleanup is `git worktree remove <path>` then `git worktree prune`.** Removing the directory by
  hand leaves a stale admin entry that makes `git worktree list` lie. Never remove a worktree that
  still holds uncommitted or unpushed work — report it and let the operator decide; the branch is a
  separate decision from the directory.

## Package installation — nix-shell with operator approval

Packages are not pre-installed in these workspaces. When a task needs a tool that is
missing, use `nix-shell -p <package> --run '<command>'` to run it transiently rather
than installing it permanently. **Ask the operator before doing so** — do not pull in
packages unilaterally.

```sh
# Example: run jq without installing it
nix-shell -p jq --run 'jq . file.json'

# Multiple packages
nix-shell -p python3 pkgs.opencv --run 'python3 script.py'
```

This keeps the workspace immutable and avoids surprising the operator with side effects
or long builds they did not request.

## Interaction — ask one thing at a time

Written 2026-10-14 after the operator called it out during a VPS firewall assessment:
the agent kept requesting four or five commands per turn, so every round trip stalled on
whichever item happened to be slowest, and the operator could not tell which answer
actually unblocked the decision.

- **Request the single next thing that unblocks the decision.** Not the full checklist.
  If the answer to question 1 determines whether questions 2-5 are even relevant, asking
  2-5 is noise.
- **Settle, then advance.** Read the answer, state the verdict it produces, then ask for
  the one next item. A checklist delivered all at once is a form of scope creep the agent
  imposes on the operator.
- **When a list is genuinely needed, make it a checklist the operator drives**, not a
  request. "Here is the pre-flight set; tick them off" is fine. "Run these five things and
  paste all of it" is not.
- **If blocked, say what is blocking and ask for exactly one item**, and give the decision
  rule so the operator can proceed without waiting.
