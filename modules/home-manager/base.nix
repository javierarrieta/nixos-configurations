{
  config,
  pkgs,
  lib,
  userOptions,
  hostname,
  ...
}:

let
  piHostnames = [
    "k8s-pi01"
    "k8s-pi02"
    "k8s-pi03"
  ];
  isPiNode = lib.elem hostname piHostnames;
in
{
  home.stateVersion = lib.mkDefault "25.11";

  imports = [
    ./host-common.nix
    ./shell.nix
  ]
  ++ lib.optionals (!isPiNode) [
    ./dev-tools.nix
    ./python.nix
    ./k8s.nix
  ];

  # Pin node: no heavy dev/python/k8s tooling (avoids native aarch64 builds)
  home.packages = lib.mkIf (!isPiNode && !(userOptions.configOnly or false)) (with pkgs; [ nixd ]);

  programs.home-manager.enable = true;
}
