#!/usr/bin/env bash
set -euo pipefail

# Comin branch-based hard-gate rollout.
# Canary ring (auto, branch main): node05 + llm01 — must converge healthy or we abort.
# Fleet ring (manual, branch stable): accepted here in least -> most critical order.
CANARY_RING=(k8s-node05 llm01)
ORDER=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03)
# k8s nodes only (llm01 is not a cluster node — skip its node_ready wait)
K8S_NODES=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03 k8s-node05)

is_k8s_node() { # host -> 0 if the host is a k8s node
  printf '%s\n' "${K8S_NODES[@]}" | grep -qx "$1"
}

deploy_status() { # host -> deployer.deployment.status
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r '.deployer.deployment.status? // "none"'
}

is_suspended() { # host -> "true" if comin is suspended
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r '.is_suspended // "false"'
}

pending() { # host -> prints 1 if a deploy confirmation is pending
  ssh "$1" 'comin status --json' 2>/dev/null | jq -r 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end'
}

node_ready() { # node -> 1 when Ready
  kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}

wait_for() { # desc, seconds, cmd...
  local desc="$1" timeout="$2"; shift 2
  local i=0
  until "$@" | grep -q "1\|True\|done"; do
    [ $i -lt "$timeout" ] || { echo "TIMEOUT waiting for $desc"; exit 1; }
    sleep 5; i=$((i + 5))
  done
  echo "$desc OK"
}

# 1) Canary pre-flight. Suspension = the health gate rolled a canary back,
#    so abort the rollout before touching the fleet.
for c in "${CANARY_RING[@]}"; do
  echo "== waiting for canary $c to auto-deploy"
  wait_for "$c deploy done" 1200 deploy_status "$c"
  if [ "$(is_suspended "$c")" = "true" ]; then
    osascript -e "display notification \"$c rolled back (comin suspended) — rollout aborted\" with title \"comin approve\""
    echo "ABORT: $c rolled back (comin suspended). Fix main before retrying."
    exit 1
  fi
  if is_k8s_node "$c"; then
    wait_for "$c node Ready" 600 node_ready "$c"
  else
    echo "== $c: not a k8s node, skipping node Ready wait"
  fi
done
echo "== canary ring healthy (node05 + llm01)"

# 2) Fleet pre-check: tell the operator when promotion hasn't happened yet.
#    Fleet hosts track 'stable'; a pending confirmation only appears after the
#    main -> stable merge is pushed.
fleet_pending=0
for h in "${ORDER[@]}"; do
  [ "$(pending "$h")" = "1" ] && fleet_pending=1
done
if [ "$fleet_pending" = "0" ]; then
  echo "Fleet has no pending confirmations — merge main -> stable and push, then re-run."
  exit 0
fi

# 3) Accept the fleet in order, waiting for each to converge.
for h in "${ORDER[@]}"; do
  if [ "$(pending "$h")" != "1" ]; then
    echo "== $h: nothing pending, skipping"
    continue
  fi
  echo "== $h: deploy confirmation pending — accepting"
  ssh "$h" 'comin confirmation accept'
  wait_for "$h deploy done" 900 deploy_status "$h"
  if [ "$(is_suspended "$h")" = "true" ]; then
    echo "ABORT: $h rolled back (comin suspended). Investigate before continuing."
    exit 1
  fi
  if is_k8s_node "$h"; then
    wait_for "$h node Ready" 600 node_ready "$h"
  else
    echo "== $h: not a k8s node, skipping node Ready wait"
  fi
done
echo "ALL HOSTS DEPLOYED AND READY"