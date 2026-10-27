# Adds `rec` (see ./default.nix) to a package set, so home configs can say
# pkgs."rec" instead of importing a path. Applied to every home configuration in
# flake.nix; the definition is lazy and fails only for a host that actually
# evaluates it on a system upstream has no build for, so the Linux hosts are
# unaffected by it sitting in the overlay list.
final: prev: {
  # `rec` is a reserved word in Nix, so the attribute name has to be
  # quoted; callers write pkgs."rec" for the same reason.
  "rec" = final.callPackage ./default.nix { };
}
