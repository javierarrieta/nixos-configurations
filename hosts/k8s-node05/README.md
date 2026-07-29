# k8s-node05 - MacBook Pro 2015 14"

## Hardware
- CPU: Intel Core i5-5257U (Broadwell, dual-core)
- RAM: 8GB
- Storage: Internal SATA SSD
- Network: USB Ethernet adapter (interface: `enp0s20u1`)
- WiFi: Broadcom (brcmfmac)

## Setup Notes
- Single-boot NixOS on internal SSD
- LUKS encryption on root partition (password-based, no TPM)
- 512M EFI boot partition
- USB Ethernet for network (interface name may vary by adapter)

## Installation
1. Boot from NixOS USB installer (use Ethernet adapter for network)
2. disko will partition and encrypt the disk
3. Run `nixos-install`
4. After install, check network interface with `ip link` and update `configuration.nix` if needed

## Post-Install
- Check network interface name matches `enp0s20u1` in `vars.nix` and `configuration.nix`
- Add SOPS keys to `secrets.yaml`
- Run `sops updatekeys secrets.yaml -y`
