{
  config,
  lib,
  pkgs,
  ...
}:

let
  vars = import ./vars.nix {
    inherit
      config
      pkgs
      lib
      ;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/raspberry-pi.nix
    ../../modules/nixos/minimal-image.nix
    ../../modules/nixos/static-network.nix
    ../../modules/nixos/comin.nix
  ];

  raspberryPi.enable = true;

  minimalImage.enable = true;

  staticNetwork.enable = true;
  staticNetwork.ipAddress = vars.ipAddress;
  staticNetwork.defaultGateway = vars.defaultGateway;
  staticNetwork.nameservers = vars.nameservers;

  cominGitOps.enable = true;

  networking.hostName = vars.hostname;
}
