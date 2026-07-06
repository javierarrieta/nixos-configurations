{
  config,
  pkgs,
  unstablePkgs,
  pkgsUnfree,
  unstablePkgsUnfree,
  lib,
  userOptions,
  hostname,
  ...
}:

{
  imports = [
    ../../../modules/home-manager/host-common.nix
    ../../../modules/home-manager/dev-tools.nix
    ../../../modules/home-manager/shell.nix
  ];

  home.stateVersion = "25.11";
  programs.home-manager.enable = true;
}
