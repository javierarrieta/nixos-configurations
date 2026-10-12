# Imported rather than copied so the two workspace generations cannot drift on
# anything except userOptions, which the flake passes per host (flake.nix,
# mkHomeConfig). The relative import inside coder-workspace/home.nix still
# resolves, because Nix resolves paths against the file they are written in.
{
  imports = [ ../coder-workspace/home.nix ];
}
