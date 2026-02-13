# NixOS Configuration Agent Guidelines

## Commands
- **Apply Config**: `nixos-rebuild switch --flake .#nixos`
- **Test Config**: `nixos-rebuild test --flake .#nixos` (builds & activates in VM/test environment)
- **Format**: `nixfmt .` (Ensure clean git state before running)
- **Secrets (Sops)**:
  - Edit: `sops secrets.yaml` (opens editor, encrypts on save)
  - Verify Encryption: `cat secrets.yaml` (must show `ENC[...]`)
  - Check Content: `sops -d secrets.yaml`
  - Rotate/Update Keys: `sops updatekeys secrets.yaml`

## Code Style & Conventions
- **Formatting**: Indent with 2 spaces. Align `=` in sets if readable.
- **Syntax**: Use `inherit (pkgs) ...` for brevity. Prefer `let ... in` for local variables.
- **Secrets**: NEVER commit plaintext secrets. Use `config.sops.secrets."path"`.
- **Imports**: Keep `configuration.nix` clean; modularize complex services into `modules/`.
- **Comments**: Explain *why*, not *what*. Document unusual hardware quirks in `hardware-configuration.nix`.

## Critical Safety Rules
1. **Always read** `secrets.yaml` (via `sops -d`) before adding keys to ensure no duplicates.
2. **Always verify** `secrets.yaml` is encrypted before committing (`grep "ENC" secrets.yaml`).
3. **Do not change** `system.stateVersion` unless performing a full release upgrade migration.
