# Republish embedded etcd metrics on the mesh, without touching k3s.
#
# WHY THIS EXISTS AT ALL. k3s' embedded etcd serves /metrics, and the chart's 15
# etcd rules need it, but the listener is on loopback and unreachable from
# k8s-casa over the tunnel. See docs/titan-metrics-scrape.md in k8s-titan for what
# is otherwise blind.
#
# WHY NOT k3s' OWN --etcd-expose-metrics FLAG. It looks like the obvious answer
# and it is the wrong one here, verified against the k3s v1.35.8+k3s1 source rather
# than from the flag's help text. pkg/etcd/etcd.go:
#
#     func (e *ETCD) listenMetricsURLs(reset bool) string {
#         metricsURLs := fmt.Sprintf("http://%s:2381", e.config.Loopback(true))
#         if !reset && e.config.EtcdExposeMetrics {
#             metricsURLs += "," + fmt.Sprintf("http://%s", net.JoinHostPort(e.address, "2381"))
#         }
#         return metricsURLs
#     }
#
# Two things fall out of those six lines. First, the loopback listener is
# UNCONDITIONAL -- there is nothing to enable, so no k3s flag change is needed and
# therefore no k3s restart, which on a single-node cluster is the whole game.
# Second, the flag adds a bind on e.address, which is the node's address, and
# titan registers InternalIP as its PUBLIC OVH address. So --etcd-expose-metrics
# would put unauthenticated plaintext etcd metrics on the internet-facing
# interface while STILL not answering on the tunnel -- the exact opposite of the
# requirement, in the one direction the mesh firewall cannot protect against
# because its rule is matched with -i wg0.
#
# So: a 20-line proxy that binds the tunnel address and forwards to loopback.
# Unauthenticated, like node_exporter on :9100, and behind the same trust boundary
# as every other meshTCPPorts entry; etcd metrics are operational counters, not
# secrets, and the cluster's secrets stay reachable only via authenticated 6443.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etcdMetricsProxy;
  listen = "TCP-LISTEN:${toString cfg.listenPort},bind=${cfg.listenAddress},fork,reuseaddr";
  upstream = "TCP:${cfg.upstreamAddress}:${toString cfg.upstreamPort}";
in
{
  options.etcdMetricsProxy = {
    enable = lib.mkEnableOption ''
      a single-purpose TCP proxy that republishes k3s' embedded etcd metrics from
      loopback onto the WireGuard mesh address
    '';

    listenAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        Address the proxy binds. This MUST be one specific address -- the tunnel
        address in practice. Binding 0.0.0.0 is refused by assertion: etcd's
        metrics endpoint is unauthenticated plaintext HTTP, and the whole reason
        not to use k3s' own --etcd-expose-metrics is that it binds the wrong
        interface. See the module comment.
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 2381;
      description = "Port the proxy listens on. Also the port opened on the mesh.";
    };

    upstreamAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Where etcd's own metrics listener lives.";
    };

    upstreamPort = lib.mkOption {
      type = lib.types.port;
      default = 2381;
      description = ''
        etcd binds this on loopback unconditionally; k3s does not make it
        configurable. See the module comment for the source reference.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "::";
        message = ''
          etcdMetricsProxy.listenAddress is "${cfg.listenAddress}". Refusing to
          build: etcd's /metrics is unauthenticated plaintext HTTP, so a wildcard
          bind puts it on every interface this host has -- including the public
          one. Bind the WireGuard address instead.
        '';
      }
      {
        assertion = cfg.upstreamAddress == "127.0.0.1" || cfg.upstreamAddress == "::1";
        message = ''
          etcdMetricsProxy.upstreamAddress is "${cfg.upstreamAddress}", which is
          not loopback. This module exists to reach an etcd listener that k3s
          binds to loopback on purpose; pointing it at a remote host would make
          this an unauthenticated metrics relay and is not what it is for.
        '';
      }
    ];

    # Opening the port is derived from the proxy being enabled, not written
    # separately in the host config, so "listening but blocked" and "open but
    # nothing behind it" are both unrepresentable. publicHost.meshTCPPortExtras is
    # matched with -i wg0, so this cannot widen the public interface.
    publicHost.meshTCPPortExtras = [ cfg.listenPort ];

    systemd.services.etcd-metrics-proxy = {
      description = "Republish embedded etcd metrics on ${cfg.listenAddress}:${toString cfg.listenPort}";
      wantedBy = [ "multi-user.target" ];
      # Ordered after k3s so etcd is up before anything can connect, but NOT
      # BindsTo=k3s: when the control plane restarts this should sit there and
      # refuse connections, then recover on its own, rather than being torn down
      # and having to be pulled back up by a dependency chain.
      after = [
        "network-online.target"
        "k3s.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        type = "simple";
        ExecStart = "${pkgs.socat}/bin/socat ${listen} ${upstream}";
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
