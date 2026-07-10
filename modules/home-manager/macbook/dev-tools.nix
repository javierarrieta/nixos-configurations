{
  config,
  pkgs,
  unstablePkgs,
  pkgsUnfree,
  unstablePkgsUnfree,
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

    unstablePkgs.esphome
    unstablePkgs.platformio

    unstablePkgs.bruno
    unstablePkgs.bruno-cli
  ];
}
