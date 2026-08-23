{
  imports = [
    ../../../modules/home-manager/base.nix
  ];

  home.stateVersion = "25.11";

  # Workspaces may hold pre-HM dotfiles; back them up instead of failing.
  home-manager.backupFileExtension = "pre-hm";

  home.sessionVariables = {
    NIX_CONFIG = "experimental-features = nix-command flakes";
  };
}
