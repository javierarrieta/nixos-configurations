# NixOS Configuration Agent Guidelines

## Project Structure

```
/Users/javier/code/nixos-configurations/
├── flake.nix                    # Flake inputs and outputs
├── configuration.nix            # Main system configuration
├── hardware-configuration.nix   # Hardware-specific settings (auto-generated)
├── secrets.yaml                 # Encrypted secrets (sops)
├── .sops.yaml                   # Sops encryption rules
├── .sops.yaml                   # Sops encryption configuration
└── secrets.yaml                 # Encrypted secrets file
```

## Key Files

- **flake.nix**: Defines flake inputs (nixpkgs, sops-nix) and system configurations
- **configuration.nix**: Main system settings, users, services, sops config
- **secrets.yaml**: Encrypted secrets managed by sops
- **.sops.yaml**: Encryption rules and age recipient keys

## Important Commands

### System Rebuild
```bash
nixos-rebuild switch --flake .#nixos
```

### Testing Changes
```bash
nixos-rebuild test --flake .#nixos
```

### Sops/Secrets Management
```bash
# Edit secrets (opens editor, auto-encrypts on save)
sops secrets.yaml

# Encrypt a file (use --in-place to modify)
sops --encrypt --in-place secrets.yaml

# Decrypt to stdout (read-only)
sops -d secrets.yaml

# Update encryption keys after adding new recipients
sops updatekeys secrets.yaml

# Verify encryption worked by reading the file
cat secrets.yaml  # Should see ENC[...] and sops metadata
```

### Age Keys
```bash
# Generate new age key
age-keygen -o ~/.config/sops/age/keys.txt

# Display public key (to add to .sops.yaml)
age-keygen -y ~/.config/sops/age/keys.txt
```

## Critical Workflows

### Adding New Secrets

1. Edit secrets file: `sops secrets.yaml`
2. Add your secret in YAML format
3. Save (sops auto-encrypts)
4. Verify: `cat secrets.yaml` - should show `ENC[...]`
5. Update configuration.nix to reference the secret:
   ```nix
   sops.secrets."path/to/secret" = { };
   ```

### Adding New Machine/Recipient

1. Generate age key on new machine
2. Copy public key to .sops.yaml
3. Run: `sops updatekeys secrets.yaml`
4. Verify: `sops -d secrets.yaml` works on both machines

### Making Configuration Changes

1. Read relevant files first to understand context
2. Make changes to configuration files
3. Test: `nixos-rebuild test --flake .#nixos`
4. Apply: `nixos-rebuild switch --flake .#nixos`

## Verification Checklist

After encrypting secrets:
- [ ] `cat secrets.yaml` shows `ENC[...]` format
- [ ] File contains `sops:` metadata section
- [ ] Can decrypt with `sops -d secrets.yaml`
- [ ] Age keys are present in .sops.yaml

Before committing:
- [ ] secrets.yaml is encrypted (no plaintext secrets)
- [ ] .sops.yaml only contains public keys
- [ ] Configuration references secrets correctly with `config.sops.secrets`

## Common Mistakes to Avoid

1. **Not verifying encryption**: Always `cat secrets.yaml` after encrypting to confirm it worked
2. **Forgetting --in-place**: Use `sops --encrypt --in-place` to modify files, otherwise output goes to stdout
3. **Hardcoding secrets in config**: Always use sops secrets, never commit plaintext secrets
4. **Not reading files first**: Always read files before editing to get current state
5. **Missing age keys**: Ensure target machine's age key is in .sops.yaml before encrypting

## Accessing Secrets in Configuration

```nix
# Sops configuration - use dynamic home directory
sops = {
  defaultSopsFile = ./secrets.yaml;
  age.keyFile = "${config.users.users.javier.home}/.config/sops/age/keys.txt";
  age.sshKeyPaths = [ "${config.users.users.javier.home}/.config/sops/age/keys.txt" ];
  secrets."ssh_keys/javier_authorized" = { };
};

# Use in configuration
users.users.javier.openssh.authorizedKeys.keys = [
  (builtins.readFile config.sops.secrets."ssh_keys/javier_authorized".path)
];

# Or for service configs
services.your-service = {
  apiKey = config.sops.placeholder."api_keys/service";
};
```

## GitOps Notes

- **Safe to commit**: .sops.yaml, secrets.yaml (encrypted), configuration.nix, flake.nix
- **Never commit**: Plaintext secrets, private age keys
- **Target machine setup**: Must have age key at configured path for auto-decryption
- **Key path**: Uses `${config.users.users.javier.home}/.config/sops/age/keys.txt` (dynamic, no username hardcoded)
