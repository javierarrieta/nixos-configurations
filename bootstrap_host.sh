#!/bin/sh

usage() {
  echo "Usage: $0 --age-key KEY --host HOSTNAME --ip SERVER_IP --disk-password DISK_PASSWORD"
  echo "  --age-key, -a        Age private key for sops"
  echo "  --age-key-file, -k   Read the age key from a file (preferred: no quoting, no argv leak)"
  echo "  --host, -h           Hostname (flake .#hostname)"
  echo "  --ip, -i             Server IP address"
  echo "  --disk-password, -d  Disk encryption password"
  echo "  --no-build-on-remote  Build on the workstation (needed when no binary cache is reachable)"
  exit 1
}

NO_BUILD_ON_REMOTE=0
AGE_KEY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --age-key|-a)
      MY_AGE_KEY="$2"
      shift 2
      ;;
    --age-key-file|-k)
      AGE_KEY_FILE="$2"
      [ -r "$2" ] || { echo "cannot read $2" >&2; exit 1; }
      MY_AGE_KEY="$(cat "$2")"
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

  # Extract exactly one line and refuse to continue if it is not there. Two real
  # failures this turns into an instant error instead of a half-installed host:
  # a shell that word-splits a multi-line substitution (fish, unquoted) so the arg
  # arrives as only the `# created:` comment, and an empty variable. age-keygen
  # writes two comment lines above the key; sops reads them fine, but there is no
  # reason to ship them to the target and wonder later.
  AGE_LINE=$(printf '%s\n' "$MY_AGE_KEY" | grep -m1 '^AGE-SECRET-KEY-')
  if [ -z "$AGE_LINE" ]; then
    echo "no AGE-SECRET-KEY- line in the key given (got $(printf '%s' "$MY_AGE_KEY" | wc -c) bytes)." >&2
    echo "Use --age-key-file ~/.config/sops/age/keys.txt to avoid shell quoting entirely." >&2
    exit 1
  fi
  echo "$AGE_LINE" > "$TMP_DIR/var/lib/sops-nix/key.txt"
  echo "$DISK_PASSWORD" > "$TMP_DIR/disko-password"
  echo "age key: $(printf '%s' "$AGE_LINE" | cut -c1-18)... $(printf '%s' "$AGE_LINE" | wc -c) chars -> /var/lib/sops-nix/key.txt"

  # Building on the target is right for the LAN hosts, which reach the Attic cache
  # over the WireGuard mesh. It is wrong for a host being bootstrapped *into* that
  # mesh: there is no mesh yet, so the build must happen here and ship its closure
  # over SSH. Unquoted on purpose -- an empty flag must vanish, and this is /bin/sh
  # with no `set -u`.
  BUILD_FLAG="--build-on-remote"
  [ "$NO_BUILD_ON_REMOTE" = "1" ] && BUILD_FLAG=""

  # nixpkgs ships a prebuilt nixos-anywhere; the GitHub flake has to be *built*, and a
  # local build dies inside a Coder workspace with `fchmodat2: Operation not permitted`
  # -- the container's seccomp profile blocks the syscall Nix 2.34 uses to make store
  # paths writable, so substitution is the only path that works here. Both are 1.13.0.
  # Override to track upstream: NIXOS_ANYWHERE=github:nix-community/nixos-anywhere
  nix run "${NIXOS_ANYWHERE:-nixpkgs#nixos-anywhere}" -- \
    $BUILD_FLAG \
    --extra-files "$TMP_DIR" \
    --disk-encryption-keys /tmp/disko-password "$TMP_DIR/disko-password" \
    --phases kexec,disko,install \
    --flake ".#$HOSTNAME" \
    "root@$SERVER_IP"

  rm -rf "$TMP_DIR"
)
