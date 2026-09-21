{
  config,
  pkgs,
  lib,
  userOptions,
  hostname,
  ...
}:

let
  piHostnames = [
    "k8s-pi01"
    "k8s-pi02"
    "k8s-pi03"
  ];
  isPiNode = lib.elem hostname piHostnames;
  # k8s-* are infrastructure hosts, not dev machines: they keep the CLI
  # niceties and the k8s tooling, but not the language toolchains,
  # formatters and editor config that dev-tools brings. The prefix check
  # covers the Pis as well, so new k8s hosts are excluded automatically.
  isK8sHost = lib.hasPrefix "k8s-" hostname;
  configOnly = userOptions.configOnly or false;
  hmProfileDir = "${userOptions.userHome}/.local/state/nix/profiles";
in
{
  home.stateVersion = lib.mkDefault "25.11";

  imports = [
    ./host-common.nix
    ./shell.nix
    ./cli-tools.nix
  ]
  ++ lib.optionals (!isPiNode) [
    # Pin node: no heavy python/k8s tooling (avoids native aarch64 builds)
    ./python.nix
    ./k8s.nix
  ]
  ++ lib.optionals (!isK8sHost) [
    ./dev-tools.nix
  ];

  # Nix LSP is dev tooling, so it follows dev-tools rather than the whole fleet.
  home.packages = lib.mkIf (!isK8sHost && !configOnly) (with pkgs; [ nixd ]);

  programs.home-manager.enable = true;

  home.activation.cleanupOldGenerations = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    max_keep=2
    profile_dir="${hmProfileDir}"
    current_link="$profile_dir/home-manager"

    if [[ ! -L "$current_link" ]]; then
      echo "cleanup-old-generations: current link not found at $current_link"
      exit 0
    fi

    echo "cleanup-old-generations: Cleaning up old Home Manager generations in $profile_dir (keeping $max_keep)"

    # Count total generations
    total=$(find "$profile_dir" -maxdepth 1 -name 'home-manager-*-link' -type l | wc -l)
    if [[ "$total" -le "$max_keep" ]]; then
      echo "cleanup-old-generations: Only $total generation(s), nothing to clean up"
      exit 0
    fi

    # Remove old generations (all except current and the most recent N)
    # Sort by mtime (newest first), skip the current one, delete the rest
    find "$profile_dir" -maxdepth 1 -name 'home-manager-*-link' -type l \
      -not -newer "$current_link" \
      -not -samefile "$current_link" \
      -type l | sort -r | tail -n +$((max_keep + 1)) | while read -r link; do
        echo "cleanup-old-generations: Removing old generation: $(basename "$link")"
        rm -f "$link"
      done

    echo "cleanup-old-generations: Done"
  '';
}
