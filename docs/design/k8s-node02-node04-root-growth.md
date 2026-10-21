# Design: k8s-node02 / k8s-node04 root filesystem growth

**Status:** Draft — needs the §4 live verification pass before it is executable
**Owner:** Javier Arrieta
**Last updated:** 2026-10-21
**Blast radius:** one k3s worker at a time; Longhorn data is not touched
**Operation type:** partition-table surgery on a live root disk. Non-destructive to
data, destructive to the partition table.

Related: `docs/design/k8s-node03-repartition.md` — same fleet-wide drift, different
node, and that one is genuinely destructive.

---

## 1. Problem statement

`hosts/k8s-node01/disko.nix`, `hosts/k8s-node02/disko.nix` and
`hosts/k8s-node04/disko.nix` are **byte-identical except the disk serial**. All three
declare `root = "120G"`.

Only node01 actually has it.

| node | declared root | actual root | actual `/var/lib/longhorn` | verdict |
| --- | --- | --- | --- | --- |
| k8s-node01 | 120G | 117.5 GiB | 341.9 GiB | matches config |
| k8s-node02 | 120G | **68.3 GiB** | 245 GiB | **undersized** |
| k8s-node04 | 120G | **48.9 GiB** | 343.4 GiB | **undersized** |
| k8s-node05 | 120G + `longhorn=100G` | 117.6 GiB | 97.9 GiB | matches its own config |

**disko only partitions at install time.** `nixos-rebuild switch` never repartitions.
The `root = "120G"` layout landed in `0e9c5ba` (2026-03-27, "[k8s-\*] remove containerd
partition"); node02 and node04 were installed under the previous layout and never
converged.

### Why it matters now

On 2026-10-21 `KubeNodeEviction` fired on k8s-node04 on `imagefs.available` with a
2.44 GiB threshold. `hindsight` and `loki-canary` were evicted. Nothing was leaking:
k3s image storage accumulates on `/` (node01 carries 46 GiB of containerd on a
117 GiB root and absorbs it), and node04 has 48.9 GiB total. The same routine
maintenance-wave image churn that node01 shrugged off at 38.8 GiB free evicted pods
on node04 at 10.2 GiB free.

This is a provisioning gap, not a workload defect. See §6 for the mitigation that is
*not* this runbook.

---

## 2. Current state — measured 2026-10-21 via `lsblk` on the hosts

```
k8s-node02  /dev/sda 476.9G
├─sda1   512M  /boot               vfat
├─sda2   250G                       crypto_LUKS → disk0-longhorn → /var/lib/longhorn ext4
├─sda3    70G                       crypto_LUKS → disk0-root     → /                   ext4
├─sda4   8G    [SWAP]               swap
└─sda5 148.4G                       ext4        ← UNMOUNTED, nothing uses it

k8s-node04  /dev/sda 476.9G
├─sda1   512M  /boot               vfat
├─sda2   350G                       crypto_LUKS → disk0-longhorn → /var/lib/longhorn ext4
├─sda3    50G                       crypto_LUKS → disk0-root     → /                   ext4
├─sda4   8G    [SWAP]               swap
└─sda5  68.4G                       ext4        ← UNMOUNTED, nothing uses it
```

`sda5` is the containerd partition that `0e9c5ba` deleted from the config but never
from the disk. It is unmounted and holds a stale ext4.

Arithmetic against the 476.9 GiB disks:

```
node01: 0.5 + 117.5 + 8 + 341.9 = 467.9 GiB   → ~9 GiB gap (GPT overhead, rounding)
node02: 0.5 +  68.3 + 8 + 245   = 321.8 GiB   → ~155 GiB unaccounted  = sda5
node04: 0.5 +  48.9 + 8 + 343.4 = 400.8 GiB   → ~76 GiB unaccounted   = sda5
```

### The structural constraint

**Partition order is `boot, longhorn, root, swap` — root is not adjacent to the free
space.** `sda4` (swap) sits between `sda3` (root) and `sda5`. Growing root therefore
requires removing or relocating swap. There is no way around this with `growpart` alone.

Note this ordering is also **the reverse of what `disko.nix` declares** (`boot, root,
swap, longhorn`). The installed layout and the config layout differ in order as well
as size. See §7.

---

## 3. Target state

Root ≥ 120 GiB on both nodes, Longhorn partition untouched, swap preserved.

Total space available to root after removing `sda4` and `sda5`:

| node | current root | + `sda5` | + `sda4` | ceiling |
| --- | --- | --- | --- | --- |
| k8s-node02 | 70 GiB | 148.4 GiB | 8 GiB | ~226 GiB |
| k8s-node04 | 50 GiB | 68.4 GiB | 8 GiB | ~126 GiB |

If swap stays an 8 GiB partition, node04's ceiling is **118.4 GiB — just under the
declared 120G**. Taking the swap partition's space and replacing it with a swapfile
is what lets node04 clear 120 GiB (→ ~126 GiB). That is the only reason to prefer the
swapfile; it is not cosmetic.

---

## 4. Live verification pass (blocking — do before scheduling)

Four things are inferred from the repo and `lsblk` and must be confirmed on each host.

### 4.1 `sda5` really is disposable

```bash
sudo mkdir -p /mnt/sda5 && sudo mount -o ro /dev/sda5 /mnt/sda5
findmnt /mnt/sda5 && sudo du -xsh /mnt/sda5 && ls /mnt/sda5
sudo umount /mnt/sda5
```

Expect stale containerd content (`io.containerd.snapshotter.v1.overlayfs`,
`io.containerd.content.v1.content`) or an old `/var/lib/rancher`. **If it holds
anything that is not containerd, stop and re-scope.**

### 4.2 How swap is actually declared

`hosts/k8s-node0{1,2,4}/hardware-configuration.nix` all set `swapDevices = [ ];`, so
swap is **not** coming from the host file — it is generated from `disko.nix`. Confirm
what the running system uses:

```bash
findmnt --swap
systemctl list-units --type=swap --all
grep -rn swap /etc/fstab /etc/crypttab 2>/dev/null
nix-instantiate --eval -E 'import <nixos> {...}.swapDevices' 2>/dev/null || \
  nix eval .#nixosConfigurations.k8s-node02.config.swapDevices   # from the repo
```

Record the answer. The swap change in Phase A has to be made wherever this points,
which is expected to be `hosts/k8s-nodeNN/disko.nix`.

**`disko.enableConfig = true` is set on node04 and not on node02**
(`hosts/k8s-node04/configuration.nix:72`). Do not assume the two behave identically
here — verify per node.

### 4.3 Swap is nearly empty before `swapoff`

`swapoff` pulls every swapped page back into RAM. Under memory pressure it fails, or
worse, starts an OOM kill on a node running Longhorn instance-managers.

```bash
free -h
swapon --show
```

**Gate: swap used must be < ~200 MiB and free RAM must exceed swap used with margin.**
If not, drain the node first or reboot to clear swap before starting.

### 4.4 Longhorn is quiet on the node

The Longhorn partition is never touched, but a partition-table write on a disk that
is also carrying the Longhorn LUKS volume is not a place to be careless.

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json \
  | jq -r '.items[] | select(.spec.nodeID=="k8s-node02") | .metadata.name'   # and node04
```

Not a hard gate — no replica data is on the partitions being edited — but zero
rebuilding on the node is the state in which to do this.

---

## 5. Procedure

Do **one node at a time**. node04 first: it is the fragile one and the smaller
operation. Verify §7 fully before starting the second.

### Phase A — swap moves to a swapfile (via git, before any partition work)

Comin deploys `stable` to the ten fleet hosts; canaries (`node05`, `llm01`, `titan`)
track `main`. A hand-edited `/etc` is reverted by the next deploy, so the swap change
must arrive through the repo.

1. On the node, create the swapfile so the config has something to point at:

   ```bash
   sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   swapon --show          # both swap devices now listed
   ```

2. In the repo, remove the swap partition entry from
   `hosts/k8s-nodeNN/disko.nix` and declare the swapfile where §4.2 says swap is
   configured. Land it as a PR, merge to `stable`, let comin apply.

3. Confirm the running system is satisfied before removing anything:

   ```bash
   swapon --show                       # /swapfile present and active
   sudo swapoff /dev/disk/by-partlabel/<swap-partlabel>
   swapon --show                       # only /swapfile remains
   free -h                             # MemAvailable still sane
   ```

   **Do not proceed until the system no longer depends on `sda4`.** If `swapoff`
   fails, stop — see §4.3.

### Phase B — partition surgery

```bash
# 0. Backup the partition table and copy it OFF the machine before anything else
sudo sgdisk --backup=/root/sda-table-$(date +%F).tar /dev/sda
scp /root/sda-table-*.tar <somewhere-else>:/backup/

# 1. Confirm sda5 is the stale partition from §4.1, then remove sda5 and sda4
sudo wipefs -a /dev/sda5
sudo parted -s /dev/sda rm 5
sudo parted -s /dev/sda rm 4

# 2. Nothing now follows sda3, so it can take the whole remainder
sudo parted -s /dev/sda resizepart 3 100%

# 3. Grow the LUKS mapping to the enlarged partition (no re-encryption happens)
sudo cryptsetup resize disk0-root

# 4. Grow the filesystem online — / stays mounted
sudo resize2fs /dev/mapper/disk0-root

df -h /
```

Expected: node04 `/` ≈ 126 GiB, node02 `/` ≈ 226 GiB.

Order matters. `cryptsetup resize` before `resize2fs`, never the reverse. `parted rm`
numbers refer to the table as it was when the command was typed — remove `5` before
`4`, not the other way round.

### Phase C — verify

See §7.

---

## 6. The mitigation that is NOT this runbook

`crictl rmi --prune` on node02 and node04 reclaims containerd garbage immediately,
with no downtime and no partition table involved. node01 carries 46 GiB of containerd
on a healthy root, so these two are carrying the same class of accumulation on a
fraction of the space.

Do this whether or not the growth happens. It is not a substitute — a 48.9 GiB root is
still a 48.9 GiB root — but it buys headroom today and it is the thing to reach for
when an eviction alert arrives at an inconvenient hour.

Also worth considering cluster-wide, out of scope here: kubelet's image GC runs late
and there is no pruning policy behind it. That is the reason containerd reaches 46 GiB
at all.

---

## 7. Verification checklist

| # | Check | Pass condition |
| --- | --- | --- |
| 1 | Root grew | `df -h /` ≥ 120 GiB |
| 2 | Longhorn mount is a different device and unchanged | `findmnt -o SOURCE / /var/lib/longhorn` shows two devices; longhorn size identical to §2 |
| 3 | Swap still active | `swapon --show` lists `/swapfile`, size ≈ 8 GiB |
| 4 | No stale swap unit | `systemctl list-units --type=swap --all` shows no failing unit for the old partition |
| 5 | Partition table clean | `lsblk /dev/sda` — no orphan partition, no `sda5` |
| 6 | Node Ready, no DiskPressure | `kubectl get node k8s-nodeNN` |
| 7 | Longhorn healthy | `kubectl -n longhorn-system get volumes.longhorn.io` — no degradation caused by this work |
| 8 | Comin happy and not reverted | `comin status --json \| jq '.is_suspended,.deployer.is_suspended'` both false; running config contains the swapfile |
| 9 | Reboots without prompts | TPM2 on node04 (`security.tpm2.enable = true`); node02 takes a LUKS passphrase at the console |

---

## 8. Rollback

| Point | Rollback |
| --- | --- |
| Before Phase A | nothing done yet |
| After Phase A, before Phase B | revert the git change, `nixos-rebuild switch` or wait for comin, `swapon` the original partition, `rm /swapfile` |
| During/after Phase B | restore the partition table from the `sgdisk --backup` tar: `sgdisk --load-backup=/root/sda-table-<date>.tar /dev/sda`, then `cryptsetup resize` down is **not** possible — the LUKS area shrank with the partition, so the filesystem must be shrunk offline from a live ISO, or the node reinstalled |

**Phase B is effectively irreversible without a reinstall.** The partition-table
backup restores the *table*; it does not restore the filesystem to a smaller
container. This is why Phase A is a reviewable PR landed before the window and why §4
is blocking.

---

## 9. Open decisions

### 9.1 Swapfile or relocated swap partition?

Swapfile is recommended: it is the only option that lets node04 clear the declared
120 GiB (118.4 GiB ceiling otherwise), and it removes the adjacency constraint
permanently. **Unverified:** that NixOS accepts a file path in `swapDevices` /
whatever mechanism §4.2 identifies. Confirm before committing Phase A.

**Decision:** ☐ swapfile ☐ relocated partition ☐ other

### 9.2 Grow to fill, or grow to exactly 120 GiB?

Filling is one `resizepart` and leaves nothing unallocated, but puts node02 at
~226 GiB where the config says 120G — i.e. it re-opens the same config-vs-reality gap
this runbook exists to close. Growing to exactly 120 GiB leaves ~106 GiB unallocated
on node02.

**Recommendation:** grow to fill, and record the real sizes in `disko.nix` so the file
stops lying. A config that describes an aspirational layout is how this drift happened
twice already.

**Decision:** ☐ fill ☐ exactly 120G ☐ other

### 9.3 Fix `disko.nix` to describe reality?

Independent of 9.2: the file orders `boot, root, swap, longhorn`; the machines are
`boot, longhorn, root, swap`. A future reinstall from this file produces a third
layout. Either rewrite the file to match the installed order, or accept that a
reinstall is a fresh install and say so in a comment.

**Decision:** ☐ rewrite ☐ document the divergence

### 9.4 Does anything else in the fleet have this problem?

node03 is covered by `k8s-node03-repartition.md`. The pi nodes and servers were not
audited at this level. A `nix eval` vs `lsblk` comparison in CI is the only thing that
stops round three.

**Decision:** ☐ audit ☐ not now

---

## 10. Timeline

| Phase | Duration |
| --- | --- |
| §4 live verification, per node | 20 min |
| Phase A — swapfile + PR + comin apply | 30 min + comin cycle |
| Phase B — surgery | 15 min |
| Phase C — verify | 15 min |
| **Per node** | **~1.5 h**, no Longhorn rebuild, no drain required |

Roughly a tenth of the node03 window, because no data moves.
