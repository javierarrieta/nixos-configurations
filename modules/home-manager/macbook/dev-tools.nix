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
    mactop

    nodejs_24

    haskell.compiler.ghc98
    haskell-language-server
    haskellPackages.cabal-install

    ocaml
    dune_3

    codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default

    unstablePkgs.esphome
    unstablePkgs.platformio

    unstablePkgs.bruno
    unstablePkgs.bruno-cli
  ];
}
