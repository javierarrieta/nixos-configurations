{
  config,
  pkgs,
  unstablePkgs,
  pkgsUnfree,
  unstablePkgsUnfree,
  codex-cli-nix,
  ...
}:

{
  home.packages = with pkgs; [
    nvtopPackages.apple
    # Disabled: mactop's Nix build currently fails its integration test because
    # the test tries to create /homeless-shelter, which is read-only in the sandbox.
    # mactop

    nodejs_24

    codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default

    unstablePkgs.esphome
    unstablePkgs.platformio

    unstablePkgs.bruno
    unstablePkgs.bruno-cli
  ];
}
