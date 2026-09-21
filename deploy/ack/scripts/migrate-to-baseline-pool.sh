#!/usr/bin/env bash
# Copyright 2026 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

if [[ ${1:-} != "--execute" ]]; then
  echo "Usage: KUBECONFIG=/path/to/config $0 --execute" >&2
  echo "This cordons and drains every node in the elastic pool." >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ack_dir=$(cd -- "$script_dir/.." && pwd)

command -v jq >/dev/null
command -v kubectl >/dev/null
[[ -n ${KUBECONFIG:-} && -s ${KUBECONFIG} ]] || {
  echo "Set KUBECONFIG to an ACK user kubeconfig before migrating nodes." >&2
  exit 1
}

$ack_dir/scripts/remote-config.sh prepare
pool_ids=$($ack_dir/scripts/tofu.sh output -json node_pool_ids)
baseline_pool=$(jq -er .baseline <<<"$pool_ids")
elastic_pool=$(jq -er .elastic <<<"$pool_ids")
expected_baseline=$($ack_dir/scripts/tofu.sh output -raw baseline_node_count)
[[ $baseline_pool != "$elastic_pool" ]] || {
  echo "Baseline and elastic outputs resolve to the same node pool; refusing migration." >&2
  exit 1
}

baseline_nodes=()
while IFS= read -r node; do
  [[ -n $node ]] && baseline_nodes+=("$node")
done < <(kubectl get nodes \
  -l "alibabacloud.com/nodepool-id=${baseline_pool}" \
  -o json | jq -r '.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.name')
if (( ${#baseline_nodes[@]} < expected_baseline )); then
  echo "Baseline pool has ${#baseline_nodes[@]} Ready nodes; expected ${expected_baseline}." >&2
  exit 1
fi

elastic_nodes=()
while IFS= read -r node; do
  [[ -n $node ]] && elastic_nodes+=("$node")
done < <(kubectl get nodes \
  -l "alibabacloud.com/nodepool-id=${elastic_pool}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if (( ${#elastic_nodes[@]} == 0 )); then
  echo "Elastic pool is already empty; no migration is required."
  exit 0
fi

restore_schedulability() {
  kubectl uncordon "${elastic_nodes[@]}" >/dev/null 2>&1 || true
}
trap restore_schedulability ERR INT TERM

wait_for_deployments() {
  local namespace deployment
  for namespace in kube-system higress-system tokenvolt-system; do
    while IFS= read -r deployment; do
      [[ -n $deployment ]] || continue
      kubectl -n "$namespace" rollout status "$deployment" --timeout=10m
    done < <(kubectl -n "$namespace" get deployment -o name 2>/dev/null || true)
  done
}

wait_for_deployments

# Cordon every source node first so an evicted Pod cannot move to another node
# that the autoscaler is expected to remove.
kubectl cordon "${elastic_nodes[@]}"
for node in "${elastic_nodes[@]}"; do
  kubectl drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=20m
done

wait_for_deployments

trap - ERR INT TERM
echo "Elastic nodes are drained and remain cordoned. ACK Cluster Autoscaler can now reduce the elastic pool to zero."
kubectl get nodes -L alibabacloud.com/nodepool-id,tokenvolt.ai/capacity-class
