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

## Lessons Learned & Troubleshooting

### SOPS & Secrets Management
- **Key Location**: If decryption fails, ensure `SOPS_AGE_KEY_FILE` is set.
  - Likely location: `~/.config/sops/age/keys.txt`
  - Command: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`
- **Workflow**:
  1. Decrypt: `sops -d secrets.yaml > secrets.dec.yaml`
  2. Edit: Modify `secrets.dec.yaml`
  3. Encrypt: `sops -e secrets.dec.yaml > secrets.yaml`
  4. **Cleanup**: **IMMEDIATELY** remove decrypted files (`secrets.dec.yaml`, etc.) after encryption. Leaving them is a critical security risk. Double-check with `ls` before finishing.
- **In-place Encryption**: `sops -e -i secrets.yaml` re-encrypts the file in place. Useful after overwriting `secrets.yaml` with plaintext content (ensure you verify encryption immediately after).

### SSH Keys
- **Trailing Newline**: SSH private keys (e.g., `id_ed25519`) **MUST** have a trailing newline. Without it, SSH clients will fail with `error in libcrypto` or `invalid format`.
  - **Check**: `cat -e keyfile` should show `-----END OPENSSH PRIVATE KEY-----$` at the very end.
  - **Fix**: Ensure the secret value ends with `\n` when adding via `jq` or manually.

### Tool Quirks
- **yq Version**: The environment uses an older version of `yq` (e.g., 3.4.3).
  - It may not support newer syntax like `-i` (in-place) or complex path expressions.
  - **Workaround**: Convert YAML to JSON, use `jq` for complex logic, then convert back to YAML.
    - `cat file.yaml | yq . > file.json`
    - `jq ... file.json > new.json`
    - `cat new.json | yq -y . > new.yaml`

### General
- **Temporary Files**: Generate keys and temporary data in `/tmp` when possible.
- **Cleanup**: Always clean up temporary files (`*.json`, `*.dec.yaml`, `*.bak`) before finishing the task.
