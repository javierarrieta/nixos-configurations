{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:
let
  configOnly = userOptions.configOnly or false;
  pythonVersion = lib.replaceStrings [ "." ] [ "" ] userOptions.pythonVersion;
  python = pkgs."python${pythonVersion}";
  pythonPackages = pkgs."python${pythonVersion}Packages";
in
{
  home.packages = lib.mkIf (!configOnly) (
    with pkgs;
    [
      python
      pipenv
      pythonPackages.virtualenv
      pythonPackages.uv
      pythonPackages.pylint
      pythonPackages.oci
      pythonPackages.huggingface-hub
    ]
  );

  programs.pyenv = lib.mkIf (!configOnly) {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
}
