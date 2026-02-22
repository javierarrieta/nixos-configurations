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

### Host Management & Renaming
- **Host Renaming Process**: When renaming a host (e.g., `nixos` → `llm01`):
  1. Update `flake.nix`: Change `nixosConfigurations.oldname` to `nixosConfigurations.newname` and update `./hosts/oldname` to `./hosts/newname`
  2. Create new host directory: `mkdir -p hosts/newhost`
  3. Copy configuration files: `cp hosts/oldhost/*.nix hosts/newhost/`
  4. Update hostname in configuration: Add `networking.hostName = "newhost";`
  5. **Critical**: Create `default.nix` in the new host directory (NixOS requires this)
  6. Remove old host directory after verification: `rm -rf hosts/oldhost`
- **Host Directory Structure**: Each host directory MUST contain a `default.nix` file:
  ```nix
  { ... }:

  {
    imports = [
      ./configuration.nix
      ./hardware-configuration.nix
    ];
  }
  ```
  Without this, NixOS will fail with "opening file '/nix/store/.../hosts/hostname/default.nix': No such file or directory"

### SSH Host Key Management
- **Persistent Host Keys**: To maintain stable SSH fingerprints across reinstalls:
  1. Generate host key pair: `ssh-keygen -t ed25519 -f llm01_host_key -N "" -C "llm01"`
  2. Add keys to secrets.yaml:
     - `ssh_keys/llm01_host_private`: Private key content with trailing newline
     - `ssh_keys/llm01_host_public`: Public key
  3. Update host configuration:
     ```nix
     sops.secrets."ssh_keys/llm01_host_private" = {
       mode = "0600";
       owner = "root";
       path = "/etc/ssh/ssh_host_ed25519_key";
     };
     sops.secrets."ssh_keys/llm01_host_public" = {
       mode = "0644";
       owner = "root";
       path = "/etc/ssh/ssh_host_ed25519_key.pub";
     };
     ```
  4. Configure OpenSSH service:
     ```nix
     services.openssh = {
       enable = true;
       hostKeys = [
         {
           path = "/etc/ssh/ssh_host_ed25519_key";
           type = "ed25519";
         }
       ];
     };
     ```

### General
- **Temporary Files**: Generate keys and temporary data in `/tmp` when possible.
- **Cleanup**: Always clean up temporary files (`*.json`, `*.dec.yaml`, `*.bak`, `*_host_key*`) before finishing the task.

### GitOps with Comin
- **What is Comin**: Comin is a GitOps tool for NixOS that runs in pull mode, periodically polling Git repositories and deploying configurations associated with the machine hostname.
- **Repository URL**: `github:nlewo/comin`
- **Flake Input Setup**:
  ```nix
  comin = {
    url = "github:nlewo/comin";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  ```
- **Module Import**: Add `comin.nixosModules.comin` to the modules list in `flake.nix`
- **Configuration** (in host `configuration.nix`):
  ```nix
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "git@github.com:your/infra.git";
        branches.main.name = "main";
        poller.period = 900;  # 15 minutes in seconds
      }
    ];
  };
  ```
- **Important Options**:
  - `services.comin.enable`: Enable the comin service
  - `services.comin.remotes`: List of Git repositories to poll
  - `services.comin.remotes.*.url`: Git repository URL
  - `services.comin.remotes.*.branches.main.name`: Branch to deploy
  - `services.comin.remotes.*.poller.period`: Polling interval in seconds (default: 60)
  - `services.comin.hostname`: Machine name (defaults to `networking.hostName`)
- **Note**: Do not use `settings` block - use direct options like `poller.period` instead
