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
| Edge Network Firewall | nine rules below | ____ |
| Rescue mode SSH key (`rescueSshKey`) | ____ | ____ |
| Proactive maintenance / interventions | **ENABLED** (spec Q20) | 2026-10-02 |
| Boot mode | hard disk (must be restored after any rescue session) | ____ |
| Disk wear baseline (`nvme0n1` / `nvme1n1`) | ____ % / ____ % | ____ |

### Edge Network Firewall (IPv4, stateless, first match wins, priorities 0–19)

| prio | rule | why |
|---|---|---|
| 0 | Accept TCP established | the ENF is stateless; without this titan cannot `git fetch` or pull from Attic at all |
| 1 | Accept UDP src 53 | DNS replies |
| 2 | Accept ICMP | path MTU / diagnostics |
| 3 | Accept TCP dst 22 | rescue mode only — rescue sshd listens on 22 and has no host firewall. In normal operation nothing listens on 22, so this costs a scanner a `connection refused` |
| 4 | Accept TCP dst 13491 | SSH |
| 5 | Accept TCP dst 80 | ingress |
| 6 | Accept TCP dst 443 | ingress |
| 7 | Accept UDP dst 51820 | WireGuard |
| 19 | **Deny IPv4** | mandatory: an Accept-only set is a no-op and drops outbound TCP + DNS |

Two properties that bite: rules keep applying **during DDoS mitigation even when the
firewall reads "off"**, and the ENF **drops UDP fragments** — which is why the
WireGuard MTU stays at 1420.

## Bootstrap

From a workstation that can reach the rescue system, with the box in rescue mode
(Debian, your key installed):

```bash
cd ~/nixos-configurations
./bootstrap_host.sh --no-build-on-remote --host titan --ip <OVH_PUBLIC_IP> \
  --age-key '<age secret key line from ~/.config/sops/age/keys.txt>' \
  --disk-password throwaway
```

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
