#!/bin/sh

usage() {
  echo "Usage: $0 --age-key KEY --host HOSTNAME --ip SERVER_IP --disk-password DISK_PASSWORD"
  echo "  --age-key, -a        Age private key for sops"
  echo "  --host, -h           Hostname (flake .#hostname)"
  echo "  --ip, -i             Server IP address"
  echo "  --disk-password, -d  Disk encryption password"
  exit 1
}

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
    *)
      usage
      ;;
  esac
done

if [ -z "$MY_AGE_KEY" ] || [ -z "$HOSTNAME" ] || [ -z "$SERVER_IP" ] || [ -z "$DISK_PASSWORD" ]; then
  usage
fi

(
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/var/lib/sops-nix"
  echo "$MY_AGE_KEY" > "$TMP_DIR/var/lib/sops-nix/key.txt"
  echo "$DISK_PASSWORD" > "$TMP_DIR/disko-password"

  nix run github:nix-community/nixos-anywhere -- \
    --build-on-remote \
    --extra-files "$TMP_DIR" \
    --disk-encryption-keys /tmp/disko-password "$TMP_DIR/disko-password" \
    --phases kexec,disko,install \
    --flake ".#$HOSTNAME" \
    "root@$SERVER_IP"

  rm -rf "$TMP_DIR"
)
