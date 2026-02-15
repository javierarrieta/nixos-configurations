{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:

{
  home.stateVersion = "25.11";

  imports = [
    ./host-common.nix
    ./dev-tools.nix
    ./shell.nix
    ./python.nix
    ./k8s.nix
    ./llm.nix
  ];

  home.packages = with pkgs; [ nixd ];

  programs.home-manager.enable = true;
}
