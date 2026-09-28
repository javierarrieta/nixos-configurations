# k8s-node04 Bootstrap Guide

## Prerequisites

- NixOS Live ISO (booted on the target machine)
- Network connectivity to your Git repository
- Your flake repository URL
- Access to your SOPS age key for secrets decryption

## Quick Bootstrap with Nix Anywhere

This is the fastest way to bootstrap your NixOS configuration:

```bash
# 1. Boot the NixOS Live ISO

# 2. Connect to network (if not already connected)
nmcli

# 3. Write the luks key to /tmp/disko-password in the target machine

# 4. Create a local file with your bootstrap age private key in a _deployment_ folder that we will use with `nix-anywhere`, using that folder as root of the overlay in the filesystem, ie `<deploy_dir>/var/lib/sops-nix`
mkdir -p <deploy_dir>/var/lib/sops-nix
cat > <deploy_dir>/var/lib/sops-nix/sops-key.txt << 'EOF'
AGE-PRIVATE-KEY-HERE
EOF

# 5. Run nix-anywhere with the bootstrap key
nix --extra-experimental-features "nix-command flakes" run github:nix-community/nixos-anywhere -- --flake .#k8s-node04 --target-host nixos@<ip_addr> --build-on-remote --extra-files <deployment_dir>

# 6. Clean up local key file
rm sops-key.txt
```

**Important**: The bootstrap age key is placed at `/var/lib/sops-nix/key.txt` during installation to resolve the circular dependency where sops-nix needs SSH host keys (which are secrets) to decrypt secrets. After first boot, the system uses its own SSH host key.

## Manual Bootstrap

If you prefer manual control:

**Critical**: SOPS has a circular dependency during installation - it needs SSH host keys (which are encrypted secrets) to decrypt secrets. You must create the age key file on the mounted filesystem before running nixos-install.

```bash
# 1. Copy the LUKS password to a file on the target machine
echo "YOUR_LUKS_PASSWORD" > /tmp/disko-password

# 2. Copy the bootstrap age private key to a file
echo "AGE-PRIVATE-KEY-HERE" > /tmp/age-key

# 3. Enable flakes
mkdir -p ~/.config/nix && \
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# 4. Clone your repository
git clone https://github.com/javierarrieta/nixos-configurations.git $HOME/nixos-configurations && \
cd $HOME/nixos-configurations

# 5. Mount your filesystem (if using disko, it will be at /mnt)
# If using disko: sudo disko --mode mount --flake .#k8s-node04

# 6. CRITICAL: Create age key file on the mounted filesystem
mkdir -p /mnt/var/lib/sops-nix
cp /tmp/age-key /mnt/var/lib/sops-nix/key.txt
chmod 600 /mnt/var/lib/sops-nix/key.txt

# 7. Install NixOS
sudo nixos-install --flake .#k8s-node04

# 8. Reboot and clean up temporary files
sudo reboot

# After first boot, you can remove the bootstrap key:
sudo rm /var/lib/sops-nix/key.txt
```

**Why this is necessary**: The configuration stores SSH host keys as SOPS secrets (`ssh_keys/k8s-node04_host_private` and `ssh_keys/k8s-node04_host_public`). During `nixos-install`, sops-nix needs to decrypt these secrets to place them at `/etc/ssh/ssh_host_ed25519_key`. However, sops-nix also needs either:
- The age key file at `/var/lib/sops-nix/key.txt`, OR
- SSH host keys to use for decryption (but these don't exist yet!)

By placing the bootstrap age key directly on the mounted filesystem before installation, we break this circular dependency. After first boot, the system uses its own SSH host key for decryption.

## Important Notes

- **Disk Setup**: disko partitions the whole M.2
  (`ata-M.2_SSD_512GB_GSID24C0400225`, 476.9 GiB) on every install, with two LUKS2
  containers:
  - `disk0-root` - `/`, 120G
  - `disk0-longhorn` - `/var/lib/longhorn`, 100% of the remainder (~348 GiB)
  plus a 512M `/boot` (vfat) and an 8G swap.

  There is **no** separate containerd partition any more: it was removed in `0e9c5ba`
  (2026-03-27), so `/var/lib/rancher` and all containerd state now live on `/`.

  ⚠️ **disko reformats everything it declares.** Re-running the bootstrap destroys the
  Longhorn replicas on this node — read [Replacing this node](#replacing-this-node-destructive)
  first. It also does **not** resize anything on an already-installed host; the partition
  change in `0e9c5ba` only took effect on nodes reinstalled afterwards.
- **Secrets**: SOPS secrets are encrypted. Make sure your age key is available when running sops-nix.

## After Installation

1. Reboot: `sudo reboot`
2. **Required** — enroll the LUKS keyslots in TPM2. `disko.nix` sets
   `crypttabExtraOpts = [ "tpm2-device=auto" ]` but nothing enrolls the keyslot; disko
   only creates the container from `passwordFile`. Skipping this leaves the box sitting at
   a passphrase prompt at boot with nobody at the console.

   Use the `disk-disk0-*` **partlabels**, not `/dev/sdaN` — disko's GPT partition
   numbering is not guaranteed to follow the declaration order in `disko.nix`.
   ```bash
   # For root partition (/)
   sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/disk-disk0-root

   # For Longhorn partition (/var/lib/longhorn)
   sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/disk-disk0-longhorn
   ```
3. Remove the bootstrap age key (if using manual bootstrap):
   ```bash
   sudo rm /var/lib/sops-nix/key.txt
   ```
4. The system will use persistent SSH host keys from secrets
5. WireGuard and other services will start automatically
6. k3s agent service will start and join the cluster (if token and network are configured correctly)

## Replacing this node (destructive)

A full reinstall runs `bootstrap_host.sh`, which passes `--phases kexec,disko,install`.
That **deletes and reformats every partition disko declares**, including the Longhorn disk.
As of 2026-09-28 the live node held **~188 GiB of Longhorn replica data** on
`/var/lib/longhorn` (343.42 GiB total, 155.02 GiB free). The new LUKS container also
gets a fresh disk UUID, so Longhorn sees a brand-new empty disk.

There is no way to get the 120G root without this: disko owns the whole disk.
(`--phases kexec,install` would skip disko and preserve Longhorn, but leaves root at its
current size.)

### Gate 1 — back up Longhorn first

Back up every volume to secondary storage and verify the backup exists. This is the only
real protection.

```bash
kubectl -n longhorn-system get volumes -o custom-columns=\
NAME:.metadata.name,ROBUST:.status.robustness,NUMREP:.spec.numberOfReplicas,\
SIZE:.status.size,NODE:.status.currentNode | sort -k2
```

### Gate 2 — no volume may depend solely on this node

Any row with `other_replicas=0`, or a volume reading `faulted`, is a **stop**.

```bash
NODE=k8s-node04
kubectl -n longhorn-system get engines.longhorn.io -o json | jq -r --arg n "$NODE" '
  .items[] | . as $e |
  ($e.status.replicaStatuses // {}) as $r |
  ([$r | to_entries[] | select(.value.hostname==$n)] | length) as $on |
  ([$r | to_entries[] | select(.value.hostname!=$n)] | length) as $off |
  select($on > 0) |
  "\($e.spec.volumeName)\treplicas_on_\($n)=\($on)\tother_replicas=\($off)\trobust=\($e.status.robustness // "?")"'
```

**Never pass `--force` to `kubectl drain` on a Longhorn node.** The Longhorn drain
controller deliberately blocks a drain that would strand the last healthy replica;
`--force` overrides exactly that safety net.

```bash
kubectl cordon k8s-node04
kubectl drain k8s-node04 --ignore-daemonsets --delete-emptydir-data --grace-period=120
# A drain that hangs on longhorn is the safety net working, not a bug.
```

### Gate 3 — capacity to rebuild into

Other nodes need headroom to absorb the rebuilds while this disk is empty.

```bash
kubectl -n longhorn-system get nodes.longhorn.io -o custom-columns=\
NAME:.metadata.name,SCHED:.spec.allowScheduling,\
SCHEDULED:.status.storageScheduledBytes,\
MAX:.status.storageMaximumBytes
```

### Live layout drift

Measured on 2026-09-28, the running partition table did **not** match `disko.nix`:

| Partition | Size | Role |
|---|---|---|
| sda1 | 512M | `/boot` |
| sda2 | 350G | `disk0-longhorn` (declared *after* root) |
| sda3 | 50G | `disk0-root` — the pre-`0e9c5ba` size |
| sda4 | 8G | swap |
| sda5 | 68.4G | orphaned old `containerd` partition, unmounted |

`cryptsetup status disk0-root` reported `size: 53670313984` bytes = 50 GiB minus the
16 MiB LUKS2 header — the container exactly filled the partition, so `cryptsetup resize`
+ `resize2fs` had nothing to grow into. A reinstall is what actually applies 120G.

## Troubleshooting

### Nix Anywhere fails with "flake not found"
- Verify your repository URL is correct
- Check that `k8s-node04` exists in the flake's `nixosConfigurations`
- Test evaluation locally: `nix eval .#nixosConfigurations.k8s-node04.config.system.build.toplevel`

### SOPS decryption errors during installation

**Error**: `cannot read keyfile '/var/lib/sops-nix/key.txt': no such file or directory` or `Cannot read ssh key '/etc/ssh/ssh_host_ed25519_key': no such file or directory`

**Solution**: This is a circular dependency - sops-nix needs SSH host keys (which are secrets) to decrypt secrets. You must create the age key file on the mounted filesystem:

```bash
# If using nix-anywhere:
nix-anywhere --extra-files sops-key.txt:/var/lib/sops-nix/key.txt ...

# If installing manually:
mkdir -p /mnt/var/lib/sops-nix
cp /tmp/age-key /mnt/var/lib/sops-nix/key.txt
chmod 600 /mnt/var/lib/sops-nix/key.txt
sudo nixos-install --flake .#k8s-node04
```

**Other SOPS issues**:
- Ensure your age key matches the one used to encrypt secrets (check `.sops.yaml`)
- The bootstrap age key is: `age1rlvgte0l7225vqdusvkzmdqmsyfd3u255rfy7ku93xx99k4vldsqhxnyxx`

### Disk partitioning issues
- Review `./hosts/k8s-node04/disko.nix` before running
- Use `sudo nixos-install --flake .#k8s-node04 --dry-run` to preview changes

### TPM2 auto-unlock not working

**Symptoms**: System prompts for LUKS password on boot despite TPM2 being configured.

**Solution**: You must enroll the LUKS key in TPM2 after installation:

```bash
# Check if TPM2 is available
systemd-cryptenroll --tpm2-device=list

# Enroll root partition
sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/disk-disk0-root

# Enroll Longhorn partition
sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/disk-disk0-longhorn

# Verify enrollment
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-disk0-root
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-disk0-longhorn
```

**Note**: TPM2 auto-unlock requires the same hardware and firmware configuration as when the key was enrolled. Changing hardware or firmware updates may require re-enrollment.
