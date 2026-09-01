# Pins Bun to exactly version 1.4.0, built from the per-platform binaries
# shipped in the official bun-v1.4.0 GitHub release. This replaces whatever
# nixpkgs provides on `bun` so home-manager configs get a deterministic,
# up-to-date version instead of drifting with the channel.
#
# Hashes are base32 sha256 values cross-checked against that release's
# SHASUMS256.txt before use.

{ ... }:

let
  bunVersion = "1.4.0";

  # Asset name per target system (names as published in the release).
  bunReleaseAssets = {
    "x86_64-linux" = "bun-linux-x64.zip";
    "aarch64-linux" = "bun-linux-aarch64.zip";
    "x86_64-darwin" = "bun-darwin-x64.zip";
    "aarch64-darwin" = "bun-darwin-aarch64.zip";
  };

  # base32 sha256 of each asset, verified against SHASUMS256.txt.
  bunReleaseHashes = {
    "x86_64-linux" = "0lp45zljagwcv1l2jv7mi3a1j6hsrsr838m0mikvbj1sp1gzn0rd";
    "aarch64-linux" = "03pdivjkbvf8lfpbv263n8qkwkprzxqggrng7fwkx631x0p366jb";
    "x86_64-darwin" = "1c6r3lscv53r8zxgg9a590anzs1fwwasv1s66j1136fwy6w120hx";
    "aarch64-darwin" = "10g3bmrll4spfm63kn6b10lljxzsinwqsx010xpckqb4c5zyjsf6";
  };

  # Each host builds natively for its own system (home-manager switch runs on
  # the host), so the host's own stdenv is always the right toolchain: linux
  # stdenv for the linux hosts, darwin stdenv on the Macs. The bun asset is
  # selected by prev.system below.

in
{
  overlays.default =
    final: prev:
    let
      stdenv = final.stdenv;
      asset =
        bunReleaseAssets.${prev.system} or (throw "bun ${bunVersion}: unsupported system ${prev.system}");
      # Directory the zip unpacks to; holds the single bun binary.
      assetName = builtins.replaceStrings [ ".zip" ] [ "" ] asset;
    in
    {
      bun = stdenv.mkDerivation {
        pname = "bun";
        version = bunVersion;

        # fetchurl hashes the release zip itself (byte-stable, matches bun's
        # official SHASUMS256.txt). fetchzip instead hashes the unpacked tree,
        # a fixed-output value that varies by environment and is unreliable.
        src = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v${bunVersion}/${asset}";
          sha256 = bunReleaseHashes.${prev.system};
        };

        nativeBuildInputs = [ final.unzip ];

        dontConfigure = true;
        dontBuild = true;

        # Each zip holds one binary at <assetName>/bun; extract it into $out/bin.
        installPhase = ''
          mkdir -p $out/bin
          unzip -j $src "${assetName}/bun" -d $out/bin
          chmod +x $out/bin/bun
        '';

        passthru = {
          version = bunVersion;
        };

        meta = with final.lib; {
          description = "The all-in-one JavaScript runtime & toolkit";
          homepage = "https://bun.sh";
          license = licenses.unfree;
          platforms = builtins.attrNames bunReleaseAssets;
          mainProgram = "bun";
        };
      };
    };
}
