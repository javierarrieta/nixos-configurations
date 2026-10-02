# Hand-written, not generated: titan is provisioned by nixos-anywhere before any
# NixOS exists to run nixos-generate-config. Keep this file to facts the flake
# cannot infer — the NVMe driver the initrd needs to see the boot disk, and the
# deliberate absence of swap (125 GiB RAM, and k3s prefers swap off).
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_hcd"
    "usbhid"
    "usb_storage"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # No swap: the §7a logical-volume list has no swap LV, and 125 GiB of RAM makes
  # one speculative for a services box. Adding it later is `lvcreate -L 8G -n
  # swap` out of the vg0 headroom plus a swapDevices entry — which is part of why
  # the VG keeps slack. Deviates from spec §6's "keep the same shape as the fleet";
  # §7a's decided layout wins.
  swapDevices = [ ];
}
