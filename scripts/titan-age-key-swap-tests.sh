#!/bin/bash
# Offline test matrix for scripts/titan-age-key-swap.sh.
#
# Why this exists: the swap's dangerous failure is silent. Install the wrong age key and
# titan still boots, still decrypts, still deploys -- and the narrowing Task 17 exists for
# simply never happened. So the script's refusals are the product, and they need to be
# exercised. Every case runs the real script against the repo's real sops files with
# --no-activate and a sandbox --key-dest, so nothing near /var/lib is touched.
#
# Cases whose key file is not present are SKIPPED, not failed: this is meant to run on a
# workstation that may hold some subset of the fleet's age keys.
#
#   scripts/titan-age-key-swap-tests.sh
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
S="$REPO/scripts/titan-age-key-swap.sh"
AGE_DIR=${AGE_DIR:-$HOME/.config/sops/age}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0; n=0

run() { # name expect_exit keyfile extra-args...
  local name=$1 expect=$2 key=$3; shift 3
  if [ ! -f "$key" ]; then
    printf 'SKIP  %s (no key: %s)\n' "$name" "$key"; skip=$((skip+1)); return
  fi
  n=$((n+1))
  # The script shreds the file it is given on success -- that is the point on the host, and
  # a way to destroy a real key here. Every case therefore gets a throwaway copy.
  local dest="$WORK/dest-$n" keytmp="$WORK/key-$n" out rc
  umask 077
  cat "$key" > "$keytmp" || { printf 'SKIP  %s (unreadable)\n' "$name"; skip=$((skip+1)); return; }
  out=$(sh "$S" --key-file "$keytmp" --key-dest "$dest" --repo "$REPO" --no-activate "$@" 2>&1); rc=$?
  if [ "$rc" = "$expect" ]; then
    printf 'PASS  %s (exit %s)\n' "$name" "$rc"; pass=$((pass+1))
  else
    printf 'FAIL  %s (exit %s, expected %s)\n' "$name" "$rc" "$expect"
    printf '%s\n' "$out" | sed 's/^/        /'; fail=$((fail+1))
  fi
  # never leak a key through its own diagnostics
  if printf '%s' "$out" | grep -q 'AGE-SECRET-KEY'; then
    printf 'LEAK  %s printed key material\n' "$name"; fail=$((fail+1))
  fi
}

# --- the discriminator: which keys are accepted -----------------------------------------
run "titan host key accepted"            0 "$AGE_DIR/titan-key.txt"
run "admin key refused"                  1 "$AGE_DIR/keys.txt"
run "cluster (k8s) key refused"          1 "$AGE_DIR/titan-k8s-key.txt"
printf 'not a key\n' > "$WORK/junk"
run "junk file refused"                  1 "$WORK/junk"
age-keygen -o "$WORK/stray" >/dev/null 2>&1
if [ -f "$WORK/stray" ]; then
  run "stray valid age key refused"      1 "$WORK/stray"
fi
# a missing file is what `run` skips on, so this one goes straight at the script
if out=$(sh "$S" --key-file "$WORK/does-not-exist" --key-dest "$WORK/dest-x" --repo "$REPO" --no-activate 2>&1); then
  echo "FAIL  missing key file accepted"; fail=$((fail+1))
else
  echo "PASS  missing key file refused"; pass=$((pass+1))
fi
run "unknown flag"                       2 "$AGE_DIR/titan-key.txt" --nope

# --- the narrowing check, exercised on its own ------------------------------------------
# An admin key fails the identity check first, so to prove check 3 (the one that catches
# "wrong key installed cleanly") the identity check is deliberately disabled by passing the
# admin key's own recipient. It must then fail because it opens secrets.yaml.
if [ -f "$AGE_DIR/keys.txt" ] && [ -f "$AGE_DIR/titan-key.txt" ]; then
  ADMIN_PUB=$(age-keygen -y "$AGE_DIR/keys.txt" 2>/dev/null)
  run "narrowing check catches an admin key" 1 "$AGE_DIR/keys.txt" --recipient "$ADMIN_PUB"
fi

# --- an accepted run must actually install the right bytes, 0600 -------------------------
if [ -f "$AGE_DIR/titan-key.txt" ]; then
  cat "$AGE_DIR/titan-key.txt" > "$WORK/titan.copy"
  WANT=$(sha256sum "$WORK/titan.copy" | cut -d' ' -f1)
  sh "$S" --key-file "$WORK/titan.copy" --key-dest "$WORK/installed" \
     --repo "$REPO" --no-activate >/dev/null 2>&1
  GOT=$(sha256sum "$WORK/installed" 2>/dev/null | cut -d' ' -f1)
  if [ "$WANT" = "$GOT" ]; then
    echo "PASS  installed key is byte-identical to the candidate"; pass=$((pass+1))
  else
    echo "FAIL  installed key differs (or is missing)"; fail=$((fail+1))
  fi
  if [ "$(stat -c '%a' "$WORK/installed" 2>/dev/null)" = "600" ]; then
    echo "PASS  installed key is 0600"; pass=$((pass+1))
  else
    echo "FAIL  installed key mode is $(stat -c '%a' "$WORK/installed" 2>/dev/null)"; fail=$((fail+1))
  fi
fi

echo "---- $pass passed, $fail failed, $skip skipped"
[ "$fail" = "0" ]
