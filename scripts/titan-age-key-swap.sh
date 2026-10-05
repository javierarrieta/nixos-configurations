#!/bin/sh
# Task 17 Steps 6-7: replace the admin age key titan was bootstrapped with by titan's own
# host key, then PROVE the narrowing instead of assuming it.
#
# WHY A SCRIPT AND NOT THREE COMMANDS IN A RUNBOOK. The failure is silent and asymmetric:
# install a key that is not titan's -- an admin key, or the k8s key, or the wrong file
# entirely -- and every secret still materialises, k3s stays Ready, comin stays green, and
# the split Task 17 exists for simply never happened. So this script refuses to finish
# until it has proved two things from the host: the installed key opens
# secrets/titan.yaml, and it CANNOT open secrets.yaml.
#
# Runs as root ON titan. The key arrives as a root-readable file, never as an argument:
# argv is world-readable through /proc, and the bootstrap already learned that keys passed
# as shell arguments get mangled (AGENTS.md, titan bring-up lesson 4).
#
#   # 1. ship the key and the script into tmpfs (never onto the root disk)
#   ssh -p 13491 nixos@titan.arrieta.eu \
#     'sudo sh -c "umask 077; cat > /run/titan-key.in"' < ~/.config/sops/age/titan-key.txt
#   ssh -p 13491 nixos@titan.arrieta.eu \
#     'sudo sh -c "umask 077; cat > /run/titan-age-key-swap.sh"' < scripts/titan-age-key-swap.sh
#   # 2. run it
#   ssh -p 13491 nixos@titan.arrieta.eu \
#     'sudo sh /run/titan-age-key-swap.sh --key-file /run/titan-key.in'
#
# Flags exist so the whole thing can be exercised off the host: --key-dest and --no-activate
# turn it into a pure verification run against a sandbox path, which is how the "is this
# really titan's key" discriminator got tested (see hosts/titan/README.md).
set -eu

# titan's own host key, from .sops.yaml under the ^secrets/titan\.yaml$ rule. Override
# only if the key was regenerated.
#
# This one was minted ON titan with `age-keygen` into tmpfs, so its private half never left
# the box. The predecessor (age1vrsm5d9…) was minted on a Coder workspace on 2026-10-02 and
# was retired by re-encrypting secrets/titan.yaml before it was ever installed -- which is
# why check 2 below is the real gate: it fails for a key .sops.yaml lists but the file was
# never re-encrypted to.
TITAN_RECIPIENT="age1xff5th53qfnj7p7xjg3t27dxhl4kwhwu2c0tj8r8uruz8lq9tf7q22f35f"

# Mirrors the sops.secrets entries in hosts/titan/configuration.nix (plus the one
# sops-base.nix adds for the break-glass password). If a secret is added there, add it
# here: an unlisted secret is an unverified secret.
EXPECTED_SECRETS="
titan/network_env
titan/minio_env
wireguard/titan_private_key
ssh_keys/titan_host_private
ssh_keys/titan_host_public
k3s_token_titan
users/javier_password_hash_titan
"

KEY_FILE=""
KEY_DEST="/var/lib/sops-nix/key.txt"
REPO=""
ACTIVATE=1
KEEP_BACKUP=0
SECRETS_DIR="/run/secrets"

while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)   KEY_FILE="$2"; shift 2 ;;
    --key-dest)   KEY_DEST="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --secrets-dir) SECRETS_DIR="$2"; shift 2 ;;
    --recipient)  TITAN_RECIPIENT="$2"; shift 2 ;;
    --no-activate) ACTIVATE=0; shift ;;
    --keep-backup) KEEP_BACKUP=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -n "$KEY_FILE" ] || die "--key-file is required (a file holding one AGE-SECRET-KEY line)"
[ -f "$KEY_FILE" ] || die "no such key file: $KEY_FILE"

# Locate a checkout holding the two sops files. Comin's is a BARE repo -- no working tree,
# so /var/lib/comin/repository has never contained these files (found the hard way on the
# host). /etc/nixos is what nixos-anywhere leaves behind and may or may not still be there.
# In practice: clone the repo somewhere and pass --repo.
if [ -z "$REPO" ]; then
  for cand in /etc/nixos /root/nixos-configurations; do
    if [ -f "$cand/secrets.yaml" ] && [ -f "$cand/secrets/titan.yaml" ]; then
      REPO="$cand"
      break
    fi
  done
fi
[ -n "$REPO" ] || die "no checkout with secrets.yaml and secrets/titan.yaml (comin's is a bare repo). Clone the repo and pass --repo, e.g. --repo /root/nixos-configurations"
[ -f "$REPO/secrets.yaml" ] || die "$REPO/secrets.yaml missing"
[ -f "$REPO/secrets/titan.yaml" ] || die "$REPO/secrets/titan.yaml missing"

for bin in sops age-keygen; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not on PATH"
done

WORK=$(mktemp -d)
umask 077
INSTALLED=0
BACKUP=""

# sops does NOT honour SOPS_AGE_KEY_FILE on its own: it also loads
# ~/.config/sops/age/keys.txt and any ssh-agent identities, and uses whichever key fits.
# On a workstation that means an admin key silently joins every "can this key open the
# fleet file" check and the check passes for the wrong reason -- this script said "titan's
# key also decrypts secrets.yaml" on its first local run, which was true only because the
# operator's admin key was sitting in the default path. So every sops call below runs with
# an empty HOME, no agent, and exactly one identity file. On titan that also means the
# proof is not accidentally satisfied by a leftover key in root's home.
SOPS_HOME="$WORK/home"
mkdir -p "$SOPS_HOME"
run_sops() {
  ident="$1"; shift
  env -i PATH="$PATH" HOME="$SOPS_HOME" TERM=dumb SSH_AUTH_SOCK="" \
      SOPS_AGE_KEY_FILE="$ident" sops "$@"
}

wipe() {
  # files only; $WORK holds the hermetic HOME directory
  [ -f "$1" ] || return 0
  shred -u "$1" 2>/dev/null || { rm -f "$1" && say "WARN: deleted without shredding: $1 (shred unavailable)"; }
}

cleanup() {
  rc=$?
  # If we installed a key and never reached the proof, put the old one back and re-run
  # activation, so a failed run cannot leave titan unable to decrypt its own secrets.
  if [ "$rc" -ne 0 ] && [ "$INSTALLED" = "1" ] && [ -n "$BACKUP" ]; then
    say "restoring the previous key and re-activating"
    install -m 0600 -o root -g root "$BACKUP" "$KEY_DEST" 2>/dev/null \
      || cp "$BACKUP" "$KEY_DEST"
    if [ "$ACTIVATE" = "1" ] && [ -x /run/current-system/bin/switch-to-configuration ]; then
      /run/current-system/bin/switch-to-configuration switch >/dev/null 2>&1 \
        || say "WARN: rollback activation failed; check /run/secrets by hand"
    fi
  fi
  for f in "$WORK"/*; do [ -f "$f" ] && wipe "$f"; done
  rmdir "$SOPS_HOME" 2>/dev/null || true
  rmdir "$WORK" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT INT TERM

# --- 1. is this actually titan's key? -------------------------------------------------
# Three independent checks, because the interesting mistake is "right kind of file, wrong
# key". The recipient equality is the direct answer; the decrypt pair is the behaviour that
# actually matters, and it is also the proof Step 7 asks for.
CAND_PUB=$(age-keygen -y "$KEY_FILE" 2>/dev/null) \
  || die "not a valid age secret key: $KEY_FILE"
[ "$CAND_PUB" = "$TITAN_RECIPIENT" ] \
  || die "key is $CAND_PUB, expected $TITAN_RECIPIENT (titan's host key per .sops.yaml)"
say "1/5 recipient matches titan's host key: $CAND_PUB"

run_sops "$KEY_FILE" -d "$REPO/secrets/titan.yaml" > "$WORK/titan.out" \
  || die "candidate cannot decrypt $REPO/secrets/titan.yaml -- it is not a recipient"
[ -s "$WORK/titan.out" ] || die "secrets/titan.yaml decrypted to nothing"
say "2/5 candidate decrypts secrets/titan.yaml"

if run_sops "$KEY_FILE" -d "$REPO/secrets.yaml" > "$WORK/fleet.out" 2>/dev/null; then
  # This is the check that catches an admin key handed in by mistake. Every admin recipient
  # opens both files, so a green run here means the swap would accomplish nothing.
  die "candidate ALSO decrypts secrets.yaml -- that is an admin key, not titan's. Aborting: installing it would leave the blast radius exactly as wide as it is now."
fi
say "3/5 candidate cannot decrypt secrets.yaml (this is the narrowing)"

# --- 2. back up what is installed now -------------------------------------------------
if [ -f "$KEY_DEST" ]; then
  BACKUP="$WORK/previous-key.txt"
  cp "$KEY_DEST" "$BACKUP"
  say "backed up $(printf '%s' "$KEY_DEST") (sha256 $(sha256sum "$KEY_DEST" | cut -c1-16)…)"
else
  say "no key at $KEY_DEST yet (fresh host?)"
fi

# --- 3. install -----------------------------------------------------------------------
install -m 0600 -o root -g root "$KEY_FILE" "$KEY_DEST" 2>/dev/null \
  || { cp "$KEY_FILE" "$KEY_DEST" && chmod 0600 "$KEY_DEST"; }
INSTALLED=1
[ "$(sha256sum "$KEY_FILE" | cut -d' ' -f1)" = "$(sha256sum "$KEY_DEST" | cut -d' ' -f1)" ] \
  || die "key did not land intact at $KEY_DEST"
say "4/5 installed at $KEY_DEST (root:root 0600)"

# --- 4. re-activate and check every secret materialised ---------------------------------
# No rebuild: switch-to-configuration on the CURRENT generation re-runs the activation
# scripts, and sops-nix decrypts during activation. Note the path is bin/, not sw/bin/.
if [ "$ACTIVATE" = "1" ]; then
  [ -x /run/current-system/bin/switch-to-configuration ] \
    || die "/run/current-system/bin/switch-to-configuration missing"
  say "re-running activation for the current generation..."
  /run/current-system/bin/switch-to-configuration switch >/dev/null \
    || die "activation failed with the new key"
  MISSING=""
  for name in $EXPECTED_SECRETS; do
    [ -s "$SECRETS_DIR/$name" ] || MISSING="$MISSING $name"
  done
  [ -z "$MISSING" ] || die "these secrets did not materialise: $MISSING"
  say "5/5 all $(printf '%s\n' $EXPECTED_SECRETS | wc -w) secrets materialised under $SECRETS_DIR"
else
  say "5/5 activation skipped (--no-activate); secrets not re-checked"
fi

# --- 5. only now is the old admin key destroyed -----------------------------------------
if [ "$KEEP_BACKUP" = "1" ]; then
  say "--keep-backup: previous key left at $BACKUP -- shred it once you are satisfied"
elif [ -n "$BACKUP" ]; then
  wipe "$BACKUP"
  BACKUP=""
  say "previous admin key destroyed"
fi
wipe "$KEY_FILE"
say "OK: titan now decrypts secrets/titan.yaml and nothing wider."
say "Next: confirm from the fleet side that comin is unsuspended and a deploy still lands."
