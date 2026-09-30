# NixOS Attic binary cache client
#
# WHY THIS EXISTS. Self-hosted Attic (deployed from k8s-casa) replaces
# `pi.cachix.org` as the binary cache for this fleet. Two independent problems
# it fixes:
#
#   1. pi.cachix.org carried only x86_64-linux NARs, populated by a single
#      upstream `ubuntu-latest` cron. It is a race we do not control: when
#      flake.lock moves to a revision the cron has not built, every x86_64-linux
#      host recompiles the bun2nix build from source. That build also fetches npm
#      tarballs at build time, so a miss additionally requires npm egress -- a
#      network that 403s on npmjs makes home generation unbuildable entirely.
#   2. The three Pis are aarch64-linux and CI only builds x86_64-linux, so a
#      CI-only cache delivers them nothing. A --dry-run of k8s-pi01 reports 258
#      derivations to build against 1,277 fetched, and each Pi compiles that
#      identical set locally. Only an aarch64 pusher fixes that, and there is
#      none today. This module still helps those hosts: every x86_64-linux path
#      they can share is now served, and the module is the precondition for an
#      aarch64 pusher later.
#
# WHY ENABLED BY DEFAULT. Design D3 says every NixOS host substitutes from this
# cache, so on-by-default matches intent and hosts opt out individually rather
# than opting in individually. It is imported unconditionally from
# modules/nixos/base.nix, which 13 of the 14 hosts already pull in.
#
# WHY THE KEY IS DEFAULTED HERE RATHER THAN REQUIRED PER-HOST. This is a
# deliberate reversal of an earlier draft. The failure this guards against is a
# silent 100% cache miss: without `extra-trusted-public-keys`, nix skips every
# path in the cache, logs nothing, and looks exactly like a working cache with
# nothing substituted. Requiring the key on each host does not avoid that -- it
# multiplies it. A key rotation then means editing 13+ files, and the one host
# you forget keeps silently missing everything. Defaulting the key in this single
# file makes rotation one visible line in one diff.
#
# The assertion below still fires if a host explicitly sets the key to "", so
# the blanked case cannot pass quietly either.
#
# WHY `extra-*` AND NOT `substituters`. `substituters` REPLACES the list and
# would drop cache.nixos.org, which remains the real fallback. `extra-*`
# appends. Same reasoning as the pi-cache.nix module this replaces.
{ lib, config, ... }:

let
  cfg = config.atticCache;
in
{
  options = {
    atticCache = {
      enable = lib.mkEnableOption "the self-hosted Attic binary cache";

      url = lib.mkOption {
        type = lib.types.str;
        default = "https://nix-cache.l.arrieta.eu/nixos-config";
        description = ''
          Attic cache URL used for substitution.

          The path suffix is the CACHE NAME and is not optional. Attic serves
          every route -- `/nix-cache-info`, `/narinfo/:hash`, `/nar/:hash` --
          under a per-cache prefix. The bare origin answers `/` with the
          Attic landing page and returns a 404 JSON body for `/nix-cache-info`,
          which nix reports as `'<url>' does not appear to be a binary cache`
          and then substitutes nothing from it, silently. That is the same
          100%-miss failure the trustedPublicKey assertion below exists to
          catch, reached a second way; see the URL of the same shape in
          .github/workflows/verify.yml, which was always correct because CI
          also has to push to the same route.

          The LAN address on purpose: `.l.` resolves to the Traefik VIP on
          public DNS, so on-LAN pulls are a direct hop with no router
          hairpinning and no DDNS-freshness dependency. There is deliberately
          no both-names fallback list -- both names terminate at the same VIP
          and pod, so neither covers the other's outage, and a stale `.l.`
          entry on a non-LAN client makes nix burn a connect timeout on every
          path in the closure before falling through.
        '';
      };

      trustedPublicKey = lib.mkOption {
        type = lib.types.str;
        default = "nixos-config:YrRk3/J8iJGRauzYYESpv6dsn3hqs6jTrINjE5d0hUc=";
        example = "nixos-config:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        description = ''
          Attic per-cache signing key, from `attic cache info nixos-config`.

          This is a PUBLIC signing key -- publishing it is the whole point and
          it grants no write access.

          The prefix is the CACHE name, not the hostname. Narinfo is signed
          per-cache, so this one key serves nix-cache.l.arrieta.eu and
          nix-cache.home.arrieta.eu alike.

          Rotate here, in this one place. `attic cache configure nixos-config
          --regenerate-keypair` invalidates the old key for every path already
          pushed, so a stale value here does not fail loudly -- it quietly
          stops substituting.
        '';
      };
    };
  };

  config = lib.mkMerge [
    # Enabled by default -- see "WHY ENABLED BY DEFAULT" in the header.
    # A host opts out with `atticCache.enable = false;`.
    {
      atticCache.enable = lib.mkDefault true;
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          # Catches the bare-origin case only -- the one this file's default
          # shipped until 2026-09-30. Deliberately not a hardcoded
          # "/nixos-config": that would put the cache name in two files, which
          # is exactly the coupling trustedPublicKey below avoids. A URL with
          # no path is never a usable Attic substituter, whatever the cache is
          # called.
          assertion = builtins.match "^https?://[^/]+/.+" cfg.url != null;
          message = ''
            atticCache.url has no path component: ${cfg.url}

            Attic serves /nix-cache-info and /narinfo under a per-cache prefix,
            so a bare origin is not a binary cache. nix logs
            "does not appear to be a binary cache" once and then substitutes
            nothing from it, for every path in the closure, with no further
            error -- a 100% cache miss that looks exactly like a slow build.

            Expected shape, verified live on 2026-09-30:
              https://nix-cache.l.arrieta.eu/nixos-config/nix-cache-info -> 200
              https://nix-cache.l.arrieta.eu/nix-cache-info             -> 404
            The path segment is the cache name, from `attic cache list`.
          '';
        }
        {
          assertion = cfg.trustedPublicKey != "";
          message = ''
            atticCache.trustedPublicKey is empty. Without it nix will miss 100% of
            the Attic cache and fall through to building, with no error and
            nothing in the logs to distinguish that from a working cache.
            Read the live value with:  attic cache info nixos-config
            (the "Public Key:" line -- the prefix is the cache name, not the
            hostname).
          '';
        }
      ];

      nix.settings = {
        extra-substituters = [ cfg.url ];
        extra-trusted-public-keys = [ cfg.trustedPublicKey ];
      };
    })
  ];
}
