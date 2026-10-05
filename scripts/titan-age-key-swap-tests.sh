#!/bin/bash
# Offline test matrix for scripts/titan-age-key-swap.sh.
#
# Why this exists: the swap's dangerous failure is silent. Install the wrong age key and
# titan still boots, still decrypts, still deploys -- and the narrowing Task 17 exists for
# simply never happened. So the script's refusals are the product, and they need to be
# exercised.
#
# It builds its own sops fixture (two synthetic keys, two encrypted files) instead of
# pointing at the repo's real secrets.yaml / secrets/titan.yaml. The real files can only
# ever be opened by an admin key (which the script must refuse) or titan's own key, whose
# private half lives on titan and nowhere else. A fixture is the only way to test the
# accept path at all -- and it means this suite runs on any machine with sops + age.
#
#   scripts/titan-age-key-swap-tests.sh
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
S="$REPO/scripts/titan-age-key-swap.sh"
AGE_DIR=${AGE_DIR:-$HOME/.config/sops/age}
WORK=$(mktemp -d)
FIX="$WORK/fix"
pass=0; fail=0; skip=0; n=0

for bin in sops age-keygen; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing dependency: $bin"; exit 1; }
done

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# --- fixture ----------------------------------------------------------------------------
umask 077
mint() { age-keygen -o "$1" >/dev/null 2>&1 && age-keygen -y "$1"; }
TITAN_PUB=$(mint "$WORK/titan.key")     # stands in for titan's host key
ADMIN_PUB=$(mint "$WORK/admin.key")     # stands in for an admin key: opens both files
STRAY_PUB=$(mint "$WORK/stray.key")     # valid age key, recipient of nothing

mkdir -p "$FIX/secrets"
# Same rule shape as the real .sops.yaml: path_regex is relative to the config file, and
# the generic rule is literal, so the titan rule has to be explicit here too.
cat > "$FIX/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^secrets/titan\.yaml\$
    key_groups:
      - age: ["$ADMIN_PUB", "$TITAN_PUB"]
  - path_regex: secrets\.ya?ml\$
    key_groups:
      - age: ["$ADMIN_PUB"]
EOF
printf 'fleet_secret: do-not-open\n' > "$FIX/secrets.yaml"
printf 'titan_secret: ok-to-open\n'  > "$FIX/secrets/titan.yaml"
# Encrypt in place: sops picks the creation rule from the file's own path, so writing the
# plaintext anywhere else would pick a different rule (or none).
sops --config "$FIX/.sops.yaml" -e -i "$FIX/secrets.yaml"
sops --config "$FIX/.sops.yaml" -e -i "$FIX/secrets/titan.yaml"
[ -s "$FIX/secrets.yaml" ] && [ -s "$FIX/secrets/titan.yaml" ] || { echo "fixture failed"; exit 1; }

pass_() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
fail_() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

run() { # name expect_exit keyfile extra-args...
  local name=$1 expect=$2 key=$3; shift 3
  if [ ! -f "$key" ]; then
    printf 'SKIP  %s (no key: %s)\n' "$name" "$key"; skip=$((skip+1)); return
  fi
  n=$((n+1))
  # The script shreds the file it is given on success -- the point on the host, a way to
  # destroy a real key here. Every case therefore gets a throwaway copy.
  local dest="$WORK/dest-$n" keytmp="$WORK/key-$n" out rc
  cat "$key" > "$keytmp" || { printf 'SKIP  %s (unreadable)\n' "$name"; skip=$((skip+1)); return; }
  out=$(sh "$S" --key-file "$keytmp" --key-dest "$dest" --repo "$FIX" --no-activate "$@" 2>&1)
  rc=$?
  if [ "$rc" = "$expect" ]; then
    printf 'PASS  %s (exit %s)\n' "$name" "$rc"; pass=$((pass+1))
  else
    printf 'FAIL  %s (exit %s, expected %s)\n' "$name" "$rc" "$expect"
    printf '%s\n' "$out" | sed 's/^/        /'; fail=$((fail+1))
  fi
  if printf '%s' "$out" | grep -q 'AGE-SECRET-KEY'; then
    fail_ "$name printed key material"
  fi
}

# --- the discriminator -------------------------------------------------------------------
run "titan's key accepted"               0 "$WORK/titan.key" --recipient "$TITAN_PUB"
run "admin key refused (identity)"       1 "$WORK/admin.key"
run "stray valid age key refused"        1 "$WORK/stray.key"
printf 'not a key\n' > "$WORK/junk"
run "junk file refused"                  1 "$WORK/junk"
run "unknown flag"                       2 "$WORK/titan.key" --nope

# a missing file is what `run` skips on, so this one goes straight at the script
if sh "$S" --key-file "$WORK/does-not-exist" --key-dest "$WORK/dx" --repo "$FIX" \
     --no-activate >/dev/null 2>&1; then
  fail_ "missing key file accepted"
else
  pass_ "missing key file refused"
fi

# --- the narrowing check, exercised on its own -------------------------------------------
# The admin stand-in opens both fixture files, so it must be refused even when it passes the
# identity check. This is the silent failure mode: an admin key installs cleanly, titan
# keeps working, and the narrowing never happened.
run "narrowing check catches an admin key" 1 "$WORK/admin.key" --recipient "$ADMIN_PUB"

# --- against the real repo files, when an admin key happens to be present -----------------
# Only the refusal direction is testable here: titan's private half is on titan.
if [ -f "$AGE_DIR/keys.txt" ]; then
  n=$((n+1)); cat "$AGE_DIR/keys.txt" > "$WORK/key-real"
  if sh "$S" --key-file "$WORK/key-real" --key-dest "$WORK/dest-real" --repo "$REPO" \
       --no-activate >/dev/null 2>&1; then
    fail_ "real admin key accepted against the real repo"
  else
    pass_ "real admin key refused against the real repo"
  fi
else
  printf 'SKIP  real-repo case (no %s)\n' "$AGE_DIR/keys.txt"; skip=$((skip+1))
fi

# --- an accepted run must install the right bytes, 0600 -----------------------------------
cat "$WORK/titan.key" > "$WORK/titan.copy"
WANT=$(sha256sum "$WORK/titan.copy" | cut -d' ' -f1)
sh "$S" --key-file "$WORK/titan.copy" --key-dest "$WORK/installed" --repo "$FIX" \
   --no-activate --recipient "$TITAN_PUB" >/dev/null 2>&1
GOT=$(sha256sum "$WORK/installed" 2>/dev/null | cut -d' ' -f1)
if [ "$WANT" = "$GOT" ]; then pass_ "installed key is byte-identical to the candidate"
else fail_ "installed key differs (or is missing)"; fi
if [ "$(stat -c '%a' "$WORK/installed" 2>/dev/null)" = "600" ]; then pass_ "installed key is 0600"
else fail_ "installed key mode is $(stat -c '%a' "$WORK/installed" 2>/dev/null)"; fi

# --- the fallback really is gone at the end, and --keep-backup really keeps it -----------
mkdir -p "$WORK/sub"
seed() { # seed a pre-existing key at the dest, as the host would have the admin key
  cat "$WORK/admin.key" > "$WORK/sub/dest"
}
seed
# the script shreds --key-file on success, so hand it a copy and compare against the original
cp "$WORK/titan.key" "$WORK/titan.a"
sh "$S" --key-file "$WORK/titan.a" --key-dest "$WORK/sub/dest" --repo "$FIX" \
   --no-activate --recipient "$TITAN_PUB" >/dev/null 2>&1
if cmp -s "$WORK/titan.key" "$WORK/sub/dest"; then
  pass_ "pre-existing admin key replaced by titan's key alone (no union left behind)"
else
  fail_ "final key file is not titan's key alone"
fi

seed
cp "$WORK/titan.key" "$WORK/titan.b"
sh "$S" --key-file "$WORK/titan.b" --key-dest "$WORK/sub/dest" --repo "$FIX" \
   --no-activate --recipient "$TITAN_PUB" --keep-backup >/dev/null 2>&1
if [ -f "$WORK/sub/dest.backup" ] && cmp -s "$WORK/admin.key" "$WORK/sub/dest.backup"; then
  pass_ "--keep-backup leaves the old key outside the sandbox workdir"
else
  fail_ "--keep-backup did not preserve the old key (cleanup shredded it?)"
fi

echo "---- $pass passed, $fail failed, $skip skipped"
[ "$fail" = "0" ]
