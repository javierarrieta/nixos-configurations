{
  imports = [
    # Sets home.username / home.homeDirectory from userOptions. Required for the
    # standalone `home-manager switch --flake .#llm01` path: unlike the NixOS
    # home-manager module (which injects both for `home-manager.users.javier`),
    # a bare homeConfigurations entry has no idea who it is being built for.
    ../../../modules/home-manager/host-common.nix
    ../../../modules/home-manager/llm.nix
  ];

  home.stateVersion = "25.11";
}
