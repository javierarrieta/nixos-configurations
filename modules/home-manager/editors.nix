{
  config,
  pkgs,
  unstablePkgsUnfree,
  userOptions,
  ...
}:

{
  home.packages = with pkgs; [
    zed-editor
  ];

  programs.vscode = {
    enable = true;
    package = unstablePkgsUnfree.vscode;
    profiles.default = {
      enableUpdateCheck = false;
      enableExtensionUpdateCheck = false;
      userSettings = {
        "yaml.schemas" = {
          "file://${userOptions.userHome}/.vscode/extensions/Continue.continue/config-yaml-schema.json" = [
            ".continue/**/*.yaml"
          ];
        };
      };
      extensions = with unstablePkgsUnfree.vscode-extensions; [
        dracula-theme.theme-dracula
        rust-lang.rust-analyzer
        tamasfe.even-better-toml
        ms-python.python
        ms-python.vscode-pylance
        ms-python.pylint
        ms-python.mypy-type-checker
        ms-python.debugpy
        coder.coder-remote
        continue.continue
        ms-vscode.makefile-tools
        ms-vscode.remote-explorer
        ms-vscode.hexeditor
        ms-vscode-remote.vscode-remote-extensionpack
        mechatroner.rainbow-csv
        redhat.vscode-yaml
        yzhang.markdown-all-in-one
        ms-kubernetes-tools.vscode-kubernetes-tools
        jnoortheen.nix-ide
        fill-labs.dependi
        ms-vscode-remote.remote-ssh
        scala-lang.scala
        scalameta.metals
        signageos.signageos-vscode-sops
        ocamllabs.ocaml-platform
        haskell.haskell
        justusadam.language-haskell
      ];
    };
  };
}
