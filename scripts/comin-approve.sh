#!/usr/bin/env bash
set -euo pipefail

# Comin branch-based hard-gate rollout.
# Canary ring (auto, branch main): node05 + llm01 + titan — must converge healthy
# or we abort. titan is spelled as its public FQDN because it is not in the bind
# zone (see ssh_host/ssh_port below).
# Fleet ring (manual, branch stable): accepted here, in the order chosen below.
CANARY_RING=(k8s-node05 llm01 titan.arrieta.eu)

# Fleet accept order. Two orders, because two different failure models:
#
#   servers-first (default) -- control plane, then workers, then Pis. This is the
#     order k3s REQUIRES whenever the pending generation changes the k3s version:
#     the Kubernetes skew policy lets servers run newer than agents and never
#     the reverse, so accepting a worker first puts a newer kubelet on a cluster
#     whose API servers are still old. Correct for every deploy, since a version
#     change is the only one where order has a correctness constraint.
#   risk -- least -> most critical (workers, Pis, then control plane). Smaller
#     blast radius first; use it for a change that is risky but version-neutral,
#     where losing a worker is cheaper than losing a server:
#     COMIN_ORDER=risk ./scripts/comin-approve.sh
#
# Note the canary ring cannot cover the skew constraint for the home cluster:
# k8s-node05 is a WORKER and auto-deploys off main, so a k3s version bump lands
# there before any casa server does. Suspend comin on node05 before merging to
# main, and resume it once the servers have converged.
case "${COMIN_ORDER:-servers-first}" in
  servers-first) ORDER=(k8s-server01 k8s-server02 k8s-server03 k8s-node01 k8s-node02 k8s-node03 k8s-node04 k8s-pi01 k8s-pi02 k8s-pi03) ;;
  risk) ORDER=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03) ;;
  *) echo "COMIN_ORDER must be 'servers-first' or 'risk', got '${COMIN_ORDER}'" >&2; exit 1 ;;
esac
# k8s nodes only (llm01 is not a cluster node — skip its node_ready wait).
# titan is deliberately absent: it is a k8s node, but of its own cluster, which
# this runner's kubectl (pointed at the home cluster) cannot see.
K8S_NODES=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03 k8s-node05)

# ssh targets are FQDNs (bind zone casa.arrieta); kubectl keeps short names
DOMAIN="${COMIN_DOMAIN:-casa.arrieta}"
# titan is not in the bind zone and its sshd is not on 22; a host name that
# already contains a dot is used verbatim.
ssh_host() { case "$1" in *.*) echo "$1";; *) echo "$1.$DOMAIN";; esac; }
ssh_port() { case "$1" in titan|titan.arrieta.eu) echo 13491;; *) echo 22;; esac; }

# The home cluster, named. Relying on an ambient current-context was a real
# failure mode (2026-11-07): ~/.kube/config had `current-context: ""`, kubectl
# fell back to localhost:8080, and the canary wait looped 600s in silence on a
# node that was Ready the whole time. The gatekeeper names its cluster so a local
# kubeconfig edit cannot impersonate an outage. Override per run with
# COMIN_KUBE_CONTEXT when this runner's kubeconfig names it differently.
KUBE_CONTEXT="${COMIN_KUBE_CONTEXT:-casa}"

# Scratch for ssh/comin stderr (kept apart from stdout, see comin_json) and for
# the once-per-host error markers. The markers are files, not a shell variable,
# because every caller runs comin_json on the left of a pipe — i.e. in a subshell
# — so an in-memory marker would be discarded before the next probe.
COMIN_ERR=$(mktemp -t comin-approve-err 2>/dev/null || true)
[ -n "$COMIN_ERR" ] || COMIN_ERR="${TMPDIR:-/tmp}/comin-approve-err.$$"
COMIN_MARKS="${TMPDIR:-/tmp}/comin-approve-marks.$$"
mkdir -p "$COMIN_MARKS"
trap 'rm -f "$COMIN_ERR"; rmdir "$COMIN_MARKS" 2>/dev/null || true' EXIT

is_k8s_node() { # host -> 0 if the host is a k8s node
  printf '%s\n' "${K8S_NODES[@]}" | grep -qx "$1"
}

notify() { # message — desktop notification where available (macOS), no-op elsewhere
  local msg="$1"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"comin approve\""
  fi
  echo "NOTIFY: $msg"
}

# Read a host's comin status. A host you cannot read is an ERROR, not an empty
# answer: every caller below used to treat empty output as "nothing pending", so
# k8s-server03 was reported as "nothing pending, skipping" for five weeks -- its
# host key was rotated in 5029fe6 (2026-10-03, after 82ad758 leaked the old one
# to a public repo), ssh refused on the stale known_hosts entry, and the stderr
# carrying that refusal went to /dev/null. Same class as the kubectl bug above:
# a swallowed error impersonating a healthy "nothing to do".
#
# stdout and stderr are kept apart on purpose: merging them (2>&1) makes any
# benign ssh/comin stderr — "Permanently added '<host>' to the list of known
# hosts", a remote rc echo — part of the "JSON", jq then fails on it, and
# wait_for silently retries a perfectly healthy host for 1200s. That is the same
# swallowed-error class this function exists to remove.
#
# The reason prints once per host, not once per probe: wait_for calls this every
# 5s for up to 1200s, so an unreachable host would otherwise emit 240 identical
# lines. A later success clears the marker, so a new failure is still reported.
comin_report() { # host, message -> print once per host until the next success
  local host="$1"; shift
  [ -e "$COMIN_MARKS/$host" ] && return 0
  : >"$COMIN_MARKS/$host"
  printf '%s\n' "$*" >&2
}

comin_json() { # host -> comin status JSON on stdout, or non-zero + reason on stderr
  local host="$1" out reason
  if ! out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$(ssh_port "$host")" "$(ssh_host "$host")" 'comin status --json' 2>"$COMIN_ERR"); then
    reason=$(tr '\n' ' ' <"$COMIN_ERR" | head -c 200)
    comin_report "$host" "comin status unavailable on $host: ${reason:-ssh failed silently}"
    return 1
  fi
  if ! printf '%s\n' "$out" | jq -e . >/dev/null 2>&1; then
    reason=$(printf '%s' "$out" | tr '\n' ' ' | head -c 200)
    comin_report "$host" "comin returned non-JSON on $host: ${reason:-<empty>}"
    return 1
  fi
  rm -f "$COMIN_MARKS/$host"
  printf '%s\n' "$out"
}

deploy_status() { # host -> deployer.deployment.status
  comin_json "$1" | jq -r '.deployer.deployment.status? // "none"'
}

is_suspended() { # host -> "true" if comin deployer is suspended (manager or deployer level)
  comin_json "$1" | jq -r 'if (.is_suspended // false) or (.deployer.is_suspended // false) then "true" else "false" end'
}

pending() { # host -> prints 1 if a deploy confirmation is pending
  comin_json "$1" | jq -r 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end'
}

# No `2>/dev/null` here on purpose. It was the actual root cause of the 2026-11-07
# silence: `context "casa" does not exist` went to /dev/null and the caller saw an
# empty string, indistinguishable from a node that is not Ready. wait_for captures
# this stderr into its progress/timeout line.
node_ready() { # node -> 1 when Ready
  kubectl --context "$KUBE_CONTEXT" get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

kubelet_version() { # node -> the kubeletVersion the API server reports
  kubectl --context "$KUBE_CONTEXT" get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}'
}

# Optional proof that the switch actually landed. `deployment.status == done`
# is not that proof -- see "comin-approve.sh 'deploy done' is not proof of a
# switch" in AGENTS.md: the deployer reports done for the PREVIOUS deploy when
# it stalls, and a node stays Ready across a k3s restart, so on a version bump
# both existing waits can pass with the old binary still running. Set
# EXPECT_VERSION to the kubeletVersion every fleet node must end on:
#   EXPECT_VERSION=v1.36.4+k3s1 ./scripts/comin-approve.sh
# Only for a deploy that moves the whole fleet ring to one version; a node held
# back on purpose (k3s.package pinned to the old minor) will time out here.
wait_version() { # node -> wait until it reports EXPECT_VERSION
  local n="$1" v="" i=0
  while :; do
    v=$(kubelet_version "$n")
    if [ "$v" = "$EXPECT_VERSION" ]; then echo "$n kubelet $v OK"; return; fi
    [ "$i" -lt "${VERSION_TIMEOUT:-600}" ] || { echo "TIMEOUT: $n reports kubelet '$v', wanted '$EXPECT_VERSION' -- the switch did not land"; exit 1; }
    sleep 5; i=$((i + 5))
  done
}

wait_for() { # desc, seconds, cmd...
  local desc="$1" timeout="$2"; shift 2
  local i=0 out=""
  # `out` holds the RAW probe output (stdout+stderr), then gets grepped; capturing
  # grep's own output would always be empty, because grep prints nothing on a miss
  # and the loop body only runs on a miss. A silent 600s loop is indistinguishable
  # from a hung script when the probe returns empty (unreachable API server, bad
  # kubeconfig, wrong node name) — so the value is echoed every 30s and on timeout.
  until out=$("$@" 2>&1) && printf '%s\n' "$out" | grep -q "1\|True\|done"; do
    [ $i -lt "$timeout" ] || { echo "TIMEOUT waiting for $desc -- last probe output: '${out:0:200}'"; exit 1; }
    if [ "$i" -gt 0 ] && [ $((i % 30)) -eq 0 ]; then
      echo "  ... still waiting for $desc (${i}s / ${timeout}s, last probe: '${out:0:120}')"
    fi
    sleep 5; i=$((i + 5))
  done
  echo "$desc OK"
}

require_cluster() { # fail fast when kubectl cannot reach the cluster at all
  local out
  if ! out=$(kubectl --context "$KUBE_CONTEXT" get nodes 2>&1); then
    notify "kubectl --context $KUBE_CONTEXT cannot reach the cluster — rollout aborted"
    echo "ABORT: kubectl --context $KUBE_CONTEXT cannot reach the cluster: ${out:-unknown error}"
    echo "Fix the kubeconfig, or point the gatekeeper elsewhere with COMIN_KUBE_CONTEXT."
    exit 1
  fi
}

# 1) Canary pre-flight. Suspension = the health gate rolled a canary back,
#    so abort the rollout before touching the fleet.
# Cluster reachability is checked before any ssh, and unconditionally: the fleet
# loop needs the cluster too and runs ~10 minutes later, and without this the
# first k8s canary burns its full 600s Ready wait on a local kubectl problem.
require_cluster

for c in "${CANARY_RING[@]}"; do
  echo "== waiting for canary $c to auto-deploy"
  # Probe reachability first: an unreachable canary would otherwise burn the
  # whole 1200s deploy timeout before this script could say so. Three tries, so
  # a canary mid-switch or a cold resolver is not mistaken for a dead host.
  probe=0
  for _ in 1 2 3; do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$(ssh_port "$c")" "$(ssh_host "$c")" true 2>/dev/null; then
      probe=1; break
    fi
    sleep 5
  done
  if [ "$probe" != "1" ]; then
    echo "ABORT: canary $c is unreachable on port $(ssh_port "$c") after 3 tries. Causes are not only network: a new host key (accept it once by hand) or BatchMode refusing a passphrase-protected key look identical here. If titan has not been bootstrapped yet (plan Task 14), remove it from CANARY_RING for this run."
    exit 1
  fi
  wait_for "$c deploy done" 1200 deploy_status "$c"
  # Statement-level assignment, not `if [ "$(f)" = x ]`: inside `[ ... ]` the
  # test's own exit status wins, so the function's failure never reached set -e.
  # This only aborts because of `pipefail` on line 2 — without it jq's exit 0 wins,
  # the value is empty, "not suspended" is reported, and the run continues blind.
  # Do not remove pipefail.
  susp=$(is_suspended "$c")
  if [ "$susp" = "true" ]; then
    notify "$c rolled back (comin suspended) — rollout aborted"
    echo "ABORT: $c rolled back (comin suspended). Fix main before retrying."
    exit 1
  fi
  if is_k8s_node "$c"; then
    wait_for "$c node Ready" 600 node_ready "$c"
  else
    echo "== $c: not a k8s node, skipping node Ready wait"
  fi
done
echo "== canary ring healthy (node05 + llm01 + titan)"

# 2) Fleet pre-check: tell the operator when promotion hasn't happened yet.
#    Fleet hosts track 'stable'; a pending confirmation only appears after the
#    main -> stable merge is pushed.
# Fail closed on purpose: an unreadable fleet host aborts the run here rather
# than falling through to "no pending confirmations" (that is how k8s-server03
# hid for five weeks). A host held back deliberately must be taken out of ORDER
# for this run, not left unreachable.
fleet_pending=0
for h in "${ORDER[@]}"; do
  p=$(pending "$h")
  if [ "$p" = "1" ]; then fleet_pending=1; fi
done
if [ "$fleet_pending" = "0" ]; then
  echo "Fleet has no pending confirmations — merge main -> stable and push, then re-run."
  exit 0
fi

# 3) Accept the fleet in order, waiting for each to converge.
for h in "${ORDER[@]}"; do
  p=$(pending "$h")
  if [ "$p" != "1" ]; then
    echo "== $h: nothing pending, skipping"
    continue
  fi
  echo "== $h: deploy confirmation pending — accepting"
  # Same ssh hardening as every other call: without BatchMode/ConnectTimeout this
  # is the one ssh in the script that can hang forever on a prompt or a dead TCP.
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$(ssh_port "$h")" "$(ssh_host "$h")" 'comin confirmation accept'; then
    notify "$h: comin confirmation accept failed — rollout aborted"
    echo "ABORT: could not accept the pending confirmation on $h (ssh or comin failed above)."
    exit 1
  fi
  wait_for "$h deploy done" 900 deploy_status "$h"
  susp=$(is_suspended "$h")
  if [ "$susp" = "true" ]; then
    echo "ABORT: $h rolled back (comin suspended). Investigate before continuing."
    exit 1
  fi
  if is_k8s_node "$h"; then
    wait_for "$h node Ready" 600 node_ready "$h"
    [ -n "${EXPECT_VERSION:-}" ] && wait_version "$h"
  else
    echo "== $h: not a k8s node, skipping node Ready wait"
  fi
done
echo "ALL HOSTS DEPLOYED AND READY"