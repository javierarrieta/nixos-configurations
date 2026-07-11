{
  config,
  pkgs,
  unstablePkgsUnfree,
  userOptions,
  ...
}:

{
  home.packages = with pkgs; [
    unstablePkgsUnfree.jetbrains.idea
    zed-editor
  ];

  programs.vscode = {
    enable = true;
    package = unstablePkgsUnfree.vscode;
    profiles.default = {
      enableUpdateCheck = false;
      enableExtensionUpdateCheck = false;
      userSettings = {
        "extensions.autoCheckUpdates" = false;
        "extensions.autoUpdate" = false;
        "update.mode" = "none";
        "git.confirmPush" = false;
        "git.confirmPull" = false;
        "git.confirmSync" = false;
        "files.watcherExclude" = {
          "**/.git/objects/**" = true;
          "**/.git/subtree-cache/**" = true;
          "**/node_modules/*/**" = true;
          "**/.nix-store/**" = true;
          "${userOptions.userHome}/.nix-profile/**" = true;
          "/nix/store/**" = true;
        };
        "files.exclude" = {
          "**/.nix-store" = true;
          "**/result" = true;
          "**/result-*" = true;
        };
        "files.autoSave" = "afterDelay";
        "files.autoSaveDelay" = 1000;
        "editor.formatOnSave" = false;
        "nix.buildOnSave" = false;
        "nix.serverPath" = "nixd";
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
