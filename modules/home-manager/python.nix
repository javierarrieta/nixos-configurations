{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:
let
  pythonVersion = lib.replaceStrings [ "." ] [ "" ] userOptions.pythonVersion;
  python = pkgs."python${pythonVersion}";
  pythonPackages = pkgs."python${pythonVersion}Packages";
in
{
  home.packages = with pkgs; [
    python
    pipenv
    pythonPackages.virtualenv
    pythonPackages.uv
    pythonPackages.pylint
    pythonPackages.oci
    pythonPackages.huggingface-hub
  ];

  programs.pyenv = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
}
