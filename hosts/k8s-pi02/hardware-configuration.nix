{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:
{

  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 2048;
    }
  ];

}
