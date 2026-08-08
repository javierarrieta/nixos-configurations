#!/usr/bin/env bash
# truenas-iscsi-helper-client.sh
#
# Client for the llm01 iSCSI helper used by the Coder provisioner pod (and by
# the plan's standalone test). Drives the helper lifecycle over mTLS:
#
#   provision  acquire lease -> provision target -> attach mount
#   attach     attach (log in + mount) existing target
#   detach     detach mount + release capability
#   destroy    detach -> delete target/zvol -> release capability
#
# The per-workspace capability is treated as sensitive state and persisted in
# a 0600 file under $CODER_HELPER_STATE_DIR (default ./.helper-state). It is
# sent only over the mTLS connection in the X-Coder-Capability header and is
# never written to the helper, to TrueNAS, or to any log.
#
# Required env:
#   CODER_HELPER_URL       e.g. https://llm01:2377
#   CODER_HELPER_CERT_DIR  dir containing ca.pem, cert.pem, key.pem
#   WORKSPACE              workspace identifier (^[a-z0-9][a-z0-9-]{0,62}$)
# Optional env:
#   SIZE_GB                disk size in GiB (10-200), required for provision
#   CODER_HELPER_STATE_DIR default ./.helper-state

set -euo pipefail

: "${CODER_HELPER_URL:?CODER_HELPER_URL is required}"
: "${CODER_HELPER_CERT_DIR:?CODER_HELPER_CERT_DIR is required}"
: "${WORKSPACE:?WORKSPACE is required}"

STATE_DIR="${CODER_HELPER_STATE_DIR:-./.helper-state}"
CAP_FILE="${STATE_DIR}/${WORKSPACE}.capability"
HELPER="${CODER_HELPER_URL}/v1"

if [[ ! -f "${CODER_HELPER_CERT_DIR}/ca.pem" ]] \
  || [[ ! -f "${CODER_HELPER_CERT_DIR}/cert.pem" ]] \
  || [[ ! -f "${CODER_HELPER_CERT_DIR}/key.pem" ]]; then
  echo "error: CODER_HELPER_CERT_DIR must contain ca.pem, cert.pem, key.pem" >&2
  exit 2
fi

CURL_ARGS=(
  --silent --show-error --fail-with-body
  --cert "${CODER_HELPER_CERT_DIR}/cert.pem"
  --key "${CODER_HELPER_CERT_DIR}/key.pem"
  --cacert "${CODER_HELPER_CERT_DIR}/ca.pem"
)

request() {
  local method="$1" path="$2" body="${3:-}" cap="${4:-}"
  local args=("${CURL_ARGS[@]}" -X "$method" -H "Content-Type: application/json")
  if [[ -n "$cap" ]]; then
    args+=(-H "X-Coder-Capability: $cap")
  fi
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}" "${HELPER}${path}"
}

get_capability() {
  if [[ -s "$CAP_FILE" ]]; then
    cat "$CAP_FILE"
    return 0
  fi
  echo "error: no capability for ${WORKSPACE}; run provision first" >&2
  exit 3
}

save_capability() {
  mkdir -p "$STATE_DIR"
  umask 077
  printf '%s' "$1" > "$CAP_FILE"
}

clear_capability() {
  rm -f "$CAP_FILE"
}

cmd_provision() {
  : "${SIZE_GB:?SIZE_GB is required for provision}"

  # Re-acquire idempotently: if we hold a capability, present it; the helper
  # returns the same capability. Otherwise acquire a fresh lease.
  local existing=""
  if [[ -s "$CAP_FILE" ]]; then
    existing="$(cat "$CAP_FILE")"
  fi

  local resp cap
  resp="$(request POST "/lease/${WORKSPACE}/acquire" "" "$existing")"
  cap="$(printf '%s' "$resp" | sed -n 's/.*"capability": *"\([^"]*\)".*/\1/p')"
  if [[ -z "$cap" ]]; then
    echo "error: acquire failed: $resp" >&2
    exit 1
  fi
  save_capability "$cap"

  resp="$(request POST "/workspaces/${WORKSPACE}/provision" "{\"size_gb\": ${SIZE_GB}}" "$cap")"
  echo "$resp"
  if ! printf '%s' "$resp" | grep -q '"ok": *true'; then
    echo "error: provision failed" >&2
    exit 1
  fi

  cmd_attach
}

cmd_attach() {
  local cap
  cap="$(get_capability)"
  local resp
  resp="$(request POST "/workspaces/${WORKSPACE}/attach" "" "$cap")"
  echo "$resp"
  if ! printf '%s' "$resp" | grep -q '"ok": *true'; then
    echo "error: attach failed" >&2
    exit 1
  fi
}

cmd_detach() {
  local cap
  cap="$(get_capability)"
  local resp
  resp="$(request POST "/workspaces/${WORKSPACE}/detach" "" "$cap")"
  echo "$resp"
  if ! printf '%s' "$resp" | grep -q '"ok": *true'; then
    echo "error: detach failed" >&2
    exit 1
  fi
  request POST "/lease/${WORKSPACE}/release" "" "$cap" >/dev/null
  clear_capability
}

cmd_destroy() {
  local cap
  cap="$(get_capability)"
  local resp
  # destroy also releases the lease on the server; clear local state on success.
  resp="$(request DELETE "/workspaces/${WORKSPACE}" "" "$cap")"
  echo "$resp"
  if ! printf '%s' "$resp" | grep -q '"ok": *true'; then
    echo "error: destroy failed" >&2
    exit 1
  fi
  clear_capability
}

case "${1:-}" in
  provision) cmd_provision ;;
  attach) cmd_attach ;;
  detach) cmd_detach ;;
  destroy) cmd_destroy ;;
  *)
    echo "usage: $0 {provision|attach|detach|destroy}" >&2
    exit 2
    ;;
esac
