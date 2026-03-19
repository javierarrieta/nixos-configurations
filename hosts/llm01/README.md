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

# 4. Create a local file with your bootstrap age private key
cat > sops-key.txt << 'EOF'
AGE-PRIVATE-KEY-HERE
EOF

# 5. Run nix-anywhere with the bootstrap key
nix --extra-experimental-features "nix-command flakes" run github:nix-community/nixos-anywhere -- --flake .#llm01 --target-host nixos@<ip_addr> --build-on-remote --extra-files sops-key.txt:/var/lib/sops-nix/key.txt

# 6. Clean up local key file
rm sops-key.txt
```

**Important**: The bootstrap age key is placed at `/var/lib/sops-nix/key.txt` during installation to resolve the circular dependency where sops-nix needs SSH host keys (which are secrets) to decrypt secrets. After first boot, the system uses its own SSH host key.

## Manual Bootstrap

If you prefer manual control:

**Critical**: SOPS has a circular dependency during installation - it needs SSH host keys (which are encrypted secrets) to decrypt secrets. You must create the age key file on the mounted filesystem before running nixos-install.

```bash
# 1. Copy the LUKS password to a file on the target machine
echo "YOUR_LUKS_PASSWORD" > /tmp/disko-password

# 2. Copy the bootstrap age private key to a file
echo "AGE-PRIVATE-KEY-HERE" > /tmp/age-key

# 3. Enable flakes
mkdir -p ~/.config/nix && \
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# 4. Clone your repository
git clone https://github.com/javierarrieta/nixos-configurations.git $HOME/nixos-configurations && \
cd $HOME/nixos-configurations

# 5. Mount your filesystem (if using disko, it will be at /mnt)
# If using disko: sudo disko --mode mount --flake .#llm01

# 6. CRITICAL: Create age key file on the mounted filesystem
mkdir -p /mnt/var/lib/sops-nix
cp /tmp/age-key /mnt/var/lib/sops-nix/key.txt
chmod 600 /mnt/var/lib/sops-nix/key.txt

# 7. Install NixOS
sudo nixos-install --flake .#llm01

# 8. Reboot and clean up temporary files
sudo reboot

# After first boot, you can remove the bootstrap key:
sudo rm /var/lib/sops-nix/key.txt
```

**Why this is necessary**: The configuration stores SSH host keys as SOPS secrets (`ssh_keys/llm01_host_private` and `ssh_keys/llm01_host_public`). During `nixos-install`, sops-nix needs to decrypt these secrets to place them at `/etc/ssh/ssh_host_ed25519_key`. However, sops-nix also needs either:
- The age key file at `/var/lib/sops-nix/key.txt`, OR
- SSH host keys to use for decryption (but these don't exist yet!)

By placing the bootstrap age key directly on the mounted filesystem before installation, we break this circular dependency. After first boot, the system uses its own SSH host key for decryption.

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

### SOPS decryption errors during installation

**Error**: `cannot read keyfile '/var/lib/sops-nix/key.txt': no such file or directory` or `Cannot read ssh key '/etc/ssh/ssh_host_ed25519_key': no such file or directory`

**Solution**: This is a circular dependency - sops-nix needs SSH host keys (which are secrets) to decrypt secrets. You must create the age key file on the mounted filesystem:

```bash
# If using nix-anywhere:
nix-anywhere --extra-files sops-key.txt:/var/lib/sops-nix/key.txt ...

# If installing manually:
mkdir -p /mnt/var/lib/sops-nix
cp /tmp/age-key /mnt/var/lib/sops-nix/key.txt
chmod 600 /mnt/var/lib/sops-nix/key.txt
sudo nixos-install --flake .#llm01
```

**Other SOPS issues**:
- Ensure your age key matches the one used to encrypt secrets (check `.sops.yaml`)
- The bootstrap age key is: `age1rlvgte0l7225vqdusvkzmdqmsyfd3u255rfy7ku93xx99k4vldsqhxnyxx`

### Disk partitioning issues
- Review `./hosts/llm01/disko.nix` before running
- Use `sudo nixos-install --flake .#llm01 --dry-run` to preview changes
