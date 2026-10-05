# titan

OVH bare metal, standalone single-node k3s cluster. Public ingress on 80/443,
key-only SSH on **13491**, WireGuard hub for the management plane, comin GitOps on
the `main` canary ring.

Design: `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md`
Runbook: `docs/superpowers/plans/2026-10-01-titan-ovh-single-node-k3s.md` (Tasks 12–16)

> **Never put the concrete public IPv4 in this file or in any committed file.** The
> repo is public. Concrete addressing lives in
> `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.private.md`
> (gitignored). Below, `<OVH_PUBLIC_IP>` means that value.

## OVH panel state

Record what the panel is actually set to, with a date. These are inputs to recovery,
not discoveries to make during an incident.

| setting | value | date |
|---|---|---|
| Reverse DNS `<OVH_PUBLIC_IP>` → `titan.arrieta.eu` | ____ | ____ |
| Edge Network Firewall | nine rules below, applied | 2026-10-02 |
| Rescue mode SSH key (`rescueSshKey`) | ____ | ____ |
| Proactive maintenance / interventions | **ENABLED** (spec Q20) | 2026-10-02 |
| Boot mode | hard disk (must be restored after any rescue session) | ____ |
| Disk wear baseline (`nvme0n1` / `nvme1n1`) | 2 % / 22 % used; 37 TB / 509 TB written; spare 98 % both | 2026-10-01 |

`nvme1n1` is the one to watch: 22 % endurance used and 509 TB written against 2 % /
37 TB on `nvme0n1`. That asymmetry is why the ESP lives on `nvme0n1`
(`pci-0000:02:00.0`). Re-read with
`smartctl -a /dev/nvme0 | grep -iE "percentage_used|available_spare|data_units_written|media_errors"`
— the numbers that matter are `Available Spare` approaching its 10 % threshold and any
non-zero `Media and Data Integrity Errors`; `Percentage Used` above 100 means past rated
endurance, not dead.

### Edge Network Firewall (IPv4, stateless, first match wins, priorities 0–19)

Panel path: **Network → Public IP addresses → `⁝` on the IPv4 → Configure Edge Network
Firewall**. It is per IP (IPv4 only), 20 rules max, lowest priority evaluated first, chain
stops at the first match.

| prio | rule | why |
|---|---|---|
| 0 | Accept TCP, TCP state = established, **Fragments unticked** | the ENF is stateless; without this titan cannot `git fetch` or pull from Attic at all |
| 1 | Accept UDP, **source port 53** | DNS replies. There is no state field on UDP rules — the source port is the only handle |
| 2 | Accept ICMP | path MTU / diagnostics |
| 3 | Accept TCP dst 22 | rescue mode only — rescue sshd listens on 22 and has no host firewall. In normal operation nothing listens on 22, so this costs a scanner a `connection refused` |
| 4 | Accept TCP dst 13491 | SSH |
| 5 | Accept TCP dst 80 | ingress |
| 6 | Accept TCP dst 443 | ingress |
| 7 | Accept UDP dst 51820 | WireGuard |
| 19 | **Deny IPv4** | mandatory. OVH warn in terms: a set of Accept rules only is "not effective at all" — the default when nothing matches is accept |

Panel fields worth knowing before you touch it: `TCP state` and `Fragments` exist **only on
TCP rules**. Leave `Fragments` unticked on rule 0 — ticking it widens an Accept to
fragmented TCP, which is the classic stateless-port-matching evasion, and leaving it off
means TCP fragments fall through to the deny. UDP fragments are dropped by the ENF
regardless of any rule.

Properties of this firewall that bite:

- **Rules apply during DDoS mitigation even when the firewall reads "off".** The ENF is
  force-enabled when the scrubbing centre engages. OVH's own warning: if you disable the
  firewall, *delete the rules too*.
- **UDP fragments are dropped by default.** This is why the WireGuard MTU stays at 1420.
- **QUIC is not supported.** HTTP/3 on Traefik (UDP 443) will not traverse this; if it is
  ever enabled, expect it to fail here and not on the host.
- **The ENF cannot open ports on the server** — it can only drop. The OS firewall in
  `public-host.nix` is still what allows anything, and it is the wall this design actually
  relies on.
- Availability is not guaranteed on the **Eco** product line (Rise / So you Start /
  Kimsufi); this host does expose the configuration page.

Proof the deny is actually in force, from outside: probe a port that is **not** in the
allow list — 6443, 9100, 8080 — and expect a **timeout**. Do not use 22/13491/80/443 for
this test: rules 3–6 explicitly allow them, so the packet reaches the box and
`connection refused` there is correct behaviour, not a leak. Verified 2026-10-02 with the
firewall enabled: 22 open (rescue sshd), 13491/80/443 refused, and 6443/9100/8080/3306/
10250 all dropped.

Source: <https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/firewall-network>

## Bootstrap

From a workstation that can reach the rescue system, with the box in rescue mode
(Debian, your key installed):

```bash
cd ~/nixos-configurations
./bootstrap_host.sh --no-build-on-remote --host titan --ip <OVH_PUBLIC_IP> \
  --age-key-file ~/.config/sops/age/titan-key.txt \
  --disk-password throwaway
```

- **Use `--age-key-file`, never `--age-key "$(cat ...)"`.** The first bootstrap wrote an
  empty `/var/lib/sops-nix/key.txt` and died in `setupSecrets` with `Error getting data
  key: 0 successful groups required, got 0`, because a multi-line key passed as a shell
  argument can arrive word-split (fish splits unquoted substitutions on newlines, so the
  script receives only the `# created:` comment line). The file argument removes quoting
  from the path; the script also extracts exactly the `AGE-SECRET-KEY-` line, prints
  `age key: AGE-SECRET-KEY-1EC... 74 chars` so you can see what it is shipping, and
  refuses to install anything if the line is absent.
- **The key is titan's own**, `~/.config/sops/age/titan-key.txt`, not an admin key. Since
  the Task 17 split, titan's secrets live in `secrets/titan.yaml`, which the titan key
  opens and the admin keys also open -- but the admin key never has to land on an
  internet-facing box, so it does not. Verify before you run:
  `age-keygen -y ~/.config/sops/age/titan-key.txt` must match the recipient in the
  `secrets/titan.yaml` footer. Confirming it by hash after the fact, without printing the
  key: `sudo sha256sum /var/lib/sops-nix/key.txt` on the box against
  `grep '^AGE-SECRET-KEY-' <file> | sha256sum` here.
- **`nixos-anywhere` comes from `nixpkgs`, not the GitHub flake.** Inside a Coder
  workspace a local build fails with `fchmodat2 ... Operation not permitted`: seccomp
  blocks the syscall Nix 2.34 uses to make store paths writable, and Nix falls back on
  `ENOSYS` but not on `EPERM`. Substitution is unaffected, and nixpkgs ships the same
  1.13.0 prebuilt. Override with `NIXOS_ANYWHERE=github:nix-community/nixos-anywhere`
  on a machine without that restriction.
- `--no-build-on-remote` is required. The Attic cache is reachable only over the
  mesh, which does not exist yet, so the build happens on the workstation and ships
  its closure over SSH.
- `--disk-password` is **unused**: root is not encrypted in v1 (spec D9, LUKS +
  initrd SSH unlock deferred). The script requires the argument, so pass something
  throwaway.
- Rescue-mode SSH is port **22**. Do not pass `--ssh-port`.
- Keep the OVH **IP-KVM** session open for the whole run: the first boot is where an
  mdraid/LVM initrd mistake shows up.

### First boot — verify over the public path only

The mesh does not exist yet, so everything here goes over the WAN.

```bash
ssh -p 13491 javier@titan.arrieta.eu '
  readlink /run/current-system
  systemctl is-system-running --wait
  findmnt -no SOURCE,TARGET /var/lib/rancher/k3s/storage
  findmnt -no SOURCE /
  cat /proc/mdstat
  systemctl is-active k3s sshd wireguard-wg0
  kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node -o wide
'
```

- `findmnt` under `/var/lib/rancher/k3s/storage` must show `lv-pvc`. **If it shows
  `/dev/mapper/vg0-root`, stop** — PV data is landing on `/`.
- `kubectl get node -o wide` `INTERNAL-IP` should be `<OVH_PUBLIC_IP>`. A `10.62.x`
  address means flannel grabbed the wrong interface.

### Prove the firewall denies

```bash
nc -zvw3 titan.arrieta.eu 13491   # succeeded
nc -zvw3 titan.arrieta.eu 80      # succeeded
nc -zvw3 titan.arrieta.eu 6443    # timeout  <- DROP, not refused
nc -zvw3 titan.arrieta.eu 9100    # timeout
nc -zuvw3 titan.arrieta.eu 51820  # succeeded
```

A **timeout** is the DROP working; a *refused* would mean something is listening.

### comin

```bash
ssh -p 13491 nixos@titan.arrieta.eu \
  'comin status --json | jq "{deployer: .deployer.deployment.status, suspended: .is_suspended, deployer_suspended: .deployer.is_suspended}"'
tail -3 /var/log/comin-health-gate.log
```

Expect `done`, both suspension flags `false`, and a recent `health gate OK`.

## Break-glass ladder

In order. SSH never depends on WireGuard, so "WG is down" is not a lockout — it
degrades Prometheus, Attic and rsyslog only.

1. `ssh -p 13491 javier@<OVH_PUBLIC_IP>` — the primary path, not the emergency one.
2. **IP-KVM console, logged in as `javier` with the break-glass password.** This exists
   precisely for the case where SSH is unreachable: `ssh.passwordAuthentication` is false,
   so the password is only ever usable here, and `sudo` prompts for it. Test it while you
   do not need it (`sudo -u javier sudo -n true` should answer `a password is required`).
   If it ever fails, the account can still be reached by editing the boot entry: at the
   systemd-boot menu press `e`, replace `init=/nix/store/.../init` with `init=/bin/sh`,
   add ` rw`, boot, then `mount -o remount,rw /`.
3. Box up but config broken: `nixos-rebuild switch --rollback` over that session, or
   boot the previous systemd-boot entry from the panel KVM
   (`boot.loader.systemd-boot.configurationLimit = 5` keeps rollback entries on disk).
   Note `switch-to-configuration` lives in `/run/current-system/bin/`, **not** `sw/bin`.
4. WG down and you need a home-side thing (Prometheus, Attic, rsyslog): nothing
   breaks the box; those just go stale.
5. Box won't boot: OVH **rescue mode** → mount the root FS → chroot →
   `nixos-rebuild switch` from `/run/current-system`, or re-run nixos-anywhere.
   This step needs ENF rule 3 (TCP 22).
6. Network config wrong and SSH unreachable: that is rung 2 -- the console path is the
   reason the break-glass password exists. Fix the address from there
   (`ip addr replace <IP>/24 dev eno1; ip route replace default via <OVH_GATEWAY> dev eno1`)
   and re-deploy rather than reinstalling.
7. OVH panel firewall to cut inbound while a bad rule is live.

## Recovery commands

```bash
# If /var/lib/sops-nix/key.txt is gone or wrong, the host can no longer deploy:
# every sops secret fails to materialise, so activation fails. It lives in /var/lib,
# not the store, so it survives rebuilds and GC — losing it means losing /var/lib or
# overwriting it by hand. Once Task 17 has landed, restore with the TITAN key; an admin
# key also works but re-widens the blast radius until it is swapped back. Either way:
# root:root, 0600, then re-run the switch.
sudo install -m 0600 -o root -g root /path/to/keys.txt /var/lib/sops-nix/key.txt

# Route watchdog around any build/switch (fresh worker switches can drop the
# default route mid-activation). Absolute paths for BOTH commands: a loop whose
# `sleep` is missing from PATH becomes a 200-spawn/sec flood into rsyslog.
sudo systemd-run --unit=routewatch --collect bash -c \
  'while true; do /run/current-system/sw/bin/ip route replace default via <OVH_GATEWAY> dev eno1; /run/current-system/sw/bin/sleep 10; done'
sudo systemctl stop routewatch        # when settled

# comin stuck after a health-gate suspend + daemon restart (comin issue #159):
# the deployer restores isSuspended=true but the manager does not, so `resume`
# alone fails. Suspend first to sync the manager, then resume.
comin suspend && comin resume

# Storage
cat /proc/mdstat
sudo mdadm --detail /dev/md/titan
sudo lvdisplay vg0
```

## titan's own sops age key (Task 17 Steps 6–7)

The point: titan must hold a key that opens `secrets/titan.yaml` and **nothing wider**.
While it holds the repo-wide admin key in `/var/lib/sops-nix/key.txt`, a popped titan
decrypts all of `secrets.yaml` — every host key, every join token, every object-store
credential. The file split is already merged (`secrets/titan.yaml`, the `.sops.yaml` rule,
all seven `titan` secrets pointing at it); what remains is one host-side swap and one proof.

**Mint the key on titan**, so its private half never leaves the box that uses it. The first
candidate for this key was minted on a Coder workspace instead and had to be shipped over;
it was retired by re-encrypting before it was ever installed, so nothing came of it.

```bash
# 1. on titan — mint into tmpfs, then print ONLY the public half
sudo sh -c 'umask 077; age-keygen -o /run/titan-key.in'
sudo age-keygen -y /run/titan-key.in

# 2. on a workstation holding an admin key — put that age1… in .sops.yaml under the
#    ^secrets/titan\.yaml$ rule (replacing the old titan line), then re-encrypt:
sops updatekeys secrets/titan.yaml -y
#    verify 5 recipients, unchanged plaintext, secrets.yaml untouched; PR both files.

# 3. back on titan — the script needs a working tree, and comin's checkout is a BARE repo
#    with no files in it, so clone one. /run is tmpfs, so it leaves nothing on the disk.
sudo git clone --depth 1 https://github.com/javierarrieta/nixos-configurations /run/nixcfg
sudo sh /run/nixcfg/scripts/titan-age-key-swap.sh \
  --key-file /run/titan-key.in \
  --repo /run/nixcfg
```

`--repo` is mandatory: the auto-detect cannot work, since neither comin's bare repo nor a
fresh clone has a fixed location. A persistent checkout (`/root/nixos-configurations`) works
just as well — it holds only encrypted secrets.

Ordering, all three parts of it:

- **Step 2 before step 3.** The admin key titan already holds stays a recipient throughout,
  so there is no window where titan cannot decrypt its own secrets.
- **The rotation commit must be deployed to titan before the swap.** Activation re-runs the
  *current* generation, and that generation carries a store copy of `secrets/titan.yaml`
  baked in when it was built. A freshly rotated repo file and that embedded copy differ, so
  a perfectly good new key opens the repo copy and fails on the one activation reads:
  `sops-install-secrets: failed to decrypt '/nix/store/…-titan.yaml': Error getting data
  key: 0 successful groups required, got 0`. Check `3b` refuses on this now. Titan is a
  canary, so `comin` deploys it on its own — wait for the commit, then swap.
- **Nothing is lost if you get it wrong.** A failed activation restores the previous key and
  re-activates; a non-zero exit means the host is exactly as it was.

`/run` is tmpfs, so the key never reaches the root disk, and the script shreds what it is
given. It refuses to finish until it has proved, on the host:

1. the candidate's public half is titan's recipient (`TITAN_RECIPIENT` in the script; pass
   `--recipient` after a regeneration);
2. it decrypts `secrets/titan.yaml` — which is also what catches a `.sops.yaml` listing a
   key the file was never actually re-encrypted to;
3. it **cannot** decrypt `secrets.yaml` — the check that catches an admin key handed in by
   mistake, which would install cleanly and change nothing at all;
4. the generation about to be re-activated embeds a `titan.yaml` this key can open (the
   ordering trap above) — tested in isolation, because with both keys installed activation
   would succeed on the admin key's effort alone and prove nothing;
5. activation is healthy with **old + new installed together**, so the host is never one
   unproven key away from its own secrets;
6. activation is healthy with **the new key alone**, and every materialised secret path is
   present — including `/run/secrets-for-users/…` (the `neededForUsers` tmpfs) and the
   host keys under `/etc/ssh`, which are not under `/run/secrets` at all.

Only then does it destroy the backup of the admin key. `--keep-backup` moves it to
`$KEY_DEST.backup` instead of shredding it. A failure at any point restores the previous
key and re-activates, so a non-zero exit means the host is exactly as it was — and by step 6
the key being restored is one already proven on this host minutes earlier, not a hope. The
refusals are exercised offline by `scripts/titan-age-key-swap-tests.sh` (12 cases, no real
keys needed).

**Why the script runs `sops` with an empty `HOME`.** `SOPS_AGE_KEY_FILE` is not exclusive:
sops also loads `~/.config/sops/age/keys.txt` and any agent identities and uses whichever
key fits. The first local run of this script reported "titan's key also decrypts
secrets.yaml" — true only because an admin key was sitting in the default path. Check 3 is
worthless without an empty `HOME`, and on titan it also stops a leftover key in root's home
from faking a green proof.

Rollback: the script keeps the previous key until every check passes. If the swap lands and
something later fails to decrypt, re-run the three steps with the old key, or take the
`## Break-glass ladder` path. Afterwards, confirm from the fleet side that
`comin status --json` shows unsuspended and one deploy still lands.

## Rotating the API server serving certificate

`--tls-san=192.168.133.1` is declarative in `vars.nix`, but k3s writes SANs into
`serving-kube-apiserver.crt` only when it generates that file. A rebuild that adds
the flag leaves the live certificate untouched, so the mesh path keeps failing
`x509: certificate is valid for ..., not 192.168.133.1` and every admin kubeconfig
keeps needing `insecure-skip-tls-verify`. Apply, then rotate, then verify — do not
assume the rebuild did it.

Check what is actually in the certificate, from the mesh side:

```bash
openssl s_client -connect 192.168.133.1:6443 -servername 10.63.0.1 </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

Rotation stops the control plane, and on a single-node cluster that means the whole
cluster: Flux pauses, pods keep running but nothing reconciles. Expect a minute.
The CAs are NOT rotated (`rotate-ca` is a different command), so kubeconfigs that
embed a client certificate — including the ones already copied off this host — keep
working; only the serving certificate changes.

```bash
systemctl stop k3s
# The k3s CLI inherits nothing from the unit, so the flag has to be repeated here
# or the rotated cert comes back with the old SAN list. Same trap as
# `k3s etcd-snapshot list` above.
k3s certificate rotate --tls-san=192.168.133.1
systemctl start k3s
```

If the installed k3s rejects the flag on that subcommand, the narrower equivalent is
to let startup regenerate just that one file:

```bash
systemctl stop k3s
mv /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt{,.bak}
mv /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key{,.bak}
systemctl start k3s
```

Re-run the `openssl` check and expect `192.168.133.1` in the list. Then delete
`insecure-skip-tls-verify: true` from the admin kubeconfigs — that was the point.
Leave it in and the next person has no way to tell whether the fix ever landed.

## Operating the cluster from the box

`k9s`, `kubectl` and `kubectx` are installed for javier. k3s writes the admin kubeconfig
to `/etc/rancher/k3s/k3s.yaml` as `root:root 0600` and nothing here widens it -- on an
internet-facing host that credential stays behind the break-glass password instead of
becoming readable by every process javier runs.

```bash
sudo k3s kubectl get nodes                                  # k3s ships its own kubectl
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml k9s              # k9s has no root ~/.kube/config
```

Plain `sudo k9s` does not work: root has no `~/.kube/config`, and k9s does not look at
k3s' path. If the sudo wrapper becomes annoying, the alternative is a tmpfiles rule
making the file `0640 root:wheel` -- decide that consciously, because it takes the password
out of the path to cluster-admin.

**Nothing that runs in this cluster is defined in this repo.** Ingress, the
`*.titan.arrieta.eu` certificate (cert-manager + the OVH DNS-01 webhook, mirrored to
consuming namespaces by Reflector), the Postgres operator and every workload live in
`../k8s-titan`. Editing a `.nix` here to change cluster behaviour is the wrong door.

## Backups and the restore drill

etcd is snapshotted every 6h by k3s itself into MinIO over the mesh
(`titan-etcd` bucket, `titan/` folder, 24 kept = 6 days of recovery points). Flags live in `vars.nix`;
credentials are the `titan/minio_env` sops secret, delivered to the unit as
`EnvironmentFiles` so no secret appears in the world-readable unit file.
Two kubelet/controller-manager knobs are coupled and must move together:
`node-status-update-frequency=2m` (kubelet lease + status interval, default 10s) and
`node-monitor-grace-period=5m` (kube-controller-manager). If the grace period is
shorter than the renew interval, the controller declares the node NotReady and after
the 5m NoExecute taint **evicts everything off the only node in the cluster**. Changing
one without the other is the trap.

PV data has **no generic backup yet**. The cluster tree is `../k8s-titan`, and what it
backs up so far is the shared Postgres through CloudNativePG's own `ScheduledBackup` to
S3 -- a better mechanism for that data than a restic CronJob over
`/var/lib/rancher/k3s/storage`. A restic PV job (plan Task 16b) is open **there**, not
here.

### The datastore must be etcd, and it was not (2026-10-02)

`k3s etcd-snapshot save` answered **`etcd datastore disabled`** because a lone k3s
server without `--cluster-init` runs on **sqlite**, not embedded etcd. Until
`--cluster-init` is in `vars.nix` every `--etcd-s3` flag is inert and there is
nothing to snapshot.

k3s cannot migrate sqlite -> etcd in place. The migration is a rebuild of the
datastore, so do it while the cluster is empty:

```bash
K=/etc/rancher/k3s/k3s.yaml
# 1. prove what you are about to lose
kubectl --kubeconfig $K get pods -A -o wide
kubectl --kubeconfig $K get ns,pvc -A
kubectl --kubeconfig $K get ns,secret,configmap,deploy,svc,ingress,pvc,cm -A -o yaml \
  > /root/k3s-sqlite-export-$(date +%F).yaml     # the only thing that can put it back

# 2. stop comin so a deploy cannot race the migration
systemctl stop comin

# 3. retire the sqlite store (the CA and certs in server/ stay, so k3s.yaml survives)
systemctl stop k3s
mkdir -p /root/sqlite-retired-$(date +%F)
mv /var/lib/rancher/k3s/server/db/state.db* /root/sqlite-retired-$(date +%F)/

# 4. deploy the generation that carries --cluster-init, then start
systemctl start comin            # or: nixos-rebuild switch --flake /var/lib/comin/repository#titan

# 5. prove etcd is real
ls /var/lib/rancher/k3s/server/db/etcd           # must exist now
journalctl -u k3s -g "initialized new cluster|etcd-server" --no-pager | tail
```

If k3s refuses to start with both `state.db` and `--cluster-init` present, the
health gate rolls back; move `state.db*` aside and redeploy. Rollback of the
migration itself is: stop k3s, move `state.db*` back, drop `--cluster-init`, switch.

### Checking snapshots are landing

A row is only proof if it points at the bucket. k3s keeps a local copy too, so a
scheduled snapshot that failed to upload still shows up in the list:

```bash
k3s etcd-snapshot list | grep 's3://'      # only these rows are backups
```

If the scheduled rows are `file://` only, the server cannot authenticate. Check that the
credentials actually reached the process -- a secret file existing and a flag being present
in `ExecStart` are both consistent with the process having neither:

```bash
systemctl show k3s -p EnvironmentFile          # must list minio_env
sudo tr '\0' '\n' < /proc/$(systemctl show k3s -p MainPID --value)/environ | grep -c AWS
journalctl -u k3s --since '12:00' | grep -iE 'snapshot|s3'   # Access Denied = no creds
```

**This bit on 2026-10-03.** The credentials were declared as
`systemd.services.k3s.serviceConfig.EnvironmentFiles` (plural). systemd has no such
`[Service]` key, ignores it with a journal warning, and the unit starts anyway -- so k3s
went to MinIO anonymously and every scheduled snapshot failed with `Access Denied` for
hours while the node stayed `Ready`. `systemctl show -p EnvironmentFiles` reports the
*property* name (plural, parsed from the singular directive), which is what made the wrong
spelling look like it was working. The config now uses `k3s.environmentFiles`, which
`k3s.nix` renders as **one `EnvironmentFile=` directive per file**, and
`k3sSnapshotMonitor` asserts the env file is on that list so the mistake fails the build.

The first fix for this space-joined both paths into a single `EnvironmentFile=a b`. That
does not work either: systemd takes the whole value as one filename, fails to load it, and
the unit dies with `Result: resources` -- it took k3s down on deploy. Proved in isolation:

```bash
systemd-run -p "EnvironmentFile=/a /b" true   # fails: unavailable resources
systemd-run -p EnvironmentFile=/a true        # succeeds
```

So check the generated unit, not the option value:
`grep '^EnvironmentFile' /run/current-system/etc/systemd/system/k3s.service` should show
one line per file. Evaluating the option and building the system both passed with the
broken join, so neither is proof of anything here.

If the list is empty, the usual cause is the bucket: MinIO answers
`AccessDenied` -- not `NoSuchBucket` -- for a bucket that does not exist, so a
missing bucket and a permissions problem look identical.

### The drill (DESTRUCTIVE)

`--cluster-reset` rewrites the datastore. Run it deliberately, never as a
reaction to something else being on fire.

```bash
K=/etc/rancher/k3s/k3s.yaml
kubectl --kubeconfig $K create ns drill
kubectl --kubeconfig $K -n drill create configmap canary --from-literal=written=before
k3s etcd-snapshot save --name pre-drill $S3FLAGS
# k3s RENAMES it: --name pre-drill became pre-drill-titan-1791014355, i.e.
# <name>-<node>-<unix-ts>. Never restore from the name you typed; capture the real one:
SNAP=$(k3s etcd-snapshot list $S3FLAGS | awk '/pre-drill/ {print $1; exit}')
echo "will restore: $SNAP"
kubectl --kubeconfig $K -n drill delete configmap canary   # make it really gone
```

`list` needs the same `$S3FLAGS` as `save`, or it shows only local snapshots. Note it
also keeps a **local copy** under `/var/lib/rancher/k3s/server/db/snapshots/` (capped by
the default local retention of 5), so each snapshot appears twice.

Define the flags once -- both `save` and the restore need them:

```bash
S3FLAGS="--etcd-s3 --etcd-s3-endpoint=s3.l.arrieta.eu --etcd-s3-bucket=titan-etcd \
--etcd-s3-region=eu-west-1 --etcd-s3-folder=titan --etcd-s3-bucket-lookup-type=path"
set -a; . /run/secrets/titan/minio_env; set +a
```

Then restore. **The manual `k3s server` invocation inherits nothing from the unit**, so
every flag has to be repeated -- and two of them are not S3 flags at all:

- **`--cluster-init`**, or the manual server comes up on sqlite and "restores" a datastore
  that does not exist.
- **`--cluster-reset-restore-path` takes a BARE SNAPSHOT NAME, not an `s3://` URL.**
  `pkg/etcd/etcd.go` passes it verbatim to `Download()`, and `pkg/etcd/s3/s3.go` computes
  the key as `path.Join(folder, snapshotName)`. So the `s3://bucket/folder/name` form the
  k3s docs show produces the key `titan/s3:/titan-etcd/titan/...` and fails with
  `The specified key does not exist` -- after the bucket check passes, which makes it look
  like a permissions problem. It is not: the object is fine, the key was nonsense.

```bash
systemctl stop k3s
k3s server --cluster-init --cluster-reset \
  --cluster-reset-restore-path=$SNAP \
  $S3FLAGS
# it exits once the store is reset; then:
systemctl start k3s
sleep 20
kubectl --kubeconfig $K -n drill get configmap canary -o jsonpath='{.data.written}'; echo
kubectl --kubeconfig $K get nodes
```

Expected: `before`, node `Ready`, no CrashLoopBackOff fleet-wide. Clean up with
`kubectl --kubeconfig $K delete ns drill`.

**A failed restore attempt is safe to retry.** k3s downloads the snapshot *before* it
touches the datastore, so a bad key or a 404 leaves the live cluster untouched -- verified
by three failed attempts followed by a successful one on the same running cluster.

### Is the backup still running?

A scheduled snapshot that stops working is invisible. k3s swallows S3 failures inside
the server process (Rancher #14144): the node stays `Ready`, k3s stays healthy, the unit
log stays quiet, and the bucket simply stops receiving objects. Every one of the six
defects found on 2026-10-03 would have looked like a working backup.

`k3sSnapshotMonitor` (module `modules/nixos/k3s-snapshot-monitor.nix`) runs
`k3s etcd-snapshot list` every 15 minutes and publishes two gauges through
node_exporter's textfile collector:

| metric | meaning |
|---|---|
| `k3s_etcd_snapshot_age_seconds` | age of the newest **`s3://`** snapshot; local copies are ignored on purpose, because a fresh local file says nothing about the upload |
| `k3s_etcd_snapshot_check_success` | `0` when the listing failed or no S3 object was found -- so a broken check is visible, not silently green |

The check re-passes the S3 flags from `vars.nix` (`snapshotS3Flags`, shared with the
server so they cannot drift), because the CLI inherits nothing from the unit.

**Not yet scraped.** The metric is exposed on `titan:9100`, which is mesh-only. The
scraper is **k8s-casa**, the central Prometheus, and the path does not need Task 15:
OPNsense routes LAN to the new mesh (route, not masquerade), so a casa target reaches
`192.168.133.1` with source `192.168.0.29` after pod masquerade -- exactly the source
`publicHost.meshTCPPortExtraSources` whitelists on `wg0`. Verify from the llm01 host
(not a podman container: bridge-sourced traffic is `10.88.0.0/16`, which OPNsense's
`LAN net -> WG_MESH` rule excludes):

```bash
curl -m 5 -s http://192.168.133.1:9100/metrics | head -3
```

If that answers, add to `k8s-casa`:

```yaml
# apply/50-apps/monitoring/node-exporter-titan.yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: node-exporter-titan
  namespace: monitoring
  labels: { prometheus: prometheus-k8s }
spec:
  staticConfigs:
  - targets: [ 192.168.133.1:9100 ]
    labels: { job: monitoring/node-exporter, host: titan }
```

```yaml
# Snapshots are scheduled every 6h (00/06/12/18), so 8h means "one missed, one late".
- alert: TitanEtcdSnapshotStale
  expr: k3s_etcd_snapshot_age_seconds > 8*3600
  for: 15m
- alert: TitanEtcdSnapshotCheckFailed
  expr: k3s_etcd_snapshot_check_success == 0
  for: 30m
```

Until then the check runs and the textfile is written, but nothing reads it: the drill
below is the only proof that backups land.

### Drill log

| date | wall clock | result | notes |
|---|---|---|---|
| 2026-10-03 | snapshot 07:59:15 UTC, restore verified ~08:05 UTC | **PASS** -- canary `written=before` came back, `titan Ready` (`control-plane,etcd`) | First drill, run against the freshly-migrated embedded-etcd datastore. Snapshot `pre-drill-titan-1791014355` (6.7 MB) at `s3://titan-etcd/titan/`. **Six defects in the plan's S3 configuration were found this way**, all of which deployed cleanly and left k3s healthy: wrong flag family (`--etcd-snapshot-s3-*`), in-cluster `:9000` port, `https://` scheme in the endpoint, `us-east-1` instead of MinIO's `eu-west-1`, missing `--cluster-init` on the restore, and the `s3://` restore path form from the k3s docs. The last two only surface during a restore, which is exactly why the drill is the exit criterion and not a formality. |

## ICMP is not a liveness probe on OVH

OVH's proactive DDoS mitigation raises an **intervention when the primary IP stops
answering ICMP**, and it **stays raised for as long as the condition holds** -- so a box
whose network config is broken sits in intervention indefinitely, and "waiting it out"
waits for something that will not happen on its own. Panel -> Server -> DDoS ->
**Resume normal traffic** clears it; fixing the host is what keeps it clear.

Consequences, all learned the hard way on 2026-10-02:

- A host that has lost its address stops answering ping, which trips the intervention.
  The intervention is a *symptom* of the outage, not a second problem.
- While an intervention is up, inbound traffic is dropped at the edge and looks exactly
  like a local firewall drop from outside: `SSH times out` tells you nothing about
  whether `sshd` is alive. Do not diagnose the host from ICMP or from a timeout.
- ENF rules apply during mitigation even when the panel toggle reads "off".
- **Disable proactive interventions during bring-up.** A transient route blip mid-switch
  should be a blip, not a multi-hour lockout. Re-enable it once titan has survived a
  couple of unattended comin deploys.

## After any OVH intervention

Proactive maintenance is enabled, so an unannounced reboot is a real event, not an
exotic one. Check, in order:

1. Panel boot mode is back to **boot from hard disk**.
2. `mdadm --detail /dev/md/titan` shows both spares rebuilt.
3. `wg show` handshakes are fresh.
4. `systemctl is-active k3s` and etcd healthy.
5. The nine ENF rules are still present.

Residual accepted risk: a single node has no redundancy, so an intervention is a
full outage. Mitigated by the health gate and the rollback entry, not by failover.

Second residual risk, until Task 17 lands: titan's age key is the **repo-wide admin
key**, so a popped titan can decrypt all of `secrets.yaml` — every host's SSH host
key, the k3s tokens, the object-store credentials. The firewalls limit exposure, not
blast radius. Task 17 replaces it with a titan-only key that decrypts only
`secrets/titan.yaml` — the swap and its proof are scripted in
`scripts/titan-age-key-swap.sh`, see `## titan's own sops age key`.
