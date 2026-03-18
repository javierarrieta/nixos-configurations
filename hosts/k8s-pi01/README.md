# k8s-pi01 - Raspberry Pi 4 K8s Node

## Overview
This is a NixOS configuration for a Raspberry Pi 4 designed to run as a Kubernetes (k3s) agent node.

## System Specs
- **Hostname**: k8s-pi01
- **Architecture**: aarch64-linux (ARM64)
- **Platform**: Raspberry Pi 4
- **Storage**: SD Card
- **K3s Role**: Agent

## Building the SD Image

### From Linux (x86_64)
```bash
nix build .#packages.x86_64-linux.sd-image-k8s-pi01
```

### From macOS (M1/M2/M3)
```bash
nix build .#packages.aarch64-darwin.sd-image-k8s-pi01
```

The resulting image will be at `./result/sd-image/*.img.zst` (compressed) or `./result/sd-image/*.img` (uncompressed).

## Flashing the SD Card

### Using dd (Linux/macOS)
```bash
# Decompress if needed
unzstd result/sd-image/*.img.zst

# Flash to SD card (be careful with the device path!)
dd if=result/sd-image/*.img of=/dev/sdX bs=4M status=progress conv=fsync sync
```

### Using Raspberry Pi Imager
1. Download and install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Select "Use custom image" and choose the generated `.img` file
3. Select your SD card storage
4. Flash the image

## Network Configuration
- **Static IP**: 192.168.0.251/24
- **Gateway**: 192.168.0.1
- **DNS**: 1.1.1.1, 8.8.8.8
- **SSH**: Enabled on port 22

## First Boot Setup

1. Insert the SD card into the Raspberry Pi 4
2. Connect power and network (Ethernet recommended)
3. Wait for boot (~2-3 minutes)
4. SSH as: `ssh javier@192.168.0.251`

## Services Enabled
- **k3s**: Kubernetes agent node
- **SSH**: Remote access
- **Prometheus Node Exporter**: Metrics on port 9002
- **Promtail**: Log forwarding to 192.168.0.41:3100
- **open-iscsi**: For Longhorn storage
- **NFS**: Network file system support

## Hardware Configuration
- Bootloader: extlinux-compatible (no GRUB)
- Kernel: linux-rpi (Raspberry Pi optimized)
- Console: ttyAMA0 (serial console)

## K3s Configuration
```yaml
Role: agent
Server: https://192.168.0.200:6443
Labels:
  - storage=sd
  - arch=aarch64
  - cpu=rpi4
```

## Notes
- Initial boot may take 2-3 minutes as NixOS sets up the system
- SSH host keys are managed via sops for persistent fingerprints
- Home directory is configured for user `javier`
- Default shell is fish
