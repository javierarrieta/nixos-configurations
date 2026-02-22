{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.fish = {
    shellAliases = {
      "nixos-apply" =
        "cd $HOME/code/nixos-configurations && git pull --ff-only && sudo nixos-rebuild switch --flake .#ryzen7 ; cd -";
    };
  };
}
