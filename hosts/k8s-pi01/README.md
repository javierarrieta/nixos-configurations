# k8s-pi01 SD Image Building

## Overview
This document explains how to build SD card images for k8s-pi01 (Raspberry Pi 4) using a GitOps minimal-intervention approach.

## Quick Start

Because native cross-compilation from macOS to `aarch64-linux` using `qemu-user` often fails with a vague `Undefined error: 0` during derivation evaluation, the most reliable method is to **offload the entire build to a Linux host**.

### Option 1: Build from macOS (Offloaded to llm01)
This is the recommended approach if you are on a Mac. We will SSH into a Linux builder (`llm01` at `192.168.0.29`), build the minimal image there, and copy the result back.

```bash
# 1. SSH into llm01, update the repo, and build the image
ssh -p 22 javier@192.168.0.29 "cd ~/code/nixos-configurations && git pull && nix build .#packages.x86_64-linux.sd-image-k8s-pi01-minimal"

# 2. Copy the resulting image back to your Mac
scp -P 22 javier@192.168.0.29:~/code/nixos-configurations/result/sd-image/*.img.zst ./
```

### Option 2: Build Natively on a Linux Host
If you are already logged into a Linux machine (x86_64 or aarch64), you can build the minimal configuration directly:

```bash
nix build .#packages.x86_64-linux.sd-image-k8s-pi01-minimal

# Result will be in result/sd-image/*.img.zst
```

## Why Minimal Image + Comin?

### The SOPS Cross-Compilation Issue
When building full configurations with SOPS secrets for another architecture, the build sandbox cannot access your local SOPS keys (`~/.config/sops/age/keys.txt`).

### The Comin GitOps Solution
Comin solves this by:
1. **Initial boot**: The minimal image provides just the bootloader, kernel, networking, SSH access, and `comin`.
2. **Key Injection**: You manually and securely copy your `keys.txt` over to the newly booted Pi.
3. **Automatic deployment**: `comin` polls the repository every 5 minutes (`poller.period = 300`), runs on the target Pi where SOPS can access secrets natively, and applies the full `configuration.nix` with all services enabled (k3s, promtail, etc.).

## File Structure

- **`configuration.nix`**: Full configuration with k3s, promtail, and all services
- **`minimal-image.nix`**: Minimal configuration for SD image building (no SOPS, no k3s, comin enabled)
- **`vars.nix`**: Shared variables (hostname, network settings)

## Flashing Instructions

### Using Raspberry Pi Imager (Recommended)
1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Select "Use custom image"
3. Choose the downloaded `*.img.zst` file.
4. Select your SD card
5. Click "Write"

### Using dd (macOS/Linux)
```bash
# Decompress
unzstd *.img.zst

# Unmount SD card (adjust /dev/diskX!)
sudo diskutil unmountDisk /dev/diskX  # macOS
# sudo umount /dev/sdX                # Linux

# Write to SD card
sudo dd if=nixos-image-*.img of=/dev/rdiskX bs=4m status=progress # macOS (use rdisk for speed)
# sudo dd if=nixos-image-*.img of=/dev/sdX bs=4M status=progress conv=fsync sync # Linux
```

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
**Cause**: Evaluating native `aarch64-linux` derivations on macOS using QEMU user-mode emulation often fails under the Nix sandbox.
**Fix**: Use Option 1 to offload the entire evaluation and build process to your Linux host (`llm01`).

### SSH Connection Refused
**Cause**: Pi still booting or SSH not ready
**Fix**: Wait 2-3 minutes after power on

### Wrong IP Address
**Default IP**: 192.168.0.21 (configured in `vars.nix`)
**Check**: `ip addr show dev eth0` on the Pi

## Reference

- [NixOS SD Image Documentation](https://nixos.org/manual/nixos/stable/#sec-image-nixos-rebuild-build-image)
- [AGENTS.md](../../AGENTS.md) - General NixOS configuration guidelines