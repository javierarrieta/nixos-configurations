Switch to `bootstrap` branch for host bootstrapping

## Standalone Home Manager Hosts

These hosts are managed by the flake's `homeConfigurations` output and should be
activated with `home-manager switch`:

```bash
home-manager switch --flake .#oracle
home-manager switch --flake .#macbookair
home-manager switch --flake .#vps
```

Run the command from the repository root, or replace `.` with the full path to
this repository, for example:

```bash
home-manager switch --flake /Users/jaarriet/code/nixos-configurations#oracle
```

`wsl` is not exposed as a standalone Home Manager host. Activate it through the
NixOS-WSL configuration instead:

```bash
sudo nixos-rebuild switch --flake .#wsl
```

## Raspberry Pi Builds

Documentation for building and upgrading the Raspberry Pi hosts (SD images,
package slimming, and build pitfalls) lives in
[`hosts/k8s-pi01/README.md`](hosts/k8s-pi01/README.md).

## Comin & Network Operational Knowledge

Mechanisms for unsticking **Comin after a force-push to `main`** (unborn `master`,
build/apply loop, manual `nixos-rebuild switch` over the comin checkout), plus
**known network issues** hit during the 26.05 migration (default-route drop on fresh
worker switches, `network-runtime-config` not re-running on `switch`, nixpkgs 26.05
eval-time address parsing, and the open-iscsi 2.1.12 regression), are documented in
[`AGENTS.md`](AGENTS.md) under *GitOps with Comin*.
