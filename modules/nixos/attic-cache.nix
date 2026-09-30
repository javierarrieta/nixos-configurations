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
        default = "https://nix-cache.l.arrieta.eu";
        description = ''
          Attic front door used for substitution.

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
