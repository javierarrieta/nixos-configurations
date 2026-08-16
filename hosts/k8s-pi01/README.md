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

## Performance & Package Slimming (2026-08)

The Raspberry Pis are `aarch64-linux` k3s worker nodes. A full `nixos-rebuild switch`
pulls a closure where the **only derivations that compile natively are heavy**:

- `linuxPackages_rpi4` (`linux-rpi-6.12.75-1+rpt1`) — the custom Raspberry Pi kernel,
  **~5 hours** of native ARM compile per Pi.
- `sops-install-secrets` and `comin` (local Go modules) — ~15 min each.
- Everything else (nodejs, python, rustup, scala-cli, k9s, helm, …) is a plain
  download from `cache.nixos.org`.

To keep the closure small and the install/download step fast, the Pis exclude the
common heavy tooling via two knobs:

```nix
# hosts/k8s-piXX/configuration.nix
systemPackages.excludePackages = [
  pkgs.kubernetes-helm
  pkgs.tpm2-tss      # Raspberry Pi 4 has no TPM
];
```

and in `modules/home-manager/base.nix`, Pi hostnames (`k8s-pi01..03`) get only the
`host-common` + `shell` home-manager modules — `dev-tools`, `python`, and `k8s`
(rustup, scala-cli, bun, nodejs, uv, k9s, …) are skipped via `lib.optionals`.
`nfs-utils` is intentionally kept (the cluster uses NFS mounts).

### Pitfalls (learned the hard way — read before touching the Pis)

1. **All three Pis compile the kernel independently and in parallel.** There is no
   built-in coordination: comin polls the same repo on every host and each Pi
   realizes the same store paths by compiling them itself. If you push a change,
   you pay the ~5h kernel build **everywhere at once**.
2. **To share a build you must do it manually** (no shared cache is configured):
   build/switch one Pi first, then `nix copy --from ssh-ng://user@<pi>.x --to ssh-ng://user@<pi>.y`
   the `.#nixosConfigurations.k8s-piXX.config.system.build.toplevel` closure to the
   others **before** they start building. Identical flake lock = identical store
   paths, so a copy dedupes perfectly.
3. **Killing a running build is non-trivial.** Stop comin first
   (`systemctl stop comin.service`), then kill the `nixos-rebuild` wrapper, then the
   reparented `nix` build process, then any lingering `make -j4` / `cc1` from the
   daemon sandbox. The kernel `make -j4` runs as a child of the *nix daemon* and
   survives killing just the client.
4. **A fresh worker switch drops the default route mid-activation** despite the
   `network-runtime` ordering fix. Keep a watchdog running during builds/switches:
   `sudo systemd-run --unit=routewatch --collect bash -c 'while true; do /run/current-system/sw/bin/ip route replace default via 192.168.0.1 dev eth0; sleep 10; done'`.
5. `nixos-rebuild` must be launched with `NIX_CONFIG="experimental-features = nix-command flakes"`
   (the `nixos-rebuild --extra-experimental-features` flag does not exist).
6. The `linux-rpi` series is deprecated upstream; the eval emits
   `linux-rpi series will be removed in a future release. Please change to use nixos-hardware.`

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