# rec -- Recursive's local inference CLI for the Flint model.
# Docs: https://docs.recursive.com/edge/rec
# Repo: https://github.com/recursive-oss/rec
#
# Upstream publishes one release asset per version: a single self-contained
# Mach-O for Apple Silicon (`rec-darwin-arm64`, ~264 MiB). It links only
# /usr/lib/libSystem, /usr/lib/libresolv and the CoreFoundation/Security
# frameworks, so nothing has to be patched or wrapped to make it run. There is
# no Linux and no Intel build, which is why this package is aarch64-darwin-only
# and why the macbookpro home config is its only consumer.
#
# This ships the CLI only. The ~30 GB Flint model and all server state are
# fetched on first `rec pull` / `rec serve` into `$XDG_DATA_HOME/rec` (default
# `~/.local/share/rec`), i.e. outside the store, so the store path never holds a
# model and the nix-sweep GC can never delete one.
#
# Upstream's own installer (install.sh in the repo) does the same thing by hand:
# download the asset, check it against the sibling `.meta` file, drop it under
# the data dir and symlink `~/.local/bin/rec`. Packaging it replaces that
# symlink with a store path; `rec` never writes next to its own binary, so both
# install methods coexist. Do not run `rec uninstall` on a packaged install --
# it removes its managed `~/.local/bin/rec` link and the whole data directory,
# model included, and knows nothing about the store copy.
#
# To bump the version:
#
#   curl -fsSL https://github.com/recursive-oss/rec/releases/latest/download/rec-darwin-arm64.meta
#   # prints "<sha256-hex> <size>"; upstream verifies both at install time
#   nix hash convert --hash-algo sha256 --to sri <sha256-hex>
#
# then update `version` and `hash` below. The `.meta` digest is the authoritative
# value; it matched the asset actually served for v0.1.1 when this was written.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "0.1.1";

  sources = {
    aarch64-darwin = {
      url = "https://github.com/recursive-oss/rec/releases/download/v${version}/rec-darwin-arm64";
      hash = "sha256-dodPr0uhaxkH6+8NapIUeh+BuV35LYBa5bmAGd8mW+0=";
    };
  };

  # Only evaluated when something actually asks for `rec`, which is what keeps
  # the overlay harmless on the Linux hosts. nixpkgs' own `meta.platforms` check
  # fires first with a clearer message; this is the backstop for a system listed
  # below that upstream stops shipping an asset for.
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "rec ${version}: no upstream build for ${stdenvNoCC.hostPlatform.system} (Apple Silicon macOS only)");
in
stdenvNoCC.mkDerivation {
  pname = "rec";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  # The asset is the executable itself, not an archive.
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # Leave the upstream bytes alone. The release binary is code-signed and
  # Apple Silicon SIGKILLs a Mach-O whose signature no longer matches its
  # contents, so skip the strip and the fixup hooks that would rewrite it.
  dontStrip = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/rec
    runHook postInstall
  '';

  passthru = {
    # The `.meta` asset upstream checks at install time, for update tooling.
    releaseAsset = "rec-darwin-arm64";
  };

  meta = {
    description = "Local inference engine for Recursive's Flint model";
    homepage = "https://docs.recursive.com/edge/rec";
    changelog = "https://github.com/recursive-oss/rec/releases/tag/v${version}";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "rec";
  };
}
