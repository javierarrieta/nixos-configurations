{
  config,
  pkgs,
  lib,
  userOptions,
  hostname,
  ...
}:

let
  # Hosts that skip the python toolchain. The Pis are here because a slow ARM box
  # must not compile a Rust/Scala/Python stack on every deploy; titan is here because
  # a 150 G root filesystem shared with etcd and container images has no business
  # holding a Scala toolchain nobody will invoke on a headless server.
  minimalHostnames = [
    "k8s-pi01"
    "k8s-pi02"
    "k8s-pi03"
    "titan"
  ];
  isMinimalHost = lib.elem hostname minimalHostnames;
  # The k8s CLI is a SEPARATE decision from the python toolchain. The Pis skip it for
  # the same reason as python -- aarch64 build cost -- but titan must not: it is a k3s
  # server, and on x86_64 kubectl/kubectx/k9s are cached downloads, not compiles.
  # Folding titan into minimalHostnames had left it unable to k9s the cluster it runs.
  # Found 2026-10-03.
  armMinimalHostnames = [
    "k8s-pi01"
    "k8s-pi02"
    "k8s-pi03"
  ];
  skipK8sTools = lib.elem hostname armMinimalHostnames;
  # k8s-* are infrastructure hosts, not dev machines: they keep the CLI
  # niceties and the k8s tooling, but not the language toolchains,
  # formatters and editor config that dev-tools brings. The prefix check
  # covers the Pis as well, so new k8s hosts are excluded automatically.
  isK8sHost = lib.hasPrefix "k8s-" hostname;
  # titan is not a k8s-* hostname but has the same reason to skip dev-tools.
  skipDevTools = isK8sHost || isMinimalHost;
  configOnly = userOptions.configOnly or false;
  hmProfileDir = "${userOptions.userHome}/.local/state/nix/profiles";
in
{
  home.stateVersion = lib.mkDefault "25.11";

  # Deliberately left unconfigured: `i18n.glibcLocales`.
  #
  # Home Manager's modules/config/i18n.nix is enabled unconditionally on Linux
  # (`mkIf stdenv.hostPlatform.isLinux`) and exports
  # `LOCALE_ARCHIVE_2_27 = ${i18n.glibcLocales}/lib/locale/locale-archive`. With
  # nothing setting `i18n.*` here, that means the standalone-HM Linux hosts --
  # coder-workspace and vps -- each carry the full 842-locale archive, 222 MiB,
  # referenced by hm-session-vars.{sh,fish} and environment.d. llm01 pays
  # nothing: HM runs there as a NixOS module and modules/nixos/base.nix sets
  # `i18n.defaultLocale`, so NixOS already has the same glibcLocales in
  # environment.systemPackages. The darwin hosts skip the module (isLinux gate).
  #
  # Shrinking it is the option the HM docs suggest and it does work --
  # `pkgs.glibcLocales.override { allLocales = false; locales = [ "en_IE.UTF-8/UTF-8" ]; }`
  # is 5.4 MiB and en_IE.UTF-8 resolves correctly through it -- but the override
  # is not on cache.nixos.org and its drv compiles glibc in order to run
  # localedef: a 2.8 GiB build-input closure dominated by gcc-wrapper, which the
  # workspace image does not share (its /bin/gcc is a different store path). So
  # it costs 2.8 GiB of download plus a local build to save 217 MiB, and it puts
  # back the local-build path that PR #91 removed. Measured 2026-10-05.
  #
  # If disk ever matters, blank the variable instead of shrinking the package --
  # but note HM's archive is the only locale data the workspace image ships, so
  # LANG=en_IE.UTF-8 would silently degrade to C.
  imports = [
    ./host-common.nix
    ./shell.nix
    ./cli-tools.nix
  ]
  ++ lib.optionals (!isMinimalHost) [
    # No heavy python tooling on minimal hosts (avoids native aarch64 builds on the
    # Pis, and tools nobody runs on a headless box).
    ./python.nix
  ]
  ++ lib.optionals (!skipK8sTools) [
    ./k8s.nix
  ]
  ++ lib.optionals (!skipDevTools) [
    ./dev-tools.nix
  ];

  # Nix LSP is dev tooling, so it follows dev-tools rather than the whole fleet.
  home.packages = lib.mkIf (!skipDevTools && !configOnly) (with pkgs; [ nixd ]);

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
