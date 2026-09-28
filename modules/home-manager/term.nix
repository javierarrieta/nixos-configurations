{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:

{
  home.packages =
    with pkgs.nerd-fonts;
    [
      fira-code
      zed-mono
      jetbrains-mono
    ]
    # Ghostty on macOS has to come from ghostty-bin. The source-built `pkgs.ghostty`
    # is `platforms = lib.platforms.linux` in nixpkgs (the Swift/AppKit half does
    # not build there), so naming it on a Mac fails at build time with "not
    # available on the requested hostPlatform". ghostty-bin unpacks the upstream
    # signed Ghostty.app from release.files.ghostty.org; it is MIT, so it passes
    # the `allowUnfreePredicate` whitelist in flake.nix (which admits only bun)
    # without widening it, and its outputsToInstall bring terminfo +
    # shell-integration along. Home Manager links the bundle into
    # ~/Applications/Home Manager Apps.
    #
    # If programs.ghostty is ever enabled here for config management, it defaults
    # its `package` to the Linux-only pkgs.ghostty -- set
    # programs.ghostty.package = pkgs.ghostty-bin on darwin.
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.ghostty-bin ];

  programs.kitty = {
    enable = true;
    shellIntegration.enableFishIntegration = true;
    font = {
      name = "JetBrainsMonoNerdFont";
      size = 10;
    };
    enableGitIntegration = true;
  };
}
