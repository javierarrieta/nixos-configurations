{
  config,
  lib,
  pkgs,
  ...
}:
let
  isPlaceholder = s: lib.hasPrefix "$" s;
  useRuntimeConfig =
    isPlaceholder config.staticNetwork.ipAddress
    || isPlaceholder config.staticNetwork.defaultGateway
    || lib.any isPlaceholder config.staticNetwork.nameservers;
  iface = config.staticNetwork.interface;
  # The SOPS network_env secret holds the runtime-resolved address, gateway and
  # DNS. It is provisioned early in activation, so it is already on disk by the
  # time activationScripts run.
  envFile = config.sops.secrets."${config.networking.hostName}/network_env".path;
  routeFlagsStr =
    if config.staticNetwork.routeFlags == [ ] then
      ""
    else
      lib.concatStringsSep " " config.staticNetwork.routeFlags + " ";
  # True when this host defers its nameservers to the runtime network_env.
  needsRuntimeResolv = lib.any isPlaceholder config.staticNetwork.nameservers;

  # On those hosts /etc/resolv.conf is not managed by NixOS at all: the
  # `networking.nameservers` assignment below is skipped while the values are
  # still "$DNS1"/"$DNS2", `environment.etc` has no "resolv.conf" entry to write,
  # and the two scripts here write the file from the SOPS network_env.
  #
  # The invariant both scripts hold: never write a nameserver line the resolver
  # cannot parse, and never fail silently. A host with no usable resolv.conf
  # answers `no such host` for every name on it, so containerd cannot pull and
  # comin cannot fetch, while its pods, its kubelet and its syslog keep working on
  # cached images and IP literals and the node still looks healthy. That is how
  # k8s-node04 ran 17 hours unseen on 2026-11-17. The incident write-up --
  # timeline, measurements, and the alternatives that were considered and rejected
  # (resolvconf -a, networking.resolvconf.enable = false, networking.dhcpcd.enable
  # = false) -- is docs/superpowers/incidents/2026-11-17-k8s-node04-dead-host-resolver.md.
  #
  # What clobbers the file is resolvconf, from two directions. resolvconf.service
  # is `Before = network-pre.target`, so `resolvconf -u` runs after activation and
  # before network-runtime-config, and with an empty /run/resolvconf/keys it
  # regenerates the file with zero nameservers and exit 0. And nixpkgs' own
  # `resolvconf -m 1 -a static`, in network-local-commands.service, is the
  # publisher that would normally fill that registry -- on these hosts it registers
  # an empty key, because networking.nameservers is mkIf'd off, and its subscriber
  # then refuses to touch the file if anything rewrote it after that `-u`. Both
  # are ordered ahead of the restore now. dhcpcd's 20-resolv.conf hook calls
  # resolvconf on every BOUND,
  # REBIND or restart. A boot survives by accident, because network-runtime-config
  # writes the nameservers back; a switch does not re-run that oneshot, which is
  # why the watchdog is the only thing standing between a switch and an empty
  # resolver.
  #
  # Both scripts are installed into the system environment and invoked as
  # /run/current-system/sw/bin/..., not as generation-specific store paths. That
  # is the health-gate ENOENT-after-GC incident (AGENTS.md, 2026-08-29) avoided at
  # the source: a unit whose ExecStart is a store path can outlive the generation
  # that owns it, and nix-sweep then collects the script while the unit keeps
  # trying to exec it. The activation script is the one caller that must keep
  # using the store path -- it runs BEFORE /run/current-system is repointed, so
  # the sw/bin path there is the previous generation's script, or absent on a
  # first deploy.
  # One interval paces the whole loop. The route half and the resolver half are
  # re-asserted in the same tick, so they share the number; the message that
  # quotes it is built from it too.
  watchIntervalSec = 10;
  resolvConfPath = "/run/current-system/sw/bin/static-network-resolv-conf";
  networkWatchPath = "/run/current-system/sw/bin/static-network-watch";
  writeResolvConf = pkgs.writeShellScriptBin "static-network-resolv-conf" ''
    if [ ! -f "${envFile}" ]; then
      echo "${envFile} is missing; leaving /etc/resolv.conf alone" >&2
      exit 2
    fi
    . "${envFile}"
    # Strip control characters from the values themselves, not only from what gets
    # logged. `.` keeps a CR as part of the value, so without this a CRLF
    # network_env -- a secret pasted out of a Windows editor, one of the shapes
    # this script exists to survive -- makes BOTH nameservers invalid and the
    # script exits 1 with zero nameservers written. That is the outage this module
    # exists to prevent, reached through a secret whose addresses were fine. It was
    # measured: DNS1=192.168.0.1<CR> gave exit 1 and left /etc/resolv.conf alone.
    #
    # The logging reason is the same CR: echoed straight back it overwrites the
    # journal line it is being reported on.
    # (Single backslashes: a Nix indented string passes them through untouched and
    # tr is the thing that interprets them. Writing \\r here would hand tr a
    # literal backslash plus the letters r and n.)
    scrub() {
      ${pkgs.coreutils}/bin/printf '%s' "$1" | ${pkgs.coreutils}/bin/tr -d '\r\n'
    }
    # Raw copies first, so the failure message can still tell an unset key from an
    # empty one after the scrub has flattened both to "".
    raw_dns1="''${DNS1-<unset>}"
    raw_dns2="''${DNS2-<unset>}"
    DNS1="$(scrub "''${DNS1:-}")"
    DNS2="$(scrub "''${DNS2:-}")"
    # Non-empty is not the same as valid, and a charset is not an address. A
    # stray space, a CR, a quote -- all pass -z. So does 999.1.1.1, and an
    # unparseable nameserver line is skipped: with no parseable nameserver left
    # the host is back in the exact outage this script exists to prevent. Measured
    # against a charset-only check: 999.1.1.1, 1.2.3.4.5, 1.1.1.1:53 and ... all
    # got through.
    #
    # The contract is glibc's res_init acceptance, NOT inet_pton, and the two
    # differ in both directions. Leading zeros are accepted here and glibc does
    # use them as live servers (measured in a mount namespace: `nameserver
    # 1.2.3.045` gets queried), while inet_pton rejects them; inet_aton-style
    # forms like 127.1 or 0177.0.0.1 are refused here and glibc would take them.
    # Do not "tighten" the leading-zero case to match inet_pton -- it is not a bug,
    # and refusing a resolver glibc would have used is the outage.
    #
    # IPv6 is refused outright, which is a decision rather than a gap: no host on
    # this fleet has an IPv6 nameserver, and the first cut of this branch tried to
    # accept v6 on a charset plus a colon count, which let `::::`, `1:2:3` and
    # `2001:db8:1` through. If a v6 resolver ever arrives, validate it properly --
    # at most one `::`, eight groups without it, 1-4 hex digits per group, optional
    # dotted-quad tail -- rather than loosening this.
    valid_ns() {
      local oct
      local -a octets
      case "$1" in
        # IPv6: refused, see above.
        *:*) return 1 ;;
        *.*.*)
          # IPv4: exactly four decimal octets, each <= 255. The pattern above
          # already rejected anything with fewer than two dots; the count check
          # rejects the ones with too many. set -f first because the split is
          # unquoted and a value like `*.*.*` would otherwise glob against the
          # working directory and be judged on whatever files are there.
          #
          # A local array rather than `set -- $1`: `set` is not function-local in
          # bash, so a positional split here would overwrite the script's own
          # positional parameters. Harmless while the script takes no arguments,
          # and a trap for whoever adds one.
          set -f
          IFS=.
          octets=( $1 )
          unset IFS
          set +f
          [ "''${#octets[@]}" -eq 4 ] || return 1
          for oct in "''${octets[@]}"; do
            case "$oct" in "" | *[!0-9]*) return 1 ;; esac
            # Length before value: `[ 99999999999999999999 -le 255 ]` is not a
            # false, it is bash complaining on stderr, and the watchdog forwards
            # stderr straight into the journal line.
            [ "''${#oct}" -le 3 ] || return 1
            [ "$oct" -le 255 ] || return 1
          done
          ;;
        # No colon and fewer than three dots: not an IPv4 address.
        *) return 1 ;;
      esac
    }
    # One usable resolver is worth writing; two is better. Requiring both is
    # stricter than resolv.conf needs: the snippet this replaced wrote
    # `nameserver ` with an empty second address, glibc skipped the unparseable
    # line, and the host resolved fine on the first one. Refusing to write
    # anything at all in that case is how a degraded secret becomes the outage
    # this module exists to prevent. A dropped nameserver is reported rather than
    # eaten -- the watchdog prints a message that changed, once.
    ns1=""
    ns2=""
    dropped=""
    if valid_ns "''${DNS1:-}"; then ns1="$DNS1"; else dropped="DNS1"; fi
    if valid_ns "''${DNS2:-}"; then ns2="$DNS2"; else dropped="''${dropped:+$dropped }DNS2"; fi
    if [ -z "$ns1" ] && [ -z "$ns2" ]; then
      echo "no usable nameserver in ${envFile} (DNS1=$(scrub "$raw_dns1") DNS2=$(scrub "$raw_dns2")); refusing to write /etc/resolv.conf" >&2
      exit 1
    fi
    if [ -n "$ns1" ] && [ -n "$ns2" ]; then
      new=$(printf 'nameserver %s\nnameserver %s\n' "$ns1" "$ns2")
    elif [ -n "$ns1" ]; then
      new=$(printf 'nameserver %s\n' "$ns1")
    else
      new=$(printf 'nameserver %s\n' "$ns2")
    fi
    if [ -n "$dropped" ]; then
      echo "writing one nameserver only; $dropped is not a usable IPv4 address in ${envFile}" >&2
    fi
    # Read the file once, then compare before touching /etc: the loop runs around
    # the clock, and a temp file created just to discover nothing changed is ~8.6k
    # create/unlink pairs a day in /etc for a file that never moved. Command
    # substitution strips trailing newlines on both sides, so this compares
    # content rather than bytes.
    old=""
    if [ -f /etc/resolv.conf ]; then
      old=$(${pkgs.coreutils}/bin/cat /etc/resolv.conf)
    fi
    if [ "$old" = "$new" ]; then
      # Content is not the whole contract. resolvconf.service hands the file back
      # with `chgrp resolvconf; chmod g=u` on every run, so an early exit on
      # content alone left mode drift in place; re-asserting costs two syscalls a
      # tick and never changes the inode.
      ${pkgs.coreutils}/bin/chgrp resolvconf /etc/resolv.conf 2>/dev/null || true
      ${pkgs.coreutils}/bin/chmod 0664 /etc/resolv.conf
      exit 0
    fi
    # Second-writer tripwire, read line by line because the writer's contract is
    # lines: it replaces /etc/resolv.conf with nameserver lines and nothing else.
    # Two things are worth reporting and only one of them was.
    #
    #   * a nameserver that did not come from network_env. The resolvconf stub
    #     this module exists to survive carries no nameserver line at all, so one
    #     means a second publisher: wg-quick with a DNS= line, NetworkManager, a
    #     VPN client that speaks resolvconf.
    #   * every other line the rewrite discards -- `search`, `domain`, `options`,
    #     `sortlist`. Dropping those unseen is the same invisibility as the bug
    #     this module fixes: an option another publisher thought it had set simply
    #     stops existing. `options edns0` from the resolvconf stub is the one this
    #     fleet hits daily (see networking.resolvconf.dnsExtensionMechanism).
    #
    # This module is the declared owner and overwrites either way; it just says so.
    # A legitimate nameserver change in the secret trips the first message too,
    # which is why it names both possibilities. Both are edge-triggered by the
    # watchdog's changed-message guard and only reached when the content differs,
    # so neither can flood.
    #
    # `read` splits the line, so there is no unquoted expansion to glob and no
    # `set -f` needed; the bare `nameserver` keyword with no address is junk being
    # removed, not a foreign address, and is not reported as one.
    foreign=""
    nforeign=0
    discarded=""
    ndiscarded=0
    while read -r kw rest; do
      case "$kw" in
        "" | "#"* | ";"*) continue ;;
        nameserver)
          if [ -n "$rest" ] && [ "$rest" != "$ns1" ] && [ "$rest" != "$ns2" ]; then
            nforeign=$((nforeign + 1))
            foreign="''${foreign:+$foreign, }$rest"
          fi
          ;;
        *)
          ndiscarded=$((ndiscarded + 1))
          discarded="''${discarded:+$discarded, }[$kw''${rest:+ $rest}]"
          ;;
      esac
    done <<< "$old"
    if [ "$nforeign" -gt 0 ]; then
      echo "replacing foreign nameservers ($(scrub "$foreign")) in /etc/resolv.conf: they did not come from ${envFile}, so either something else is publishing resolvers or the nameservers changed in the secret" >&2
    fi
    if [ "$ndiscarded" -gt 0 ]; then
      echo "dropping $ndiscarded non-nameserver line(s) from /etc/resolv.conf: $(scrub "$discarded"). This module writes nameserver lines only, so anything another publisher put there is discarded; if a search domain or resolver option has gone missing, that is why" >&2
    fi
    # Unique temp name: the activation script and the watchdog can land here
    # at the same instant, and a shared name lets one mv the other's half-written
    # file into /etc/resolv.conf.
    tmp=$(${pkgs.coreutils}/bin/mktemp /etc/resolv.conf.tmp.XXXXXX) || exit 1
    # Anything that kills us between here and the mv must not leave a root-owned
    # turd in /etc for ever. EXIT alone is not enough -- bash does not run an
    # EXIT trap for an untrapped SIGTERM -- and a signal trap that does not exit
    # would let the script carry on and write the file anyway.
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"; exit 1' HUP INT TERM
    printf '%s\n' "$new" > "$tmp"
    # mv swaps the inode, and resolvconf.service keeps /etc/resolv.conf
    # group-writable for the resolvconf group so dhcpcd's hook can write it. A
    # bare mv throws that away on every rewrite and locks dhcpcd out of the file,
    # so carry the mode over instead of inventing one. (chgrp is a no-op where the
    # group does not exist.)
    ${pkgs.coreutils}/bin/chgrp resolvconf "$tmp" 2>/dev/null || true
    ${pkgs.coreutils}/bin/chmod 0664 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" /etc/resolv.conf
  '';
  # Runs on the watchIntervalSec interval for the life of the boot. Nothing
  # re-asserts resolv.conf after activation -- NixOS does not own it, and
  # resolvconf.service is itself one of the things that can clobber it -- so
  # anything that rewrites it wins until the next switch, which is how a 17-hour
  # outage stayed one.
  #
  # Diagnostics are edge-triggered, on purpose. This loop runs around the clock;
  # at the default interval, printing on every failure would push ~17k lines a day
  # through journald and rsyslog into /var/log/messages, which is the watchdog
  # failure mode already recorded in AGENTS.md (2026-08-27, k8s-node03, a runaway
  # loop filling the root filesystem). A message goes out when the state changes
  # and when it recovers, and not in between.
  networkWatchLoop = pkgs.writeShellScriptBin "static-network-watch" ''
    last_rc=0
    last_msg=""
    last_rt_rc=0
    while true; do
      # Re-read the secret on every tick, and drop the previous tick's value
      # first. systemd reads EnvironmentFile once, at unit start, and this loop
      # outlives that moment: setupSecrets is an activation script and not a unit,
      # so network_env can land long after the loop started -- and can go away
      # again. Taking DEFAULT_GATEWAY from the unit environment alone made a late
      # secret permanent, and keeping the last sourced value makes a vanished one
      # permanent the other way: the route half would keep calling `ip route
      # replace` on a stale gateway while reporting that everything is fine.
      # writeResolvConf re-reads the file itself for the same reason.
      unset DEFAULT_GATEWAY
      if [ -f "${envFile}" ]; then
        . "${envFile}"
      fi
      # The route half is edge-triggered for the same reason the resolver half is,
      # and it used to be worse: `|| true` with stderr on the floor meant a route
      # that could not be restored was indistinguishable from one that was. That
      # is exactly how the last silent failure stayed silent.
      if [ -n "''${DEFAULT_GATEWAY:-}" ]; then
        ${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via "$DEFAULT_GATEWAY" dev ${iface} 2>/dev/null
        rt_rc=$?
      else
        # The secret is not on disk yet, or carries no DEFAULT_GATEWAY. The source
        # above re-reads it every tick, so this state clears itself and the
        # edge-trigger below prints the recovery. A word, not a number: `ip`
        # exits with real errnos (2 for `Network is unreachable`, among others),
        # so a numeric sentinel here is one a genuine route failure can also
        # return -- and that failure would be reported as an unloaded secret
        # instead of as a route that would not come back.
        rt_rc=no_gw
      fi
      if [ "$rt_rc" != "$last_rt_rc" ]; then
        case "$rt_rc" in
          0) echo "static-network: default route self-heal recovered" >&2 ;;
          no_gw) echo "static-network: DEFAULT_GATEWAY is unset; cannot self-heal the default route" >&2 ;;
          *) echo "static-network: default route self-heal failing (ip route replace exit $rt_rc)" >&2 ;;
        esac
        last_rt_rc=$rt_rc
      fi
      ${lib.optionalString needsRuntimeResolv ''
        msg=$(${resolvConfPath} 2>&1) && rc=0 || rc=$?
        if [ "$rc" != "$last_rc" ] || [ "$msg" != "$last_msg" ]; then
          case "$rc" in
            0)
              if [ "$last_rc" != 0 ]; then
                echo "static-network: /etc/resolv.conf self-heal recovered" >&2
              fi
              # rc 0 with a message is a warning the writer chose to emit -- one
              # usable nameserver out of two, say, or a foreign nameserver it is
              # replacing. The guard above only lets a changed message through, so
              # this prints once, not per tick.
              if [ -n "$msg" ]; then
                echo "static-network: $msg" >&2
              fi
              ;;
            2)
              echo "static-network: $msg (retrying every ${toString watchIntervalSec}s)" >&2
              ;;
            *)
              echo "static-network: $msg -- host DNS is broken until this clears" >&2
              ;;
          esac
        fi
        last_rc=$rc
        last_msg=$msg
      ''}
      ${pkgs.coreutils}/bin/sleep ${toString watchIntervalSec}
    done
  '';
in
{
  options = {
    staticNetwork = {
      enable = lib.mkEnableOption "Static network configuration";
      ipAddress = lib.mkOption {
        type = lib.types.str;
        description = "Static IP address";
      };
      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 24;
        description = "Network prefix length";
      };
      defaultGateway = lib.mkOption {
        type = lib.types.str;
        description = "Default gateway IP address";
      };
      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "List of DNS nameservers";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Network interface name";
      };
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
    };
  };

  config = lib.mkIf config.staticNetwork.enable {
    # Both scripts live in the system environment so that the units below can be
    # pointed at /run/current-system/sw/bin/... instead of at a generation-specific
    # store path. See the health-gate ENOENT-after-GC incident (AGENTS.md,
    # 2026-08-29): a unit whose ExecStart is a store path can outlive the
    # generation that owns it, and nix-sweep then collects the script while the
    # unit keeps trying to exec it -- silently, and the watchdog is the only thing
    # keeping the resolver and the default route up.
    environment.systemPackages = lib.mkIf useRuntimeConfig [
      writeResolvConf
      networkWatchLoop
    ];

    # The address stays here: it is eval-safe once defaultGateway is null
    # (parseAddr is only reached through isGateway), and the generated
    # network-addresses-*.service expands the placeholder at runtime from the
    # SOPS network_env EnvironmentFile.
    networking.interfaces.${config.staticNetwork.interface} = {
      ipv4.addresses = [
        {
          address = config.staticNetwork.ipAddress;
          prefixLength = config.staticNetwork.prefixLength;
        }
      ];
      useDHCP = false;
    };

    # Placeholder values are resolved at runtime from the SOPS network_env
    # secret. nixpkgs >= 26.05 parses addresses and gateways during evaluation
    # (which fails on "$IP_ADDRESS"), so defer gateway and nameservers to a
    # runtime service instead of baking shell placeholders into the NixOS
    # networking config.
    networking.defaultGateway = lib.mkIf (
      !isPlaceholder config.staticNetwork.ipAddress && !isPlaceholder config.staticNetwork.defaultGateway
    ) config.staticNetwork.defaultGateway;
    networking.nameservers = lib.mkIf (
      !lib.any isPlaceholder config.staticNetwork.nameservers
    ) config.staticNetwork.nameservers;

    systemd.services.network-runtime-config = lib.mkIf useRuntimeConfig {
      description = "Runtime network configuration from SOPS";
      requires = [ "network-addresses-${config.staticNetwork.interface}.service" ];
      # resolvconf.service is Before=network-pre.target and wipes the file; this
      # unit is the restore. Ordering it explicitly instead of relying on
      # network-pre.target sorting before network.target.
      #
      # network-local-commands.service is the other clobberer and the easy one to
      # miss. nixpkgs renders networking.localCommands as
      # `resolvconf -m 1 -a static`, fed from networking.nameservers -- and on
      # these hosts that option is mkIf'd off, so the heredoc it registers is
      # empty. That unit is WantedBy=network.target with no ordering against this
      # one, so the two race on every boot. Measured with openresolv 3.17.4 in a
      # mount namespace: run after this unit it exits 1 with `signature mismatch:
      # /etc/resolv.conf`. That exit is the libc subscriber refusing to append to
      # a file whose first line is not `# Generated by resolvconf` -- not the
      # registration failing, because resolvconf writes the key
      # /run/resolvconf/keys/static before it runs any subscriber. What the
      # refusal prevents is the regeneration, which is the half that would drop
      # these nameservers again. Ordering after it makes the restore last, and
      # the unit green: resolvconf.service re-signs the file at network-pre, so
      # as long as nothing has rewritten it since, `-a static` matches, exits 0,
      # and this unit overwrites it afterwards.
      after = [
        "network-addresses-${config.staticNetwork.interface}.service"
        "resolvconf.service"
        "network-local-commands.service"
      ];
      wantedBy = [ "network.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # '-' on purpose. Without it a missing network_env is not a degraded
        # start, it is `Result: resources` and no unit at all -- k3s.nix records
        # that failure mode from titan on 2026-10-03. This unit is the restore,
        # so it has to survive the thing it is restoring after; the script below
        # checks each variable instead of assuming the file landed.
        EnvironmentFile = [ "-${config.sops.secrets."${config.networking.hostName}/network_env".path}" ];
      };
      script = ''
        ${lib.optionalString
          (isPlaceholder config.staticNetwork.ipAddress || isPlaceholder config.staticNetwork.defaultGateway)
          ''
            if [ -n "$DEFAULT_GATEWAY" ]; then
              ip route replace ${routeFlagsStr}default via "$DEFAULT_GATEWAY" dev ${config.staticNetwork.interface}
            else
              echo "static-network: network_env not loaded; skipping the default route at boot, the watchdog owns it now" >&2
            fi
          ''
        }
        # The sw/bin path is correct here: this unit is started after the system
        # symlink is repointed, unlike the activation script below.
        ${lib.optionalString needsRuntimeResolv "${resolvConfPath} || echo 'static-network: could not write /etc/resolv.conf at boot; the watchdog keeps retrying' >&2"}
      '';
    };

    # switch-to-configuration does not re-trigger units whose OnlyBy/WantedBy
    # target is already active (e.g. network.target during a `nixos-rebuild
    # switch`), so network-addresses-<iface>.service is NOT re-run on a switch.
    # That is not only a route problem. If the address currently on the interface
    # came from anything other than that unit -- a DHCP lease covering for a
    # generation whose useDHCP=false named a device the kernel does not have, for
    # instance -- then switching to a correct generation makes networkd drop the
    # lease and nothing puts the static address back. The interface ends up with
    # no address at all and the host is dark until someone reaches a console.
    # Observed on titan 2026-10-02, five minutes after a healthy-looking deploy.
    # Re-applying the address on every activation closes that window, and is a
    # no-op when the address is already the right one.
    #
    # The route half exists for the same reason: hosts (notably k3s servers) lost
    # their default route on the nixpkgs 26.05 switch and k3s crashed with
    # "unable to select an IP from default routes". Gateway and DNS are re-applied
    # here, on every activation (boot + switch), before services restart.
    system.activationScripts.network-runtime = lib.mkIf useRuntimeConfig {
      # sops-nix provisions /run/secrets via the `setupSecrets` activation
      # script. Without this dependency the network_env file may not exist yet
      # when this script runs on a fresh switch (hosts whose /run/secrets was
      # recreated), leaving the default route unset and k3s unable to start.
      deps = [ "setupSecrets" ];
      text = ''
        if [ -f "${envFile}" ]; then
          . "${envFile}"
          ${lib.optionalString (isPlaceholder config.staticNetwork.ipAddress) "${pkgs.iproute2}/bin/ip addr replace \"$IP_ADDRESS\"/${toString config.staticNetwork.prefixLength} dev ${iface}"}
          # Deliberately unguarded here, unlike the same line in
          # network-runtime-config: this runs during activation, so an empty
          # DEFAULT_GATEWAY fails the switch loudly instead of activating a host
          # with no route and no complaint. That is the behaviour wanted for a
          # half-written secret at deploy time; the boot unit above is the one
          # that has to survive it and leave the machine reachable.
          ${lib.optionalString (isPlaceholder config.staticNetwork.defaultGateway) "${pkgs.iproute2}/bin/ip route replace ${routeFlagsStr}default via \"$DEFAULT_GATEWAY\" dev ${iface}"}
          # Deliberately the store path and not /run/current-system/sw/bin: an
          # activation script runs BEFORE switch-to-configuration repoints
          # /run/current-system, so the sw/bin path here is the previous
          # generation's script -- or does not exist at all on a first deploy.
          # getExe, never the bare derivation: writeShellScriptBin puts the
          # script at $out/bin/<name>, so coercing the derivation to a string
          # yields the directory and bash cannot exec a directory. The first cut
          # interpolated the derivation; it rendered as a perfectly plausible
          # store path, did nothing, and left every activation logging the
          # fallback below instead of writing the resolver.
          ${lib.optionalString needsRuntimeResolv "${lib.getExe writeResolvConf} || echo 'static-network: could not re-assert /etc/resolv.conf during activation' >&2"}
        fi
      '';
    };

    # The network-runtime-config oneshot only fires on fresh boots (it is
    # WantedBy network.target which is already active during a switch).
    # The activation script above runs on every activation but can still miss
    # the route mid-switch. A persistent watchdog is the only reliable
    # self-heal: it restores the route no matter when or why it is lost.
    #
    # It now re-asserts resolv.conf in the same loop, for the same reason: the
    # route and the resolver are both runtime state that nothing owns after
    # activation, and the resolver half went unwatched until a node ran 17 hours
    # with a dead one. The unit keeps its name -- renaming it would mean a switch
    # has to stop the old unit before the replacement takes over, and the last
    # thing a half-applied network change needs is a window with no watchdog.
    systemd.services.network-route-watch = lib.mkIf useRuntimeConfig {
      description = "Self-heal default route and /etc/resolv.conf if lost or clobbered";
      # setupSecrets is an activation script in sops-nix, not a systemd unit --
      # `config.systemd.services ? setupSecrets` is false on every host here --
      # so this After= orders against nothing and the loop can genuinely start
      # before network_env exists. That is what writeResolvConf's exit 2 is for:
      # a missing secret at boot is a retry, not an outage.
      after = [
        "network.target"
        "resolvconf.service"
        "setupSecrets.service"
      ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # ExecStart is a constant path now, so switch-to-configuration sees no
      # change and would leave a long-running loop executing the previous
      # generation's code forever. restartTriggers is what closes that: the script
      # store path changes whenever its content does, and that restarts the unit
      # without a stop/start window. Without it, "deploy done" would not mean the
      # running loop matches the deployed one.
      restartTriggers = [ networkWatchLoop ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "10s";
        ExecStart = networkWatchPath;
        # '-' on purpose: without it a missing network_env kills the unit with
        # `Result: resources` before anything runs and the watchdog is gone for
        # the boot. It is NOT what makes a late secret recoverable, though --
        # systemd reads EnvironmentFile once, at unit start, so the loop sources
        # the file itself every tick. Keep both: this one gets the values onto
        # tick one when the secret is already there, and the source in the loop
        # is what picks the secret up when it is not.
        EnvironmentFile = [ "-${config.sops.secrets."${config.networking.hostName}/network_env".path}" ];
      };
    };
  };
}
