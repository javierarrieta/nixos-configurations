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
- `resolvconf -u` regenerates the file from the key directory -- **
  `/run/resolvconf/keys/`**, which is openresolv's `KEYDIR` under `VARDIR =
  /run/resolvconf` (`pkgs/by-name/op/openresolv/package.nix`), with a compat
  fallback to `interfaces`, plural -- and drops every nameserver not registered
  through it. With the key directory empty it leaves `# Generated by resolvconf`
  plus `options edns0` and nothing else: zero nameservers, exit 0. Proved by
  running openresolv 3.17.4 against a bind-mounted `/etc` in a mount namespace.

  > **Path correction, round 6.** Every earlier version of this document, and the
  > spot-check it leaned on, said `/run/resolvconf/interface` (singular). That
  > directory does not exist. `ls -A /run/resolvconf/interface/ | wc -l` returns
  > `0` because `ls` fails, not because the registry is empty -- the reading was
  > void, and it is the only reason this section claimed the registry was empty
  > rather than holding one empty key. Re-measure with `ls -A
  > /run/resolvconf/keys/`. What follows is read from the openresolv 3.17.4
  > source and has **not** been re-measured on a host.
- **The one publisher on these hosts registers an empty key, and its subscriber
  is what fails -- not the registration.** nixpkgs publishes
  `networking.nameservers` itself: it renders `networking.localCommands` as
  `resolvconf -m 1 -a static`, run by `network-local-commands.service`. On the
  nine, that option is `mkIf`'d off -- evaluated on `k8s-node04`, the heredoc it
  feeds is empty. `resolvconf` writes the key `keys/static` *before* it runs any
  subscriber, so the key lands either way; the `exit 1` and the
  `signature mismatch: /etc/resolv.conf` come afterwards from the `libc`
  subscriber, which refuses to append to a file whose first line is not
  `# Generated by resolvconf` -- a check it skips entirely for `-u`, which
  instead copies the foreign file to `/etc/resolv.conf.bak`. So the refusal
  protects the file from a regeneration that would drop these nameservers again;
  it does not stop the registration.
- Which makes `network-local-commands.service` a second clobberer, and it is
  `WantedBy = network.target` with no ordering against `network-runtime-config`,
  so the restore and the wipe raced on every boot. `network-runtime-config` now
  orders after it, so the restore is last. That also settles the unit's colour,
  which is not what an earlier draft of this section claimed: activation runs in
  stage 2, before any unit, and `resolvconf.service` is `before =
  network-pre.target` while `network-local-commands` is `after =
  network-pre.target`, so `-u` re-signs the file before `-a static` ever runs.
  Absent an interleaving restore, `-a static` sees a signed file whose content
  already matches what it would write and exits 0 early. The unit was red only
  when `network-runtime-config` won the race -- which is exactly what the new
  `After=` removes.
- dhcpcd's own `20-resolv.conf` hook takes the resolvconf path whenever
  `command -v resolvconf` succeeds, and the dhcpcd unit puts openresolv on `PATH`
  and hands the process the `resolvconf` group -- so every BOUND, REBIND or plain
  restart recomputes the file.

A boot survives by accident: activation writes the file, resolvconf wipes it
early, `network-local-commands.service` regenerates the same empty stub, and
`network-runtime-config` writes the nameservers back. A switch does **not** re-run
that oneshot, which is exactly why node04's dhcpcd SEGV storm, minutes after its
switch, left it dead for 17 hours.

One side effect of that ordering, so it is not mistaken for a break later:
because activation writes an unsigned `resolv.conf` and `resolvconf -u` runs
after it, the `libc` subscriber copies it to **`/etc/resolv.conf.bak`** on every
boot. A root-owned `/etc/resolv.conf.bak` holding the last two nameservers is
this design working, not a leftover.

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
  the resolver half went unwatched.
- Diagnostics are edge-triggered -- printing on every failure would push ~17k
  lines/day into `/var/log/messages`, the watchdog failure mode already recorded
  in AGENTS.md (2026-08-27, k8s-node03). That edge-triggering only protects
  messages the loop itself produces. Its own `source` of `network_env` was outside
  it, and bash prints parse errors for a sourced file: a secret line written
  `DNS1= 192.168.0.1` (space after `=`) makes bash try to *run* the value, so the
  unit logged `192.168.0.1: command not found` once a tick. Measured in a sandbox:
  10 lines in 2s at the test interval, ~8.6k/day at the real one, which is the
  same flood AGENTS.md records from the other direction. The loop's `source` now
  sends stderr to the floor; nothing is hidden, because a gateway the source
  failed to set is reported by the edge-triggered `no_gw` branch and the writer
  re-reads the same file and reports its own parse errors through `$msg`.
- The writer call in the loop is bounded by `timeout 5`. The route half and the
  resolver half share one loop, so a writer that blocks -- hung `/etc`, stuck
  filesystem -- would also stop the default-route self-heal, and a loop that never
  finishes a tick logs nothing at all: the silence this change exists to end. With
  a bound the route half keeps ticking and the hang becomes a journal line naming
  the writer, rather than an empty message that reads like a resolver fault.
- `network-runtime-config` is `Before=network-online.target` and wanted by it.
  `WantedBy=network.target` alone makes nothing wait for the restore: `network.target`
  activates without it, and `k3s.service` is `After=network-online.target`, so
  containerd could reach the network barrier while `/etc/resolv.conf` was still
  the zero-nameserver stub `resolvconf.service` had just written. Same failure mode
  as §4, bounded by a boot instead of by 17 hours. `network-online.target` is
  `After=network.target` in systemd's own unit, so this adds an edge and no cycle.
- Both scripts are installed into the system environment and started as
  `/run/current-system/sw/bin/...`, not as generation-specific store paths. This
  is the health-gate ENOENT-after-GC incident (AGENTS.md 2026-08-29) avoided at
  the source: a unit whose `ExecStart` is a store path can end up pointing at a
  path nix-sweep collected, and the loss is silent. The activation script is the
  one caller that must use the store path instead, and it must reach for
  `lib.getExe`: a `writeShellScriptBin` derivation coerces to `$out`, which is a
  **directory**, and the script lives at `$out/bin/<name>`. Interpolating the
  derivation renders a store path that looks exactly right in the eval and does
  nothing at runtime -- see gate 4.
- The writer treats a `/etc/resolv.conf` that carries nameservers from anywhere
  other than `network_env` as a second writer and says so once. wg-quick with a
  `DNS=` line, NetworkManager, or a VPN client that speaks resolvconf would all
  qualify. The comparison is against scrubbed addresses: a CRLF file holds the
  same servers with a trailing `\r`, and comparing raw reported them as foreign --
  a tripwire that fires on a file it is describing is a tripwire nobody believes
  when it fires for real.
- Three smaller writer tightenings, all of them the same "do not create the thing
  you are about to report as unchanged" rule the temp-file guard came from:
  `0.0.0.0` and `255.255.255.255` are refused (four well-formed octets is not the
  same as a resolver that answers); `DNS1 == DNS2` writes one nameserver and says
  it is a duplicate rather than a dropped entry, because glibc would send every
  retry to the same box; and the mode re-assert on the unchanged path is guarded
  on the mode actually being wrong, since `chmod` bumps ctime every tick for a file
  that never moved.

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

**Do not debug this by hand with `dhcpcd -d <iface>`.** A manual invocation carries none
of the `denyInterfaces` from `modules/nixos/k3s.nix`, because those live only in the
generated `--config` file that the unit's `ExecStart` names. So running dhcpcd against
`flannel.1` or `cni0` by hand reproduces the exact crash this section is about, on a
host whose shipped configuration is correct -- which reads like a regression in the fix
when it is only the missing config. If a foreground dhcpcd is genuinely needed, pass it
the same `--config` the unit uses.

Five gates, because `deploy done` proves nothing about any of them:

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
3. **`network-local-commands.service` must not be failing.** It goes red when
   `network-runtime-config` lands between `resolvconf -u` and `resolvconf -a
   static`, because the subscriber then refuses the unsigned file (§4), and this
   change is the first time anything orders the two:

   ```sh
   systemctl is-failed network-local-commands   # want: no
   journalctl -b -u network-local-commands      # "signature mismatch" = still racing
   ls -A /run/resolvconf/keys/                  # want: a `static` key (empty is fine)
   ```

   If it is still red after the switch, the ordering did not take and the boot
   restore is still racing the wipe. Note the directory is `keys`, not the
   `interface` an earlier draft of this gate named -- that path does not exist and
   `ls` on it fails with a clean `0` on stdout.
4. **The activation write must actually have run.** It is the one caller that
   cannot go through `/run/current-system/sw/bin` (activation runs before that
   symlink is repointed), and the first cut of it interpolated a
   `writeShellScriptBin` derivation, which is a directory, so it failed into its
   own `|| echo` on every activation of all nine hosts. The switch output must be
   clean of it:

   ```sh
   # in the comin deploy log, or the nixos-rebuild output
   grep -F "could not re-assert /etc/resolv.conf during activation" <switch log>
   ```

   Silence is the pass. If it prints, the resolver was not written at activation
   and only the <=10 s watchdog tick is holding it up.
5. **The boot barrier only proves itself on a reboot.** A switch does not re-run
   `network-runtime-config`, so nothing short of a boot shows whether k3s now waits
   for the resolver restore instead of racing it (§5):

   ```sh
   systemctl show network-runtime-config -p ExecMainExitTimestamp
   systemctl show k3s -p ExecMainStartTimestamp
   systemd-analyze critical-chain k3s.service
   ```

   The restore's exit must precede k3s's start, and
   `journalctl -b -u network-runtime-config` must be clean. If k3s still starts
   first, the barrier did not take and the boot window is still open. node04 was
   the host checked, on its 2026-11-19 14:53:33 reboot; result in §8.

## 7. Not covered here

- **node04 needed a boot to recover, and got one at 2026-11-18 07:46** -- before
  this change even merged. It recovered exactly as §4 predicted a boot would: 1466
  `no such host` lines in the 48 h before that boot, zero after. Nothing has owed a
  reboot since (`nixos_reboot_required` is 0 on all thirteen hosts), which is why
  gate 5 sat unverified until a reboot was done deliberately for it (§8).
- **Nothing probes host DNS.** Detection still depends on something failing
  loudly, which is what made this a 17-hour incident. A textfile-metric timer
  resolving one name, following the existing `comin-pending-metric` pattern,
  would close that gap. A `systemctl is-active network-route-watch` check in the
  comin health gate belongs in the same change, not folded into a DNS fix: the
  gate rolls a host back when a check fails.
- `k8s-node02` is written up above as carrying the same dhcpcd crash load. Its 24 h
  baseline immediately before its 2026-11-19 deploy was 18 dhcpcd lines, 0
  coredumps and zero `no such host`, so whatever it was doing in mid-November had
  stopped by then; the two counts were taken differently (§8) and the disagreement
  is unresolved rather than refuted. The `DiskPressure=True` half (10.3 GiB free on
  `/`, the tightest in the cluster) is unchanged and still worth attention.
- The writer asserts a `resolv.conf` of `nameserver` lines and nothing else, so
  `networking.resolvconf.dnsExtensionMechanism` (default true -> `options edns0`)
  is defeated on the nine re-asserting hosts. Pre-existing; publishing through
  resolvconf (§5) is the fix. It is at least no longer silent -- the writer names
  the lines it discards, so `options edns0` disappearing shows up in the journal
  once per rewrite.

## 8. Rollout results (2026-11-19)

Everything in this section was read from Loki, Prometheus and `kubectl`. The
workspace that watched the rollout has no SSH to the fleet, so anything that needs
a shell on a host says so instead of claiming a result.

`main` -> `stable` was a fast-forward to `e0b1000`, carrying #181 (this fix), #182
(an unrelated Pi refactor) and #183 (a side finding, below). It was fast-forwarded
again to `70d12dd` later the same day to carry #185, the dhcpcd boot-wait fix below.

| host | switched | how |
|---|---|---|
| titan | 08:59:53 | canary, auto |
| k8s-node05 | 09:04:11 | canary, auto |
| llm01 | skipped | `out path ... has already been deployed` -- correct, its toplevel did not change |
| k8s-node01 | 12:34:37 | fleet, manual accept |
| k8s-node02 | 12:38:40 | fleet, manual accept |
| k8s-node03 | 14:06:02 | fleet, manual accept |
| k8s-node04 | 14:11:18 | fleet, manual accept; rebooted 14:53:33 for gate 5 |

### Gate 1 -- the crash loop: pass, on node04 only

node04 is the only host that ever had the pathology, so it is the only host where
this gate carries information. Matched five-minute windows of raw log lines, the
after-window starting two minutes past the switch so the switch minute cannot leak
into it:

| signal | 5 min before | 5 min after |
|---|---|---|
| dhcpcd log lines | 15 (177/h) | 0 |
| coredumps | 2 (24/h) | 0 |
| lease solicitations | 276 (3261/h) | 0 |

Across the six hours before the switch: 201 dhcpcd lines/h, 26 coredumps/h, 3360
lease solicitations/h. At that rate the after-window should have held ~272 lease
solicitations and held none. The cold boot at 14:53:33 was clean too -- dhcpcd's
unit started (`Started DHCP Client.`) and emitted nothing at all, which is the
point: denied the overlay it has no interface to work on, and that survives a boot
rather than only a `switch`.

The four other fleet hosts could not demonstrate this and should not be counted as
passing it. Their 24 h baselines before their own deploys were 18 dhcpcd lines and
0-2 coredumps with zero `no such host` -- they never had the crash loop, so zero
after is not evidence of anything.

### Gates 3 and 4 -- pass

Zero `signature mismatch`, zero failed units, and zero
`could not re-assert /etc/resolv.conf during activation` across all six hosts that
switched and across node04's reboot. Gate 3 was the one most likely to go red, since
it is the first ordering that has ever existed between `resolvconf -u` and
`resolvconf -a static`.

### Gate 5 -- the boot barrier: pass, with a caveat that matters

On node04 after the reboot, monotonic microseconds from the host:

| | |
|---|---|
| `network-runtime-config` start | 8.253 s |
| `network-runtime-config` exit | 8.303 s (ran 50 ms) |
| `network-online.target` reached | 33.367 s |
| `k3s.service` start | 38.301 s |

The restore finished half a minute before k3s started, and `critical-chain` confirms
`network-online.target` sits on k3s's dependency path, which is the edge the fix
added. What this does **not** establish is that the barrier was the binding
constraint: dhcpcd's own 30 s timeout put `network-online.target` at 33.367 s
regardless, so the barrier was handed ~30 s of slack. Showing necessity would need a
host with the barrier and the deny list removed, which is not something to do to a
production node. Recorded so nobody over-reads the green.

**This caveat is retired by §8's dhcpcd fix.** Once `wait = "background"` landed and
node04 rebooted at 20:38:07, the chain has nothing left between the barrier and
`network-online.target`:

```
network-online.target                @3.198s
  └─network.target                   @3.198s
    └─network-runtime-config.service @3.154s +43ms
      └─network-addresses-enp2s0.service @2.879s +272ms
```

The barrier exits at 3.197 s and `network-online.target` completes at 3.198 s -- one
millisecond later. The barrier is now the only thing gating it, so it is visibly
load-bearing rather than hidden behind a 30 s timeout. Still not a direct test of the
no-barrier case, but the slack is gone: remove the barrier and `network-online.target`
fires before the writer has run. The whole fix for this incident's class costs 43 ms of
boot.

### Gate 2 -- not demonstrable

No host still holds the bad state, so the positive branch of this gate cannot be
exercised anywhere. What exists is the negative: the writer ran on six hosts and
never emitted the fail-loud warning, and no `static-network:` watchdog line appeared
on any of them. `systemctl is-active network-route-watch` still needs someone with a
shell.

### Follow-up, diagnosed and fixed: dhcpcd costs ~30 s of every boot on the nine placeholder hosts

`systemd-analyze critical-chain k3s.service` on node04 after the reboot:

```
k3s.service +24ms
└─network-online.target @33.367s
  └─dhcpcd.service @3.012s +30.352s
```

dhcpcd runs, cannot get a lease on a statically configured interface, times out after
30 s, and `network-online.target` waits for it. That framing was close but not
right -- see the next subsection for the actual mechanism, which is that dhcpcd
manages no interface at all. What is measured and stands: this is **not** a
regression from `denyInterfaces`. node01 booted with 33.890 s of userspace on
2026-11-18 and node02 with 33.433 s, both before this change existed, against
node04's 33.541 s after it. It has been there the whole time.

Since dhcpcd now does nothing useful on these nine hosts and caused this incident,
`networking.dhcpcd.enable = false` deserves weighing on its own merits -- it would
cut ~30 s from every boot and delete the crash-loop class outright instead of fencing
it. Deliberately not folded into this change: it is a different decision from the one
#181 carried, and it needs a look at whether anything else expects a DHCP client.

### Resolved the same day: why a host with no DHCP waits 30 s anyway

The subsection above left the cause open -- "why does DHCP wait 30 s on a host that
does not use DHCP" had been unanswered since provisioning. It is a nixpkgs default
interacting with the fact that these hosts configure their addresses out of band.
Four links, each checked against the pinned nixpkgs and a live eval of node04:

1. **`networking.dhcpcd.wait` defaults to `"any"`** (`dhcpcd.nix:252`), and the module
   turns that value into the line `waitip` in the generated `dhcpcd.conf`
   (`dhcpcd.nix:98-108`). `waitip` means *do not fork to background until an address
   has been assigned*.
2. **`ExecStart` carries no `-b`** (`dhcpcd.nix:331`, confirmed by eval: `dhcpcd
   --quiet --config ...`), so whether dhcpcd backgrounds is decided entirely by that
   line. The unit is `Type = "forking"` (`dhcpcd.nix:312`), so systemd considers it
   started only once the parent forks.
3. **The condition is unsatisfiable by construction.** Every declared interface here
   is static, which puts it in `denyinterfaces` via `dhcpcd.nix:29-31`; `wg0` is
   ignored; the overlay is denied by §3 above. dhcpcd manages nothing, so `waitip`
   can never be met. It is not slow, it is impossible.
4. **dhcpcd's give-up timer is 30 s.** From `dhcpcd.conf(5)`, `timeout seconds`:
   "Time out after seconds, instead of the default 30 ... otherwise dhcpcd will fork
   into the background." It sits in the foreground for exactly that, logs the bare
   `timed out` visible in the boot journal, forks, and only then does
   `network-online.target` complete -- which k3s is `After=`.

So the host is not waiting for configuration it needs. It is waiting on a condition
that cannot be met, and 30 s is just how long it is willing to wait before giving up.
It would pay this with no interfaces at all, which is why "the host does not use DHCP"
never explained it on its own.

Known upstream papercut: nixpkgs issue #50930 and PR #58526 exist because `wait` had
no non-blocking mode, and `background` was added as the escape hatch.

Fixed by `networking.dhcpcd.wait = "background"` in `modules/nixos/k3s.nix`, which
reaches exactly the nine hosts that have the unit. Chosen over `enable = false`
because it needs no proof about what dhcpcd ends up managing and keeps the deny list
meaningful; once `dhcpcd --status` confirms nothing is managed on a live host,
`enable = false` should replace it rather than sit alongside it. `wait =
"if-carrier-up"` is not a fix -- it behaves like `any` whenever ethernet has carrier,
which it does on all nine.

What is proven from here, and what is not: the option flips to `background` on all
nine hosts and on none of the eight that have no unit, and node04's generated
`dhcpcd.conf` store path changes with `wait` as the only changed input. The
`waitip` -> `background` line itself is derived from `dhcpcd.nix:101-102` rather than
read directly, because the module exposes the conf only through `ExecStart`.

### Confirmed on node04: 33.4 s of userspace becomes 3.8 s

node04 rebooted at 20:38:07 with the fix live. `systemd-analyze` on the host:

| | before (20:09:23 boot) | after (20:38:07 boot) | delta |
|---|---|---|---|
| userspace | 33.393 s | **3.771 s** | **-29.6 s** |
| `network-online.target` | 33.367 s | 3.198 s | -30.2 s |
| `dhcpcd.service` on the critical chain | `@3.012s +30.352s` | **absent** | gone |

The prediction was ~3.5 s against a measured 3.771 s, so the diagnosis holds: the
entire 30 s was the unsatisfiable `waitip` timing out, on nine hosts, on every boot,
since provisioning. `multi-user.target` now also arrives at 3.771 s, i.e. nothing else
on the boot path was waiting on dhcpcd.

One caveat on how this was measured: the boot journal for this boot never reached Loki
(see below), so these numbers come from `systemd-analyze` run on the host, not from
the log pipeline the earlier gates used.

### Side finding: the boot journal for the verified reboot never reached Loki

The 14:53:33 and 20:09:23 boots are both fully queryable in Loki, each arriving as one
flush stamped ~40 s after boot start -- rsyslog's queue draining once the network came
up. The 20:38:07 boot produced **nothing**: no `Startup finished` summary, no `Started
DHCP Client.`, no `Reached target Network is Online.`, while node04 streamed normally
from ~20:39 onward. The pipeline was healthy before and after, so this is not an
outage.

The likely cause is Loki rejecting the early-boot entries as out-of-bounds, because
they carry pre-NTP timestamps and arrived much later than the ~40 s flush of the two
earlier boots. Not proven from here, and it matters: the boot journal is the evidence
base for every boot-path gate in this document, and it silently went missing for the
one reboot that would have verified the fix from the console-free side. Anyone
verifying a boot change remotely should plan on `systemd-analyze` on the host, not on
Loki, and should confirm the boot journal arrived before trusting its absence.

Worth a follow-up outside this incident: check the rsyslog omfwd queue and Loki's
acceptance window for backdated entries.

### Side finding: the comin gauges were blind for the first half of this rollout

`comin_pending_confirmation` and `comin_deployer_suspended` read 2 (probe broken) on
all three canaries from each host's own deploy until ~10:42, because
`comin status --json` embeds the deployment's build log and passes the 128 KiB
per-argument `execve` limit. Fixed in #183. The lesson is not the fix, it is the
window: the two gauges the rollout gatekeeper depends on were unreadable during
exactly the ~1 h 45 m after a deploy in which a health-gate rollback would have shown
up, and they healed on their own once a smaller deploy rotated the record out.

### Measurement traps hit while reading these gates

- Loki's `query_range` caps at 5000 entries and returns exactly 5000 when it hits
  the cap. A count of 5000 means at least 5000. Use `sum(count_over_time(...))` for
  anything that could exceed it.
- `count_over_time(sel[1m])` stepped across a window inflates a post-event rate,
  because the sample at the boundary reaches a minute before it. The first version
  of the gate 1 table said 93 dhcpcd lines/h after the switch; the raw log count was
  0. The contradiction is what caught it.
- Early-boot journald lines arrive stamped with the NTP sync, not the event. node04's
  entire boot arrived as 14:54:12 because rsyslog's forward action had been blocked
  and flushed at `Initial clock synchronization`. Ordering cannot be read out of Loki
  for that window -- gate 5 needed on-host monotonic timestamps, and the first
  attempt to derive it from Loki was worthless.
- Every journald line arrives twice (imjournal and rsyslog both ship). Deduplicate
  before counting anything.
