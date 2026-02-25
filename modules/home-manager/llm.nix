{
  config,
  pkgs,
  ...
}:

{
  home.packages = with pkgs; [
    htop
    btop
    git
    screen
    opencode
    nvtopPackages.amd
    sops
    age
  ];
}
