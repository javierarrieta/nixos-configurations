# llm01 - Replatforming Guide

## Disk Layout (After Resize)

| Partition | Size | Purpose |
|-----------|------|---------|
| nvme0n1p1 | 1G   | /boot (EFI) |
| nvme0n1p2 | 100G | / (root, encrypted) |
| nvme0n1p3 | 8G   | swap |
| nvme0n1p4 | ~356G | /opt/llm (encrypted, models) |

## Replatforming with Disks

### Prerequisites
- Boot from NixOS Live USB
- Connect to network (if using flakes)
- Have your secrets.yaml accessible

### Commands

```bash
# Boot into NixOS installer

# Install to disk with new partition layout
nix-shell -p disko --run "disko --system ./hosts/llm01/disko.nix"

# OR run disko from within nixos-configurations flake
nix run .#disko -- --system ./hosts/llm01/disko.nix
```

### Post-Install Steps

1. **Restore data:**
   ```bash
   # Copy models back (if backed up)
   cp -r /path/to/backup/models /opt/llm/
   chown -R ollama:ollama /opt/llm/models
   ```

2. **Rebuild configuration:**
   ```bash
   nixos-rebuild switch --flake .#llm01
   ```

3. **Verify services:**
   ```bash
   systemctl status llama-cpp-server
   systemctl status open-webui
   systemctl status comfyui
   ```

## Backup Before Reinstall

```bash
# Backup models
tar -czf /tmp/llm-models-backup.tar.gz /opt/llm/models

# Or rsync to external drive
rsync -avz /opt/llm/models /mnt/backup/
```

## Troubleshooting

### TPM2 Unlock Issues
If the encrypted partitions fail to unlock:
```bash
# Check TPM status
systemd-cryptenroll --status /dev/mapper/disk0-root
systemd-cryptenroll --status /dev/mapper/disk0-llm

# Fallback: use password during boot
# Password: defined in secrets.yaml
```

### Missing Secrets
Ensure `SOPS_AGE_KEY_FILE` is set if decrypting manually:
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

### Network Issues
If Comin fails to pull:
```bash
# Check git remote
git -C /etc/nixos remote -v

# Force pull
systemctl restart comin@llm01
```
