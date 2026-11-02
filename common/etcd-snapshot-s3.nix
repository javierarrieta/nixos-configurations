# Shared --etcd-s3 flag set for the casa control plane (k8s-server01..03).
#
# Mirrors hosts/titan/vars.nix, which is the proven pattern: it has been uploading
# etcd snapshots to this same MinIO since 2026-10-02 and has had a restore drill
# actually run against it. The traps are summarised here, not re-derived; read that
# file before changing anything below.
#
# Takes { folder, cron } because BOTH must differ per member:
#
#   - folder scopes retention. pkg/etcd/s3/s3.go:395 (release-1.36) does
#     `prefix = path.Join(c.etcdS3.Folder, prefix)` before listing for pruning, and
#     the function comment says "for this specific node". So three members sharing
#     one folder each prune the OTHERS' snapshots down to their own retention count
#     -- the bucket would end up with roughly `retention` objects total instead of
#     3x that, chosen arbitrarily by whichever member ran its retention pass last.
#     One folder per member and they never touch each other's objects.
#
#   - cron staggers the uploads. Identical crons make all three snapshot in the same
#     minute, which is three concurrent ~52 MB uploads to a NAS and, more annoyingly,
#     three near-identical object timestamps to tell apart during a restore.
#
# Before this deploys, the SOPS secret named by k3s.environmentFiles must exist on
# the host (see the hosts/k8s-serverNN/configuration.nix side of this change). A
# missing EnvironmentFile makes the k3s unit fail at start, on a control plane.
{ folder, cron }:
[
  "--etcd-s3"
  # BARE HOST: no scheme, no port. s3.l.arrieta.eu is a Traefik Ingress on 443
  # (k8s-casa apply/50-apps/casa/minio.yaml, an Endpoints object pointing at the
  # out-of-cluster MinIO at 192.168.0.6:9000). Two separate ways to get this wrong,
  # both hit on 2026-10-03 with titan: pinning :9000 hits a VIP and hangs until
  # --etcd-s3-timeout, and a scheme makes minio-go reject the endpoint outright.
  # TLS is on by default; --etcd-s3-insecure is what turns it off, not the scheme.
  "--etcd-s3-endpoint=s3.l.arrieta.eu"
  # Own bucket, NOT titan-etcd. An etcd snapshot is every Secret in the cluster in
  # plaintext, so the bucket boundary is the access boundary: the MinIO key for
  # casa-etcd must not be able to read titan-etcd, or a casa credential becomes
  # cross-cluster.
  "--etcd-s3-bucket=casa-etcd"
  # eu-west-1, not k3s' us-east-1 AWS default. MinIO signs per bucket and rejects a
  # region mismatch outright rather than ignoring it.
  "--etcd-s3-region=eu-west-1"
  "--etcd-s3-folder=${folder}"
  # Mandatory, not an optimisation: 'auto' lookup resolves casa-etcd.s3.l.arrieta.eu,
  # which has no DNS record and no certificate, because the Ingress serves exactly
  # one host. Verified 2026-11-02: the bare host answers 403 (MinIO, anonymous deny),
  # the vhost form does not resolve at all.
  "--etcd-s3-bucket-lookup-type=path"
  # A COUNT, not a duration: the recovery window is this number times the cadence
  # below, so changing the cron silently changes what this line means. 28 at 6h is
  # 7 days per member. Size is not the constraint -- casa's etcd members measured
  # ~52 MB each (etcd_mvcc_db_total_size_in_bytes), so 28 x 3 members is ~4.4 GB.
  "--etcd-s3-retention=28"
  # The embedded quotes are load-bearing. k3s.extraFlags is toString'd into a single
  # ExecStart string and systemd word-splits it, so an unquoted cron arrives as
  # --etcd-snapshot-schedule-cron=0 plus three stray arguments, which is how titan's
  # k3s was taken down on 2026-10-03.
  "--etcd-snapshot-schedule-cron=\"${cron}\""
]
