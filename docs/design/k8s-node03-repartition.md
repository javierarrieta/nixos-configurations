# Design: k8s-node03 Longhorn Partition Remediation

**Status:** Draft — awaiting pre-flight verification
**Owner:** Javier Arrieta
**Last updated:** 2026-09-21
**Blast radius:** one k3s worker (k8s-node03) + Longhorn data locality
**Operation type:** DESTRUCTIVE — full disk repartition via nixos-anywhere

---

## 1. Problem statement

k8s-node03 was provisioned with Longhorn writing to `/var/lib/longhorn` as a plain
directory on the **root filesystem**, instead of on a dedicated encrypted partition
as every other storage node uses.

This is a provisioning mistake, corrected in code but never applied to the machine.

### Why it matters

Longhorn replicas grow on demand. Sharing `/` with the nix store, containerd, logs,
and systemd state means a replica growth event can exhaust the root filesystem and
take down the node. This cluster already has documented `dbus-broker` reload
timeouts during switches (`AGENTS.md`, 2026-08-31) — Longhorn competing with nix
for root space is the worst possible combination on a k3s worker.

A dedicated partition makes this failure mode **contained**: Longhorn fills its own
disk, Longhorn stops scheduling, the OS survives.

---

## 2. Current vs. target state

### Measured current state (2026-09-21, via node_exporter)

| Path | Device | Size | Free | Notes |
|---|---|---|---|---|
| `/` | `/dev/sda1` (ext4) | 494 GB | 146 GB | holds everything |
| `/var/lib/longhorn` | **not a mount** | — | — | plain dir on `/`, ~300 GB Longhorn data |
| `/boot` | vfat | 512 MB | — | |

Estimated composition of the 348 GB used on `/`: ~300 GB Longhorn + ~48 GB OS/nix/containerd.

### Target state (matching node01/02/04/05)

| Partition | LUKS name | Mount | Size |
|---|---|---|---|
| `disk0-boot` | — (vfat) | `/boot` | 512 MB |
| `disk0-root` | `disk0-root` | `/` | **120 GB** |
| `disk0-swap` | — | swap | 8 GB |
| `disk0-longhorn` | `disk0-longhorn` | `/var/lib/longhorn` | **~367 GB** (100% of remainder) |

Target disk: `/dev/disk/by-id/ata-N900-512_RNG00000000000001240`

> ⚠️ **Root shrinks from 494 GB → 120 GB.** This is the single most important
> number in this document. See §4.1.

### Fleet context (Longhorn disk nodes)

| Node | Longhorn path | Total | Free | Used |
|---|---|---|---|---|
| k8s-node01 | dedicated | 367 GB | 18 GB | **95%** ⚠️ |
| k8s-node02 | dedicated | 263 GB | 150 GB | 57% |
| **k8s-node03** | **on `/`** | 494 GB | 146 GB | ~300 GB Longhorn |
| k8s-node04 | dedicated | 368 GB | 145 GB | 60% |
| k8s-node05 | dedicated | 105 GB | 99 GB | 5% |

Cluster-wide Longhorn occupies ~987 GB against **~23 GiB of live application data**
(measured via `kubelet_volume_stats_used_bytes` across 28 attached PVCs). The
overwhelming majority is snapshot retention and orphaned replicas, not data.

---

## 3. Git archaeology — how this happened

```
68d76b1  [k8s-node03] disko                          ← disko configured correctly
72feeaa  [k8s-node02|3] disko fine tuning
0e9c5ba  [k8s-*] remove containerd partition
1cfe480  [k8s-node03] disable disko and adapt to     ← THE MISTAKE (2026-03-29)
         current disk layout
68843b8  [k8s-node03] dm_crypt module
```

Commit `1cfe480` removed `./disko.nix` from the imports list, renamed
`disko.nix` → `ignored-disko.nix`, and rewrote `hardware-configuration.nix` to
hardcode the then-current UUID-based mounts. The node has run that way ever since.

`ignored-disko.nix` is **dead code** — `grep -rn "ignored-disko"` returns nothing.

---

## 4. Risk analysis

### 4.1 ROOT SIZE SHRINK — verify before you commit (HIGH)

Root goes 494 GB → 120 GB. My estimate of non-Longhorn usage is ~48 GB, which
fits with ~72 GB headroom. **But that estimate is only as good as the "~300 GB
Longhorn" figure.** If Longhorn is actually using less, the OS footprint is larger
and 120 GB gets tight.

**Blocking check — must pass before proceeding:**

```bash
ssh k8s-node03 'df -h /; du -xsh /var/lib/longhorn /nix /var/lib/containerd /var/log /home 2>/dev/null | sort -rh'
```

Gate: non-Longhorn usage on `/` must be **≤ 80 GB**. If it exceeds that, either
bump `size = "120G"` in the disko config or clean before reinstalling.

### 4.2 DATA LOSS — the ~300 GB on node03 gets destroyed (CRITICAL)

Repartitioning wipes the disk. That 300 GB is Longhorn **replicas**. With
`default-replica-count: 2`, most volumes have a copy elsewhere — but **any volume
whose only healthy replica lives on node03 is permanently lost.**

This is the one risk that cannot be undone. §5.1 is a hard gate.

### 4.3 LAST-COPY RISK WHILE node03 IS DOWN (HIGH)

k8s-node01 is at **95% used / 18 GB free = 4.9%**, already below the cluster's
`storage-minimal-available-percentage: 10` (36.7 GB). node01 is therefore
effectively unschedulable right now.

Consider a volume with replicas on **node01 + node03**:

1. node03 is wiped → volume degraded to one replica, on node01.
2. node01's disk fills the remaining 18 GB during the maintenance window.
3. **Both replicas gone. Permanent data loss.**

**Mitigation: relieve node01 before opening the maintenance window** (§5.2).
Rebuild targets during the window are node02 (150 GB) + node04 (145 GB) +
node05 (99 GB) = 394 GB — ample for ~23 GiB of live data. The risk is not
capacity, it is node01 having zero headroom while a degraded volume keeps writing.

### 4.4 hardware-configuration.nix UUID pinning (CRITICAL — boot-breaking)

node03's `hardware-configuration.nix` pins mounts to UUIDs that **die with the
repartition**:

```nix
fileSystems."/"     = { device = "/dev/disk/by-uuid/0cc39954-43a6-44aa-a1a6-0637abcc2772"; };
fileSystems."/boot" = { device = "/dev/disk/by-uuid/5497-FF12"; };
swapDevices = [ { device = "/dev/disk/by-uuid/7a78afe3-b479-4220-909e-975228ba3ec2"; } ];
```

Compare node01 (the working disko reference) — it has **no `fileSystems.*` entries
at all** and `swapDevices = [ ]`, because **disko owns the mounts**.

Leaving node03's stale UUID entries in place while enabling disko produces
conflicting mount configuration and a **system that will not boot**. These entries
must be removed. See §6.1.

### 4.5 Network route loss during switch (MEDIUM)

`AGENTS.md` documents that fresh worker switches drop the default route
mid-activation. Run the route watchdog through the whole operation:

```bash
sudo systemd-run --unit=routewatch --collect bash -c '
  while true; do
    /run/current-system/sw/bin/ip route replace default via 192.168.0.1 dev enp3s0
    /run/current-system/sw/bin/sleep 10
  done'
```

Use **absolute paths for both `ip` and `sleep`** — a watchdog whose `sleep` is
missing from PATH becomes a 200-spawn/sec loop that floods journald and fills the
disk (`AGENTS.md`, incident 2026-08-27, k8s-node03 — this exact host).

### 4.6 TPM2 enrollment mismatch (MEDIUM)

The disko config declares `crypttabExtraOpts = [ "tpm2-device=auto" ]`, but
node03 does **not** set `security.tpm2.enable = true`. Only node04 does:

| Host | `security.tpm2.enable` | `disko.enableConfig` |
|---|---|---|
| node01 | no | no |
| node02 | no | no |
| node03 | no | no |
| **node04** | **yes** | **yes** |
| node05 | no | no |

Decision needed (§10.1). Without TPM enrollment the box prompts for the LUKS
passphrase on every boot — acceptable but worse than the other nodes.

### 4.7 Longhorn rebuild pressure (LOW-MEDIUM)

`replica-soft-anti-affinity: false` (strict) + `default-replica-count: 2` means
every volume needs 2 distinct schedulable nodes. During the window the pool is
node01 (unschedulable), node02, node04, node05 → 3 usable. Sufficient, but
`replica-replenishment-wait-interval: 600` (10 min) throttles how fast rebuilds
start. Budget for it.

---

## 5. Pre-flight gates (all must pass before the maintenance window)

### 5.1 GATE: no volume depends solely on a node03 replica

```bash
# Full volume inventory
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
  .items[] | "\(.metadata.name)\trobustness=\(.status.robustness)\tnumReplicas=\(.status.numberOfReplicas)"'

# Replica placement per node
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r '
  .items[] | "\(.spec.volumeName)\t\(.spec.nodeID)\tdesired=\(.spec.desiredState)\tcurrent=\(.status.currentState)"' | sort

# THE DECISIVE CHECK — replica count per volume EXCLUDING node03
kubectl -n longhorn-system get replicas.longhorn.io -o json \
  | jq -r '.items[] | select(.spec.nodeID != "k8s-node03") | .spec.volumeName' \
  | sort | uniq -c
```

**Pass condition:** every volume in the first listing appears in the last listing
with count **≥ 1**. Any volume absent from the last listing has all its replicas on
node03 → **do not proceed** until it is rebuilt elsewhere or backed up and verified.

**Safety net:** if a backup target (TrueNAS/S3) is configured, take a fresh backup
of every volume and verify backup integrity before the window. Do not rely on
"backups probably exist."

### 5.2 GATE: node01 has headroom

```bash
# node01 must be comfortably above storage-minimal-available-percentage (10% = 36.7 GB)
P=http://192.168.0.14:30900
curl -s -G "$P/api/v1/query" \
  --data-urlencode 'query=100 * node_filesystem_avail_bytes{mountpoint="/var/lib/longhorn",instance="192.168.0.14:9100"} / node_filesystem_size_bytes{mountpoint="/var/lib/longhorn",instance="192.168.0.14:9100"}' \
  | jq -r '.data.result[0].value[1] | "\(.)% free on node01"'
```

**Pass condition:** node01 **> 15% free** (≥ 55 GB). Achieve this by purging
snapshots and orphaned replicas on node01 — **not** by migrating data. Only
~23 GiB of the 348 GB is live; the rest is retention garbage.

Longhorn UI → Volume → Snapshots → select → Delete → **Purge** (deleted snapshots
do not release blocks until purged). Then check `kubectl get orphans.longhorn.io -A`.

### 5.3 GATE: root fits in 120 GB

Run the §4.1 check. Pass condition: non-Longhorn `/` usage ≤ 80 GB.

### 5.4 GATE: install prerequisites staged

- [ ] NixOS Live ISO bootable on node03 (console/IPMI/KVM access available)
- [ ] LUKS passphrase available → will be written to `/tmp/disko-password` on target
- [ ] SOPS bootstrap age key available
      (`age1rlvgte0l7225vqdusvkzmdqmsyfd3u255rfy7ku93xx99k4vldsqhxnyxx`)
- [ ] Build host can reach the flake repo and node03
- [ ] `k8s-node03/network_env`, `ssh_keys/k8s-node03_host_private`,
      `ssh_keys/k8s-node03_host_public`, `k3s_token` all present in `secrets.yaml`
      (confirmed present 2026-09-21)
- [ ] Maintenance window agreed; node03 workloads reschedulable

---

## 6. Procedure

### Phase A — Repository changes (do BEFORE the window, review as a PR)

#### 6.1 Restore the disko module and strip the stale UUID mounts

```bash
git mv hosts/k8s-node03/ignored-disko.nix hosts/k8s-node03/disko.nix
```

Add to `hosts/k8s-node03/configuration.nix` imports (matching node01/02/04/05):

```nix
  imports = [
    ./disko.nix                    # ← ADD (line ~12)
    ./hardware-configuration.nix
    ../../common/users.nix
    ...
  ];
```

**Critical:** remove the three UUID-pinned blocks from
`hosts/k8s-node03/hardware-configuration.nix` so disko owns the mounts. Match
node01's pattern exactly — delete `fileSystems."/"`, `fileSystems."/boot"`, and
set `swapDevices = [ ];`. Keep node03's own `boot.initrd.availableKernelModules`,
`boot.kernelModules` (including `dm_crypt`), and `nixpkgs.hostPlatform`.

The flake already wires `disko.nixosModules.disko` for node03
(`flake.nix:240`) — no flake change needed.

#### 6.2 Verify evaluation before the window

```bash
nix eval .#nixosConfigurations.k8s-node03.config.system.build.toplevel --show-trace
nix eval .#nixosConfigurations.k8s-node03.config.disko.devices.disk --show-trace
nixfmt .
```

Confirm the rendered disko config targets
`ata-N900-512_RNG00000000000001240` and produces the four expected partitions.

#### 6.3 Optional: align TPM2 with node04

If §10.1 resolves to "use TPM2", add to `hosts/k8s-node03/configuration.nix`:

```nix
  security.tpm2.enable = true;
```

### Phase B — Drain node03 (start of window)

```bash
# 1. Route watchdog (see §4.5) — start on node03 before anything else
sudo systemd-run --unit=routewatch --collect bash -c '
  while true; do
    /run/current-system/sw/bin/ip route replace default via 192.168.0.1 dev enp3s0
    /run/current-system/sw/bin/sleep 10
  done'

# 2. Stop Longhorn placing new replicas on node03
kubectl -n longhorn-system edit nodes.longhorn.io k8s-node03
#   → set spec.disks.<disk>.allowScheduling = false

# 3. Cordon + drain workloads off node03
kubectl cordon k8s-node03
kubectl drain k8s-node03 --ignore-daemonsets --delete-emptydir-data \
  --grace-period=120 --timeout=600s
# Note: node-drain-policy is 'allow-if-replica-is-stopped'

# 4. Force replicas off node03: for each volume with a node03 replica,
#    delete that replica CR → controller rebuilds on node02/04/05.
#    Do this ONE VOLUME AT A TIME; wait for robustness=Healthy before the next.
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r '
  .items[] | select(.spec.nodeID=="k8s-node03") | "\(.metadata.name)\t\(.spec.volumeName)"'
# kubectl -n longhorn-system delete replica <name>   # repeat, verifying between each
```

**Do not wipe until this returns zero:**

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json \
  | jq -r '.items[] | select(.spec.nodeID=="k8s-node03") | .metadata.name' | wc -l
```

> ⚠️ Never delete all replicas of a single volume at once. One at a time,
> `Healthy` between each.

### Phase C — Repartition and reinstall

```bash
# 1. Boot node03 on the NixOS Live ISO; ensure network is up
# 2. Write the LUKS passphrase on the target
echo "YOUR_LUKS_PASSWORD" > /tmp/disko-password

# 3. Stage the sops bootstrap key in an overlay dir
mkdir -p <deploy_dir>/var/lib/sops-nix
cat > <deploy_dir>/var/lib/sops-nix/sops-key.txt << 'EOF'
AGE-PRIVATE-KEY-HERE
EOF

# 4. Reinstall (DESTRUCTIVE — wipes /dev/disk/by-id/ata-N900-512_RNG00000000000001240)
nix --extra-experimental-features "nix-command flakes" \
  run github:nix-community/nixos-anywhere \
  -- --flake .#k8s-node03 \
     --target-host nixos@<node03-ip> \
     --build-on-remote \
     --extra-files <deploy_dir>

# 5. Clean up local key material immediately
rm -rf <deploy_dir>
```

Reference: `hosts/k8s-node04/README.md` (same procedure, same disk model).

### Phase D — Post-install, first boot

```bash
# 1. Verify the partition layout actually landed
lsblk -o NAME,SIZE,MOUNTPOINT,FSTYPE /dev/sda
df -h / /var/lib/longhorn
# Expected: / ≈ 120 GB, /var/lib/longhorn ≈ 367 GB, SEPARATE filesystems

# 2. Confirm /var/lib/longhorn is NOT on / anymore  ← the whole point of this exercise
findmnt -n -o SOURCE,MOUNTPOINT /var/lib/longhorn
findmnt -n -o SOURCE,MOUNTPOINT /
# These MUST be different devices

# 3. Enroll LUKS keys in TPM2 (if §10.1 = yes)
systemd-cryptenroll --tpm2-device=list
sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/disk-disk0-root
sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/disk-disk0-longhorn
# verify partlabel names with: ls /dev/disk/by-partlabel/

# 4. Remove the bootstrap age key
sudo rm /var/lib/sops-nix/key.txt

# 5. Reboot and confirm it comes up WITHOUT prompting for a passphrase
sudo reboot
```

### Phase E — Rejoin and validate

```bash
# 1. Longhorn sees the new dedicated disk
kubectl -n longhorn-system get nodes.longhorn.io k8s-node03 -o json | jq '
  {sched: .spec.disks, status: .status.diskStatus}'
# Expected: storageMaximum ≈ 367 GB on a real disk, not the root filesystem

# 2. Re-enable scheduling on node03's disk
kubectl -n longhorn-system edit nodes.longhorn.io k8s-node03
#   → allowScheduling = true

# 3. Uncordon the k8s node
kubectl uncordon k8s-node03
kubectl get node k8s-node03

# 4. k3s agent rejoined
systemctl status k3s.service
journalctl -u k3s -n 50 --no-pager

# 5. Stop the route watchdog once settled
sudo systemctl stop routewatch

# 6. Confirm Longhorn is on the dedicated disk, not root
df -h / /var/lib/longhorn   # on node03
```

---

## 7. Verification checklist

| # | Check | Pass condition |
|---|---|---|
| 1 | `/var/lib/longhorn` is a separate mount | `findmnt` shows a different device than `/` |
| 2 | Longhorn disk size | `storageMaximum` ≈ 367 GB |
| 3 | Root filesystem | ≈ 120 GB total, Longhorn contributes 0 |
| 4 | Boots without passphrase prompt | TPM2 enrollment succeeded (§10.1) |
| 5 | All volumes `robustness=Healthy` | `kubectl -n longhorn-system get volumes.longhorn.io` |
| 6 | 2 replicas per volume, spread | replica placement listing |
| 7 | node03 Ready in k8s | `kubectl get node k8s-node03` |
| 8 | k3s agent active | `systemctl is-active k3s` |
| 9 | No orphaned replicas cluster-wide | `kubectl get orphans.longhorn.io -A` empty |
| 10 | No stale `/var/lib/longhorn` UUID refs | `grep -r '0cc39954\|5497-FF12\|7a78afe3' hosts/k8s-node03/` → empty |
| 11 | Secrets decrypted | `systemctl status sops-nix*`, sshd using persistent host key |
| 12 | Comin on `stable`, not suspended | `comin status --json \| jq '.is_suspended,.deployer.is_suspended'` |

---

## 8. Rollback

**There is no rollback after Phase C.** The old partition table and its data are
destroyed by the repartition. Rollback options are:

- **Before Phase C:** `git revert` the Phase A commit. node03 keeps running as-is.
  Zero cost. This is why Phase A is a reviewable PR landed *before* the window.
- **After Phase C, install failed:** re-run nixos-anywhere, or restore node03 to
  the pre-op state by reinstalling from the previous config revision
  (`git revert` of Phase A) and reinstalling. Data on the old layout is gone
  regardless — recovery depends entirely on Longhorn replicas on other nodes plus
  backups.
- **Data recovery:** only from Longhorn replicas on node02/04/05, or from the
  backup target. This is why §5.1 and §5.2 are hard gates.

---

## 9. Follow-up work (separate from this operation)

These are fleet-wide issues surfaced by the investigation, not blockers for node03:

1. **Lower `storage-over-provisioning-percentage: 200 → 100–130`.** At 200%
   Longhorn advertises double the physical disk, which is what let node01 reach 95%
   while Longhorn believed there was room. This is the systemic enabler of the
   whole class of failure.
2. **Purge snapshot retention cluster-wide.** ~987 GB occupied vs ~23 GiB live
   data. `auto-cleanup-system-generated-snapshot: true` is already on, so the
   retention is user snapshots and recurring-job `retain` counts.
3. **Clean orphaned replicas** on node01/02/04.
4. **Give `k8s-reader` read access to `*.longhorn.io`.** This investigation was
   blocked by `Forbidden` on Longhorn CRDs, `pods/exec`, and `pods/portforward` —
   diagnosis had to be reconstructed from node_exporter filesystem metrics.
5. **Fix the stale `hosts/k8s-node04/README.md`** — it claims root is 50 GB and
   mentions a containerd partition; the actual disko config is 120 GB root with
   no containerd partition.
6. **Consider `disko.enableConfig` consistency** across node01/02/03/05 (only
   node04 sets it).

---

## 10. Open decisions

### 10.1 TPM2 on node03?

The disko config declares `tpm2-device=auto` but node03 never set
`security.tpm2.enable`. node04 is the only host that does.

- **Option A — match node04:** add `security.tpm2.enable = true`, enroll TPM2.
  Passphrase-free boot. Recommended if node03's hardware has a working TPM2.
- **Option B — match node01/02/05:** leave TPM2 off. Boot prompts for the LUKS
  passphrase. Requires physical/console access at every boot.

**Decision:** ☐ A ☐ B

### 10.2 Root size

120 GB matches every other node. Confirm §4.1 passes. If node03's non-Longhorn
footprint exceeds 80 GB, decide: clean it, or raise `size = "120G"` (which
shrinks the Longhorn partition correspondingly).

**Decision:** ☐ keep 120G ☐ raise to ______ GB

### 10.3 Rebalance node01 afterward?

After a snapshot purge, node01 may have ample room and rebalancing to node03 may
be unnecessary. Re-evaluate post-op rather than planning it now.

**Decision:** ☐ rebalance later ☐ not needed

---

## 11. Timeline estimate

| Phase | Duration |
|---|---|
| A — repo changes + PR review | 30 min (async, before window) |
| Pre-flight gates | 30–45 min |
| B — drain + replica rebuild | 45–90 min (throttled by `replica-replenishment-wait-interval: 600`) |
| C — repartition + reinstall | 30–60 min |
| D — post-install + TPM enroll + reboot | 30 min |
| E — rejoin + validation | 30 min |
| **Total maintenance window** | **~3–4 hours** |

The Longhorn rebuild in Phase B dominates and is the least predictable. Do not
schedule this window tight against another change.
