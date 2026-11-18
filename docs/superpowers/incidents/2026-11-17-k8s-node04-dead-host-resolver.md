# Incident: k8s-node04 ran 17 hours with a dead host resolver (2026-11-17)

**Status:** fixed in `modules/nixos/static-network.nix` + `modules/nixos/k3s.nix` (PR #181)
**Owner:** Javier Arrieta
**Hosts affected:** `k8s-node04` (outage), `k8s-node02` (same crash load, not yet an outage)
**Blast radius of the fix:** all 9 hosts with a `network_env` secret; canary is `k8s-node05`

The module comments state the invariants. This file holds the narrative, the
measurements, and the alternatives that were considered and rejected -- so the
next reader does not re-derive them, and so a wrong claim in a `.nix` comment
has one place to be corrected instead of four.

## 1. Symptom

Nothing in the monitoring stack noticed. It surfaced only when kured's reboot wave
pushed `casa/nextcloud` onto node04 and the pod needed an image the node had
never cached:

```
Failed to create pod sandbox: failed to pull image "rancher/mirrored-pause:3.10.2":
  dial tcp: lookup registry-1.docker.io: no such host
```

The pod sat in `ContainerCreating`, `Service/nextcloud` had `<none>` endpoints,
Traefik answered 404 on `/status.php`, Gatus paged. Cluster DNS was never the
problem: bind9 (`192.168.0.41`) answered `registry-1.docker.io` with 8 records
and both endpoints Ready. `no such host` appeared in the k3s logs of **node04
only** -- 328 occurrences/24h, every other host 0.

## 2. Timeline (Loki, UTC)

| when | what |
|---|---|
| 11-17 14:36:19 | comin deploys generation `fe0a8939` (tip of `stable`, `0f59e3f`) via `switch-to-configuration` -- a switch, not a reboot |
| 14:36:20 | `Stopped resolvconf update`, `Stopped target Host and Network Name Lookups` |
| 14:36:46 | `dhcpcd.service: Main process exited, code=dumped, status=11/SEGV` -- restart counter at 6 |
| 14:37:05 | `dhcpcd.service: Deactivated successfully` |
| **14:41:37** | first `no such host` (comin cannot resolve `github.com`) -- continuous at 24/hour ever since |
| 11-18 05:55-07:08 | kured reboots 9 of 11 nodes; each gets a clean network bring-up and is fine |
| 07:07 | nextcloud lands on node04 -- the one node with dead DNS -- and cannot start |

k3s restarted at 14:36:36 with `Found left-over process ... (containerd-shim) ...
unclean termination of a previous run`, so the node kept serving workloads with a
broken `/etc/resolv.conf`. Nothing needed to resolve a name on that node for four
weeks, so it stayed invisible.

## 3. Defect 1 -- dhcpcd was claiming the pod network

nixpkgs' dhcpcd module only keeps dhcpcd off interfaces **NixOS itself declares**
(it builds `ignoredInterfaces` from `networking.interfaces`, bridges, sits and
bonds). k3s creates `flannel.1`, `cni0` and a fresh `veth` per pod sandbox behind
NixOS' back, so dhcpcd claimed each one: solicited a lease, got nothing, fell back
to IPv4LL, and then **installed a default route through the pod overlay**:

```
flannel.1: soliciting a DHCP lease
flannel.1: adding default route
flannel.1: using IPv4LL address 169.254.219.67
```

Upstream carries the same defect for Docker-created veths, route overwrite
included ([NetworkConfiguration/dhcpcd#531](https://github.com/NetworkConfiguration/dhcpcd/issues/531)).
The crash is the known one for container-runtime hosts: dhcpcd dies in
`ipv6nd_expire` under veth churn and systemd restarts it straight into the next
one. **Every pod sandbox makes more veths, so the workload feeds the loop.**

Measured 2026-11-18: 112 core dumps/24h on `k8s-node04`, 100 on `k8s-node02`,
nine hosts with dhcpcd on `flannel.1`.

Fix: `networking.dhcpcd.denyInterfaces` in `k3s.nix`, limited to the interfaces
k3s actually creates (`flannel.*`, `cni0`, `veth*`).

**The denial is proven to stop the lease solicitation. It is NOT proven to stop
the SEGV.** `denyinterfaces` keeps dhcpcd from configuring an interface; whether
it also stops the netlink churn that reaches `ipv6nd_expire` is an empirical
question. See §6 for the gate.

### Which hosts actually run a DHCP client

nixpkgs gates the unit on `dhcpcd.enable && (networking.useDHCP || any declared
interface with useDHCP = true)`. `networking.dhcpcd.enable` reads true on 16 of
the 17 configurations (only `wsl` is false), but **a dhcpcd unit exists on exactly
nine**: `k8s-node01..05`, `k8s-server01..03`, `titan` -- the same nine that showed
the crash loop. The Pi workers, the three `*-minimal` images and `llm01` have no
dhcpcd unit at all, so the deny list is inert there and `useDHCP = false` alone
would not have fixed anything.

Verified by evaluating `config.systemd.services ? dhcpcd` for all 17 hosts.

## 4. Defect 2 -- `/etc/resolv.conf` could be written invalid, silently

On the placeholder hosts `networking.nameservers` is skipped while the values are
still `"$DNS1"/"$DNS2"`, and a shell snippet in the activation script wrote the
file **once** from the SOPS `network_env`. Two silent failure modes:

- `[ -f "$envFile" ]` false -> the whole block is skipped, no message.
- empty `$DNS1`/`$DNS2` -> writes `nameserver ` twice. Invalid resolv.conf, every
  resolver on the host answers `no such host` for everything -- while pods,
  kubelet and syslog keep working on cached images and IP literals, so the node
  still looks healthy.

### What actually wiped the file on 2026-11-17

Not the activation snippet. `secrets.yaml` last changed 2026-11-03 and
`secrets/titan.yaml` 2026-10-13, both before the incident, and all nine
re-asserting hosts hold a plain bare IPv4 in `DNS1`/`DNS2` -- the empty-`$DNS1`
case has no candidate on this fleet.

The clobberer is **resolvconf**, from two directions, and the ordering is the
whole story:

- `networking.resolvconf.enable` is true on 16 of the 17 configurations (`wsl` is
  the only host without it, and it has no resolvconf unit).
- `resolvconf.service` is `Before = network-pre.target`, so at boot it runs
  `resolvconf -u` **after** the activation script and **before** the
  `network-runtime-config` oneshot that is `WantedBy = network.target`.
- `resolvconf -u` regenerates the file from `/run/resolvconf/interface/*` and
  drops every nameserver not registered through it. With the interface db empty
  it leaves `# Generated by resolvconf` plus `options edns0` and nothing else:
  zero nameservers, exit 0. Proved by running openresolv 3.17.4 against a
  bind-mounted `/etc` in a mount namespace.
- **The registry is empty because a registration is failing, not because nothing
  publishes.** nixpkgs publishes `networking.nameservers` itself: it renders
  `networking.localCommands` as `resolvconf -m 1 -a static`, run by
  `network-local-commands.service`. On the nine, that option is `mkIf`'d off --
  evaluated on `k8s-node04`, the heredoc it feeds is empty -- and once anything
  has rewritten `/etc/resolv.conf` out from under openresolv, the call refuses
  with `signature mismatch: /etc/resolv.conf` and exits 1 without ever writing
  `/run/resolvconf/interface/static`. Measured with openresolv 3.17.4 in a mount
  namespace. That is what the spot-check was really reading:
  `ls -A /run/resolvconf/interface/ | wc -l` is **0** on k8s-node01 because the
  one publisher on these hosts dies before it can register, not because there is
  no publisher. It also means `network-local-commands.service` has been failing
  at boot since the activation snippet first started rewriting the file.
- Which makes `network-local-commands.service` a second clobberer, and it is
  `WantedBy = network.target` with no ordering against `network-runtime-config`,
  so the restore and the wipe raced on every boot. `network-runtime-config` now
  orders after it, so the restore is last and the failing unit stops failing.
- dhcpcd's own `20-resolv.conf` hook takes the resolvconf path whenever
  `command -v resolvconf` succeeds, and the dhcpcd unit puts openresolv on `PATH`
  and hands the process the `resolvconf` group -- so every BOUND, REBIND or plain
  restart recomputes the file.

A boot survives by accident: activation writes the file, resolvconf wipes it
early, `network-local-commands.service` fails to re-register anything, and
`network-runtime-config` writes the nameservers back. A switch does **not** re-run
that oneshot, which is exactly why node04's dhcpcd SEGV storm, minutes after its
switch, left it dead for 17 hours.

## 5. The fix, and what it deliberately is not

- `writeResolvConf` validates before writing, writes atomically, and exits
  non-zero rather than emit an empty `nameserver` line. One usable address out of
  two is written and the dropped one is reported; both unusable is `exit 1`.
- Secrets are scrubbed of CR/LF **before** validation, not only in the message
  that reports them. A CRLF `network_env` used to make both nameservers invalid,
  so the script exited 1 having written nothing -- the outage this module exists
  to prevent, reached through a secret whose addresses were fine. Measured before
  the fix: `DNS1=192.168.0.1<CR>` gave exit 1 and left the file alone.
- The writer says what it discards. It asserts a `resolv.conf` of `nameserver`
  lines and nothing else, so a `search`, `domain`, `options` or `sortlist` line
  put there by anyone else is dropped -- and dropping it quietly is the same
  invisibility as the bug being fixed. It now reports the discarded lines once per
  rewrite, alongside the foreign-nameserver tripwire.
- The validator matches **glibc's `res_init` acceptance, not `inet_pton`**. That
  distinction matters: `192.168.0.01` and `1.2.3.045` are accepted here and glibc
  uses them as live servers (measured in a mount namespace), while `inet_pton`
  rejects both. Do not "tighten" the leading-zero case; it is not a bug.
- `network-route-watch` re-asserts `resolv.conf` every 10s for the same reason it
  re-asserts the route: both are runtime state nothing owns after activation, and
  the resolver half went unwatched. Diagnostics are edge-triggered -- printing on
  every failure would push ~17k lines/day into `/var/log/messages`, the watchdog
  failure mode already recorded in AGENTS.md (2026-08-27, k8s-node03).
- Both scripts are installed into the system environment and started as
  `/run/current-system/sw/bin/...`, not as generation-specific store paths. This
  is the health-gate ENOENT-after-GC incident (AGENTS.md 2026-08-29) avoided at
  the source: a unit whose `ExecStart` is a store path can end up pointing at a
  path nix-sweep collected, and the loss is silent.
- The writer treats a `/etc/resolv.conf` that carries nameservers from anywhere
  other than `network_env` as a second writer and says so once. wg-quick with a
  `DNS=` line, NetworkManager, or a VPN client that speaks resolvconf would all
  qualify.

Rejected, with reasons:

- **`networking.resolvconf.enable = false`** does not remove the clobberer.
  Without resolvconf, dhcpcd's hook falls through to writing `/etc/resolv.conf`
  itself (`change_file /etc/resolv.conf` then `chmod 644`).
- **`networking.dhcpcd.enable = false`** is now equivalent rather than risky --
  every declared interface on the nine is static and so ignored, `wg0` is ignored
  via `networking.wireguard.interfaces`, and the overlay is denied, so dhcpcd
  manages nothing. It deletes the crash source outright instead of fencing it in.
  It stays its own change with its own canary. Prove it with `dhcpcd --status`.
- **Publish through resolvconf instead of racing it.** Restated after review,
  because the first version of this bullet was wrong: this is not new machinery,
  it is machinery nixpkgs already runs. The `resolvconf -m 1 -a static` in
  `network-local-commands.service` *is* this registration, fed from
  `networking.nameservers`, and it is why the Pi workers are unaffected --
  evaluated on `k8s-pi01`, that heredoc carries `nameserver 1.1.1.1` and
  `nameserver 8.8.8.8`, so `resolvconf -u` has something to merge. On the nine it
  carries nothing. So the change is a `networking.localCommands` append feeding
  `$DNS1`/`$DNS2` into that same `static` interface, not new infrastructure.

  It is still not in this change, on two honest grounds rather than the size of
  the job: `/run` is cleared at boot, so the registration has to be re-done by
  whatever re-writes the file, and a switch does not re-run
  `network-local-commands.service` either -- so the watchdog is needed either way
  and this only closes one of the two races. It would restore `options edns0` for
  free. Its own change, its own canary; the watchdog then becomes a backstop
  rather than the mechanism.

## 6. Rollout gates

Merge to `main` -> canary `k8s-node05` -> verify -> promote to `stable`.

**Before** the switch, on each host:

```sh
dhcpcd --status          # must show no interface holding a real lease
```

This switch changes dhcpcd's `--config` path, so `switch-to-configuration`
restarts dhcpcd, and `networking.dhcpcd.persistent` is false -- dhcpcd
deconfigures everything it holds on exit. That restart is what clears the stale
`flannel.1` route, so it cannot be avoided; it just must not be a surprise.

After the switch, the dhcpcd half:

```sh
systemctl show dhcpcd -p ExecStart          # there is no /etc/dhcpcd.conf on NixOS
grep denyinterfaces <the --config path>
ip route show default                        # must not name flannel.1 or cni0
ip -4 addr show flannel.1                    # no 169.254.x/16 once dhcpcd has restarted
```

Read `ip route show default` **after** the dhcpcd restart, not before.

Three gates, because `deploy done` proves nothing about any of them:

1. **The crash loop is the pass/fail gate for defect 1**, not a metric:
   `ls /var/lib/systemd/coredump | wc -l` before and after (node04 was 112/24h,
   node02 100/24h) and `journalctl -u dhcpcd --since "-1h" | grep -c "soliciting
   a DHCP lease"` must go to 0. If the coredump count does not fall, the deny
   list fixed the route but not the SEGV, and the answer is
   `networking.dhcpcd.enable = false`.
2. **The watchdog must be alive**: `systemctl is-active network-route-watch`, and
   `journalctl -u network-route-watch` must be quiet. A `no usable nameserver in
   ...` line means the secret is the problem; silence plus working DNS means
   something was clobbering the file and the loop is catching it.
3. **`network-local-commands.service` must not be failing.** It has almost
   certainly been failing at every boot since the activation snippet started
   rewriting `/etc/resolv.conf` (§4), and this change is the first time anything
   orders against it:

   ```sh
   systemctl is-failed network-local-commands   # want: no
   journalctl -b -u network-local-commands      # "signature mismatch" = still racing
   ls -A /run/resolvconf/interface/             # empty = the registration never landed
   ```

   If it is still red after the switch, the ordering did not take and the boot
   restore is still racing the wipe.

## 7. Not covered here

- **node04 does not recover from this change alone.** It needs its reboot (already
  flagged `Reboot required`) or a manual resolv restore.
- **Nothing probes host DNS.** Detection still depends on something failing
  loudly, which is what made this a 17-hour incident. A textfile-metric timer
  resolving one name, following the existing `comin-pending-metric` pattern,
  would close that gap. A `systemctl is-active network-route-watch` check in the
  comin health gate belongs in the same change, not folded into a DNS fix: the
  gate rolls a host back when a check fails.
- `k8s-node02` has the same dhcpcd crash load **and** `DiskPressure=True`
  (10.3 GiB free on `/`, the tightest in the cluster).
- The writer asserts a `resolv.conf` of `nameserver` lines and nothing else, so
  `networking.resolvconf.dnsExtensionMechanism` (default true -> `options edns0`)
  is defeated on the nine re-asserting hosts. Pre-existing; publishing through
  resolvconf (§5) is the fix. It is at least no longer silent -- the writer names
  the lines it discards, so `options edns0` disappearing shows up in the journal
  once per rewrite.
