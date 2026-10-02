#!/bin/sh
# Task 17 Step 4: move titan's secrets out of secrets.yaml into secrets/titan.yaml,
# which .sops.yaml encrypts to the admin keys PLUS titan's own host key. After this, a
# popped titan decrypts secrets/titan.yaml and nothing else.
#
# Run from any machine holding an admin age key, with the repo clean.
#
# Two sops realities this script is shaped around:
#   * sops picks its creation rule from the path it is given, so encrypting a temp file
#     and renaming it would match no rule. Encryption happens in place (`sops -e -i`).
#   * sops has no value-removal flag -- only `set`. Stripping keys therefore goes through
#     plaintext at the real path for a moment, bounded by umask 077 and a trap that
#     restores the encrypted backup on any non-clean exit.
#
# Step 5 afterwards: point the five sops.secrets entries at the new file with
#   sopsFile = ../../secrets/titan.yaml;
# in hosts/titan/configuration.nix, or titan's build fails -- sops-nix resolves key
# NAMES at build time, so a missing key is a build error, not an activation surprise.
set -eu

cd "$(dirname "$0")/.."

if [ -e secrets/titan.yaml ]; then
  echo "refusing: secrets/titan.yaml already exists" >&2
  exit 1
fi

if ! git diff --quiet HEAD -- secrets.yaml .sops.yaml; then
  echo "refusing: secrets.yaml or .sops.yaml has uncommitted changes" >&2
  exit 1
fi

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

umask 077
WORK=$(mktemp -d)
BACKUP=""

is_encrypted() { grep -q '^sops:' "$1" 2>/dev/null; }

cleanup() {
  rc=$?
  # Undo whatever is half-written so the repo is never left holding plaintext. Each
  # check is guarded by is_encrypted, so a completed run is a no-op here.
  if [ -e secrets/titan.yaml ] && ! is_encrypted secrets/titan.yaml; then
    shred -u secrets/titan.yaml 2>/dev/null || rm -f secrets/titan.yaml
  fi
  if [ -n "$BACKUP" ] && [ -e secrets.yaml ] && ! is_encrypted secrets.yaml; then
    echo "restoring encrypted secrets.yaml from backup" >&2
    cp "$BACKUP" secrets.yaml
  fi
  for f in "$WORK"/*; do
    [ -e "$f" ] || continue
    shred -u "$f" 2>/dev/null || rm -f "$f"
  done
  rmdir "$WORK" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT INT TERM

# An encrypted copy of the original, kept outside the repo. Safe to keep: it is still
# encrypted, and it is the only way back if a step below half-finishes.
BACKUP="../secrets.yaml.pre-split.$(date +%Y%m%dT%H%M%S)"
cp secrets.yaml "$BACKUP"
echo "backup (encrypted): $BACKUP"

mkdir -p secrets
sops -d --output-type json secrets.yaml > "$WORK/dec.json"

# The five values that belong to titan alone. `.titan` and `.wireguard` are nested maps;
# only titan's own entries move.
jq '
  {
    titan: (.titan // {}),
    wireguard: { titan_private_key: .wireguard.titan_private_key },
    ssh_keys: {
      titan_host_private: .ssh_keys.titan_host_private,
      titan_host_public:  .ssh_keys.titan_host_public
    },
    k3s_token_titan: .k3s_token_titan
  }
' "$WORK/dec.json" > "$WORK/titan.json"

MISSING=$(jq -r '
  . as $d
  | [ "titan.network_env", "wireguard.titan_private_key",
      "ssh_keys.titan_host_private", "ssh_keys.titan_host_public", "k3s_token_titan" ]
    | map(. as $p | select((($d | getpath($p | split("."))) // "MISSING") == "MISSING") | $p)
    | join(" ")
' "$WORK/titan.json")
if [ -n "$MISSING" ]; then
  echo "refusing: not found in secrets.yaml: $MISSING" >&2
  exit 1
fi

jq '
  del(.titan, .wireguard.titan_private_key, .ssh_keys.titan_host_private,
      .ssh_keys.titan_host_public, .k3s_token_titan)
  | with_entries(select(.value != {} and .value != null))
' "$WORK/dec.json" > "$WORK/rest.json"

# pyyaml rather than a hand-rolled emitter: these values are long base64 scalars and
# multi-line PEM blocks, and getting indentation wrong is how you end up with a file sops
# encrypts happily and sops-nix then cannot parse.
to_yaml() {
  python3 -c '
import json, sys, yaml
yaml.safe_dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"),
               default_flow_style=False, width=10**9, allow_unicode=True)
' "$1" "$2"
}

to_yaml "$WORK/titan.json" secrets/titan.yaml
sops -e -i secrets/titan.yaml

to_yaml "$WORK/rest.json" secrets.yaml
sops -e -i secrets.yaml

# --- prove the split, not just that both files decrypt ---
# Path-aware on purpose: `network_env` and friends exist for every other host too, so a
# grep for the key name anywhere in secrets.yaml is a false alarm (it fired on the first
# real run, against k8s-node01/network_env).
sops -d --output-type json secrets/titan.yaml > "$WORK/v-titan.json"
sops -d --output-type json secrets.yaml > "$WORK/v-rest.json"
python3 - "$WORK/v-titan.json" "$WORK/v-rest.json" <<'PY'
import json, sys
titan = json.load(open(sys.argv[1]))
rest = json.load(open(sys.argv[2]))
paths = [("titan", "network_env"), ("wireguard", "titan_private_key"),
         ("ssh_keys", "titan_host_private"), ("ssh_keys", "titan_host_public"),
         ("k3s_token_titan",)]
def has(d, p):
    for k in p:
        if not isinstance(d, dict) or k not in d:
            return False
        d = d[k]
    return True
bad = ["/".join(p) for p in paths if not has(titan, p)]
bad += ["/".join(p) + " still in secrets.yaml" for p in paths if has(rest, p)]
if bad:
    sys.exit("FAIL: " + "; ".join(bad))
print("verified: all five present in secrets/titan.yaml, all five absent from secrets.yaml")
PY

# Presence is not enough. The values survive a round trip through sops JSON, jq, pyyaml
# and sops YAML on the way here, and the one that bites is the trailing newline on the
# OpenSSH private key -- lose it and ssh refuses the key with a confusing error, weeks
# later. So compare every value byte-for-byte against the pre-split file.
sops -d --input-type yaml --output-type json "$BACKUP" > "$WORK/orig.json"
sops -d --output-type json secrets/titan.yaml > "$WORK/new-titan.json"
sops -d --output-type json secrets.yaml > "$WORK/new-rest.json"
python3 - "$WORK/orig.json" "$WORK/new-titan.json" "$WORK/new-rest.json" <<'PY'
import json, sys
orig = json.load(open(sys.argv[1]))
merged = json.load(open(sys.argv[2]))

def deep_merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            deep_merge(a[k], v)
        else:
            a[k] = v
    return a

deep_merge(merged, json.load(open(sys.argv[3])))
if merged == orig:
    print("verified: every value byte-for-byte identical to the pre-split file")
else:
    diffs = []
    def walk(a, b, path=""):
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}" if path else k
            if k not in a or k not in b:
                diffs.append(f"{p}: present in only one side")
            elif isinstance(a[k], dict) and isinstance(b[k], dict):
                walk(a[k], b[k], p)
            elif a[k] != b[k]:
                diffs.append(f"{p}: differs (len {len(str(a[k]))} vs {len(str(b[k]))})")
    walk(orig, merged)
    sys.exit("FAIL: values changed:\n  " + "\n  ".join(diffs))
PY

if ! is_encrypted secrets/titan.yaml || ! is_encrypted secrets.yaml; then
  echo "FAIL: a file is not encrypted" >&2
  exit 1
fi

echo "OK: five values in secrets/titan.yaml; secrets.yaml re-encrypted to its own recipients."
echo "Next (Step 5): add 'sopsFile = ../../secrets/titan.yaml;' to the five entries in"
echo "hosts/titan/configuration.nix, then:"
echo "  nix eval .#nixosConfigurations.titan.config.sops.secrets --apply 'builtins.attrNames'"
