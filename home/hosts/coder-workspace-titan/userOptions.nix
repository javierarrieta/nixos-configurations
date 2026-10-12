# The same workspace dotfiles as ../coder-workspace, for the workspaces Coder
# provisions on titan (k8s pods, ../k8s-titan coder/templates/dev) rather than in
# llm01's podman. Everything is shared except how pi reaches halogen.
#
# Why a second flake attribute instead of one config that figures it out at
# runtime: pi.baseUrl is baked into ~/.pi/agent/models.json by the activation
# script in modules/home-manager/dev-tools.nix, and that merge lets the *declared*
# value win over whatever is already in the file (`.[0] * .[1]`, declared is [1]).
# A hand-edit of models.json to point pi somewhere reachable is therefore silently
# reverted on the next `home-manager switch`. So the value has to be decided at
# eval time, and eval time only knows which flake attribute it is building.
let
  base = import ../coder-workspace/userOptions.nix;
in
base
// {
  # Merged per-key rather than with a plain `//` on the whole attrset: `//` would
  # replace `pi` wholesale and drop any future `pi.enable` the base grows, which is
  # exactly the kind of silent loss this file exists to prevent.
  pi = (base.pi or { }) // {
    # halogen runs on llm01 with `--network=host`, bound 0.0.0.0 on :8731, and is
    # reached from here over the WireGuard mesh: titan's only path into the home
    # LAN is the OPNsense peer advertising 192.168.0.0/24
    # (hosts/titan/configuration.nix). Checked from a `dev` workspace pod on
    # 2026-10-12: `curl http://192.168.0.29:8731/health` -> 200.
    #
    # This is the same address the non-workspace hosts get from the default in
    # dev-tools.nix, which is why it looks redundant. It is not: the default is
    # correct here by coincidence of value, and stating it keeps the reason --
    # the mesh route -- next to the thing that depends on it.
    #
    # The podman value is unusable in a k8s pod. `host.containers.internal` is
    # injected by podman's own DNS and is not a kubernetes thing at all; from this
    # pod it fails to resolve outright (socket.gaierror), which is what broke pi
    # here before this file existed.
    baseUrl = "http://192.168.0.29:8731/v1";
  };
}
