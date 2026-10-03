# `titan` OVH single-node k3s host — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring up `titan`, a new OVH bare-metal host running a standalone single-node k3s cluster, as a first-class member of the `nixos-configurations` fleet — public ingress on 80/443, key-only SSH on 13491, and the WireGuard mesh hub relocated onto it.

**Architecture:** NixOS declared per-host under `hosts/titan/`, built from the repo flake, deployed once with `nixos-anywhere` and thereafter GitOps'd by comin on the `main` (canary) branch. Shared behaviour lives in `modules/nixos/`; the host file only composes it. Two new modules carry the genuinely new concerns: `wireguard.nix` (the repo has never owned a WG hub) and `public-host.nix` (the repo has never had a firewall on).

**Tech Stack:** Nix / NixOS 26.05 (pinned `nixpkgs` 26.05.20260928.7fc6f2c), disko (legacy schema), sops-nix + age, k3s, comin, systemd-networkd via the repo's `static-network` module, iptables backend firewall, Terraform (OVH provider) in `../public-dns-tf`.

**Spec:** `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md` — read it alongside this plan. Operator-only values (the public IPv4, gateway, IPv6 block, disk serials, wear counters) are in the gitignored companion `2026-10-01-ovh-single-node-k3s-design.private.md` and are **never** committed.

## Global Constraints

- **This repo is public.** Never commit credentials or concrete public IP addresses. Before every commit run the two greps in spec §0. Placeholders in this plan: `<OVH_PUBLIC_IP>`, `<OVH_GW>`, `<OVH_IPV6>`.
- **`main` is PR-only** (GitHub ruleset 14106538, `required_linear_history`). Work on a feature branch, open a PR, merge with `gh pr merge --squash` or `--rebase`. Never `git push origin main`.
- **Never commit or push without explicit human permission.**
- Format with `nixfmt .` before committing; CI lint fails otherwise.
- 2-space indent, aligned `=` in attribute sets, `let … in` for locals (repo style).
- **The first deployed config must already be hardened** (spec §17): key-only SSH on 13491 and the default-deny firewall ship in the first boot. There is no "deploy then harden" step.
- **No LUKS in v1** (D9). `bootstrap_host.sh` still demands `--disk-password`; pass a throwaway and say why in the host README.
- k3s CIDRs are `10.62.0.0/16` (pods) / `10.63.0.0/16` (services) — both existing clusters already own the k3s defaults.
- Firewall backend is **iptables** on the pinned nixpkgs: `networking.nftables.enable` defaults to `false`, and `networking.firewall.extraCommands` is defined only by `firewall-iptables.nix` (verified 2026-10-01; spec Q10 closed). If anyone later flips `networking.nftables.enable`, nixpkgs asserts that `extraCommands` is incompatible — the failure is loud, not silent.

### How "test" works in this repo

There is no unit-test harness for NixOS modules, so every task's test cycle is an **evaluation assertion**: a `nix eval` of the exact option the task changes, plus a **regression eval** proving the twelve existing hosts are unaffected. To assert behaviour that no host currently selects, override the option on the fly with `extendModules` — that is how the `routeFlags` task tests a value nothing sets yet:

```bash
nix eval --raw --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.titan.extendModules {
    modules = [ { staticNetwork.routeFlags = [ "onlink" ]; } ];
  }.config.system.activationScripts.network-runtime.text'
```

`nix eval` on a derivation-valued option prints a `.drv` path; `nix build --dry-run` resolves it without building. Both are cheap enough to run per task.

## Review Focus

Failure modes the spec implies that no single task's happy-path eval catches. Each line gets a test in the task that owns the code.

- **A mesh port silently becomes public.** `wg0` carries both static peers and roadwarriors, so per-interface allowlisting (`firewall.interfaces.wg0.allowedTCPPorts`) cannot express "static peers only" — and if a mesh port also lands in `allowedTCPPorts`, the more permissive rule wins and 6443 is on the internet. Expected: 6443/10250/9100/4243 reachable from `192.168.133.0/25` and from nothing else. (Task 6 assertion + Task 14 on-host probe.)
- **`ssh.port` and the firewall allowlist drift apart.** sshd on 13491 with the firewall opening 22 is a lockout; the reverse is an open port nobody listens on. Expected: eval fails at build time, not at the console. (Task 6 assertion.)
- **PV data lands on `/`.** If k3s starts before `/var/lib/rancher/k3s/storage` is mounted, k3s creates the directory on the root filesystem and PVs end up split across two devices with no error. Expected: k3s cannot start until the mount is up. (Task 7 ordering + Task 14 `findmnt` check.)
- **Stage 1 cannot assemble mdraid + LVM.** The repo has no `mdraid`/`lvm_vg` precedent; a missing initrd module means a kernel panic on a box whose only console is OVH IP-KVM. Expected: `boot.initrd.services.lvm.enable` evaluates `true` and the generated initrd carries `mdadm` + `lvm`. (Task 8.)
- **A silent 100 % Attic cache miss.** `attic-cache.nix` documents this failure class: a wrong URL or key substitutes nothing and logs nothing, so a 40-minute build looks normal. Expected: `atticCache.url` keeps its path component and the trusted key is untouched. (Task 1 assertion; module already asserts the URL shape.)
- **flannel binds to `wg0` instead of `eno1`.** On a host where the tunnel is up at boot, flannel's interface auto-detection can pick `wg0`, and the pod network then runs over a link that leads to the home LAN instead of the local bridge — pods come up and nothing can reach them. Expected: `--flannel-iface=eno1` is always emitted, and `kubectl get node -o wide` shows the public address as `Internal-IP`. (Task 7 flag + Task 14 Step 4.)
- **The mesh is the only path to the backups.** rsyslog, Attic pulls and etcd snapshots all reach `192.168.0.42`/`.41` through `wg0`; a hub migration that breaks the tunnel silently stops backups and log shipping. Expected: post-migration verification proves each of the three paths, not just `wg show`. (Tasks 10, 15, 16.)

## File structure

**New files**

| Path | Responsibility |
|---|---|
| `hosts/titan/default.nix` | NixOS host entry point (mandatory for flake lookup) |
| `hosts/titan/configuration.nix` | composition only: module imports + host-specific values |
| `hosts/titan/vars.nix` | host variables (interface, placeholders, k3s options) |
| `hosts/titan/hardware-configuration.nix` | hand-written minimal hardware facts (initrd modules, no swap) |
| `hosts/titan/disko.nix` | mdraid-1 → LVM → `lv-root` + `lv-pvc` layout |
| `hosts/titan/README.md` | operator notes: OVH panel state, wear baseline, recovery commands |
| `modules/nixos/wireguard.nix` | declarative WG hub/peer, exported mesh subnets, LAN masquerade |
| `modules/nixos/public-host.nix` | default-deny posture for an internet-facing host |

**Modified files**

| Path | Change |
|---|---|
| `flake.nix` | `nixosConfigurations.titan` |
| `.github/workflows/verify.yml` | `titan` matrix leg (added in Task 8). Blocking: titan's sops keys landed with Task 12 on 2026-10-02, so the toplevel builds in CI. |
| `modules/nixos/ssh.nix` | `port`, `passwordAuthentication`, `listenAddresses` |
| `modules/nixos/static-network.nix` | `routeFlags` threaded into all three route installs |
| `modules/nixos/comin-health-gate.nix` | heal branch honours `routeFlags` |
| `modules/nixos/k3s.nix` | `mkDefault false` firewall; optional `serverAddr`/`tokenFile`; CIDRs; `requiresMountFor` |
| `modules/nixos/k8s-network.nix` | `mkDefault false` firewall |
| `modules/nixos/comin.nix` | `hermesEnable` opt-out |
| `modules/nixos/rsyslog.nix` | disk-backed remote queue |
| `modules/home-manager/base.nix` | `titan` joins the minimal package set |
| `secrets.yaml` | `titan/*`, `ssh_keys/titan_host_*`, `k3s_token_titan`, `wireguard/titan_*` |
| `../public-dns-tf/titan.arrieta.eu.tf` | A + wildcard A (private repo) |

## Not in this plan

Spec §13 lists the cluster-side tree — a **new GitOps repo** (Flux + sops, mirroring `k8s-techdelivery`) with cert-manager + `cert-manager-webhook-ovh`, a `ClusterIssuer le-prod-titan`, the `*.titan.arrieta.eu` `Certificate`, Traefik tuned down, and the restic CronJob. It is a different repository with its own review cycle and deserves its own plan; Tasks 13–16 here only prepare the host to receive it (DNS, mesh, MinIO credentials, the `local-path` volume layout). Nothing in this plan fails if that tree does not exist yet — titan boots with the k3s bundle's own Traefik and no certificate.

---

## Task 1: Host skeleton and flake entry

Creates a host that evaluates with nothing but the base modules, so every later task has a real config to assert against. Nothing here is secret.

**Not here, on purpose:** the CI matrix leg and the toplevel build. `base.nix` enables systemd-boot, which sets `fileSystems."/boot"`, and nixpkgs then asserts that `fileSystems` contains `/` — so no host in this repo can build a toplevel before it has a disk layout. Both move to Task 8, the task that creates one. Adding the matrix leg here would turn CI red and hide real failures on every commit in between.

**Files:**
- Create: `hosts/titan/default.nix`, `hosts/titan/configuration.nix`, `hosts/titan/vars.nix`, `hosts/titan/hardware-configuration.nix`
- Modify: `flake.nix` (add after the `llm01` block, ~line 216)

**Interfaces:**
- Consumes: nothing.
- Produces: `nixosConfigurations.titan`, `hosts/titan/vars.nix` keys `hostname`, `networkInterface`, `ipAddress`, `defaultGateway`, `nameservers` — every later task reads its values from here.

- [ ] **Step 1: Write the failing assertion** — the flake attribute must not exist yet.

```bash
cd ~/nixos-configurations
nix eval .#nixosConfigurations.titan.config.networking.hostName 2>&1 | tail -3
```
Expected: `error: attribute 'titan' missing`.

- [ ] **Step 2: Create `hosts/titan/vars.nix`**

```nix
{ config, pkgs }:
let
  networkInterface = "eno1";
in
{
  hostname = "titan";
  inherit networkInterface;
  # Placeholders on purpose: nixpkgs 26.05 parses addresses at eval time, so the
  # real values arrive at runtime from the SOPS `titan/network_env` secret.
  ipAddress = "$IP_ADDRESS";
  defaultGateway = "$DEFAULT_GATEWAY";
  nameservers = [
    "$DNS1"
    "$DNS2"
  ];
}
```

- [ ] **Step 3: Create `hosts/titan/hardware-configuration.nix`**

Hand-written, not `nixos-generate-config`: the machine does not exist yet, and the only facts that matter are the initrd modules (NVMe boot) and the deliberate absence of swap.

```nix
# Hand-written, not generated: titan is provisioned by nixos-anywhere before any
# NixOS exists to run nixos-generate-config. Keep this file to facts the flake
# cannot infer — the NVMe driver the initrd needs to see the boot disk, and the
# deliberate absence of swap (125 GiB RAM, and k3s prefers swap off).
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_hcd"
    "usbhid"
    "usb_storage"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # No swap: the §7a logical-volume list has no swap LV, and 125 GiB of RAM makes
  # one speculative for a services box. Adding it later is `lvcreate -L 8G -n
  # swap` out of the vg0 headroom plus a swapDevices entry — which is part of why
  # the VG keeps slack. Deviates from spec §6's "keep the same shape as the fleet";
  # §7a's decided layout wins.
  swapDevices = [ ];
}
```

- [ ] **Step 4: Create `hosts/titan/configuration.nix`** (minimal; later tasks extend it)

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vars = import ./vars.nix { inherit config pkgs; };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../common/users.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/static-network.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/nix-sweep.nix
  ];

  base.enable = true;
  systemPackages.enable = true;
  ssh.enable = true;
  sopsBase.enable = true;
  nixSweep.enable = true;

  networking.hostName = vars.hostname;

  staticNetwork = {
    enable = true;
    interface = vars.networkInterface;
    ipAddress = vars.ipAddress;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
  };
  networking.interfaces.${vars.networkInterface}.useDHCP = false;
  # eth1 is present and physically down (confirmed in rescue mode). Declaring it
  # keeps a DHCP client off a dead link and documents that the second NIC is
  # unused rather than overlooked.
  networking.interfaces.eth1.useDHCP = false;

  sops.secrets."titan/network_env" = {
    mode = "0400";
    owner = "root";
  };
  sops.secrets."ssh_keys/titan_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/titan_host_public" = {
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  system.stateVersion = "26.05";
}
```

- [ ] **Step 5: Create `hosts/titan/default.nix`**

```nix
{ ... }:
{
  imports = [
    ./configuration.nix
    ./hardware-configuration.nix
  ];
}
```

- [ ] **Step 6: Register in `flake.nix`** — insert after the `nixosConfigurations.llm01` block:

```nix
      nixosConfigurations.titan = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/titan
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };
```

- [ ] **Step 7: Verify the assertion now passes**

```bash
nix eval .#nixosConfigurations.titan.config.networking.hostName --raw; echo
nix eval .#nixosConfigurations.titan.config.staticNetwork.interface --raw; echo
nix eval .#nixosConfigurations.titan.config.sops.secrets."titan/network_env".path
nix flake show 2>/dev/null | grep titan
```
Expected: `titan`, `eno1`, a `/run/secrets/...` path, and a `nixosConfigurations.titan` line.

Do **not** build the toplevel here, and do not add a placeholder `fileSystems."/"` to make it pass. `nix build .#nixosConfigurations.titan.config.system.build.toplevel` fails at this stage with `The 'fileSystems' option does not specify your root file system.` — that is systemd-boot's `/boot` entry with no root yet, and Task 8 removes the condition by giving the host a real layout. A fake root filesystem here would be a false hardware fact that disko and `fileSystems` then fight over at boot.

- [ ] **Step 8: Regression — the existing hosts still evaluate**

```bash
for h in k8s-node05 k8s-server01 llm01; do
  printf '%s ' "$h"; nix eval ".#nixosConfigurations.$h.config.networking.hostName" --raw; echo
done
```
Expected: three hostnames, no errors.

- [ ] **Step 10: Commit**

```bash
nixfmt .
git add hosts/titan flake.nix
git commit -m "feat(titan): host skeleton and flake entry

Adds the OVH host with base/ssh/static-network/sops/nix-sweep only, so the
module work that follows has a real config to evaluate against. Hand-written
hardware-configuration.nix because nixos-generate-config has nothing to scan
until nixos-anywhere has installed something. The CI matrix leg and the toplevel
build belong to the disk-layout task: systemd-boot sets fileSystems./boot, and
nixpkgs asserts a root filesystem alongside it."
```

---

## Task 2: `ssh.nix` — port, password auth, listen addresses

The fleet default is `PasswordAuthentication = true` on port 22. Shipping that on a public IP is the one thing spec §17 forbids, so the module needs the knobs rather than a host-level override of a module's hardcoded value.

**Files:**
- Modify: `modules/nixos/ssh.nix`
- Modify: `hosts/titan/configuration.nix`

**Interfaces:**
- Consumes: nothing.
- Produces: `ssh.port` (port, default 22), `ssh.passwordAuthentication` (bool, default true), `ssh.listenAddresses` (list of str, default `[]`). Task 6 asserts `services.openssh.ports == [ config.publicHost.sshPort ]`.

- [ ] **Step 1: Write the failing assertion**

```bash
nix eval .#nixosConfigurations.titan.config.services.openssh.settings.PasswordAuthentication
nix eval .#nixosConfigurations.titan.config.services.openssh.ports
```
Expected: `true` and `[ 22 ]` — the fleet defaults, which is exactly what must change.

- [ ] **Step 2: Add the options** to `modules/nixos/ssh.nix` inside `options.ssh`:

```nix
      port = lib.mkOption {
        type = lib.types.port;
        default = 22;
        description = ''
          TCP port sshd listens on. Port choice is not a defence; the option
          exists so a public host can move off the port every scanner probes
          first, and so public-host.nix can assert the firewall opens the same
          port sshd binds.
        '';
      };
      passwordAuthentication = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether sshd accepts passwords. The fleet default is true because
          every existing host sits behind the LAN or the mesh; an
          internet-facing host must set this false, since key-only auth is the
          whole defence once the box is publicly reachable.
        '';
      };
      listenAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.168.0.29" "10.0.0.1" ];
        description = ''
          Addresses sshd binds. Empty keeps the sshd default (every address),
          which on a k3s node means sshd also answers on cni0 and flannel.1.
          Rendered comma-separated because sshd_config takes one
          ListenAddresses line holding a comma list, not repeated keys.
        '';
      };
```

- [ ] **Step 3: Use them** — replace the `config` block body:

```nix
  config = lib.mkIf config.ssh.enable {
    services.openssh = {
      enable = true;
      ports = [ config.ssh.port ];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = config.ssh.passwordAuthentication;
      }
      // lib.optionalAttrs (config.ssh.listenAddresses != [ ]) {
        ListenAddresses = lib.concatStringsSep "," config.ssh.listenAddresses;
      };
      hostKeys = [
        {
          path = config.ssh.hostKeyPath;
          type = config.ssh.hostKeyType;
        }
      ];
    };
  };
```

- [ ] **Step 4: Set the public-host values** in `hosts/titan/configuration.nix`, replacing `ssh.enable = true;`:

```nix
  # Public on the internet from the first boot (spec D3): key-only, off the
  # default port, and never dependent on the mesh being up.
  ssh = {
    enable = true;
    port = 13491;
    passwordAuthentication = false;
  };
```

- [ ] **Step 5: Verify**

```bash
nix eval .#nixosConfigurations.titan.config.services.openssh.settings.PasswordAuthentication
nix eval .#nixosConfigurations.titan.config.services.openssh.ports
```
Expected: `false` and `[ 13491 ]`.

- [ ] **Step 6: Regression — the fleet is untouched**

```bash
for h in k8s-node05 k8s-server01 llm01 k8s-pi01; do
  printf '%s pw=' "$h"
  nix eval ".#nixosConfigurations.$h.config.services.openssh.settings.PasswordAuthentication"
  printf '%s ports=' "$h"
  nix eval ".#nixosConfigurations.$h.config.services.openssh.ports"
done
```
Expected: `pw=true` and `ports=[ 22 ]` for all four.

- [ ] **Step 7: Commit**

```bash
nixfmt . && git add modules/nixos/ssh.nix hosts/titan/configuration.nix
git commit -m "feat(ssh): make port, password auth and listen addresses options

The module hardcoded PasswordAuthentication = true on 22, which is right for
the LAN/mesh fleet and unacceptable on a public IP. Options default to the
current behaviour, so no existing host changes; titan opts into key-only on
13491."
```

---

## Task 3: `static-network.nix` — `routeFlags`

Every route install in the repo is `ip route replace default via $GW dev <iface>`. On an off-link gateway the kernel rejects that with `Network is unreachable`. `titan`'s gateway turned out to be on-link (spec §4.2), so the flag ships empty — but the option is what keeps the config honest if OVH ever re-addresses the box, and it is the missing piece in the health gate's heal branch.

**Files:**
- Modify: `modules/nixos/static-network.nix` (options block + three route installs)
- Modify: `modules/nixos/comin-health-gate.nix` (heal line, ~line 33)
- Modify: `hosts/titan/configuration.nix` (documents the empty default)

**Interfaces:**
- Consumes: nothing.
- Produces: `staticNetwork.routeFlags` (list of str, default `[]`), read by `comin-health-gate.nix`.

- [ ] **Step 1: Write the failing assertion**

```bash
nix eval --raw --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.titan.extendModules {
    modules = [ { staticNetwork.routeFlags = [ "onlink" ]; } ];
  }.config.system.activationScripts.network-runtime.text' 2>&1 | tail -3
```
Expected: `error: The option 'staticNetwork.routeFlags' does not exist`.

- [ ] **Step 2: Add the option** inside `options.staticNetwork`:

```nix
      routeFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "onlink" ];
        description = ''
          Extra flags appended to every `ip route replace` this module emits
          (runtime service, activation script, route watchdog and the comin
          health gate's heal branch).

          OVH's primary IP is normally a /24 with an on-link gateway, so this
          stays empty. It exists for the routed/failover shape, where the
          gateway is off-link and the kernel refuses the route with
          `Network is unreachable` unless the route is marked onlink -- a
          failure that otherwise shows up as a host that silently loses its
          default route on the first switch.
        '';
      };
```

- [ ] **Step 3: Build the flag string** — add to the `let` block:

```nix
  routeFlagsStr =
    if config.staticNetwork.routeFlags == [ ] then
      ""
    else
      lib.concatStringsSep " " config.staticNetwork.routeFlags + " ";
```

- [ ] **Step 4: Thread it through all three installs.** In `network-runtime-config.script`:

```nix
            ip route replace ${routeFlagsStr}"$DEFAULT_GATEWAY" ...
```
becomes, precisely — replace each `ip route replace default via "$DEFAULT_GATEWAY" dev ${config.staticNetwork.interface}` with:

```nix
          ip route replace ${routeFlagsStr}default via "$DEFAULT_GATEWAY" dev ${config.staticNetwork.interface}
```

In `system.activationScripts.network-runtime.text`:

```nix
          ${lib.optionalString (isPlaceholder config.staticNetwork.defaultGateway) "${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via \"$DEFAULT_GATEWAY\" dev ${iface}"}
```

In `network-route-watch` `ExecStart`:

```nix
        ExecStart = "${pkgs.bash}/bin/bash -c 'while true; do ${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via \"$DEFAULT_GATEWAY\" dev ${iface} 2>/dev/null; ${pkgs.coreutils}/bin/sleep 10; done'";
```

- [ ] **Step 5: Make the health gate honour it.** In `modules/nixos/comin-health-gate.nix`, add the same helper the module now has — a `let` binding, not an inline expression, so the two files cannot drift in how they render the flag:

```nix
  routeFlagsStr =
    if config.staticNetwork.routeFlags == [ ] then
      ""
    else
      lib.concatStringsSep " " config.staticNetwork.routeFlags + " ";
```

and the heal line becomes:

```nix
      ${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via "${defaultGatewayRef}" dev ${config.staticNetwork.interface}
```

- [ ] **Step 6: Verify both states**

```bash
# default: no flag anywhere
nix eval --raw .#nixosConfigurations.titan.config.system.activationScripts.network-runtime.text | grep -c onlink
# overridden: the flag appears
nix eval --raw --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.titan.extendModules {
    modules = [ { staticNetwork.routeFlags = [ "onlink" ]; } ];
  }.config.system.activationScripts.network-runtime.text' | grep -c "onlink default via"
```
Expected: `0` then `1`.

- [ ] **Step 7: Regression — the watchdog and the gate still render for existing hosts**

```bash
nix eval --raw .#nixosConfigurations.k8s-node05.config.systemd.services.network-route-watch.serviceConfig.ExecStart | grep -o "ip route replace default via"
nix eval .#nixosConfigurations.k8s-server01.config.staticNetwork.routeFlags
```
Expected: one match, and `[ ]`.

- [ ] **Step 8: Commit**

```bash
nixfmt . && git add modules/nixos/static-network.nix modules/nixos/comin-health-gate.nix
git commit -m "feat(static-network): routeFlags option for off-link gateways

Adds the flag to all four places a default route gets installed, including the
comin health gate's heal branch, which duplicated the command and would have
drifted. Empty by default: titan's OVH gateway is on-link /24, verified in
rescue mode, so nothing changes today."
```

---

## Task 4: Let the firewall exist on a k3s host

`k3s.nix` and `k8s-network.nix` both hard-set `networking.firewall.enable = false`. That is correct for twelve LAN hosts and fatal for a public one. `mkDefault` keeps every existing host identical while letting `public-host.nix` win.

**Files:**
- Modify: `modules/nixos/k3s.nix:76`
- Modify: `modules/nixos/k8s-network.nix:28`

**Interfaces:**
- Consumes: nothing.
- Produces: a `networking.firewall.enable` that a host (Task 6) can set to `true` without a `lib.mkForce`.

- [ ] **Step 1: Write the failing assertion** — prove the current value is a hard `false` that a plain assignment cannot override:

```bash
nix eval --raw --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.k8s-node05.extendModules {
    modules = [ { networking.firewall.enable = true; } ];
  }.config.networking.firewall.enable' 2>&1 | tail -4
```
Expected: an error about conflicting definitions for `networking.firewall.enable`.

- [ ] **Step 2: `k3s.nix`** — replace line 76:

```nix
    # k3s needs to masquerade and DNAT freely, so the fleet disables the NixOS
    # firewall outright. mkDefault rather than a hard assignment so an
    # internet-facing host (titan) can keep the firewall on via public-host.nix
    # without lib.mkForce; every existing host leaves it at false.
    networking.firewall.enable = lib.mkDefault false;
```

- [ ] **Step 3: `k8s-network.nix`** — replace line 28:

```nix
    # See k3s.nix: mkDefault so public-host.nix can win without mkForce.
    networking.firewall.enable = lib.mkDefault false;
```

- [ ] **Step 4: Verify the override now works**

```bash
nix eval --raw --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.k8s-node05.extendModules {
    modules = [ { networking.firewall.enable = true; } ];
  }.config.networking.firewall.enable'
```
Expected: `true`.

- [ ] **Step 5: Regression — every existing host still evaluates to `false`**

```bash
for h in $(nix flake show --json 2>/dev/null | jq -r '.nixosConfigurations | keys[]'); do
  printf '%s ' "$h"; nix eval ".#nixosConfigurations.$h.config.networking.firewall.enable"
done
```
Expected: `false` for every existing host. `titan` prints `true` and that is correct at this stage — it imports neither `k3s.nix` nor `k8s-network.nix` yet, so nothing has disabled the firewall for it; Task 6 makes that `true` mean something, and Task 7 keeps it `true` against `k3s.nix`'s `mkDefault false`.

- [ ] **Step 6: Commit**

```bash
nixfmt . && git add modules/nixos/k3s.nix modules/nixos/k8s-network.nix
git commit -m "refactor(k3s,k8s-network): firewall disable is mkDefault

Hard false blocked a public host from ever enabling the firewall without
mkForce. mkDefault keeps all twelve LAN hosts at false and lets
public-host.nix turn it on for titan."
```

---

## Task 5: `wireguard.nix` — the repo becomes the hub

No WireGuard module exists anywhere in this repo: `llm01` carries WG material in SOPS and lets NetworkManager handle it. `titan` needs a declarative hub, and the mesh split (static peers vs roadwarriors) has to be declared once so the firewall can consume it instead of repeating it.

**Files:**
- Create: `modules/nixos/wireguard.nix`
- Modify: `hosts/titan/configuration.nix`

**Interfaces:**
- Consumes: `sops.secrets."wireguard/titan_private_key".path` (Task 12 creates the secret).
- Produces: `wireguard.meshSubnet` = `192.168.133.0/24`, `wireguard.staticSubnet` = `192.168.133.0/25`, `wireguard.roadwarriorSubnet` = `192.168.133.128/25`, `wireguard.lanSubnet` = `192.168.0.0/24`, `wireguard.listenPort`. Task 6 reads `staticSubnet`; Task 10 relies on the masquerade for rsyslog/Attic/MinIO reachability.

- [ ] **Step 1: Write the failing assertion**

```bash
nix eval .#nixosConfigurations.titan.config.wireguard.staticSubnet 2>&1 | tail -2
```
Expected: `error: The option 'wireguard.staticSubnet' does not exist`.

- [ ] **Step 2: Create `modules/nixos/wireguard.nix`**

```nix
# Declarative WireGuard for the home mesh.
#
# WHY THIS MODULE EXISTS. Until titan the hub lived on a non-NixOS VPS and the
# only NixOS-side WG was llm01's NetworkManager profile with SOPS-fed files.
# Owning the hub means owning it declaratively: keys from sops, peers from the
# flake, and the mesh ranges exported as options so public-host.nix consumes
# them instead of hardcoding a second copy of the same /25.
#
# WHY THE SUBNET SPLIT. Roadwarriors (phones, laptops) get
# 192.168.133.128/25 and static peers 192.168.133.0/25. Both arrive on wg0, so
# an interface-based firewall rule cannot tell them apart; the split only means
# something if the firewall matches on the source subnet, which is what
# public-host.nix does with staticSubnet.
{ config, lib, ... }:
let
  cfg = config.wireguard;

  peerOpts = {
    options = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "Peer public key (wireguard public keys are safe to commit).";
      };
      allowedIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Routes this peer advertises. On the hub this is the peer's own /32
          plus, for the home-LAN gateway peer, the LAN range titan must reach.
        '';
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "titan.arrieta.eu:51820";
        description = "host:port, only for the peer role (the hub is dialled).";
      };
      persistentKeepalive = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = 25;
        description = "Needed for NAT'd peers; null disables it.";
      };
    };
  };
in
{
  options = {
    wireguard = {
      enable = lib.mkEnableOption "the WireGuard mesh interface wg0";

      role = lib.mkOption {
        type = lib.types.enum [
          "hub"
          "peer"
        ];
        description = "hub listens and holds every peer; peer dials one hub.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        example = "192.168.133.1/24";
        description = "This host's tunnel address with prefix.";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 51820;
        description = "UDP listen port.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to the private key, from sops. Never inline the key.";
      };

      peers = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule peerOpts);
        default = [ ];
        description = "Hub: every peer. Peer role: exactly one entry, the hub.";
      };

      meshSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.133.0/24";
        description = "Whole mesh. Kept out of 172.16/12 (Docker) and 10.42/10.43 (k3s defaults).";
      };
      staticSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.133.0/25";
        description = "Static peers. The only source the control plane and exporters answer.";
      };
      roadwarriorSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.133.128/25";
        description = "Phones and laptops: ingress apps and the home LAN, never the control plane.";
      };
      lanSubnet = lib.mkOption {
        type = lib.types.str;
        default = "192.168.0.0/24";
        description = "Home LAN, reachable through the hub link.";
      };

      forwardToLan = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Hub only: enable IPv4 forwarding and SNAT mesh -> LAN traffic to the
          hub's tunnel address. Without SNAT the home router needs a return
          route for the mesh subnet, and that dependency has already bitten this
          fleet once (AGENTS.md, fresh worker switches dropping the route).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.interfaces.wg0 = {
      ips = [ cfg.address ];
      listenPort = cfg.listenPort;
      privateKeyFile = cfg.privateKeyFile;
      peers = map (p: {
        inherit (p)
          publicKey
          allowedIPs
          endpoint
          persistentKeepalive
          ;
      }) cfg.peers;
    };

    networking.firewall = {
      # Reverse-path filtering drops WireGuard: packets arrive on wg0 with
      # sources whose route is not wg0 (roaming roadwarriors, the advertised
      # LAN range), and rpfilter discards them before any allow rule is
      # consulted. This is the classic WG-on-a-firewalled-host failure and it is
      # silent.
      checkReversePath = false;
      allowedUDPPorts = [ cfg.listenPort ];
    };

    boot.kernel.sysctl = lib.mkIf cfg.forwardToLan { "net.ipv4.ip_forward" = "1"; };

    networking.firewall.extraCommands = lib.mkIf cfg.forwardToLan ''
      # -C first: the firewall unit re-runs extraCommands on every restart and a
      # duplicate MASQUERADE rule is a slow leak of identical rules.
      iptables -t nat -C POSTROUTING -s ${cfg.meshSubnet} -d ${cfg.lanSubnet} -o wg0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s ${cfg.meshSubnet} -d ${cfg.lanSubnet} -o wg0 -j MASQUERADE
    '';
  };
}
```

- [ ] **Step 3: Import and configure it in `hosts/titan/configuration.nix`** — add `../../modules/nixos/wireguard.nix` to `imports`, the secret, and:

```nix
  sops.secrets."wireguard/titan_private_key" = {
    mode = "0400";
    owner = "root";
  };

  wireguard = {
    enable = true;
    role = "hub";
    address = "192.168.133.1/24";
    privateKeyFile = config.sops.secrets."wireguard/titan_private_key".path;
    forwardToLan = true;
    # Peers are added by the hub migration (spec §11a). Empty here on purpose:
    # an empty hub is a working hub, and shipping the hub before the peers are
    # rewired is what keeps the old path alive during the move.
    peers = [ ];
  };
```

- [ ] **Step 4: Verify**

```bash
nix eval .#nixosConfigurations.titan.config.wireguard.staticSubnet --raw; echo
nix eval .#nixosConfigurations.titan.config.wireguard.roadwarriorSubnet --raw; echo
nix eval .#nixosConfigurations.titan.config.networking.wireguard.interfaces.wg0.ips
nix eval .#nixosConfigurations.titan.config.networking.firewall.checkReversePath
nix eval .#nixosConfigurations.titan.config.boot.kernel.sysctl."net.ipv4.ip_forward"
```
Expected: `192.168.133.0/25`, `192.168.133.128/25`, `[ "192.168.133.1/24" ]`, `false`, `"1"`.

- [ ] **Step 5: Regression — no other host grows a wg0.** No other host imports this module, so the option does not exist there — an "option does not exist" error is the pass condition, and it is what proves the module is opt-in rather than pulled in by `base.nix`:

```bash
for h in k8s-node05 k8s-server01 llm01; do
  printf '%s: ' "$h"
  nix eval ".#nixosConfigurations.$h.config.wireguard.enable" 2>&1 | tail -1 | head -c 120; echo
done
```
Expected: three `The option …wireguard.enable does not exist` errors. If any prints `false`, the module leaked into a host that never asked for it — find the import.

- [ ] **Step 6: Commit**

```bash
nixfmt . && git add modules/nixos/wireguard.nix hosts/titan/configuration.nix
git commit -m "feat(wireguard): declarative hub/peer module with exported mesh subnets

First WireGuard module in the repo: keys from sops, peers declarative, and the
static/roadwarrior /25 split exported as options so public-host.nix consumes
one declaration instead of a second hardcoded range.

checkReversePath = false is load-bearing: reverse-path filtering drops WireGuard
silently. forwardToLan SNATs mesh->LAN so the home router needs no return route
for the mesh."
```

---

## Task 6: `public-host.nix` — the default-deny contract

This is the module the whole design turns on: everything inbound is dropped except an explicit allowlist, and the k3s control plane answers only to static mesh peers. It also carries the two assertions that turn silent misconfigurations into build failures.

**Files:**
- Create: `modules/nixos/public-host.nix`
- Modify: `hosts/titan/configuration.nix`

**Interfaces:**
- Consumes: `wireguard.staticSubnet` (Task 5), `services.openssh.ports` (Task 2).
- Produces: `networking.firewall.enable = true` plus the allowlist; `publicHost.meshTCPPorts` as the single list of control-plane/exporter ports.

- [ ] **Step 1: Write the failing assertion.** At this point titan imports neither `k3s.nix` nor `k8s-network.nix`, so `networking.firewall.enable` is still nixpkgs' own default `true` — the unsafe state is not the boolean, it is that **nothing is declared**: the allowlist is empty, so an enabled firewall would drop SSH and ingress alike, and once Task 7 imports `k3s.nix` the firewall flips to `false` outright.

```bash
nix eval .#nixosConfigurations.titan.config.networking.firewall.enable
nix eval .#nixosConfigurations.titan.config.networking.firewall.allowedTCPPorts
```
Expected: `true` and `[ ]` — a firewall that is on by accident with no contract, and about to be switched off by `k3s.nix`.

- [ ] **Step 2: Create `modules/nixos/public-host.nix`**

```nix
# Firewall posture for a host sitting on the public internet.
#
# WHY A SEPARATE MODULE. Every other host in this fleet runs with the NixOS
# firewall disabled (k3s.nix, k8s-network.nix) because they live behind a LAN or
# the mesh. Here the opposite is true: the box has a routable IPv4, OVH traffic
# reaches it within minutes of boot, and the k3s control plane must never answer
# to the world. This module is the one place that says what is reachable.
#
# WHY RAW iptables for the mesh ports. wg0 carries static peers and roadwarriors
# alike, so networking.firewall.interfaces.wg0.allowedTCPPorts cannot express
# "static peers only" -- it would hand 6443 and 10250 to any lost phone. The
# rule has to match the source subnet, which is why it lives in extraCommands and
# why it consumes wireguard.staticSubnet rather than repeating the /25.
{ config, lib, ... }:
let
  cfg = config.publicHost;
in
{
  options = {
    publicHost = {
      enable = lib.mkEnableOption "public-internet host firewall posture";

      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 13491;
        description = "TCP port opened for SSH. Must match ssh.port.";
      };

      ingressTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          80
          443
        ];
        description = "Public ingress (Traefik via ServiceLB).";
      };

      meshTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          6443
          9100
          4243
          10250
          10257
          10259
        ];
        description = ''
          Control plane and exporters. Accepted only from
          wireguard.staticSubnet: 10250 is authenticated but RCE-shaped, and
          roadwarriors must not reach any of it.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.openssh.enable -> (config.services.openssh.ports == [ cfg.sshPort ]);
        message = ''
          publicHost.sshPort is ${toString cfg.sshPort} but sshd listens on
          ${lib.concatStringsSep ", " (map toString config.services.openssh.ports)}.
          Either SSH is unreachable from outside or the firewall opens a port
          nothing listens on. Set ssh.port to match.
        '';
      }
      {
        assertion = builtins.intersectLists cfg.meshTCPPorts config.networking.firewall.allowedTCPPorts == [ ];
        message = ''
          ${lib.concatStringsSep ", " (map toString (builtins.intersectLists cfg.meshTCPPorts config.networking.firewall.allowedTCPPorts))}
          is in networking.firewall.allowedTCPPorts, which opens it to the whole
          internet. Mesh-only ports must appear only in publicHost.meshTCPPorts.
        '';
      }
      {
        assertion = cfg.meshTCPPorts == [ ] || config.wireguard.enable;
        message = ''
          publicHost.meshTCPPorts is non-empty but wireguard is disabled, so the
          mesh rule would match ${config.wireguard.staticSubnet} with no tunnel
          behind it. Either enable wireguard or empty meshTCPPorts.
        '';
      }
    ];

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ cfg.sshPort ] ++ cfg.ingressTCPPorts;
      # extraCommands is emitted inside the nixos-fw chain *before* its final
      # refuse rule (firewall-iptables.nix), so appending here works; -A after
      # the chain was closed would be dead code. nixos-fw-accept is the module's
      # own accept target.
      extraCommands = ''
        iptables -A nixos-fw -s ${config.wireguard.staticSubnet} -p tcp \
          -m multiport --dports ${lib.concatStringsSep "," (map toString cfg.meshTCPPorts)} \
          -j nixos-fw-accept
      '';
    };
  };
}
```

- [ ] **Step 3: Enable it** — add `../../modules/nixos/public-host.nix` to `imports` and:

```nix
  # Inbound default-deny; the allowlist is the contract in spec §4.4.
  publicHost.enable = true;
```

- [ ] **Step 4: Verify**

```bash
nix eval .#nixosConfigurations.titan.config.networking.firewall.enable
nix eval .#nixosConfigurations.titan.config.networking.firewall.allowedTCPPorts
nix eval --raw .#nixosConfigurations.titan.config.networking.firewall.extraCommands
```
Expected: `true`, `[ 13491 80 443 ]`, and a rule containing `-s 192.168.133.0/25 -p tcp -m multiport --dports 6443,9100,4243,10250,10257,10259`.

- [ ] **Step 5: Prove the assertions fire** (each must fail the eval, not warn):

```bash
# mesh port leaked to the world
nix eval --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.titan.extendModules {
    modules = [ { networking.firewall.allowedTCPPorts = [ 6443 ]; } ];
  }.config.system.build.toplevel' 2>&1 | grep -o "opens it to the whole"
# sshd and the allowlist disagree
nix eval --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.titan.extendModules {
    modules = [ { services.openssh.ports = [ 22 ]; } ];
  }.config.system.build.toplevel' 2>&1 | grep -o "sshd listens on"
```
Expected: one grep hit each. Assertions are evaluated during module eval, so any option path works, but `system.build.toplevel` is the one CI evaluates.

- [ ] **Step 6: Regression — other hosts keep the firewall off**

```bash
for h in k8s-node05 llm01; do printf '%s ' "$h"; nix eval ".#nixosConfigurations.$h.config.networking.firewall.enable"; done
```
Expected: `false` twice.

- [ ] **Step 7: Commit**

```bash
nixfmt . && git add modules/nixos/public-host.nix hosts/titan/configuration.nix
git commit -m "feat(public-host): default-deny firewall posture for titan

Allowlist is 13491/80/443 public, 51820/udp for the mesh, and the k3s control
plane plus exporters only from wireguard.staticSubnet. Raw iptables rather than
interfaces.wg0.allowedTCPPorts because roadwarriors share wg0 and must not reach
6443 or 10250.

Two assertions: sshd's port must equal the opened port, and no mesh-only port may
appear in allowedTCPPorts. Both are lockout-or-exposure mistakes that would
otherwise only surface at the console."
```

---

## Task 7: `k3s.nix` — single-node server, own CIDRs, storage-mount ordering

The repo module makes `serverAddr` and `tokenFile` mandatory strings, which only makes sense for an agent. A single-node cluster needs neither. It also needs its own pod/service CIDRs (both existing clusters own the k3s defaults) and a hard ordering guarantee that the PV filesystem is mounted before k3s starts.

Verified against the pinned nixpkgs (`nixos/modules/services/cluster/rancher/default.nix:934-936`): upstream appends `--server` only when `serverAddr != ""` and `--token-file` only when `tokenFile != null`. So `serverAddr = ""` and `tokenFile = null` are the correct "not needed" values — `tokenFile = ""` would emit a bare `--token-file` and swallow the next argument.

**Files:**
- Modify: `modules/nixos/k3s.nix` (options + `extraFlags` + systemd ordering)
- Modify: `hosts/titan/vars.nix` (add the `k3s` block)
- Modify: `hosts/titan/configuration.nix` (import `k3s.nix` + `k8s-network.nix`, k3s sysctls)

**Interfaces:**
- Consumes: `sops.secrets."k3s_token_titan".path` (Task 12), the disko mount unit name (Task 8).
- Produces: `k3s.clusterCidr`, `k3s.serviceCidr`, `k3s.requiresMountFor`.

- [ ] **Step 1: Write the failing assertion** — the options do not exist and the module cannot be enabled without a server address:

```bash
nix eval .#nixosConfigurations.titan.config.k3s.clusterCidr 2>&1 | tail -2
```
Expected: `error: The option 'k3s.clusterCidr' does not exist`.

- [ ] **Step 2: Relax the two agent-only options** in `modules/nixos/k3s.nix`:

```nix
      serverAddr = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          K3s server address (required for agent role). Empty for a server that
          initialises its own embedded etcd, which includes a single-node
          cluster: upstream only emits --server when this is non-empty.
        '';
      };
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to the K3s token file. null omits --token-file entirely; the
          empty string does NOT (upstream tests for null, so "" emits a bare
          --token-file that eats the following argument). A single-node server
          mints its own token and needs no file.
        '';
      };
```

- [ ] **Step 3: Add the three new options** after `extraFlags`:

```nix
      clusterCidr = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "10.62.0.0/16";
        description = ''
          Pod CIDR. Empty keeps the k3s default 10.42.0.0/16. Set it on any host
          whose pod ranges could ever be routed to another cluster -- titan
          reaches the home LAN over WireGuard, where 10.42/10.43 are already
          claimed by two clusters.
        '';
      };
      serviceCidr = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "10.63.0.0/16";
        description = "Service CIDR. Empty keeps the k3s default 10.43.0.0/16.";
      };
      requiresMountFor = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "var-lib-rancher-k3s-storage.mount" ];
        description = ''
          systemd units k3s must wait for -- the mount units of filesystems under
          /var/lib/rancher. Without this, k3s can win the race against a separate
          data LV, create the directory on the root filesystem, and silently write
          PersistentVolume data to / until the root disk fills.
        '';
      };
```

- [ ] **Step 4: Emit the flags and the ordering.** Inside the `extraFlags` `toString (...)` list, after the `controlPlaneMetricsBindAddress` block:

```nix
        ++ lib.optionals (config.k3s.clusterCidr != "") [ "--cluster-cidr=${config.k3s.clusterCidr}" ]
        ++ lib.optionals (config.k3s.serviceCidr != "") [ "--service-cidr=${config.k3s.serviceCidr}" ]
```

and after the existing `systemd.services.k3s.path = …` block:

```nix
    # requires + after: `after` alone would still start k3s when the mount unit
    # failed, and k3s would then write PV data to / unnoticed.
    systemd.services.k3s = {
      requires = config.k3s.requiresMountFor;
      after = config.k3s.requiresMountFor;
    };
```

- [ ] **Step 5: Configure titan** — add to `hosts/titan/vars.nix`:

```nix
  k3s = {
    enable = true;
    role = "server";
    # Single-node cluster of its own: no serverAddr, no token file. The token
    # secret exists so a future second node can join without re-initialising.
    tokenFile = config.sops.secrets."k3s_token_titan".path;
    # Both home clusters already run the k3s defaults, and titan reaches the home
    # LAN over WireGuard, so the defaults would collide.
    clusterCidr = "10.62.0.0/16";
    serviceCidr = "10.63.0.0/16";
    # Keep the k3s bundle intact: Traefik + ServiceLB are the public ingress path
    # on a host with no LoadBalancer controller of its own (spec D4).
    disable = [ ];
    taints = [ ];
    controlPlaneMetricsBindAddress = "0.0.0.0";
    requiresMountFor = [ "var-lib-rancher-k3s-storage.mount" ];
    extraFlags = [
      # wg0 is up before k3s starts, and flannel's interface auto-detection will
      # pick it; the pod network then runs into a tunnel that leads to the home
      # LAN instead of the local bridge. Pin it to the public NIC (spec §6).
      "--flannel-iface=${networkInterface}"
    ];
    kubeletArgs = [
      # The 150 G root filesystem is small enough that a fat image cache starves
      # etcd before the kubelet would evict anything on its own.
      "image-gc-high-threshold=80"
      "image-gc-low-threshold=70"
      "eviction-hard=nodefs.available<10%"
    ];
  };
```

and in `hosts/titan/configuration.nix` add `../../modules/nixos/k3s.nix` and `../../modules/nixos/k8s-network.nix` to `imports`, plus:

```nix
  k3s = vars.k3s;

  # k8s-network forces the network_env EnvironmentFile onto both
  # network-addresses-eno1 and k3s, which is what resolves the $IP_ADDRESS
  # placeholders for k3s' own node-ip detection.
  k8sNetwork = {
    enable = true;
    primaryInterface = vars.networkInterface;
    hostName = vars.hostname;
  };

  sops.secrets."k3s_token_titan" = {
    mode = "0600";
    owner = "root";
  };

  # Same as the fleet's k3s hosts: without these, pod traffic crossing a bridge
  # bypasses netfilter and NetworkPolicy silently does nothing.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };
```

- [ ] **Step 6: Verify**

```bash
nix eval --raw .#nixosConfigurations.titan.config.services.k3s.extraFlags | tr ' ' '\n' | grep -E "cluster-cidr|service-cidr|kubelet-arg|flannel-iface|disable="
nix eval .#nixosConfigurations.titan.config.services.k3s.serverAddr --raw; echo
nix eval .#nixosConfigurations.titan.config.services.k3s.tokenFile
nix eval .#nixosConfigurations.titan.config.systemd.services.k3s.after
```
Expected: `--cluster-cidr=10.62.0.0/16`, `--service-cidr=10.63.0.0/16`, `--flannel-iface=eno1`, three `--kubelet-arg=` entries, no `--disable=`; empty string; the token path; a list containing `var-lib-rancher-k3s-storage.mount`.

`--node-external-ip` is deliberately **not** set. `k8s-techdelivery`'s single node reports its public address as `Internal-IP` and runs fine, which proves k3s picks a sane address on a public-only host; Task 14 Step 4 verifies it on titan instead of assuming the flag is needed.

- [ ] **Step 7: Regression — the fleet's flags are unchanged**

```bash
for h in k8s-node05 k8s-server01 k8s-pi01; do
  printf '%s: ' "$h"
  nix eval --raw ".#nixosConfigurations.$h.config.services.k3s.extraFlags" | grep -c "cluster-cidr"
done
```
Expected: `0` for each (no CIDR flags injected where none were set).

- [ ] **Step 8: Commit**

```bash
nixfmt . && git add modules/nixos/k3s.nix hosts/titan/vars.nix hosts/titan/configuration.nix
git commit -m "feat(k3s): support a standalone single-node server

serverAddr/tokenFile were mandatory strings, which only fits an agent. Both now
default to upstream's 'omit the flag' values (tokenFile must be null, not \"\":
upstream tests null). Adds clusterCidr/serviceCidr so titan can leave 10.42/43
to the two home clusters it reaches over WireGuard, and requiresMountFor so k3s
cannot start before the PV filesystem is mounted and write data to /."
```

---

## Task 8: `disko.nix` — mdraid-1 under LVM

First mdraid + LVM layout in this repo, so nothing here has a precedent to copy. The layout is spec D13: plain 1 GiB ESP on `nvme0n1`, `mdadm` metadata 1.2 with `--homehost=titan`, VG `vg0`, `lv-root` 150 G on `/`, `lv-pvc` 240 G on `/var/lib/rancher/k3s/storage`, ~29 G left unallocated in the VG as headroom.

**Files:**
- Create: `hosts/titan/disko.nix`
- Modify: `hosts/titan/configuration.nix` (import + `boot.swraid` + initrd modules)

**Interfaces:**
- Consumes: the two NVMe by-path names from spec §4.1 (in the private companion doc).
- Produces: the `var-lib-rancher-k3s-storage.mount` unit Task 7 orders k3s against.

- [ ] **Step 1: Write the failing assertion**

```bash
nix eval .#nixosConfigurations.titan.config.boot.swraid.enable 2>&1 | tail -2
```
Expected: `error: ... "boot.swraid.enable" … The option … does not exist` or `false` — either way, mdraid is not in the initrd yet.

- [ ] **Step 2: Create `hosts/titan/disko.nix`**

```nix
# titan disk layout (spec D13).
#
# mdraid-1 first, LVM on top. The RAID1 is what survives one dead NVMe; LVM on
# top of it is what makes the two halves resizeable later. Order matters: LVM
# inside md, never md inside LVM.
#
# The ESP stays a plain partition on nvme0n1 rather than a RAID1 mirror: systemd-boot
# on a mirrored ESP is a support burden for a boot path that rarely changes, and
# losing the ESP is recoverable from rescue mode in minutes.
#
# lv-pvc holds PersistentVolume data ONLY. etcd lives on lv-root with the rest of
# the system, and its snapshots go straight to S3 (spec §13b), so a pvc LV that
# also had to hold snapshots would need capacity sized against a second axis.
#
# ~29 G is left unallocated in vg0 on purpose: a full LV is an outage, and the
# headroom is what lets `lvextend` fix that without moving a partition.
{ ... }:
{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = "/dev/disk/by-path/pci-0000:02:00.0-nvme-1";
        content = {
          type = "gpt";
          partitions = {
            esp = {
              type = "EF00";
              size = "1G";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "titan";
              };
            };
          };
        };
      };
      nvme1 = {
        type = "disk";
        device = "/dev/disk/by-path/pci-0000:03:00.0-nvme-1";
        content = {
          type = "gpt";
          partitions = {
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "titan";
              };
            };
          };
        };
      };
    };
    mdadm = {
      titan = {
        type = "mdadm";
        level = 1;
        metadata = "1.2";
        # --homehost makes the array self-identify and stops mdadm_autoassemble
        # from importing a stale foreign array on a replacement disk.
        extraArgs = [
          "--homehost=titan"
        ];
        content = {
          type = "lvm_pv";
          vg = "vg0";
        };
      };
    };
    # disko rejects an `lvm_vg` nested inside an mdadm `content` block: the md
    # device is declared as an `lvm_pv` naming its VG, and the VG itself is a
    # top-level key next to `disk` and `mdadm`. (Corrected during implementation;
    # the nesting this step originally showed does not evaluate.)
    lvm_vg = {
      vg0 = {
        type = "lvm_vg";
        lvs = {
          root = {
            size = "150G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [
                "defaults"
                "noatime"
              ];
            };
          };
          pvc = {
            size = "240G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/lib/rancher/k3s/storage";
              mountOptions = [
                "defaults"
                "noatime"
              ];
            };
          };
        };
      };
    };
  };
}
```

- [ ] **Step 3: Wire it into the host** — add `./disko.nix` to `imports` in `hosts/titan/configuration.nix` and:

```nix
  # disko creates the arrays and LVs but does not configure the initrd to
  # assemble them at boot; without swraid the root filesystem is never found.
  boot.swraid.enable = true;
  # services.lvm drives boot.initrd.services.lvm.enable (which otherwise only
  # follows services.lvm.enable). Asserted in the task's verification step --
  # a missing LVM in the initrd is a panic on a box whose only console is IP-KVM.
  services.lvm.enable = true;
  boot.initrd.availableKernelModules = [
    "nvme"
    "raid1"
    "dm-mod"
  ];
  # Keep the OVH-generated boot entry working: disko formats a fresh ESP and
  # base.nix installs systemd-boot into it.
  boot.loader.systemd-boot.configurationLimit = 5;
```

- [ ] **Step 4: Verify the generated partitioning script**

```bash
script=$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.titan.config.system.build.diskoScript)
grep -cE 'mdadm --create /dev/md/titan' "$script"
grep -cE 'lvcreate .*-n root|lvcreate .*-n pvc' "$script"
grep -cE 'mkfs.ext4 /dev/vg0/root|mkfs.ext4 /dev/mapper/vg0-root' "$script"
grep -E 'by-path/pci-0000:0[23]:00.0-nvme-1' "$script" | head -2
```
Expected: `1`, `2`, `>=1`, and both by-path devices present.

- [ ] **Step 5: Verify the initrd can assemble it**

```bash
nix eval .#nixosConfigurations.titan.config.boot.swraid.enable
nix eval .#nixosConfigurations.titan.config.boot.initrd.services.lvm.enable
nix eval .#nixosConfigurations.titan.config.boot.initrd.availableKernelModules
nix eval .#nixosConfigurations.titan.config.boot.initrd.swraid.enable
```
Expected: `true`, `true`, a list containing `nvme`, `raid1`, `dm-mod`, `true`.

- [ ] **Step 6: Verify the mount unit name matches what Task 7 ordered against.** The unit name is derived from the mountpoint, so check both sides of the agreement:

```bash
script=$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.titan.config.system.build.diskoScript)
grep -cE '/var/lib/rancher/k3s/storage' "$script"
nix eval .#nixosConfigurations.titan.config.systemd.services.k3s.after | grep -c var-lib-rancher-k3s-storage
```
Expected: `>=1` and `1`. If the second is `0`, Task 7's `requiresMountFor` string does not match the mountpoint disko created — fix the spelling in `vars.nix`, not the unit name.

- [ ] **Step 7: Register the host in CI — and only now build the toplevel.** Before this task titan could not build at all (systemd-boot sets `fileSystems."/boot"` and nixpkgs asserts a root alongside it); the layout above is what makes the matrix leg honest. In `.github/workflows/verify.yml`, after the `llm01` line of the matrix:

> Historical, kept because the reasoning still matters: between Task 8 and Task 12 the
> build step carried a narrow escape hatch — if the build failed with
> `sops-install-secrets: manifest is not valid`, it warned and exited 0. sops encrypts
> values but leaves key names in plaintext, so sops-nix verifies every `sops.secrets`
> key name against `secrets.yaml`'s key tree at **build** time, and titan's five keys
> did not exist yet. The hatch was keyed on that exact error, not on the host name, so
> any other titan build break still went red. Task 12 landed on 2026-10-02 and the hatch
> was deleted in the same branch.

```yaml
          - { host: titan,        runner: ubuntu-24.04,   arch: x86_64 }
```

Then prove the toplevel resolves:

```bash
nix build --dry-run --no-link .#nixosConfigurations.titan.config.system.build.toplevel
```
Expected: a dry-run plan with no assertion about `fileSystems`. If it still complains, the disko mountpoints did not reach `config.fileSystems` — check that `disko.nix` is imported by `hosts/titan/configuration.nix` and that the flake passes `disko.nixosModules.disko`.

- [ ] **Step 8: Regression — no other host gained mdraid or LVM**

```bash
for h in k8s-node05 llm01; do printf '%s swraid=' "$h"; nix eval ".#nixosConfigurations.$h.config.boot.swraid.enable"; done
```
Expected: `false` for both.

- [ ] **Step 9: Commit**

```bash
nixfmt . && git add hosts/titan/disko.nix hosts/titan/configuration.nix .github/workflows/verify.yml
git commit -m "feat(titan): mdraid-1 + LVM layout via disko

RAID1 for disk loss, LVM on top for resize headroom, lv-pvc reserved for PV data
only. boot.swraid.enable and services.lvm.enable are not set by disko and are
what make the initrd assemble the array; both are asserted by eval here because a
missing initrd module is a boot panic with only IP-KVM to read it.

Adds the CI matrix leg here rather than with the host skeleton: the toplevel only
becomes buildable once a root filesystem exists."
```

---

## Task 9: comin on a public host — GitOps without the `hermes` account

`comin.nix` force-enables `hermesSsh` for every comin host. `hermes` exists so the agent can run `scripts/comin-approve.sh` over SSH on the fleet; titan is auto-confirming and reachable from the public internet, so the account is pure attack surface (Q17).

**Files:**
- Modify: `modules/nixos/comin.nix` (new `hermesEnable` option, line ~112)
- Modify: `hosts/titan/configuration.nix`

**Interfaces:**
- Consumes: `cominGitOps.*` as they exist.
- Produces: `cominGitOps.hermesEnable` (bool, default `true`).

- [ ] **Step 1: Write the failing assertion**

```bash
nix eval .#nixosConfigurations.titan.config.hermesSsh.enable 2>&1 | tail -2
```
Expected: an error (comin is not enabled on titan yet, so the option is unset).

- [ ] **Step 2: Add the opt-out** in `modules/nixos/comin.nix`, next to `confirmerMode`:

```nix
      hermesEnable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to create the 'hermes' deployer account. Fleet hosts need it:
          the hermes agent SSHes in to run comin confirmation accept. A host on
          the public internet with confirmerMode = auto has no use for it and
          should not carry a second SSH-login-capable account.
        '';
      };
```

and change line 112 from `hermesSsh.enable = true;` to:

```nix
    hermesSsh.enable = config.cominGitOps.hermesEnable;
```

- [ ] **Step 3: Enable GitOps on titan** in `hosts/titan/configuration.nix`:

```nix
  # Canary ring, auto-confirm: titan is the only WAN-reached host, so a bad
  # deploy is caught by its own health gate rather than by a human at 3am.
  # Revisit confirmerMode when it holds workloads worth a manual gate (spec D10).
  cominGitOps = {
    enable = true;
    branch = "main";
    confirmerMode = "auto";
    hermesEnable = false;
    healthGate = {
      enable = true;
      # No iSCSI on titan (no Longhorn), and halogen-flash is llm01-only.
      checks = [
        "route"
        "k3s"
        "current-system"
      ];
    };
  };
```

Also add `../../modules/nixos/comin.nix` and `../../modules/nixos/comin-health-gate.nix` to `imports`.

- [ ] **Step 4: Verify**

```bash
nix eval .#nixosConfigurations.titan.config.hermesSsh.enable
nix eval .#nixosConfigurations.titan.config.services.comin.enable
nix eval .#nixosConfigurations.titan.config.cominGitOps.healthGate.checks
nix eval --raw .#nixosConfigurations.titan.config.services.comin.postDeploymentCommand
```
Expected: `false`, `true`, `[ "route" "k3s" "current-system" ]`, `/run/current-system/sw/bin/comin-health-gate`.

- [ ] **Step 5: Regression — the fleet still gets `hermes`**

```bash
for h in k8s-node05 k8s-server01 llm01; do printf '%s ' "$h"; nix eval ".#nixosConfigurations.$h.config.hermesSsh.enable"; done
```
Expected: `true` three times.

- [ ] **Step 6: Let the gatekeeper reach a host outside the bind zone.** `scripts/comin-approve.sh` builds every SSH target as `$host.$COMIN_DOMAIN` (default `casa.arrieta`) on the default port; titan lives at `titan.arrieta.eu:13491`, so the script cannot reach it as written. Add a port function next to `ssh_host` and make `ssh_host` pass already-qualified names through:

```bash
# titan is not in the bind zone and its sshd is not on 22; a host name that
# already contains a dot is used verbatim.
ssh_host() { case "$1" in *.*) echo "$1"; *) echo "$1.$DOMAIN";; esac; }
ssh_port() { case "$1" in titan) echo 13491; *) echo 22;; esac; }
```

then change all four `ssh "$(ssh_host "$1")"` call sites (lines 29, 33, 38, 92) to `ssh -p "$(ssh_port "$1")" "$(ssh_host "$1")"`, and add titan to the canary ring:

```bash
CANARY_RING=(k8s-node05 llm01 titan)
```

Do **not** add it to `K8S_NODES`: `kubectl get node titan` queries the home cluster, which has no such node, and `is_k8s_node` would make the script wait for a Ready condition that can never appear.

Verify without touching any host:

```bash
bash -n scripts/comin-approve.sh
awk 'NR==13 || /^ssh_host\(\)|^ssh_port\(\)/' scripts/comin-approve.sh
```
Expected: no syntax errors, and the three lines shown are the `DOMAIN` default plus the two functions.

- [ ] **Step 7: Commit**

```bash
nixfmt . && git add modules/nixos/comin.nix hosts/titan/configuration.nix scripts/comin-approve.sh
git commit -m "feat(comin): hermesEnable opt-out; titan joins the canary ring

hermes exists for SSH-driven confirmation on the fleet. titan auto-confirms and
is publicly reachable, so it gets no second login-capable account. Health gate
keeps route/k3s/current-system checks; iscsi and halogen-flash are not applicable.

comin-approve.sh gains a per-host SSH port and passes dotted host names through,
otherwise the gatekeeper cannot reach the one canary that is not in the bind zone."
```

---

## Task 10: Observability and logs over the mesh

Spec Q9: Prometheus scrapes titan over WireGuard, titan ships rsyslog to `192.168.0.41` over WireGuard, and backups reach MinIO at `192.168.0.42`. All three depend on the mesh being up, and none of them should depend on split-horizon DNS.

**Files:**
- Modify: `modules/nixos/rsyslog.nix` (opt-in disk-backed queue)
- Modify: `hosts/titan/configuration.nix`
- Not modified: `modules/nixos/attic-cache.nix` — spec §9 asks for a "per-host URL override", and the module already exposes `atticCache.url`, so titan sets the option instead of the module gaining a second mechanism.

**Interfaces:**
- Consumes: `wireguard` mesh routes (Task 5), `staticNetwork.nameservers`.
- Produces: `rsyslog.diskQueue.enable` (bool, default `false`).

- [ ] **Step 1: Write the failing assertion**

```bash
nix eval .#nixosConfigurations.titan.config.prometheus.nodeExporter.enable 2>&1 | tail -2
```
Expected: an error or `false` — node_exporter is not on yet.

- [ ] **Step 2: Add the disk queue option** to `modules/nixos/rsyslog.nix`:

```nix
      diskQueue = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Buffer forwarded messages on disk instead of in memory. Off by
            default because it changes behaviour on every host that turns it on;
            opt-in per host.

            Needed by any host whose log target is reached over WireGuard: the
            tunnel can be down for minutes (hub restart, renumbering) while the
            in-memory queue overflows and drops the evidence you wanted the
            remote copy for.
          '';
        };
      };
```

and inside `extraConfig`, immediately before the forwarding line:

```nix
        ${lib.optionalString config.rsyslog.diskQueue.enable ''
          $ActionQueueType LinkedList
          $ActionQueueFileName remote-fwd
          $ActionQueueMaxDiskSpace 1g
          $ActionQueueSaveOnShutdown on
          $ActionResumeRetryCount -1
        ''}
```

> Superseded during implementation: the hardcoded `1g` became
> `rsyslog.diskQueue.maxDiskSpace` (default `1g`, validated
> `^[0-9]+[kmg]?$` at eval), so the line reads
> `$ActionQueueMaxDiskSpace ${cfg.diskQueue.maxDiskSpace}`.

- [ ] **Step 3: Configure titan** in `hosts/titan/configuration.nix` (add `../../modules/nixos/rsyslog.nix` and `../../modules/nixos/prometheus.nix` to `imports`):

```nix
  rsyslog = {
    enable = true;
    # Target is the home LAN collector, reached through wg0.
    diskQueue = { enable = true; };
  };

  prometheus.nodeExporter.enable = true;

  # Pin the MinIO host so etcd snapshots and restic do not depend on
  # split-horizon DNS resolving s3.l.arrieta.eu to the LAN address. The mesh
  # route exists; this removes the resolver from the critical path (spec Q7).
  networking.hosts = {
    "192.168.0.42" = [ "s3.l.arrieta.eu" ];
  };

  # journald on a k3s host with a 150 G root filesystem needs a ceiling; the
  # fleet learned that the hard way when a runaway logger filled a node's disk.
  # An option, not an extraConfig append: two SystemMaxUse lines in one file work
  # only while journald keeps the last one and the host merges after its imports.
  base.journald.systemMaxUse = "2G";
```

- [ ] **Step 4: Verify**

```bash
nix eval .#nixosConfigurations.titan.config.prometheus.nodeExporter.enable
nix eval --raw .#nixosConfigurations.titan.config.services.rsyslogd.extraConfig | grep -c "ActionQueueSaveOnShutdown on"
nix eval .#nixosConfigurations.titan.config.networking.hosts."192.168.0.42"
nix eval .#nixosConfigurations.titan.config.networking.firewall.allowedTCPPorts
```
Expected: `true`, `1`, `[ "s3.l.arrieta.eu" ]`, and the mesh ports must still be absent from that list (Task 6's assertion enforces it).

- [ ] **Step 5: Make the binary cache reachable, or accept a full local build.** `attic-cache.nix` is imported unconditionally by `base.nix` and defaults to `https://nix-cache.l.arrieta.eu/nixos-config`. `*.l.arrieta.eu` is a LAN name, so on titan that resolves nowhere (or to a public address that is not the cache) and every deploy silently substitutes nothing — the failure mode the module's own header warns about, made permanent by geography.

```bash
# from any machine already on the LAN or the mesh
getent hosts nix-cache.l.arrieta.eu
dig +short A nix-cache.l.arrieta.eu @192.168.0.41
```

Then pick one, in this order of preference:

1. If a public name exists for the cache, set it per host and stop there:

```nix
  atticCache.url = "https://<public cache name>/nixos-config";
```

2. Otherwise pin the LAN address the same way as MinIO — reachable over `wg0`, no resolver in the path:

```nix
  networking.hosts = {
    "192.168.0.42" = [ "s3.l.arrieta.eu" ];
    "<attic lan address>" = [ "nix-cache.l.arrieta.eu" ];
  };
```

Record the choice and the address in the private companion doc. Verify after deploy with `nix path-info --substituters https://nix-cache.l.arrieta.eu/nixos-config <a known store path>`; a cache miss and an unreachable host look identical from `nix log`, which is why this is checked with `path-info` and not with a log line.

- [ ] **Step 6: Regression — the fleet's rsyslog config is byte-identical**

```bash
nix eval --raw .#nixosConfigurations.k8s-node05.config.services.rsyslogd.extraConfig \
  | grep -c "ActionQueueType"
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
nixfmt . && git add modules/nixos/rsyslog.nix hosts/titan/configuration.nix
git commit -m "feat(titan): node exporter, disk-backed rsyslog queue, MinIO host pin

Log forwarding and backups both traverse wg0, so the rsyslog queue must survive
the tunnel being down; diskQueue is opt-in so the twelve existing hosts are
unchanged. networking.hosts removes the split-horizon DNS dependency for
s3.l.arrieta.eu."
```

---

## Task 11: Lean user environment on `titan`

`modules/home-manager/base.nix` skips the heavy modules for `k8s-*` hostnames; `titan` does not match that prefix, so it would otherwise pull rustup, scala-cli, nodejs, uv and k9s onto a 150 G root filesystem (spec Q18).

**Files:**
- Modify: `modules/home-manager/base.nix`
- Modify: `hosts/titan/configuration.nix` (nothing extra if the gate is hostname-based)

**Interfaces:**
- Consumes: the `hostname` specialArg (`common/users.nix` passes `config.networking.hostName`).
- Produces: nothing consumed downstream.

- [ ] **Step 1: Write the failing assertion** — show titan currently inherits the full tool set. Derivation values have no `pname` at eval time; `.name` (the drv name) is what works:

```bash
# define once per shell; these are separate invocations, so each step that uses
# heavy() must define it again
heavy() { nix eval ".#nixosConfigurations.$1.config.home-manager.users.javier.home.packages" \
  --apply 'xs: builtins.filter (n: builtins.match ".*(k9s|virtualenv|rustup|scala-cli).*" n != null) (map (x: x.name or (baseNameOf x.outPath)) xs)'; }
heavy k8s-node05
heavy k8s-pi01
```
Expected: node05 prints a non-empty list (`k9s-0.51.0`, `python3.13-virtualenv-…`), pi01 prints `[ ]`. Baselines for the regression step: node05 has 46 packages, pi01 has 35.

- [ ] **Step 2: Generalise the gate** in `modules/home-manager/base.nix`. Replace the `piHostnames`/`isPiNode` pair with:

```nix
  # Hosts that get host-common + shell only. The Pis are here to keep a slow ARM
  # box from compiling a Rust toolchain on every deploy; titan is here because a
  # 150 G root filesystem shared with etcd and container images has no business
  # holding a Scala toolchain nobody will invoke on a headless server.
  minimalHostnames = [
    "k8s-pi01"
    "k8s-pi02"
    "k8s-pi03"
    "titan"
  ];
  isMinimalHost = lib.elem hostname minimalHostnames;
  isK8sHost = lib.hasPrefix "k8s-" hostname;
  # titan is not a k8s-* hostname but has the same reason to skip dev-tools.
  skipDevTools = isK8sHost || isMinimalHost;
```

then change the two gates that referenced `isPiNode` to `isMinimalHost`, and the `dev-tools` gate from `!isK8sHost` to `!skipDevTools`. Keep the existing behaviour that `k8s-node01..05` still receive `python.nix` and `k8s.nix`.

- [ ] **Step 3: Verify**

```bash
heavy titan
nix eval .#nixosConfigurations.titan.config.home-manager.users.javier.home.packages --apply 'xs: builtins.length xs'
```
Expected: `[ ]` for the heavy-tool filter, and a count at or below pi01's 35.

- [ ] **Step 4: Regression — the workers keep their tools**

```bash
heavy k8s-node05
nix eval .#nixosConfigurations.k8s-node05.config.home-manager.users.javier.home.packages --apply 'xs: builtins.length xs'
nix eval .#nixosConfigurations.k8s-pi01.config.home-manager.users.javier.home.packages --apply 'xs: builtins.length xs'
```
Expected: node05 still lists `k9s-0.51.0` and the virtualenv, still 46 packages; pi01 still 35.

- [ ] **Step 5: Commit**

```bash
nixfmt . && git add modules/home-manager/base.nix
git commit -m "feat(home-manager): titan joins the minimal package set

Rename the Pi-only gate to minimalHostnames and add titan: a headless server
whose root filesystem is shared with etcd does not need a Scala or Rust
toolchain. k8s-* hosts keep python/k8s tools exactly as before."
```

---

## Task 12: SOPS secrets for `titan`

> **DONE 2026-10-02**, pulled ahead of the merge at the operator's request so the branch
> lands complete. All five keys were written with `sops --set` (never a decrypt-to-disk
> round trip), which preserves the file's four age recipients — verified before and after.
> The manifest derivation that CI failed on now builds locally; the CI escape hatch was
> deleted in the same branch. Steps 1–7 below are the runbook as executed.

Five secrets, all generated locally, none committed in plaintext. Spec §10 listed a `wireguard/titan_address` secret; the mesh address is not secret and lives in `vars.nix`, so it is dropped here and spec §10 should be amended to match.

Until these five keys exist, `nix build .#nixosConfigurations.titan.config.system.build.toplevel` **fails** with `sops-install-secrets: manifest is not valid: … the key '<name>' cannot be found` — sops encrypts values but leaves key names in plaintext, so sops-nix can verify the key tree at build time and does. The CI build step tolerated exactly that error (Task 8 Step 7); that tolerance is gone now that the keys exist.

**Files:**
- Modify: `secrets.yaml` (encrypted)
- Modify: `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md` (§10 note)

**Interfaces:**
- Consumes: the age key at `~/.config/sops/age/keys.txt`, `titan` already a recipient in `.sops.yaml`.
- Produces: `titan/network_env`, `ssh_keys/titan_host_{private,public}`, `k3s_token_titan`, `wireguard/titan_private_key` — consumed by Tasks 1, 5, 7.

- [ ] **Step 1: Generate the material** (never paste these into a chat or a log):

```bash
cd ~/nixos-configurations
umask 077
ssh-keygen -t ed25519 -f ./titan_host_key -N "" -C "titan"        # OVH host key pair
cat ./titan_host_key.pub                                            # safe to show
wg genkey | tee /tmp/titan_wg_private | wg pubkey                   # private is secret, public feeds Task 15
openssl rand -base64 40 | tr -dc 'A-Za-z0-9' | head -c 56; echo      # k3s join token
```

- [ ] **Step 2: Decrypt, edit, re-encrypt** using the documented manual workflow:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d secrets.yaml > /tmp/secrets.dec.yaml
$EDITOR /tmp/secrets.dec.yaml     # add the five keys below
sops -e /tmp/secrets.dec.yaml > secrets.yaml
rm -f /tmp/secrets.dec.yaml /tmp/titan_wg_private   # critical: no plaintext left behind
```

The keys to add (values from Step 1 and the private companion doc). The private-key body is written as a description rather than the literal `-----BEGIN …-----` frame, so this document passes the spec §0 credential grep instead of tripping it on every future diff:

```yaml
titan:
    network_env: |
        IP_ADDRESS=<OVH_PUBLIC_IP>
        DEFAULT_GATEWAY=<OVH_GW>
        DNS1=213.186.33.99
        DNS2=1.1.1.1
ssh_keys:
    titan_host_private: |
        # the full contents of ./titan_host_key, frame lines included,
        # with a trailing newline after the closing frame line
    titan_host_public: the one-line contents of ./titan_host_key.pub
k3s_token_titan: <token from step 1>
wireguard:
    titan_private_key: <wg private key from step 1, single line>
```

- [ ] **Step 3: Verify the private keys survived round-tripping** (the trailing-newline trap from AGENTS.md):

```bash
sops -d secrets.yaml | yq -r '.ssh_keys.titan_host_private' | tail -1
sops -d secrets.yaml | yq -r '.titan.network_env'
sops -d secrets.yaml | yq -r '.wireguard.titan_private_key' | tr -d '\n' | wc -c
```
Expected: the last line is `-----END OPENSSH PRIVATE KEY-----` (so a newline follows it), the four `network_env` lines, and `44`.

- [ ] **Step 4: Verify nothing plaintext is staged**

```bash
git diff -- secrets.yaml | head -5
git diff -- secrets.yaml | grep -c "ENC\[" 
git diff -- secrets.yaml | grep -E "BEGIN OPENSSH|AGE-SECRET|IP_ADDRESS=[0-9]" | wc -l
```
Expected: `ENC[` present, and `0` for the third command.

- [ ] **Step 5: Amend spec §10** to drop `wireguard/titan_address` with a one-line reason, then commit both files:

```bash
git add secrets.yaml docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md
git commit -m "feat(secrets): titan host keys, network env, k3s token, wg key

Drops wireguard/titan_address from spec §10: the mesh address is not secret and
is declared in vars.nix."
```

- [ ] **Step 6: Confirm the host evaluates against the real secret set**

```bash
nix eval .#nixosConfigurations.titan.config.sops.secrets."titan/network_env".path
nix eval .#nixosConfigurations.titan.config.sops.secrets."wireguard/titan_private_key".path
```
Expected: two `/run/secrets/...` paths.

- [ ] **Step 7: Make the CI leg blocking again.** With all five keys present the toplevel builds for real:

```bash
nix build .#nixosConfigurations.titan.config.system.build.toplevel --no-link
```
Expected: success (this is the build that failed with `the key 'k3s_token_titan' cannot be found` before this task).

Then delete the escape-hatch block (the `grep -q "sops-install-secrets: manifest is not valid"` branch and its comment) from the build step in `.github/workflows/verify.yml`, and the matching early-exit in the Attic push step, and commit:

```bash
git add .github/workflows/verify.yml secrets.yaml
git commit -m "chore(titan): secrets land; make the CI build leg blocking again"
```

---

## Task 13: DNS — `titan.arrieta.eu` and its wildcard

Spec Q2: plain A + wildcard A in the existing `arrieta.eu` zone, managed by Terraform in `../public-dns-tf` (private repo). The wildcard is what lets cert-manager solve DNS-01 for `*.titan.arrieta.eu` without a new delegation.

**Files:**
- Create: `../public-dns-tf/titan.arrieta.eu.tf`
- Modify: `../public-dns-tf/README.md` (if it lists zones/records)

**Interfaces:**
- Consumes: `<OVH_PUBLIC_IP>` from the private companion doc.
- Produces: `titan.arrieta.eu` (WG endpoint + SSH hostname) and `*.titan.arrieta.eu` (ingress apps).

- [ ] **Step 1: Write the failing assertion**

```bash
dig +short A titan.arrieta.eu; dig +short A anything.titan.arrieta.eu
```
Expected: both empty (NXDOMAIN).

- [ ] **Step 2: Create `../public-dns-tf/titan.arrieta.eu.tf`**, following the style of `home.arrieta.eu.tf`:

```hcl
# titan (OVH baremetal) — A + wildcard A.
#
# The wildcard is not convenience, it is the certificate strategy: cert-manager
# solves DNS-01 for *.titan.arrieta.eu with one OVH API call per cert instead of
# one per app. OVH's DNS API can create records under a wildcard name, so the
# solver only needs the zone credential.
#
# The plain A is load-bearing twice over: it is the WireGuard endpoint every peer
# dials (endpoint = titan.arrieta.eu:51820) and the SSH hostname.
#
# ttl 300 matches local.arrieta.eu.tf: a moved host should converge in minutes,
# not at the default TTL.
resource "ovh_domain_zone_record" "titan" {
  zone      = "arrieta.eu"
  subdomain = "titan"
  fieldtype = "A"
  ttl       = 300
  target    = "<OVH_PUBLIC_IP>"
}

resource "ovh_domain_zone_record" "titan_wildcard" {
  zone      = "arrieta.eu"
  subdomain = "*.titan"
  fieldtype = "A"
  ttl       = 300
  target    = "<OVH_PUBLIC_IP>"
}
```

> Corrected 2026-10-02: an earlier draft used `zone = var.ovh_domain`. `public-dns-tf`
> has no such variable — `variables.tf` defines only `host_map`, and every existing
> record hardcodes `zone = "arrieta.eu"`. Follow the repo, not the draft.

- [ ] **Step 3: Plan, review, apply**

```bash
cd ../public-dns-tf
terraform init
terraform plan -out titan.tfplan
terraform show titan.tfplan        # exactly two additions, no destroys
terraform apply titan.tfplan
```

- [ ] **Step 4: Verify propagation**

```bash
dig +short A titan.arrieta.eu
dig +short A anything.titan.arrieta.eu
dig +short A titan.arrieta.eu @213.186.33.99
```
Expected: the public IPv4 three times.

- [ ] **Step 5: Commit in the private repo** (never with the IP redacted — that repo is private and holds the real values):

```bash
cd ../public-dns-tf && git add titan.arrieta.eu.tf && git commit -m "feat(dns): titan.arrieta.eu A + wildcard for DNS-01"
```

---

## Task 14: Bootstrap the machine

> **DONE 2026-10-02.** Three bootstrap runs. Run 1 failed `setupSecrets` (age key arrived
> word-split as a shell argument). Run 2 installed cleanly but `main` still named `eth0`,
> so comin deployed a generation k3s could not start (`interface eth0 does not have a
> correct global unicast ip`, restart counter 136) and the health gate healed, retried and
> suspended the deployer instead of accepting it -- the gate earning its keep on its first
> real deployment. Run 3, after #56 and #57, is the machine now running: generation
> `d22f2bqpip8j0r9wz51945nxmyv3mb0q-nixos-system-titan`, `titan Ready` with `INTERNAL-IP`
> = the public address, `vg0-pvc` mounted under `/var/lib/rancher/k3s/storage`, `md127`
> `[2/2][UU]`, comin live and unsuspended, bootstrap generation identical to `main`.
>
> **Still unproven:** the `ip addr replace` from #57 has never run on a real switch --
> comin had nothing to deploy. The next change touching titan is the actual test.
>
> Found and fixed on the way: `eth0` vs `eno1` (#56), static address not re-applied on
> switch plus the break-glass password (#57), `--age-key-file` and `nixos-anywhere` from
> `nixpkgs` (#57). See `hosts/titan/README.md`.

The one irreversible task. Everything before it is evaluated, not executed. Read spec §17 (hard ordering) and §11 (hub migration) first, and keep the OVH IP-KVM session open for the whole run — the first boot is where an mdraid/LVM initrd mistake shows up.

**Files:**
- Modify: `bootstrap_host.sh` (opt out of `--build-on-remote`)
- Create: `hosts/titan/README.md`

**Interfaces:**
- Consumes: every task above, Task 12's secrets, Task 13's DNS, the OVH rescue system.
- Produces: a running titan with `/run/current-system` matching the flake.

- [ ] **Step 1: Let the bootstrap script build locally.** `--build-on-remote` is wrong for titan: the Attic cache is reachable only over the mesh, which does not exist yet, so the build must happen on the workstation and ship its closure over SSH. Three edits to `bootstrap_host.sh`.

In `usage()`, add a line after the `--disk-password` line:

```sh
  echo "  --no-build-on-remote  Build on the workstation (needed when no binary cache is reachable)"
```

In the `case` statement, add a branch before `*)`:

```sh
    --no-build-on-remote)
      NO_BUILD_ON_REMOTE=1
      shift
      ;;
```

and initialise `NO_BUILD_ON_REMOTE=0` beside the other variable defaults at the top, then replace the fixed `--build-on-remote \` line in the `nix run` invocation with a computed flag before the subshell body:

```sh
  BUILD_FLAG="--build-on-remote"
  [ "$NO_BUILD_ON_REMOTE" = "1" ] && BUILD_FLAG=""
```

and drop the literal flag from the `nix run github:nix-community/nixos-anywhere --` line, adding unquoted `$BUILD_FLAG` in its place (unquoted so the word disappears when empty — this is `/bin/sh` with no `set -u`).

Verify the flag parsing without bootstrapping anything:

```bash
sh -n bootstrap_host.sh
./bootstrap_host.sh --no-build-on-remote 2>&1 | head -2   # still prints usage: required args missing
./bootstrap_host.sh --help 2>&1 | grep -c no-build-on-remote
```
Expected: no syntax errors, the usage line, and `1`.

- [ ] **Step 2: OVH panel pre-flight** (spec Q19 + Q20 + §11). Record each in `hosts/titan/README.md`:
  - Reverse DNS for `<OVH_PUBLIC_IP>` → `titan.arrieta.eu`
  - **Edge Network Firewall** (spec §14 step 1 table, nine rules, first match wins):
    0 Accept TCP established · 1 Accept UDP src 53 · 2 Accept ICMP · 3 Accept TCP dst 22
    (rescue mode only) · 4 Accept TCP dst 13491 · 5 Accept TCP dst 80 · 6 Accept TCP dst 443
    · 7 Accept UDP dst 51820 · 19 **Deny IPv4**. The Deny is mandatory — an Accept-only set
    is a no-op — and rule 0 is what lets titan fetch from Attic and `git fetch` at all, since
    the ENF is stateless. Rules also apply automatically during DDoS mitigation even when the
    firewall is toggled off, so verify them now, not during an incident.
  - Rescue mode: Debian, your SSH key installed (`rescueSshKey` via the API is the tidy way)
  - Note the disk wear baseline from the private doc so a later SMART change is attributable
  - **Proactive maintenance / interventions: ENABLED (spec Q20, decided 2026-10-02).** Record
    the setting and the date. Consequences to write into the README:
    - OVH monitoring/HDV is disabled only for the bootstrap window and **re-enabled after the
      first successful disk boot** — it is the signal that triggers the intervention you opted into.
    - Rescue mode becomes a routine post-intervention step, which is exactly why ENF rule 3
      (TCP 22) exists: the rescue image's sshd listens on 22 and the NixOS firewall is not
      running there. In normal operation nothing listens on 22, so the rule costs a scanner
      a `connection refused`.
    - Leave the WireGuard MTU at 1420: the ENF drops UDP fragments by default.
    - After any OVH intervention, run the recovery check: boot mode back to "boot from hard
      disk", `mdadm --detail /dev/md/titan` rebuilt, `wg show` peers handshakes fresh,
      `systemctl is-active k3s` and etcd healthy, ENF rules still present.

- [ ] **Step 3: Run the bootstrap** from the workstation, in a terminal you can watch. Preferred path, now that Step 1's flag exists:

```bash
cd ~/nixos-configurations
./bootstrap_host.sh --no-build-on-remote --host titan --ip <OVH_PUBLIC_IP> \
  --age-key '<the age secret key line from ~/.config/sops/age/keys.txt>' \
  --disk-password throwaway
```

The disk password is unused without LUKS (spec D9); the script requires the argument, so pass something throwaway and say so in the README. To see exactly what runs, or to add `--ssh-port`, invoke `nixos-anywhere` directly instead — this is the same thing `bootstrap_host.sh` builds, with the temp tree spelled out:

```bash
TMP_DIR=$(mktemp -d); mkdir -p "$TMP_DIR/var/lib/sops-nix"
umask 077
cp ~/.config/sops/age/keys.txt "$TMP_DIR/var/lib/sops-nix/key.txt"
echo throwaway > "$TMP_DIR/disko-password"

nix run github:nix-community/nixos-anywhere -- \
  --extra-files "$TMP_DIR" \
  --disk-encryption-keys /tmp/disko-password "$TMP_DIR/disko-password" \
  --phases kexec,disko,install \
  --flake ".#titan" \
  "root@<OVH_PUBLIC_IP>"

rm -rf "$TMP_DIR"
```

> Corrected 2026-10-02: an earlier draft of that snippet passed `--ssh-port 10022`.
> OVH rescue-mode sshd listens on **22**, which is also nixos-anywhere's default, so
> the flag must not be passed at all. Verified against the live rescue system
> (`ssh root@<OVH_PUBLIC_IP>` answers with a publickey banner on 22).

There is no `--no-build-on-remote` flag on `nixos-anywhere` itself — building locally is its default, and `bootstrap_host.sh` is what hardcodes the opposite.

- [ ] **Step 4: First-boot verification, over the public path only** (the mesh does not exist yet):

```bash
ssh -p 13491 nixos@titan.arrieta.eu '
  readlink /run/current-system
  systemctl is-system-running --wait
  findmnt -no SOURCE,TARGET /var/lib/rancher/k3s/storage
  findmnt -no SOURCE / 
  cat /proc/mdstat
  systemctl is-active k3s sshd wireguard-wg0
  kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node -o wide
'
```
Expected: a store path, `running`, `lv-pvc` mounted at the k3s storage path, `md/raid1` in `/proc/mdstat`, all units `active`, node `Ready`. **If `findmnt` shows `/dev/mapper/vg0-root` under `/var/lib/rancher/k3s/storage`, stop** — the mount ordering is wrong and PV data is landing on `/`.

Read the `Internal-IP` column of that `kubectl get node -o wide` output while you are there: it should be `<OVH_PUBLIC_IP>`. If it is something else (a `10.62.x` flannel address means flannel grabbed the wrong interface), that is the moment `--node-external-ip` becomes necessary — it is not set by default (Task 7).

- [ ] **Step 5: Prove the firewall actually denies** (the Review Focus item no eval can catch):

```bash
nc -zvw3 titan.arrieta.eu 13491; echo "ssh: $?"
nc -zvw3 titan.arrieta.eu 80;    echo "http: $?"
nc -zvw3 titan.arrieta.eu 6443;  echo "api-should-fail: $?"
nc -zvw3 titan.arrieta.eu 9100;  echo "nodeexp-should-fail: $?"
nc -zuvw3 titan.arrieta.eu 51820; echo "wg: $?"
```
Expected: `succeeded` for 13491, 80, 443 and 51820; timeout (not refused) for 6443 and 9100 — a timeout is the DROP, a refused would mean something is listening.

- [ ] **Step 6: Confirm comin took over**

```bash
ssh -p 13491 nixos@titan.arrieta.eu 'comin status --json | jq "{deployer: .deployer.deployment.status, suspended: .is_suspended, deployer_suspended: .deployer.is_suspended}"'
cat /var/log/comin-health-gate.log | tail -3
```
Expected: `status: "done"`, both suspension flags `false`, and a recent `health gate OK`.

- [ ] **Step 7: Write `hosts/titan/README.md`** — OVH panel state, the throwaway-disk-password note, the disk wear baseline, and these recovery commands: route watchdog, `comin suspend`/`resume` pair (issue #159), `mdadm --detail /dev/md/titan`, `lvdisplay vg0`.

Copy the break-glass ladder from spec §5 into it verbatim, in order: SSH on 13491 (the primary path, not the emergency one) → `nixos-rebuild switch --rollback` or the previous systemd-boot entry from the panel KVM → OVH rescue mode + chroot (**needs ENF rule 3, TCP 22 — see Task 14 Step 2**) → IP-KVM to see the console → panel firewall to cut inbound while a bad rule is live. The ladder is only usable because `boot.loader.systemd-boot.configurationLimit = 5` (Task 8) keeps a rollback entry on disk, and because SSH never depends on the mesh (spec D3). Note in the README that a WG outage degrades Prometheus, Attic and rsyslog but never locks anyone out.

- [ ] **Step 8: Commit**

```bash
git add bootstrap_host.sh hosts/titan/README.md
git commit -m "feat(bootstrap): opt out of --build-on-remote; titan runbook

The Attic cache is only reachable over the mesh, which does not exist during the
first bootstrap, so titan must build locally and ship its closure."
```

---

## Task 15: Move the WireGuard hub onto `titan`

The mesh renumber (D15: `192.168.2.0/24` → `192.168.133.0/24`) and the hub move (D14) are one operation: every peer changes address and endpoint at once. The old hub on `techdelivery.es` stays up until every peer has handshaked with the new one, so the two meshes coexist during the move.

**Update 2026-10-02 — the core is a triangle (spec §4.3).** Before any peer flips, OPNsense and `techdelivery.es` each *add* a link to `titan` and remove nothing: the three cores hold a direct link to each other, so the mesh survives `titan` for the one path worth saving (home↔VPS) and there is no standby hub, no shared keypair and no failover procedure. Roadwarriors move to `.129`/`.130`, **not** the `.101`/`.102` they had on the old flat `/24` — `public-host.nix` trusts only `192.168.133.0/25`, so the old numbers would have handed both laptops 6443 and 10250. Full runbook: private companion §5.

**Update 2026-10-02 — `chiclana` is not migrated.** Nobody can touch that box for a few months, so it stays on the old `192.168.2.0/24` mesh with the VPS as its hub. The old hub is therefore **scoped, not retired**: it keeps running with **`chiclana` and OPNsense** as its members. OPNsense carries both meshes indefinitely — routing home↔chiclana through the bridge instead (home → titan → VPS → chiclana) would make that path depend on `titan`, which is exactly the dependency the triangle exists to remove, and it would vanish at the moment it was wanted.

**Files:**
- Modify: `hosts/titan/configuration.nix` (fill `wireguard.peers`)
- Modify: `../k8s-techdelivery` manifests that hardcode `192.168.2.x` (`node-exporter-llm01.yaml`, `chiclana-hass.yaml`, `gatus.yaml`) and the Prometheus scrape list
- Modify: the home-LAN gateway peer config and each roadwarrior config

**Interfaces:**
- Consumes: `wireguard` module (Task 5), `titan.arrieta.eu` (Task 13), the peer table in the private companion doc.
- Produces: the mesh at `192.168.133.0/24`, titan as hub for the leaves, and the three core boxes (`titan`, `techdelivery.es`, OPNsense) each holding a direct link to the other two.

- [ ] **Step 1: Confirm what is left before touching anything.** Q5c and Q12 are **closed** — the old hub is `192.168.2.1`, the old mesh is `192.168.2.0/24`, and `192.168.133.0/24` is free at home, chiclana and on the OVH host network. **Q5d is now closed too** (2026-10-02): the home router is `OPNsense`, and the mesh returns by **route, not masquerade** — OPNsense must carry `192.168.133.0/24` into its WG peer, which its WireGuard plugin installs from the endpoint's Allowed IPs. Whether the old hub masquerades is still worth recording for the audit (Firewall → NAT → Outbound, or Routing → Static Routes), but it no longer gates the move, and any existing masquerade stays exactly where it is until the old hub is retired. See spec §11a.

- [ ] **Step 2: Generate one keypair per peer** and record `{ mesh address, public key, role }` in the private companion doc. Static peers take `192.168.133.2…127`, roadwarriors `192.168.133.128+`.

- [ ] **Step 3: Declare the peers on the hub** — fill `wireguard.peers` in `hosts/titan/configuration.nix`. The home-LAN gateway peer advertises both its own `/32` and `192.168.0.0/24`; every other peer advertises only its own `/32`:

```nix
      peers = [
        {
          publicKey = "<home-lan-gateway-public-key>";
          allowedIPs = [
            "192.168.133.2/32"
            "192.168.0.0/24"
          ];
        }
        # one entry per static peer and per roadwarrior, each with its own /32
      ];
```

Deploy via comin (or `nixos-rebuild switch --flake .#titan` over SSH), then:

```bash
ssh -p 13491 nixos@titan.arrieta.eu 'wg show | grep -c "(resolved)"'
```
Expected: one line per peer that is currently online.

- [ ] **Step 3a: Bridge the two hubs.** Add `titan` as a peer on the old hub with `192.168.133.0/24` in AllowedIPs, and the old hub as a peer on `titan` with `192.168.2.0/24`. Without this the moment a peer moves, every peer still on the old mesh black-holes traffic to it, because the old hub keeps routing that peer's dead old address. With it the whole flip window is non-breaking and retiring the old hub is one deletion. Verify both directions before flipping anything: `ping -c1 192.168.2.4` from `titan` and `ping -c1 192.168.133.4` from the VPS.

- [ ] **Step 4: Rewire each peer**, in this order — `pixel7`, `macbookair`, home LAN (`OPNsense`), then the `techdelivery.es` VPS. **`chiclana` is not rewired** (see the update above): it stays on the old mesh. **`llm01` leaves the mesh entirely** — its peer existed to bridge it to the VPS and it now sits inside the home LAN, so repoint whatever scraped it over the mesh at `192.168.0.29`. **Checked on the host 2026-10-02: there is nothing to retire.** `wg show` lists no interface, `/etc/wireguard` does not exist, no `wireguard*` units — llm01 has never had a tunnel under this config, so the old hub's `192.168.2.4` peer is a corpse that could never have handshaked. What is left is hygiene, not migration: delete the five unread `wireguard/*` `sops.secrets` entries from `hosts/llm01/configuration.nix` and the secrets themselves, and fix `node-exporter-llm01.yaml`, which scrapes `192.168.2.3:9100` — chiclana's address, not llm01's — and should point at `192.168.0.29:9100`. Roadwarriors first (nothing runs behind them), the home LAN early because the restore drill's MinIO path rides it, the VPS last because it *is* the old hub. to endpoint `titan.arrieta.eu:51820` with its new address. For the `techdelivery.es` VPS, that is its client config, not a hub config any more. Roll one peer at a time and confirm a **fresh** handshake on `titan` before moving to the next — compare the `latest handshake` counter, do not trust that a line exists at all. Rollback for any step is to revert that one peer to the old hub and its old address; the bridge means nothing else notices.

- [ ] **Step 5: Repoint everything that addressed the old mesh.** In `../k8s-techdelivery`: Prometheus scrape targets, `node-exporter-llm01.yaml`, `chiclana-hass.yaml`, `gatus.yaml`. Then verify each path independently — a green `wg show` proves the tunnel, not the services behind it:

> **`titan` is scraped over the mesh, and the source address is what the firewall
> checks.** `public-host.nix` accepts 6443/9100/4243/10250/10257/10259 only with
> `-i wg0 -s 192.168.133.0/25`. So the scrape target must be titan's tunnel
> address (`192.168.133.1`) **and** the connection must leave home through
> `wg0`, which means the hub is the route to it. A scrape aimed at titan's public
> IP is dropped by the default-deny INPUT policy with no log line and no
> certificate error — it just times out, which reads like a down node. After
> adding the target, confirm from the Prometheus pod:
> `wget -qO- http://192.168.133.1:9100/metrics | head -1` and
> `wget -qO- http://192.168.133.1:4243/metrics | grep -m1 comin_` — comin's
> exporter has no enable flag, it answers whenever comin runs. If both time out
> while `wg show` is green, the pod's traffic is reaching `wg0` with a pod or
> `cni0` source address rather than the node's mesh address; that is a home-side
> SNAT/routing gap, not a titan problem.

```bash
ping -c1 192.168.133.4                                   # llm01
nc -zvw3 192.168.0.41 514                                # rsyslog collector
nc -zvw3 192.168.0.42 9000                               # MinIO
nix path-info --store https://<attic> 2>/dev/null || echo "attic: verify by pulling a known path"
```

- [ ] **Step 6: Prove the roadwarrior boundary holds** (the point of the /25 split):

```bash
# from a roadwarrior, on the tunnel
nc -zvw3 192.168.133.1 6443;  echo "must fail"
nc -zvw3 192.168.133.1 443;   echo "must succeed"
# from a static peer
nc -zvw3 192.168.133.1 6443;  echo "must succeed"
```

- [ ] **Step 7: Retire the old hub** (`192.168.2.1` on the `techdelivery.es` VPS) only after every peer handshakes and every service path above is green. Keep the old config file in the private doc as the rollback — and when you read it, copy out only the `Address =` line and the NAT/forward rules; the file also holds the hub's private key, which must never reach a transcript or a commit.

- [ ] **Step 8: Commit** the peer list (public keys only — never private keys) and the `../k8s-techdelivery` changes in their respective repos.

---

## Task 16: Backups, and the restore drill that closes v1

> **PREREQUISITE FOUND THE HARD WAY (2026-10-02): titan had no etcd at all.**
> `k3s etcd-snapshot save` answered `etcd datastore disabled`. A lone k3s server
> without `--cluster-init` runs on **sqlite**; the module comment claiming an empty
> `serverAddr` implied embedded etcd was wrong, so spec D1 was written down and never
> actually satisfied. `--cluster-init` is now in `extraFlags`, and because k3s cannot
> migrate sqlite -> etcd in place the datastore has to be rebuilt -- see the
> "datastore must be etcd" section of `hosts/titan/README.md` for the procedure.
> Everything below assumes that migration has happened. Note the home fleet's
> `k8s-server01` also lacks `--cluster-init`; its etcd was bootstrapped out-of-band
> and survives only because the data directory does. Do not "fix" a live cluster.

Spec §13b and Q15: etcd snapshots go to S3 with k3s' native mechanism, PV data goes to restic, both land in MinIO over the mesh. The restore drill is the v1 exit criterion — a backup nobody has restored is a rumour.

**Files:**
- Modify: `hosts/titan/vars.nix` (etcd snapshot flags)
- Modify: `hosts/titan/configuration.nix` (MinIO credential secret)
- Create: the restic CronJob manifest in the new GitOps repo (spec Q16)
- Modify: `hosts/titan/README.md` (drill log)

**Interfaces:**
- Consumes: `networking.hosts` pin (Task 10), the mesh (Task 15), a MinIO key scoped to exactly two buckets.
- Produces: `titan-etcd` and `titan-pvc` buckets with content, and a dated drill entry.

- [ ] **Step 1: Scope the MinIO credentials** to `titan-etcd` and `titan-pvc` only, and store them as an env-file-shaped secret:

```bash
sops -d secrets.yaml > /tmp/secrets.dec.yaml
# add titan/minio_env:
#   AWS_ACCESS_KEY_ID=...
#   AWS_SECRET_ACCESS_KEY=...
sops -e /tmp/secrets.dec.yaml > secrets.yaml && rm /tmp/secrets.dec.yaml
```

- [ ] **Step 2: Turn on k3s' native etcd snapshots** — **append** these to the `extraFlags` list Task 7 already created in `hosts/titan/vars.nix` (assigning a new list would silently drop `--flannel-iface`):

```nix
      # An etcd snapshot is every Secret in the cluster in plaintext, so the
      # bucket is the most sensitive object in the design: the MinIO key is
      # scoped to exactly these two buckets and nothing else.
      #
      # FLAG NAMES WERE WRONG IN THE FIRST DRAFT of this task. The S3 family is
      # `--etcd-s3-*`, NOT `--etcd-snapshot-s3-*`; the cron flag is
      # `--etcd-snapshot-schedule-cron`; the restore flag is
      # `--cluster-reset-restore-path`, not `-url`. k3s exits on an unknown flag,
      # so the old list would have killed k3s at startup, tripped the health gate
      # and rolled the canary back. Verified against docs.k3s.io/cli/server on
      # 2026-10-02; re-verify against the binary on the host before deploying:
      #   k3s server --help 2>&1 | grep -E "etcd-s3|schedule-cron|cluster-reset"
      #
      # The endpoint has NO PORT. s3.l.arrieta.eu is a Traefik Ingress on 443
      # (k8s-casa apply/50-apps/casa/minio.yaml: the Service port 9000 is the
      # in-cluster port, never reachable from outside). Pinning :9000 would
      # connect to the MetalLB VIP and hang.
      "--etcd-s3"
      "--etcd-s3-folder=titan"
      "--etcd-s3-bucket=titan-etcd"
      "--etcd-s3-endpoint=s3.l.arrieta.eu"
      "--etcd-s3-region=eu-west-1"
      # PATH STYLE IS MANDATORY. The default 'auto' lookup would try
      # titan-etcd.s3.l.arrieta.eu, which has no DNS record and no cert -- the
      # Traefik Ingress serves one host. k8s-techdelivery hits the same wall and
      # its boto3 config sets addressing_style=path for exactly this reason.
      "--etcd-s3-bucket-lookup-type=path"
      # S3 retention, NOT --etcd-snapshot-retention: the latter governs local
      # snapshot files, which do not exist when snapshots go to S3. Confirmed on
      # the host binary: `--etcd-s3-retention value (db) S3 retention limit`.
      "--etcd-s3-retention=24"
      # The embedded quotes are load-bearing. k3s.extraFlags is toString'd into a
      # single ExecStart string, so an unquoted cron is word-split by systemd into
      # `--etcd-snapshot-schedule-cron=0` plus three stray args and k3s exits.
      # Verified by evaluating ExecStart: the quotes survive and systemd's parser
      # keeps it as one argument.
      "--etcd-snapshot-schedule-cron=\"0 * * * *\""
```

Credentials come from the environment, not flags: `--etcd-s3-access-key` reads
`AWS_ACCESS_KEY_ID` and `--etcd-s3-secret-key` reads `AWS_SECRET_ACCESS_KEY`, which is
what the `EnvironmentFiles` wiring below supplies.

and in `hosts/titan/configuration.nix`:

```nix
  sops.secrets."titan/minio_env" = {
    mode = "0400";
    owner = "root";
  };
  systemd.services.k3s.serviceConfig.EnvironmentFiles = [
    config.sops.secrets."titan/minio_env".path
  ];
```

- [ ] **Step 3: Verify the flags and the credentials reach the service**

```bash
nix eval --raw .#nixosConfigurations.titan.config.services.k3s.extraFlags | tr ' ' '\n' | grep -E "etcd-s3|schedule-cron"
ssh -p 13491 nixos@titan.arrieta.eu 'systemctl show k3s -p EnvironmentFiles; journalctl -u k3s -g "snapshot" --no-pager | tail -5'
```
Expected: seven `--etcd-snapshot-*` flags; the env file path; a log line showing a successful snapshot upload.

- [ ] **Step 4: Stand up restic for PVs** as a CronJob in the GitOps repo (it needs the PVCs, so it belongs in-cluster, not in NixOS):

```yaml
# nightly snapshot of every k3s PV into MinIO, over the mesh.
# The PVs are on lv-pvc, so a host restore is: stop k3s, restic restore into
# /var/lib/rancher/k3s/storage, start k3s.
spec:
  schedule: "30 3 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: restic
              image: restic/restic:latest
              args: ["backup", "/pvc", "--exclude", "/pvc/**/lost+found"]
              envFrom:
                - secretRef: { name: titan-restic }   # RESTIC_REPOSITORY=s3:.../titan-pvc, RESTIC_PASSWORD, AWS_*
              volumeMounts:
                - { name: pvc, mountPath: /pvc }
          volumes:
            - name: pvc
              hostPath: { path: /var/lib/rancher/k3s/storage }
```

- [ ] **Step 5: Run the restore drill** on a scratch namespace, and time it. **This is destructive**: `--cluster-reset` rewrites the datastore, so run it before real workloads land, or schedule it as downtime.

```bash
ssh -p 13491 nixos@titan.arrieta.eu '
  kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml create ns drill \
  && kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n drill create configmap canary --from-literal=written=before
  k3s etcd-snapshot save --name pre-drill
'
```

Then restore, and confirm the canary survived. The manual `k3s server` run needs the same MinIO credentials the unit gets from `EnvironmentFiles`, so load them first:

```bash
ssh -p 13491 nixos@titan.arrieta.eu '
  systemctl stop k3s
  set -a; . /run/secrets/titan/minio_env; set +a
  k3s server --cluster-reset --cluster-reset-restore-path=s3://titan-etcd/titan/pre-drill
  systemctl start k3s
  kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n drill get configmap canary -o jsonpath="{.data.written}"
'
```
Expected: `before`, node `Ready`, and no CrashLoopBackOff fleet-wide. Then restore one PV file with `restic restore` and confirm the pod sees it.

- [ ] **Step 6: Record the drill** in `hosts/titan/README.md`: date, commands used, wall-clock time to restore, and anything that did not work first try. This is the exit criterion for v1 — do not mark v1 done on a snapshot that has only ever been written.

- [ ] **Step 7: Commit**

```bash
git add hosts/titan/vars.nix hosts/titan/configuration.nix hosts/titan/README.md secrets.yaml
git commit -m "feat(titan): etcd snapshots to S3, restic PV backups, restore drill

k3s' native --etcd-snapshot-s3 for etcd, a restic CronJob for PV data, both into
MinIO over the mesh. The MinIO key is scoped to the two buckets because an etcd
snapshot is every Secret in plaintext. Restore drill recorded in the host README
is the v1 exit criterion."
```

---

## Task 17: Give `titan` its own age key, scoped to `titan`'s secrets

SOPS encrypts a *data key* to every recipient, so anyone holding any recipient's
private key decrypts the **whole file**. "titan may only read titan's secrets" is
therefore impossible inside one file — it needs a second file with a narrower
recipient set. Task 14 bootstraps with the operator's admin key because that key
already exists; this task replaces it.

**Files:** create `secrets/titan.yaml`; edit `.sops.yaml`, `hosts/titan/configuration.nix`,
`modules/nixos/sops-base.nix`, `common/users.nix`; edit `secrets.yaml` (drop the moved keys).

- [x] **Step 1 — Decide what titan actually needs.** It declared eight secrets: the five
  titan keys, plus `users/javier_password_hash`, `ssh_keys/javier_private`,
  `ssh_keys/javier_public`. The two `javier_*` entries were the problem: they put
  javier's **personal SSH private key** on an internet-facing host — a lateral-movement
  path independent of `secrets.yaml`. Added `sopsBase.javierSshKey` and
  `sopsBase.javierPasswordHash` to `sops-base.nix` (both default `true`, so the fleet is
  unchanged) and set both `false` on titan; `common/users.nix` locks the account with
  `hashedPassword = "!"` when the hash is off. Verified by evaluation: titan now declares
  exactly its five keys, `hashedPasswordFile = null`, `hashedPassword = "!"`, while
  `k8s-node01` and `ryzen7` are byte-for-byte unchanged.
  Note `sops.secrets.<name> = lib.mkIf false {...}` does **not** work here — `sops.secrets`
  is an `attrsOf submodule` and the empty instance still materialises, then fails at build
  time. `lib.optionalAttrs` on the whole `secrets` set is the form that works.

- [x] **Step 2 — Generate the host key.** Done with `umask 077; age-keygen`. Public key
  `age1vrsm5d9a4gd7wugem8lskq93n5hc7yxvdms77a76xcrqu7eunylscvh48e`; the private half is at
  `~/.config/sops/age/titan-key.txt` (0600) on the Coder workspace and was never printed.
  Regenerating is cheap: run `age-keygen` again and replace the recipient in `.sops.yaml`
  before Step 4 runs — after Step 4 the file must be re-encrypted with `sops updatekeys`.

- [x] **Step 3 — Recipient rules.** `.sops.yaml` now has a `^secrets/titan\.yaml$` rule
  whose `key_groups` are the four admin recipients **plus the titan public key**, listed
  first. Correction to the reasoning written here earlier: the generic `secrets\.ya?ml$`
  rule is literal and does **not** match a path under `secrets/` (probed with a scratch
  file — sops reports "no rules matched"), so the new rule is required rather than an
  override, and ordering is hygiene, not correctness. The titan public key is deliberately
  absent from the `secrets.yaml` rule; adding it returns all the blast radius removed.

- [x] **Step 4 scripted, not run.** `scripts/titan-key-split.sh` moves the five values,
  re-encrypts `secrets.yaml` to its own recipients, and verifies by **path** (a grep for
  `network_env` is a false alarm — every host has one). Shaped around two sops realities:
  the creation rule is chosen from the path handed to sops, so encryption must happen in
  place (`sops -e -i`), and sops has no value-removal flag, so the strip goes through
  plaintext at the real path for a moment under `umask 077` with a trap that restores the
  encrypted backup on any non-clean exit. Tested end to end in a throwaway `git worktree`:
  recipients went 4 → 5 in `secrets/titan.yaml` and stayed 4 in `secrets.yaml`, and the
  re-run guard refuses when the destination exists.

- [ ] **Step 5 — Point the module at the new file.** In `hosts/titan/configuration.nix`,
  each of the five becomes
  `sops.secrets."titan/network_env" = { sopsFile = ../../secrets/titan.yaml; ... }`.

- [ ] **Step 6 — Swap the key on the host.** Copy the titan private key to
  `/var/lib/sops-nix/key.txt` (root:root, 0600) **after** `shred -u` the admin key that
  Task 14 left there. Then deploy and confirm all remaining secrets materialise:
  `ssh -p 13491 nixos@titan.arrieta.eu 'ls -l /run/secrets/titan /run/secrets/ssh_keys'`.

- [ ] **Step 7 — Prove the narrowing, not just the happy path.** From titan:
  ```bash
  sudo sops -d /etc/nixos/secrets.yaml >/dev/null; echo "exit=$?"
  ```
  This must **fail** with `Failed to get the data key ... group 0: FAILED`. A green
  decrypt here means the split did not happen and Step 6 only moved bytes around.

- [ ] **Step 8 — Commit** `secrets/titan.yaml`, `.sops.yaml`, and the module changes, and
  record the titan public key in the private companion doc.

---

## Exit criteria

v1 is done when all of these are true and each has a command behind it in the task that owns it:

- `nix build .#nixosConfigurations.titan.config.system.build.toplevel` succeeds with **no** escape hatch in its CI step (that tolerance is removed at the end of Task 12), and `titan` is in the `verify.yml` matrix.
- All twelve existing hosts evaluate with unchanged `firewall.enable`, `services.openssh.*`, `services.k3s.extraFlags`, `rsyslogd.extraConfig`, and home-manager package counts.
- titan runs: mdraid + LVM mounted, `lv-pvc` under `/var/lib/rancher/k3s/storage`, k3s `Ready`, Traefik + ServiceLB serving 80/443 with a `*.titan.arrieta.eu` certificate.
- Public probes: 13491/80/443/51820 reachable, 6443/9100/10250 unreachable from the internet, 6443 reachable from a static mesh peer and unreachable from a roadwarrior.
- Mesh at `192.168.133.0/24` with titan as hub, old hub retired, Prometheus scraping titan and rsyslog arriving at `192.168.0.41`.
- etcd snapshot and restic backup both landing, and one restore drill logged with a date.
- titan's `/var/lib/sops-nix/key.txt` decrypts `secrets/titan.yaml` and **fails** on
  `secrets.yaml` (Task 17 Step 7), and titan holds no copy of javier's personal SSH key.
- No credentials and no concrete public IPv4/IPv6 anywhere in the public repo (spec §0 greps clean).
