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
