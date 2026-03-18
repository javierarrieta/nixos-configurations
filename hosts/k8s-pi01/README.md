# k8s-pi01 SD Image Building

## Overview
This document explains how to build SD card images for k8s-pi01 (Raspberry Pi 4) using a GitOps minimal-intervention approach.

## Quick Start

### Option 1: Build Minimal Image + Comin (Recommended, Works on Mac & Linux)
This is the recommended approach for cross-compiling, especially from macOS (aarch64-darwin → aarch64-linux), as it avoids `sops` cross-compilation errors.

```bash
# Build the minimal image (no SOPS dependencies)
# On macOS:
nix build .#packages.aarch64-darwin.sd-image-k8s-pi01-minimal

# On Linux:
nix build .#packages.x86_64-linux.sd-image-k8s-pi01-minimal

# Result: result/sd-image/*.img.zst
```

### Option 2: Build on Linux (Full Config)
If you have access to a Linux machine (x86_64 or aarch64) and your SOPS key is correctly injected into the environment, you can build the full configuration straight away:

```bash
# Set up SOPS environment
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Build SD image
nix build .#packages.x86_64-linux.sd-image-k8s-pi01

# Result: result/sd-image/*.img.zst
```

## Why Two Options?

### Cross-Compilation Issue
When building SD images on Mac for Linux (aarch64-darwin → aarch64-linux):
- Build sandbox cannot access SOPS secrets from `~/.config/sops/age/keys.txt`
- This causes evaluation to fail with "Undefined error: 0"

### Comin GitOps Solution
Comin solves this by:
1. **Initial boot**: Minimal image provides just the bootloader, kernel, networking, SSH access, and `comin`.
2. **Key Injection**: You manually securely copy your `keys.txt` over to the newly booted Pi.
3. **Automatic deployment**: `comin` polls the repository every 5 minutes (`poller.period = 300`), runs on the target Pi where SOPS can access secrets, and applies `configuration.nix` with all services enabled (k3s, promtail, etc.).

## File Structure

- **`configuration.nix`**: Full configuration with k3s, promtail, and all services
- **`minimal-image.nix`**: Minimal configuration for SD image building (no SOPS, no k3s, comin enabled)
- **`vars.nix`**: Shared variables (hostname, network settings)

## Flashing Instructions

### Using dd
```bash
# Decompress (if needed)
unzstd result/sd-image/*.img.zst

# Write to SD card (adjust device path!)
sudo dd if=result/sd-image/*.img of=/dev/sdX bs=4M status=progress conv=fsync sync

# Unmount SD card
# Linux:
sudo umount /dev/sdX
# macOS:
sudo diskutil unmountDisk /dev/sdX
```

### Using Raspberry Pi Imager
1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Select "Use custom image"
3. Choose `result/sd-image/*.img` or `result/sd-image/*.img.zst`
4. Select your SD card
5. Click "Write"

## First Boot Setup (GitOps Flow)

1. Insert SD card into Raspberry Pi 4
2. Connect Ethernet cable (recommended) or WiFi
3. Connect power
4. Wait 2-3 minutes for initial boot
5. SSH into the Pi: `ssh javier@192.168.0.21`

### Injecting SOPS Secrets

After first boot, you need to provide the AGE key so Comin can decrypt the secrets during its autonomous deployments:

```bash
# From your laptop, scp the age key to the Pi
scp ~/.config/sops/age/keys.txt javier@192.168.0.21:~/.config/sops/keys.txt

# SSH into the Pi and move the key to the expected location
ssh javier@192.168.0.21
sudo mkdir -p /var/lib/sops-nix
sudo cp ~/.config/sops/keys.txt /var/lib/sops-nix/key.txt
sudo chmod 600 /var/lib/sops-nix/key.txt
```

Once the key is in place, `comin` will automatically evaluate `.#nixosConfigurations.k8s-pi01`, decrypt all secrets, install `k3s`, and seamlessly deploy the full configuration.

## Troubleshooting

### Build Fails with "Undefined error: 0"
**Cause**: Cross-compiling on Mac with SOPS secrets
**Fix**: Use Option 1 (minimal image + Comin) or build natively on Linux

### SSH Connection Refused
**Cause**: Pi still booting or SSH not ready
**Fix**: Wait 2-3 minutes after power on

### Wrong IP Address
**Default IP**: 192.168.0.21 (configured in `vars.nix`)
**Check**: `ip addr show dev eth0` on the Pi

## Reference

- [NixOS SD Image Documentation](https://nixos.org/manual/nixos/stable/#sec-image-nixos-rebuild-build-image)
- [AGENTS.md](../../AGENTS.md) - General NixOS configuration guidelines