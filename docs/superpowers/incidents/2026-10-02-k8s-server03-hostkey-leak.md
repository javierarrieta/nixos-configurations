# k8s-server03 SSH host key leaked in public git history

**Status: resolved.** Rotated and verified 2026-10-03.
**Severity: high** (a host key that authenticated this machine for ~6 months is in a
public repository).
**Detected: 2026-10-02**, by `ggshield`, during a routine pre-push scan of an unrelated
branch.

## What happened

Commit `82ad758` (2026-03-26, message `[k8s-server03]`) added an **unencrypted OpenSSH
ed25519 private key** to `secrets.yaml`. The file is SOPS-encrypted at rest, but that
commit contained the PEM in plaintext. `cfccdd7` reverted it the same day.

The revert is not a fix. Git history is the artifact: anyone who clones the repository
gets the key from `82ad758`, forever. The repo is public.

## Impact

The leaked key was **still the live host key** when discovered — verified by comparing
`ssh-keyscan` output against the fingerprint in the leaked commit. So for roughly six
months, anyone who cloned the repo could have impersonated `k8s-server03` to any client
that had not pinned the key by other means, or MITM a first connection.

Containment checks, all clean:

- **No cross-host key reuse.** All 13 host-key fingerprints in the sops file are pairwise
  distinct; only `k8s-server03` matched the leak.
- **Nothing pinned the key.** The fingerprint appears in no repository here — no
  `known_hosts` pins, no `StrictHostKeyChecking` automation, no CI fingerprint allowlist.
- **Not reused as a client key.** The public half was grepped across five repos: absent
  from every `authorized_keys`, template and automation.
- **Not a secrets-decryption path.** The host key is not a SOPS recipient or age
  identity, so the leak does not expose `secrets.yaml` itself. This was checked *before*
  rotation, because if it had been an age identity, rotating it would have bricked
  secrets decryption on a control-plane node.

**No abuse evidence either way.** The `journalctl -u sshd` review for the exposure window
could not be completed: journald is capped by `SystemMaxUse` and had rolled past March.
That is recorded as *unavailable*, not as *clean* — absence of evidence about a
six-month window on an internet-adjacent host is not evidence of absence.

## Why it was possible

`secrets.yaml` is encrypted, so the mental model is "nothing plaintext goes in here".
The file's own documentation encouraged the mistake: the new-host checklist in
`AGENTS.md` shows a `ssh_keys/<hostname>_host_private:` block with a PEM placeholder.
A plaintext paste into an encrypted file is permanent, because the plaintext lives in the
commit, not the file.

## Remediation

1. Generated a fresh ed25519 keypair.
2. Replaced `ssh_keys/k8s-server03_host_private` and `_host_public` with `sops --set`,
   which preserves the recipient list — so no one's decrypt access changed.
3. Verified before committing: decrypted both revisions and diffed **all 48 keys** —
   exactly the two targets changed; the file still had zero plaintext PEM headers; the
   stored public value matched the key derived from the stored private key; the private
   key ends with a newline.
4. Deployed to `k8s-server03` through comin (fleet ring: `stable` branch, manual
   confirmation).

### Verification after deploy

```
live on host   : SHA256:N/dvyjjwTnjApzE5zUVC2282Q93gURLtu3fzpOFtFCc
sops stored    : SHA256:N/dvyjjwTnjApzE5zUVC2282Q93gURLtu3fzpOFtFCc
burned         : SHA256:WLa2vokv65OpNQe6AdAiFBcMiWDNS1S7rg0c1esvwGI   (no longer served)
node           : k8s-server03 Ready control-plane,etcd,master
```

## What we deliberately did not do

**No history rewrite.** The usual instinct — scrub the blob with `filter-repo` — does not
work on a public repo. Mirrors, forks, clones and crawler caches keep their copies, so
the key stays public while every clone breaks and every open PR conflicts. Rotation is
the fix; rewriting history would have been theatre with a large blast radius.

## Follow-ups

- **Every client of the host needs `ssh-keygen -R`.** `scripts/comin-approve.sh` uses
  plain `ssh` with no pinning, so a stale entry makes the gatekeeper **hard-fail** rather
  than warn. Note that the investigation itself pins the compromised key — the
  `ssh-keyscan` used to confirm the leak added it to the investigator's own
  `known_hosts`.
- **Validity checks on host keys are cheap and under-used.** The containment checks above
  (cross-host reuse, client-key reuse, age-identity usage) are all fingerprint
  comparisons and took minutes. They are worth scripting as a pre-rotation gate.
- The scan that found this also produced one false positive, now scope-ignored by match
  hash in `.gitguardian.yaml`. The ignore is deliberately narrow: `ggshield secret scan
  repo .` still reports this key, which is what proves the ignore is a filter and not a
  mute. Secret scanning runs on every PR push in CI.

## Lessons

1. **Encryption at rest does not encrypt history.** A secret pasted once into a
   SOPS-managed file is public if the plaintext ever reached a commit.
2. **A revert is not a redaction.** Judge exposure by the commit graph, not the working
   tree.
3. **Check what trusts a key before rotating it.** The age-identity question was the one
   that could have turned a routine rotation into an outage.
4. **Record unavailability honestly.** "journald rolled" is a different claim from
   "logs were clean", and only one of them is true.
