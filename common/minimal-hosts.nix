# Hosts that get no language toolchains from home-manager.
#
# Single source of truth, read from two places:
#   * modules/home-manager/base.nix  -- drops python.nix and dev-tools.nix
#   * modules/home-manager/shell.nix -- skips the fish default-venv bootstrap,
#     which shells out to `python3 -m venv` and would otherwise print two
#     errors on every login on a host with no python.
#
# Keep it a list: adding a host here must not require touching shell.nix too.
#
# The Pis are here because a slow ARM box must not compile a Rust/Scala/Python
# stack on every deploy. Titan is here because a 150 G root filesystem shared
# with etcd and container images has no business holding a Scala toolchain
# nobody will invoke on a headless server -- it gets python3 from
# environment.systemPackages instead (see hosts/titan/configuration.nix), which
# is a cached download rather than a toolchain.
[
  "k8s-pi01"
  "k8s-pi02"
  "k8s-pi03"
  "titan"
]
