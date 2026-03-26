{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:
{
  programs.fish = {
    shellAliases = {
      "nixos-apply" =
        "cd $HOME/code/nixos-configurations && git pull --ff-only && sudo nixos-rebuild switch --flake .#k8s-server01 ; cd -";
    };
  };
}
