{
  config,
  pkgs,
  ...
}:

{
  home.packages = with pkgs; [
    zed-editor
  ];

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    extensions = with pkgs.vscode-extensions; [
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
      github.copilot
      github.copilot-chat
      ms-kubernetes-tools.vscode-kubernetes-tools
      jnoortheen.nix-ide
      fill-labs.dependi
      ms-vscode-remote.remote-ssh
      scala-lang.scala
      scalameta.metals
    ];
  };
}
