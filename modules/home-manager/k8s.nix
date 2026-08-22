{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:

let
  configOnly = userOptions.configOnly or false;
in
{
  home.packages = lib.mkIf (!configOnly) (
    with pkgs;
    [
      kubectl
      kubectx
      k9s
    ]
  );
}
