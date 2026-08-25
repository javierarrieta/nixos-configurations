{
  config,
  pkgs,
  unstablePkgsUnfree,
  userOptions,
  ...
}:

let
  # Must match VS Code's own serialization exactly ("off", not false) or
  # VS Code tries to rewrite settings.json on every window open/close,
  # which fails with EACCES since home-manager symlinks it read-only.
  userSettings = {
    "yaml.schemas" = {
      "file://${userOptions.userHome}/.vscode/extensions/Continue.continue/config-yaml-schema.json" = [
        ".continue/**/*.yaml"
      ];
    };
    "python.terminal.activateEnvironment" = false;
    "git.confirmSync" = false;
    "extensions.autoUpdate" = "off";
    "telemetry.telemetryLevel" = "off";
    "update.mode" = "none";
    "extensions.autoCheckUpdates" = false;
    "settingsSync.keybindingsPerPlatform" = true;
  };

  # The vscode module serializes userSettings with `jq`, which appends a
  # trailing newline. VS Code's writer omits it, so the stray \n makes VS
  # Code treat the read-only file as externally modified on every window and
  # prompt to save. Reuse the same jq generation but trim the final newline.
  userSettingsFile =
    pkgs.runCommand "vscode-user-settings"
      {
        value = userSettings;
        nativeBuildInputs = [ pkgs.jq ];
        __structuredAttrs = true;
        preferLocalBuild = true;
      }
      ''
        printf '%s' "$(jq .value "$NIX_ATTRS_JSON_FILE")" > $out
      '';
in
{
  programs.vscode = {
    enable = true;
    package = unstablePkgsUnfree.vscode;
    profiles.default = {
      enableUpdateCheck = false;
      enableExtensionUpdateCheck = false;
      userSettings = userSettingsFile;
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
