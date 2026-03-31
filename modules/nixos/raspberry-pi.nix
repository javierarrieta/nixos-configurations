{ config, lib, pkgs, ... }:
{
  options = {
    raspberryPi.enable = lib.mkEnableOption "Raspberry Pi 4 specific configuration";
  };

  config = lib.mkIf config.raspberryPi.enable {
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;
    boot.kernelPackages = pkgs.linuxPackages_rpi4;
    boot.kernelParams = [
      "8250.nr_uarts=1"
      "console=ttyAMA0,115200"
      "console=tty1"
    ];

    environment.systemPackages = with pkgs; [
      libraspberrypi
    ];
  };
}
