{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:

{
  home.stateVersion = lib.mkDefault "25.11";

  imports = [
    ./host-common.nix
    ./dev-tools.nix
    ./shell.nix
    ./python.nix
    ./k8s.nix
  ];

  home.packages = with pkgs; [ nixd ];

  programs.home-manager.enable = true;
}
