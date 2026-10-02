#!/usr/bin/env bash
set -euo pipefail

# Comin branch-based hard-gate rollout.
# Canary ring (auto, branch main): node05 + llm01 + titan — must converge healthy
# or we abort. titan is spelled as its public FQDN because it is not in the bind
# zone (see ssh_host/ssh_port below).
# Fleet ring (manual, branch stable): accepted here in least -> most critical order.
CANARY_RING=(k8s-node05 llm01 titan.arrieta.eu)
ORDER=(k8s-node04 k8s-node03 k8s-node02 k8s-node01 k8s-pi01 k8s-pi02 k8s-pi03 k8s-server01 k8s-server02 k8s-server03)
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

deploy_status() { # host -> deployer.deployment.status
  ssh -p "$(ssh_port "$1")" "$(ssh_host "$1")" 'comin status --json' 2>/dev/null | jq -r '.deployer.deployment.status? // "none"'
}

is_suspended() { # host -> "true" if comin deployer is suspended (manager or deployer level)
  ssh -p "$(ssh_port "$1")" "$(ssh_host "$1")" 'comin status --json' 2>/dev/null \
    | jq -r 'if (.is_suspended // false) or (.deployer.is_suspended // false) then "true" else "false" end'
}

pending() { # host -> prints 1 if a deploy confirmation is pending
  ssh -p "$(ssh_port "$1")" "$(ssh_host "$1")" 'comin status --json' 2>/dev/null | jq -r 'if (.deploy_confirmer.submitted? != "" and .deploy_confirmer.confirmed? == "") then 1 else 0 end'
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
  if [ "$(is_suspended "$c")" = "true" ]; then
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
  ssh -p "$(ssh_port "$h")" "$(ssh_host "$h")" 'comin confirmation accept'
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