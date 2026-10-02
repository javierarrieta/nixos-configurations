#!/bin/sh

usage() {
  echo "Usage: $0 --age-key KEY --host HOSTNAME --ip SERVER_IP --disk-password DISK_PASSWORD"
  echo "  --age-key, -a        Age private key for sops"
  echo "  --host, -h           Hostname (flake .#hostname)"
  echo "  --ip, -i             Server IP address"
  echo "  --disk-password, -d  Disk encryption password"
  echo "  --no-build-on-remote  Build on the workstation (needed when no binary cache is reachable)"
  exit 1
}

NO_BUILD_ON_REMOTE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --age-key|-a)
      MY_AGE_KEY="$2"
      shift 2
      ;;
    --host|-h)
      HOSTNAME="$2"
      shift 2
      ;;
    --ip|-i)
      SERVER_IP="$2"
      shift 2
      ;;
    --disk-password|-d)
      DISK_PASSWORD="$2"
      shift 2
      ;;
    --no-build-on-remote)
      NO_BUILD_ON_REMOTE=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

if [ -z "$MY_AGE_KEY" ] || [ -z "$HOSTNAME" ] || [ -z "$SERVER_IP" ] || [ -z "$DISK_PASSWORD" ]; then
  usage
fi

(
  # The age key lands in the target's /var/lib/sops-nix/key.txt with whatever mode
  # it has here, so pin it before the first write rather than trusting the caller's
  # umask. Same reason the plan's direct nixos-anywhere invocation sets umask 077.
  umask 077
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/var/lib/sops-nix"
  echo "$MY_AGE_KEY" > "$TMP_DIR/var/lib/sops-nix/key.txt"
  echo "$DISK_PASSWORD" > "$TMP_DIR/disko-password"

  # Building on the target is right for the LAN hosts, which reach the Attic cache
  # over the WireGuard mesh. It is wrong for a host being bootstrapped *into* that
  # mesh: there is no mesh yet, so the build must happen here and ship its closure
  # over SSH. Unquoted on purpose -- an empty flag must vanish, and this is /bin/sh
  # with no `set -u`.
  BUILD_FLAG="--build-on-remote"
  [ "$NO_BUILD_ON_REMOTE" = "1" ] && BUILD_FLAG=""

  nix run github:nix-community/nixos-anywhere -- \
    $BUILD_FLAG \
    --extra-files "$TMP_DIR" \
    --disk-encryption-keys /tmp/disko-password "$TMP_DIR/disko-password" \
    --phases kexec,disko,install \
    --flake ".#$HOSTNAME" \
    "root@$SERVER_IP"

  rm -rf "$TMP_DIR"
)
