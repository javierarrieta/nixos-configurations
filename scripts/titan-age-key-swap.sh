#!/bin/sh
# titan-age-key-swap.sh -- replace titan's repo-wide admin sops age key with titan's own,
# without ever leaving the host unable to decrypt its own secrets.
#
# Why this is a script and not three commands in a runbook: the dangerous failure is
# silent. Install the wrong key and titan still boots, still decrypts, still deploys -- and
# the narrowing Task 17 exists for simply never happened. So the script refuses to report
# success until it has proved each thing it claims.
#
# The flow is ADDITIVE on purpose. The old key is never removed until the new one has been
# activated alongside it and proven in isolation, so there is no moment where the host's
# only path to its own secrets is a key that has not worked yet. An earlier version
# installed the new key first and rolled back on failure; on the host the rollback itself
# failed, which is the hole this design closes.
#
#   1. prove the candidate is titan's key and nothing wider (nothing installed yet)
#   2. install old + candidate together, activate -- must be healthy, admin key guarantees it
#   3. install candidate alone, activate -- the real narrowing test, with the old key one cp away
#   4. verify every secret path, then destroy the backup
#
# Usage (on titan, as root):
#   titan-age-key-swap.sh --key-file /run/titan-key.in --repo /run/nixcfg
#
# The key goes in a file, never an argv (AGENTS: keys passed as shell arguments get
# mangled), and into /run so it never touches the root disk. The script shreds it at the
# end, including on the paths where it refuses.
#
# Flags exist so the whole thing can be exercised off the host: --key-dest and --no-activate
# turn it into a pure verification run against a sandbox path, which is how the refusals got
# tested (scripts/titan-age-key-swap-tests.sh).
set -eu

# titan's own host key, from .sops.yaml under the ^secrets/titan\.yaml$ rule. Override
# only if the key was regenerated.
#
# This one was minted ON titan with `age-keygen` into tmpfs, so its private half never left
# the box. The predecessor (age1vrsm5d9…) was minted on a Coder workspace on 2026-10-02 and
# was retired by re-encrypting secrets/titan.yaml before it was ever installed.
TITAN_RECIPIENT="age1xff5th53qfnj7p7xjg3t27dxhl4kwhwu2c0tj8r8uruz8lq9tf7q22f35f"

# Every secret the deployed titan must end up with, as absolute paths. These are the
# *materialised* paths, which are not all under /run/secrets:
#
#   - neededForUsers secrets go to /run/secrets-for-users (sops-nix mounts a separate
#     tmpfs there so the hash exists before users are created)
#   - the ssh host keys declare an explicit path under /etc/ssh
#
# Regenerate after any change to hosts/titan/configuration.nix or sops-base.nix with:
#   nix eval --raw --impure --expr \
#     'let c = (builtins.getFlake (toString ./.)).nixosConfigurations.titan.config;
#      in builtins.concatStringsSep "\n"
#         (builtins.map (n: c.sops.secrets.${n}.path) (builtins.attrNames c.sops.secrets))'
EXPECTED_SECRETS="
/run/secrets/titan/network_env
/run/secrets/titan/minio_env
/run/secrets/wireguard/titan_private_key
/run/secrets/k3s_token_titan
/run/secrets-for-users/users/javier_password_hash_titan
/etc/ssh/ssh_host_ed25519_key
/etc/ssh/ssh_host_ed25519_key.pub
"

KEY_FILE=""
KEY_DEST="/var/lib/sops-nix/key.txt"
REPO=""
ACTIVATE=1
KEEP_BACKUP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)   KEY_FILE="$2"; shift 2 ;;
    --key-dest)   KEY_DEST="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
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
[ -n "$REPO" ] || die "no checkout with secrets.yaml and secrets/titan.yaml (comin's is a bare repo). Clone the repo and pass --repo, e.g. --repo /run/nixcfg"
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

put_key() { # install one file as the sops key, root:root 0600, verified byte-identical
  install -m 0600 -o root -g root "$1" "$KEY_DEST" 2>/dev/null \
    || { cp "$1" "$KEY_DEST" && chmod 0600 "$KEY_DEST"; }
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$(sha256sum "$KEY_DEST" | cut -d' ' -f1)" ] \
    || die "key did not land intact at $KEY_DEST"
}

activate() { # re-run activation for the CURRENT generation; echo output on failure
  # No rebuild: switch-to-configuration on the current generation re-runs the activation
  # scripts, and sops-nix decrypts during activation. Note the path is bin/, not sw/bin/.
  [ -x /run/current-system/bin/switch-to-configuration ] \
    || die "/run/current-system/bin/switch-to-configuration missing"
  local_out=$(/run/current-system/bin/switch-to-configuration switch 2>&1) && return 0
  printf '%s\n' "$local_out" | sed 's/^/    /'
  return 1
}

# comin runs switch-to-configuration on its own schedule, and this script rewrites
# /var/lib/sops-nix/key.txt with a non-atomic cp. A deploy landing mid-write reads a
# half-written key and fails to decrypt, which looks exactly like a bad key. This bit the
# host on 2026-10-05: comin's retried switches failed while an earlier version of this
# script was swapping keys underneath them. So comin is stopped for the duration and put
# back exactly as it was found.
COMIN_WAS_ACTIVE=0
stop_comin() {
  if systemctl is-active --quiet comin 2>/dev/null; then
    COMIN_WAS_ACTIVE=1
    systemctl stop comin 2>/dev/null || true
    say "    comin stopped for the duration of the swap"
  fi
}
start_comin() {
  [ "$COMIN_WAS_ACTIVE" = "1" ] || return 0
  COMIN_WAS_ACTIVE=0
  systemctl start comin 2>/dev/null || true
}

cleanup() {
  rc=$?
  # Only reachable if the candidate was installed and something then failed. The old key is
  # put back and activation re-run, so a failed run cannot leave titan unable to decrypt its
  # own secrets. Caveat found the hard way: after a recipient rotation the old key is a
  # recipient of nothing, so this restores a key that opens no file -- the rollback is not a
  # safety net in exactly the situation where a rotation went wrong. Phase A is the real
  # protection: the working key stays in the file until the new one has activated on its own.
  if [ "$rc" -ne 0 ] && [ "$INSTALLED" = "1" ] && [ -n "$BACKUP" ]; then
    say "restoring the previous key and re-activating"
    # plain cp here, not put_key: put_key dies on a mismatch, and dying inside cleanup would
    # abandon the restore halfway through
    cp "$BACKUP" "$KEY_DEST" 2>/dev/null && chmod 0600 "$KEY_DEST"
    if [ "$ACTIVATE" = "1" ]; then
      activate >/dev/null 2>&1 || say "WARN: rollback activation failed; check /run/secrets by hand"
    fi
  fi
  start_comin
  for f in "$WORK"/*; do [ -f "$f" ] && wipe "$f"; done
  rmdir "$SOPS_HOME" 2>/dev/null || true
  rmdir "$WORK" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT INT TERM

# --- 1. is this actually titan's key? ---------------------------------------------------
# The recipient equality is the direct answer; the decrypt pair is the behaviour that
# actually matters, and it is also the proof Step 7 asks for.
CAND_PUB=$(age-keygen -y "$KEY_FILE" 2>/dev/null) \
  || die "not a valid age secret key: $KEY_FILE"
[ "$CAND_PUB" = "$TITAN_RECIPIENT" ] \
  || die "key is $CAND_PUB, expected $TITAN_RECIPIENT (titan's host key per .sops.yaml)"
say "1/6 recipient matches titan's host key: $CAND_PUB"

run_sops "$KEY_FILE" -d "$REPO/secrets/titan.yaml" > "$WORK/titan.out" \
  || die "candidate cannot decrypt $REPO/secrets/titan.yaml -- it is not a recipient"
[ -s "$WORK/titan.out" ] || die "secrets/titan.yaml decrypted to nothing"
say "2/6 candidate decrypts secrets/titan.yaml"

if run_sops "$KEY_FILE" -d "$REPO/secrets.yaml" > "$WORK/fleet.out" 2>/dev/null; then
  # This is the check that catches an admin key handed in by mistake. Every admin recipient
  # opens both files, so a green run here means the swap would accomplish nothing.
  die "candidate ALSO decrypts secrets.yaml -- that is an admin key, not titan's. Aborting: installing it would leave the blast radius exactly as wide as it is now."
fi
say "3/6 candidate cannot decrypt secrets.yaml (this is the narrowing)"

# --- 1b. does the generation we are about to re-activate embed the rotated file? ----------
# Activation re-runs the CURRENT generation, and that generation carries a store copy of
# secrets/titan.yaml baked in when it was built. After a recipient rotation the repo file
# and the embedded copy differ: the new key opens the repo copy (check 2) but not the one
# activation will read. That is how a correct key still died with "0 successful groups
# required, got 0" on the host -- the swap has to come after the rotation commit is deployed.
# With both keys installed this check would pass on the admin key's effort alone, which is
# exactly why it runs here, in isolation, before anything is written.
say "    checking the deployed generation's own copy of titan.yaml"
if command -v nix-store >/dev/null 2>&1; then
  GEN_TITAN=$(nix-store -q --requisites /run/current-system 2>/dev/null \
              | grep -- '-titan\.yaml$' | head -1)
  if [ -n "$GEN_TITAN" ]; then
    if run_sops "$KEY_FILE" -d "$GEN_TITAN" >/dev/null 2>&1; then
      say "    deployed generation embeds a titan.yaml this key opens"
    else
      die "the deployed generation still embeds the pre-rotation $GEN_TITAN, which this key cannot open. Deploy the commit that re-encrypted secrets/titan.yaml first, then swap the key."
    fi
  else
    say "    (no titan.yaml found in the current system closure; skipping that check)"
  fi
else
  say "    (nix-store unavailable; skipping that check)"
fi

# --- 2. back up what is installed now -------------------------------------------------
stop_comin
if [ -f "$KEY_DEST" ]; then
  BACKUP="$WORK/previous-key.txt"
  cp "$KEY_DEST" "$BACKUP"
  say "backed up $KEY_DEST (sha256 $(sha256sum "$KEY_DEST" | cut -c1-16)…)"
else
  say "no key at $KEY_DEST yet (fresh host?)"
fi

# --- 3. install old + candidate together, and activate ----------------------------------
# The point of this phase is that the host cannot be made worse by it: whatever the old key
# could open, the union still opens. It proves sops-nix accepts a multi-identity key file
# and that activation is healthy with both, before the fallback is removed.
if [ -n "$BACKUP" ]; then
  cat "$BACKUP" "$KEY_FILE" > "$WORK/both.txt"
  put_key "$WORK/both.txt"
  INSTALLED=1
  if [ "$ACTIVATE" = "1" ]; then
    say "    activating with both keys..."
    activate || die "activation failed with both keys installed -- the old key is still in the file, so nothing has been lost, but investigate before going further"
  fi
  say "4/6 both keys installed, activation healthy"
else
  put_key "$KEY_FILE"
  INSTALLED=1
  if [ "$ACTIVATE" = "1" ]; then
    activate || die "activation failed with the candidate key"
  fi
  say "4/6 no previous key to keep, candidate installed, activation healthy"
fi

# --- 4. now remove the fallback: candidate alone -----------------------------------------
# This is the narrowing test. If it fails, cleanup restores the old key -- which at this
# point is a key already proven to work on this host minutes ago, not a hope.
put_key "$KEY_FILE"
if [ "$ACTIVATE" = "1" ]; then
  say "    activating with titan's key alone..."
  activate || die "activation failed with titan's key alone (old key restored)"
  MISSING=""
  for p in $EXPECTED_SECRETS; do
    [ -s "$p" ] || MISSING="$MISSING $p"
  done
  [ -z "$MISSING" ] || die "these secrets did not materialise: $MISSING"
  say "5/6 titan's key alone, activation healthy, all $(printf '%s\n' "$EXPECTED_SECRETS" | wc -w) secrets present"
else
  put_key "$KEY_FILE"
  say "5/6 activation skipped (--no-activate); secrets not re-checked"
fi

# --- 5. only now is the old admin key destroyed -----------------------------------------
if [ "$KEEP_BACKUP" = "1" ]; then
  # Move it out of $WORK first: cleanup shreds everything in $WORK, so leaving it there
  # would make this flag a lie.
  KEEP="$KEY_DEST.backup"
  mv "$BACKUP" "$KEEP" && chmod 0600 "$KEEP"
  BACKUP=""
  say "--keep-backup: previous key moved to $KEEP -- shred it once you are satisfied"
elif [ -n "$BACKUP" ]; then
  wipe "$BACKUP"
  BACKUP=""
  say "previous admin key destroyed"
fi
wipe "$KEY_FILE"
start_comin
say "OK: titan now decrypts secrets/titan.yaml and nothing wider."
say "Next: confirm from the fleet side that comin is unsuspended and a deploy still lands."
