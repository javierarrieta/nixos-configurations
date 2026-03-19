# LLM01 Bootstrap Guide

## Prerequisites

- NixOS Live ISO (booted on the target machine)
- Network connectivity to your Git repository
- Your flake repository URL
- Access to your SOPS age key for secrets decryption

## Quick Bootstrap with Nix Anywhere

This is the fastest way to bootstrap your NixOS configuration:

```bash
# 1. Boot the NixOS Live ISO

# 2. Connect to network (if not already connected)
nmcli

# 3. Write the luks key to /tmp/disko-password in the target machine

# 4. Run nix-anywhere
SOPS_AGE_KEY=~<path_to_age_key> nix run github:nix-community/nixos-anywhere -- --flake <path_to_flake>.#llm01 --target-host nixos@<ip_addr> --build-on-remote
```

## Manual Bootstrap

If you prefer manual control:

```bash
# 1. Install Nix (single-user mode, flakes enabled)
sh <(curl -L https://nixos.org/nix/install) --no-daemon

# Add to ~/.config/nix/nix.conf (create if doesn't exist)
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# 2. Clone your repository
git clone https://github.com/javierarrieta/nixos-configurations.git /root/nixos-configurations
cd /root/nixos-configurations

# 3. Install NixOS
sudo nixos-install --flake .#llm01

# Or test first without installing:
sudo nixos-rebuild switch --flake .#llm01
```

## Important Notes

- **Disk Setup**: This configuration uses disko for automated disk partitioning. Ensure your disk is unmounted before installation.
- **Secrets**: SOPS secrets are encrypted. Make sure your age key is available when running sops-nix.
- **Hardware**: The configuration includes AMD GPU optimizations and ROCm support.

## After Installation

1. Reboot: `sudo reboot`
2. The system will use persistent SSH host keys from secrets
3. WireGuard and other services will start automatically
4. Open WebUI will be available on port 8080
5. ComfyUI will be available on port 8188
6. llama-cpp server will be available on port 8001

## Troubleshooting

### Nix Anywhere fails with "flake not found"
- Verify your repository URL is correct
- Check that `llm01` exists in the flake's `nixosConfigurations`
- Test evaluation locally: `nix eval .#nixosConfigurations.llm01.config.system.build.toplevel`

### SOPS decryption errors
- Ensure `SOPS_AGE_KEY_FILE` is set in your environment
- Check that the age public key matches the one used to encrypt secrets

### Disk partitioning issues
- Review `./hosts/llm01/disko.nix` before running
- Use `sudo nixos-install --flake .#llm01 --dry-run` to preview changes
