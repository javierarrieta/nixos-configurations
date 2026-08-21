{
  imports = [
    ../../modules/home-manager/base.nix
  ];

  home.stateVersion = "25.11";

  home.sessionVariables = {
    NIX_CONFIG = "experimental-features = nix-command flakes";
  };
}
