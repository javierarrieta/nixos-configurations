# k8s-pi01 SD Image Building

## Overview
This document explains how to build SD card images for k8s-pi01 (Raspberry Pi 4).

## Quick Start

### Option 1: Build on Linux (Recommended for Full Config)
If you have access to a Linux machine (x86_64 or aarch64), build the full configuration:

```bash
# Set up SOPS environment
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Build SD image
nixos-rebuild build-image --flake .#k8s-pi01 --image-variant sd-card

# Result: result/sd-image/*.img.zst
```

### Option 2: Build Minimal Image + Comin (Works on Mac)
For cross-compiling from Mac (aarch64-darwin → aarch64-linux), use the minimal image approach:

```bash
# Build minimal image (no SOPS dependencies, builds anywhere)
nixos-rebuild build-image --flake .#k8s-pi01-minimal --image-variant sd-card

# Flash to SD card
unzstd result/sd-image/*.img.zst
dd if=result/sd-image/*.img of=/dev/sdX bs=4M status=progress conv=fsync sync

# Boot Pi, then let Comin deploy full configuration
# The full configuration will be pulled automatically with k3s, promtail, etc. enabled
```

## Why Two Options?

### Cross-Compilation Issue
When building SD images on Mac for Linux (aarch64-darwin → aarch64-linux):
- Build sandbox cannot access SOPS secrets from `~/.config/sops/age/keys.txt`
- This causes `nixos-rebuild build-image` to fail with "Undefined error: 0"
- The error occurs even if secrets are conditionally included with `lib.mkIf`

### Comin GitOps Solution
Comin solves this by:
1. **Initial boot**: Minimal image provides just bootloader, kernel, networking, and SSH access
2. **Automatic deployment**: Comin runs on the target Pi where SOPS can access secrets
3. **Full configuration**: Comin pulls and applies `configuration.nix` with all services enabled (k3s, promtail, etc.)

## File Structure

- **`configuration.nix`**: Full configuration with k3s, promtail, and all services
- **`minimal-image.nix`**: Minimal configuration for SD image building (no SOPS, no k3s)
- **`vars.nix`**: Shared variables (hostname, network settings)

## Flashing Instructions

### Using dd
```bash
# Decompress (if needed)
unzstd result/sd-image/*.img.zst

# Write to SD card (adjust device path!)
sudo dd if=result/sd-image/*.img of=/dev/sdX bs=4M status=progress conv=fsync sync

# Unmount SD card
sudo diskutil unmountDisk /dev/sdX
```

### Using Raspberry Pi Imager
1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Select "Use custom image"
3. Choose `result/sd-image/*.img` or `result/sd-image/*.img.zst`
4. Select your SD card
5. Click "Write"

## First Boot Setup

1. Insert SD card into Raspberry Pi 4
2. Connect Ethernet cable (recommended) or WiFi
3. Connect power
4. Wait 2-3 minutes for initial boot
5. SSH as: `ssh javier@192.168.0.21`

### Adding SOPS Secrets

After first boot, you need to set up SOPS:

```bash
# On the Pi, add your age key
age-keygen -o ~/.config/sops/age/keys.txt

# Or copy from your laptop
scp ~/.config/sops/age/keys.txt javier@192.168.0.21:~/.config/sops/

# Test SOPS
sops -d secrets.yaml  # Should decrypt without errors
```

Then the full configuration will be deployed automatically by Comin.

## Troubleshooting

### Build Fails with "Undefined error: 0"
**Cause**: Cross-compiling on Mac with SOPS secrets
**Fix**: Use Option 2 (minimal image + Comin) or build on Linux

### SSH Connection Refused
**Cause**: Pi still booting or SSH not ready
**Fix**: Wait 2-3 minutes after power on

### Wrong IP Address
**Default IP**: 192.168.0.21 (configured in `vars.nix`)
**Check**: `ip addr show dev eth0` on the Pi

## Reference

- [NixOS SD Image Documentation](https://nixos.org/manual/nixos/stable/#sec-image-nixos-rebuild-build-image)
- [AGENTS.md](../../AGENTS.md) - General NixOS configuration guidelines
