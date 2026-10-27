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
# PARTLY VERIFIED ON A MAC -- the rest costs 30 GB. The asset is not only a CLI:
# it embeds `assets/runtime.tar.gz` (a Python 3.12 tree carrying numpy, tvm_ffi
# and xgrammar dylibs) and unpacks it on first run -- the binary contains
# `extract.lock`, `rec-tmp-`, `.install-*` and the error "unexpected runtime
# archive entry". Measured on macbookpro 2026-10-27: `nix build .#rec &&
# ./result/bin/rec doctor` runs from the read-only store, reports
# `Data /Users/javier/.local/share/rec`, and passes the hardware gate, so the
# binary does not need to write next to itself in order to start. What that does
# not prove is the runtime unpack, which only `rec pull` / `rec serve` triggers.
# If that ever fails against a read-only path, the fix is a makeWrapper pointing
# the runtime root at a writable directory under ~/.local/share/rec.
#
# Upstream's own installer (install.sh in the repo) does the same download by
# hand: fetch the asset, check it against the sibling `.meta`, store it under
# the data dir as `releases/<version>/rec` with a `.managed` marker, and symlink
# `~/.local/bin/rec`. A store path is not that layout, so the two commands that
# assume it are off-limits here:
#
# - `rec uninstall` deletes the data directory (model included) and its managed
#   `~/.local/bin/rec` link, and knows nothing about the store copy.
# - `rec update` looks for a managed instance (the binary carries "no managed
#   rec instance is reachable"), so bump the version in this file instead.
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

  # Single source of truth for both the download and meta.platforms below, so
  # adding a Linux asset later cannot leave the two out of step. No fallback
  # here: nixpkgs refuses an unsupported platform before `src` is ever forced,
  # which is what keeps this overlay harmless on the Linux hosts.
  source = sources.${stdenvNoCC.hostPlatform.system};
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
