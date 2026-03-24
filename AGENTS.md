# NixOS Configuration Agent Guidelines

## Commands
- **Apply Config**: `nixos-rebuild switch --flake .#<hostname>`
- **Test Config (NixOS)**: `nixos-rebuild test --flake .#<hostname>` (builds & activates in test environment)
- **Test Evaluation (macOS/Non-NixOS)**: `nix eval .#nixosConfigurations.<hostname>.config.system.build.toplevel --show-trace` (verifies syntax and module configuration locally without needing `nixos-rebuild`)
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
- **Agent Decryption Limitations**: When a user's SSH key (like `~/.ssh/id_ed25519`) has a passphrase, `sops updatekeys` cannot prompt for the passphrase non-interactively in the agent's shell environment. `sops` will fail with an error `failed to obtain passphrase... standard input is not a terminal`. In these cases:
  1. Add the public keys to `.sops.yaml` yourself.
  2. Ask the user to run `sops updatekeys secrets.yaml -y` and `sops secrets.yaml` in their own terminal.
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

### Creating a New Host
**Complete Checklist for New Host Setup:**
1. **Create host directory**: `mkdir -p hosts/<hostname>`
2. **Create all required files** (do not skip any):
    - `configuration.nix` - Main NixOS configuration
    - `default.nix` - Required by NixOS for host lookup (see below)
    - `hardware-configuration.nix` - Hardware scan results
    - `vars.nix` - Variables (hostname, IP addresses, k3s options)
    - `users.nix` - User accounts and SSH keys
    - `home-manager.nix` - Home-manager per-host config (even if empty)
3. **Generate SSH host keys** for persistent SSH fingerprints:
    ```bash
    ssh-keygen -t ed25519 -f <hostname>_host_key -N "" -C "<hostname>"
    ```
4. **Add to `secrets.yaml`**: Create `<hostname>/network_env` secret with:
    ```
    IP_ADDRESS=192.168.0.X
    DEFAULT_GATEWAY=192.168.0.1
    DNS1=192.168.0.1
    DNS2=192.168.0.41
    ```
5. **Add SSH host keys to `secrets.yaml`**:
    ```yaml
    ssh_keys/<hostname>_host_private: |
        -----BEGIN OPENSSH PRIVATE KEY-----
        ... (private key content with trailing newline)
        -----END OPENSSH PRIVATE KEY-----
    ssh_keys/<hostname>_host_public: ssh-ed25519 ... (public key)
    ```
5. **Add SSH host keys to `.sops.yaml`**: **CRITICAL** - Add the new host public key to the age recipients list in `.sops.yaml` for encryption to work:
    ```yaml
    creation_rules:
      - path_regex: secrets\.ya?ml$
        key_groups:
          - age:
              # ... existing recipients
              - "ssh-ed25519 <public_key> <hostname>"  # Add new host
    ```
6. **Add to `flake.nix`**: Add `nixosConfigurations.<hostname>` entry with correct modules
7. **Track with Git**: `git add hosts/<hostname>` before evaluation

**Required Files:**
- `default.nix` (in host directory):
  ```nix
  { ... }:
  {
    imports = [
      ./configuration.nix
      ./hardware-configuration.nix
    ];
  }
  ```
- `home-manager.nix` (can be empty):
  ```nix
  { config, pkgs, lib, userOptions, ... }:
  {
    programs.fish = {
      shellAliases = {
        "nixos-apply" =
          "cd $HOME/code/nixos-configurations && git pull --ff-only && sudo nixos-rebuild switch --flake .#<hostname> ; cd -";
      };
    };
  }
  ```
- **Critical**: Without `default.nix`, NixOS fails with "opening file '/nix/store/.../hosts/hostname/default.nix': No such file or directory"
- **Critical**: Without `home-manager.nix`, evaluation may fail with module errors
- **Critical**: Must `git add` host directory before evaluation; untracked directories cause "path does not exist" errors

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

### Kubernetes Node Configuration (k3s)
- **Rsyslog Configuration**: Use `services.rsyslogd` module instead of `environment.etc` for cleaner configuration:
  ```nix
  services.rsyslogd = {
    enable = true;
    extraConfig = ''
      $ModLoad imuxsock
      $ModLoad imjournal
      $WorkDirectory /var/spool/rsyslog
      $ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
      $FileOwner root
      $FileGroup adm
      $FileCreateMode 0640
      $DirCreateMode 0755
      $UMask 0022
      $WorkDirectoryCreateMode 0755

      *.* @@192.168.0.41:514
    '';
  };
  ```
- **Kubelet Configuration**: K3s bundles kubelet, configure via `k3sOptions.extraFlags`:
  ```nix
  k3sOptions = {
    enable = true;
    role = "agent";
    extraFlags = toString [
      "--kubelet-arg pod-max-pids=500"
    ];
  };
  ```
- **State Version**: Match `system.stateVersion` with current NixOS release and home-manager version (e.g., "25.11")
- **SMART Monitoring**: Enable `services.smartd.enable = true` for disk health monitoring (don't just install smartmontools)
- **Prometheus**: Node exporter uses default port 9100 unless explicitly changed
- **Kernel Params**: Add cgroup support for Kubernetes:
  ```nix
  boot.kernelParams = [
    "overlay.override_cgroup=1"
    "cgroup.no_restrict=1"
  ];
  ```
- **Firewall**: Kubernetes nodes with MetalLB should keep firewall disabled due to dynamic ports and ARP/BGP protocols
- **Secret Binding**: Don't bind services to secrets they don't need (e.g., rsyslog doesn't need network_env)
- **Log Rotation**: Configure rsyslog file permissions and ownership via `extraConfig` to prevent work directory filling up

### ComfyUI Installation
- **Flake Setup**: Use `utensils/comfyui-nix` flake for ComfyUI on NixOS
  - Add to flake inputs: `comfyui-nix.url = "github:utensils/comfyui-nix"`
  - Add overlay: `nixpkgs.overlays = [ comfyui-nix.overlays.default ]`
  - Add module: `comfyui-nix.nixosModules.default` to host modules
- **Service Configuration**:
  ```nix
  services.comfyui = {
    enable = true;
    gpuSupport = "cuda";  # or "rocm" for AMD GPUs
    enableManager = true;
    listenAddress = "0.0.0.0";
    openFirewall = true;
  };
  ```
- **GPU Support**:
  - CUDA: Use `gpuSupport = "cuda"` for NVIDIA GPUs (all architectures supported)
  - ROCm: Use `gpuSupport = "rocm"` for AMD GPUs (tested on gfx1100/7900XTX)
  - Apple Silicon: Base `comfy-ui` package automatically uses Metal
- **Data Directory**: Default is `/var/lib/comfyui` for system service
- **Built-in Custom Nodes**: The flake includes curated custom nodes (Impact Pack, rgthree-comfy, KJNodes, ComfyUI-GGUF, etc.)
- **Reference**: https://github.com/utensils/comfyui-nix

### Log Forwarding Options
- **Rsyslog**: For simple log forwarding to a syslog server:
  ```nix
  services.rsyslogd = {
    enable = true;
    extraConfig = ''
      $ModLoad imuxsock
      $ModLoad imjournal
      $WorkDirectory /var/spool/rsyslog
      $ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
      *.* @@192.168.0.41:514
    '';
  };
  ```
  - Note: Service is `rsyslogd`, not `rsyslog`
  - Simpler than promtail for basic log aggregation
- **Promtail**: For advanced log forwarding to Loki (as configured in k8s-node03)
  - More complex but provides structured logging with labels

### Raspberry Pi 4 / ARM64 Configuration
- **SD Image Building**: See `hosts/k8s-pi01/README.md` for detailed instructions on building SD card images
- **Platform**: Use `system = "aarch64-linux"` in flake.nix for Raspberry Pi
- **Kernel**: Use `pkgs.linuxPackages_rpi4` for Raspberry Pi 4 optimized kernel
  ```nix
  boot.kernelPackages = pkgs.linuxPackages_rpi4;
  ```
- **Bootloader**: Use extlinux-compatible bootloader (no GRUB on ARM):
  ```nix
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  ```
- **Kernel Parameters**: Add for Raspberry Pi 4:
  ```nix
  boot.kernelParams = [
    "8250.nr_uarts=1"
    "console=ttyAMA0,115200"
    "console=tty1"
  ];
  ```
- **Filesystem**: SD card uses label-based mounting:
  ```nix
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
  ```
- **Additional Packages**: Include `pkgs.libraspberrypi` for Raspberry Pi firmware/tools

### SD Image Generation
- **Tool**: Use `nixos-generators` for cross-compiling NixOS images
- **Flake Input**:
  ```nix
  nixos-generators = {
    url = "github:nix-community/nixos-generators";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  ```
- **Warning**: nixos-generators is deprecated (upstreamed into nixpkgs as of NixOS 25.05)
- **Cross-Compilation Packages**:
  - For building on Linux (x86_64): `packages.x86_64-linux.sd-image-k8s-pi01`
  - For building on Mac (aarch64-darwin): `packages.aarch64-darwin.sd-image-k8s-pi01`
- **Output Format**:
  ```nix
  format = "sd-aarch64";  # For SD card images
  ```
- **Configuration Example**:
  ```nix
  packages.x86_64-linux.sd-image-k8s-pi01 = nixos-generators.nixosGenerate {
    system = "aarch64-linux";
    modules = [
      ./hosts/k8s-pi01
      sops-nix.nixosModules.sops
      home-manager.nixosModules.home-manager
    ];
    format = "sd-aarch64";
  };
  ```
- **Building**:
  ```bash
  nix build .#packages.x86_64-linux.sd-image-k8s-pi01
  # Result: ./result/sd-image/*.img.zst (compressed)
  ```

### AGE Encryption Key Management
- **Age Key Generation**: Generate local AGE key for SOPS encryption without SSH key dependencies
  ```bash
  age-keygen -o ~/.config/sops/age/keys.txt
  # Output shows both public and private key
  ```
- **Adding to .sops.yaml**: Add the public key to the age recipients list:
  ```yaml
  creation_rules:
    - path_regex: secrets\.ya?ml$
      key_groups:
        - age:
            - "age1YOUR_PUBLIC_KEY_HERE"  # Your local development AGE key
            # ... other recipients
  ```
- **Environment Variable**: Set `SOPS_AGE_KEY_FILE` for SOPS operations:
  ```bash
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
  ```
- **SOPS Operations with AGE Key**:
  - Decrypt: `sops -d secrets.yaml`
  - Encrypt: `sops -e secrets.yaml` (with .sops.yaml config)
  - Encrypt custom file: `sops --config /dev/null --encrypt --age <public_key> --input-type yaml --output secrets.yaml secrets.dec.yaml`
- **Benefits over SSH Keys**:
   - No passphrase prompts (age keys don't require passphrases by default)
   - Works better in non-interactive environments (CI/agents)
   - Separate from SSH authentication keys

### Filesystem Mounts
- **fileSystems**: Must be defined at top-level of configuration (not inside `services` or other blocks)
- **Correct syntax**: Use `fsType` not `type`:
  ```nix
  fileSystems = {
    "/mount/point" = {
      device = "server:/path";
      fsType = "nfs";  # NOT "type"
      options = [ "defaults" "nfs4" "rw" ];
    };
  };
  ```

### SD Image Cross-Compilation Issues with SOPS
- **Problem**: When cross-compiling SD images (e.g., aarch64-darwin → aarch64-linux), the build sandbox cannot access SOPS secrets, causing build failures with "Undefined error: 0"
- **Symptoms**:
  - `nixos-rebuild build-image` fails accessing secrets during cross-compilation
  - Error message: `executing '/nix/store/.../bin/bash': Undefined error: 0`
- **Solution 1 - Build on Target Platform**:
  - Run the build command on a Linux machine (x86_64 or aarch64) where SOPS can access your age key:
    ```bash
    export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
    nixos-rebuild build-image --flake .#k8s-pi01 --image-variant sd-card
    ```
  - This works because `nixos-rebuild build-image` runs on the target system where SOPS environment is available
- **Solution 2 - Bootstrap Image + Comin**:
  - Create a minimal image configuration without SOPS dependencies (like `minimal-image.nix`)
  - Build the minimal image on any platform:
    ```bash
    nixos-rebuild build-image --flake .#k8s-pi01-minimal --image-variant sd-card
    ```
  - Flash and boot the Pi, then let Comin deploy the full configuration with SOPS secrets
  - This works because Comin runs on the target machine where secrets are properly accessible
- **Note**: `nixos-generators` is deprecated; use `nixos-rebuild build-image` instead

