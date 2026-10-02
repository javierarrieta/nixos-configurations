# titan

OVH bare metal, standalone single-node k3s cluster. Public ingress on 80/443,
key-only SSH on **13491**, WireGuard hub for the management plane, comin GitOps on
the `main` canary ring.

Design: `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md`
Runbook: `docs/superpowers/plans/2026-10-01-titan-ovh-single-node-k3s.md` (Tasks 12–16)

> **Never put the concrete public IPv4 in this file or in any committed file.** The
> repo is public. Concrete addressing lives in
> `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.private.md`
> (gitignored). Below, `<OVH_PUBLIC_IP>` means that value.

## OVH panel state

Record what the panel is actually set to, with a date. These are inputs to recovery,
not discoveries to make during an incident.

| setting | value | date |
|---|---|---|
| Reverse DNS `<OVH_PUBLIC_IP>` → `titan.arrieta.eu` | ____ | ____ |
| Edge Network Firewall | nine rules below, applied | 2026-10-02 |
| Rescue mode SSH key (`rescueSshKey`) | ____ | ____ |
| Proactive maintenance / interventions | **ENABLED** (spec Q20) | 2026-10-02 |
| Boot mode | hard disk (must be restored after any rescue session) | ____ |
| Disk wear baseline (`nvme0n1` / `nvme1n1`) | 2 % / 22 % used; 37 TB / 509 TB written; spare 98 % both | 2026-10-01 |

`nvme1n1` is the one to watch: 22 % endurance used and 509 TB written against 2 % /
37 TB on `nvme0n1`. That asymmetry is why the ESP lives on `nvme0n1`
(`pci-0000:02:00.0`). Re-read with
`smartctl -a /dev/nvme0 | grep -iE "percentage_used|available_spare|data_units_written|media_errors"`
— the numbers that matter are `Available Spare` approaching its 10 % threshold and any
non-zero `Media and Data Integrity Errors`; `Percentage Used` above 100 means past rated
endurance, not dead.

### Edge Network Firewall (IPv4, stateless, first match wins, priorities 0–19)

Panel path: **Network → Public IP addresses → `⁝` on the IPv4 → Configure Edge Network
Firewall**. It is per IP (IPv4 only), 20 rules max, lowest priority evaluated first, chain
stops at the first match.

| prio | rule | why |
|---|---|---|
| 0 | Accept TCP, TCP state = established, **Fragments unticked** | the ENF is stateless; without this titan cannot `git fetch` or pull from Attic at all |
| 1 | Accept UDP, **source port 53** | DNS replies. There is no state field on UDP rules — the source port is the only handle |
| 2 | Accept ICMP | path MTU / diagnostics |
| 3 | Accept TCP dst 22 | rescue mode only — rescue sshd listens on 22 and has no host firewall. In normal operation nothing listens on 22, so this costs a scanner a `connection refused` |
| 4 | Accept TCP dst 13491 | SSH |
| 5 | Accept TCP dst 80 | ingress |
| 6 | Accept TCP dst 443 | ingress |
| 7 | Accept UDP dst 51820 | WireGuard |
| 19 | **Deny IPv4** | mandatory. OVH warn in terms: a set of Accept rules only is "not effective at all" — the default when nothing matches is accept |

Panel fields worth knowing before you touch it: `TCP state` and `Fragments` exist **only on
TCP rules**. Leave `Fragments` unticked on rule 0 — ticking it widens an Accept to
fragmented TCP, which is the classic stateless-port-matching evasion, and leaving it off
means TCP fragments fall through to the deny. UDP fragments are dropped by the ENF
regardless of any rule.

Properties of this firewall that bite:

- **Rules apply during DDoS mitigation even when the firewall reads "off".** The ENF is
  force-enabled when the scrubbing centre engages. OVH's own warning: if you disable the
  firewall, *delete the rules too*.
- **UDP fragments are dropped by default.** This is why the WireGuard MTU stays at 1420.
- **QUIC is not supported.** HTTP/3 on Traefik (UDP 443) will not traverse this; if it is
  ever enabled, expect it to fail here and not on the host.
- **The ENF cannot open ports on the server** — it can only drop. The OS firewall in
  `public-host.nix` is still what allows anything, and it is the wall this design actually
  relies on.
- Availability is not guaranteed on the **Eco** product line (Rise / So you Start /
  Kimsufi); this host does expose the configuration page.

Proof the deny is actually in force, from outside: a closed port must **time out**, not
return `connection refused`. Refused means the packet reached the box, i.e. no deny rule
applied.

Source: <https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/firewall-network>

## Bootstrap

From a workstation that can reach the rescue system, with the box in rescue mode
(Debian, your key installed):

```bash
cd ~/nixos-configurations
./bootstrap_host.sh --no-build-on-remote --host titan --ip <OVH_PUBLIC_IP> \
  --age-key "$(cat ~/.config/sops/age/keys.txt)" \
  --disk-password throwaway
```

- **The age key here is an *admin* key, not titan's own host key.** Until Task 17 Step 4
  runs, titan's five secrets live in `secrets.yaml`, whose recipients are the four admin
  keys only -- titan's key is deliberately not one of them, so passing it here fails
  activation with `Failed to get the data key ... group 0: FAILED`. Task 17 Step 6 is the
  point where `/var/lib/sops-nix/key.txt` becomes the titan-scoped key and the admin key
  is shredded. Check which key you are holding with `age-keygen -y <file>` and compare
  against the `sops.key_groups` footer of the file it has to open. Reading it with `$(cat
  ...)` rather than pasting keeps it out of your shell history.
- `--no-build-on-remote` is required. The Attic cache is reachable only over the
  mesh, which does not exist yet, so the build happens on the workstation and ships
  its closure over SSH.
- `--disk-password` is **unused**: root is not encrypted in v1 (spec D9, LUKS +
  initrd SSH unlock deferred). The script requires the argument, so pass something
  throwaway.
- Rescue-mode SSH is port **22**. Do not pass `--ssh-port`.
- Keep the OVH **IP-KVM** session open for the whole run: the first boot is where an
  mdraid/LVM initrd mistake shows up.

### First boot — verify over the public path only

The mesh does not exist yet, so everything here goes over the WAN.

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

- `findmnt` under `/var/lib/rancher/k3s/storage` must show `lv-pvc`. **If it shows
  `/dev/mapper/vg0-root`, stop** — PV data is landing on `/`.
- `kubectl get node -o wide` `INTERNAL-IP` should be `<OVH_PUBLIC_IP>`. A `10.62.x`
  address means flannel grabbed the wrong interface.

### Prove the firewall denies

```bash
nc -zvw3 titan.arrieta.eu 13491   # succeeded
nc -zvw3 titan.arrieta.eu 80      # succeeded
nc -zvw3 titan.arrieta.eu 6443    # timeout  <- DROP, not refused
nc -zvw3 titan.arrieta.eu 9100    # timeout
nc -zuvw3 titan.arrieta.eu 51820  # succeeded
```

A **timeout** is the DROP working; a *refused* would mean something is listening.

### comin

```bash
ssh -p 13491 nixos@titan.arrieta.eu \
  'comin status --json | jq "{deployer: .deployer.deployment.status, suspended: .is_suspended, deployer_suspended: .deployer.is_suspended}"'
tail -3 /var/log/comin-health-gate.log
```

Expect `done`, both suspension flags `false`, and a recent `health gate OK`.

## Break-glass ladder

In order. SSH never depends on WireGuard, so "WG is down" is not a lockout — it
degrades Prometheus, Attic and rsyslog only.

1. `ssh -p 13491 javier@<OVH_PUBLIC_IP>` — the primary path, not the emergency one.
2. Box up but config broken: `nixos-rebuild switch --rollback` over that session, or
   boot the previous systemd-boot entry from the panel KVM
   (`boot.loader.systemd-boot.configurationLimit = 5` keeps rollback entries on disk).
3. WG down and you need a home-side thing (Prometheus, Attic, rsyslog): nothing
   breaks the box; those just go stale.
4. Box won't boot: OVH **rescue mode** → mount the root FS → chroot →
   `nixos-rebuild switch` from `/run/current-system`, or re-run nixos-anywhere.
   This step needs ENF rule 3 (TCP 22).
5. Network config wrong and SSH unreachable: OVH **IP-KVM** to see the console.
6. OVH panel firewall to cut inbound while a bad rule is live.

## Recovery commands

```bash
# If /var/lib/sops-nix/key.txt is gone or wrong, the host can no longer deploy:
# every sops secret fails to materialise, so activation fails. It lives in /var/lib,
# not the store, so it survives rebuilds and GC — losing it means losing /var/lib or
# overwriting it by hand. Once Task 17 has landed, restore with the TITAN key; an admin
# key also works but re-widens the blast radius until it is swapped back. Either way:
# root:root, 0600, then re-run the switch.
sudo install -m 0600 -o root -g root /path/to/keys.txt /var/lib/sops-nix/key.txt

# Route watchdog around any build/switch (fresh worker switches can drop the
# default route mid-activation). Absolute paths for BOTH commands: a loop whose
# `sleep` is missing from PATH becomes a 200-spawn/sec flood into rsyslog.
sudo systemd-run --unit=routewatch --collect bash -c \
  'while true; do /run/current-system/sw/bin/ip route replace default via <OVH_GATEWAY> dev eth0; /run/current-system/sw/bin/sleep 10; done'
sudo systemctl stop routewatch        # when settled

# comin stuck after a health-gate suspend + daemon restart (comin issue #159):
# the deployer restores isSuspended=true but the manager does not, so `resume`
# alone fails. Suspend first to sync the manager, then resume.
comin suspend && comin resume

# Storage
cat /proc/mdstat
sudo mdadm --detail /dev/md/titan
sudo lvdisplay vg0
```

## After any OVH intervention

Proactive maintenance is enabled, so an unannounced reboot is a real event, not an
exotic one. Check, in order:

1. Panel boot mode is back to **boot from hard disk**.
2. `mdadm --detail /dev/md/titan` shows both spares rebuilt.
3. `wg show` handshakes are fresh.
4. `systemctl is-active k3s` and etcd healthy.
5. The nine ENF rules are still present.

Residual accepted risk: a single node has no redundancy, so an intervention is a
full outage. Mitigated by the health gate and the rollback entry, not by failover.

Second residual risk, until Task 17 lands: titan's age key is the **repo-wide admin
key**, so a popped titan can decrypt all of `secrets.yaml` — every host's SSH host
key, the k3s tokens, the object-store credentials. The firewalls limit exposure, not
blast radius. Task 17 replaces it with a titan-only key that decrypts only
`secrets/titan.yaml`.
