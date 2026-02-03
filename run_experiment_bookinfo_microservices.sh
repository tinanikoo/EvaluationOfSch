#!/bin/bash
#
# Copyright (c) 2025 Athena RC.
# Copyright (c) 2026 Tina Samizadeh.
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
#
# SPDX-License-Identifier: Apache-2.0
#
# Contributors:
#      George Koukis - author
#      Tina Samizadeh - modifications (Bookinfo experiments, logging, etc.)
#
# Modifications (summary):
# Modifications:
#   - Replaced postgres/perfapp workload with Bookinfo microservices workload
#   - Added summary log extraction and scheduler selection
#   - Adjusted namespace cleanup for kube-burner namespace suffix (-0)
#   - Logs

set -euo pipefail

# ---------------------------------------------------------------------------
# Tina Samizadeh: Summary log
# ---------------------------------------------------------------------------
SCHED="${1:-qos}"   # qos | def
DATE_TAG="$(date +%d%b_%H%M)"
SUMMARY_FILE="kube-burner-podlatency-summary_${DATE_TAG}_${SCHED}_5.log"
echo "# podLatency summary (selected kube-burner output)" >> "${SUMMARY_FILE}"
echo "# started: $(date -Is)" >> "${SUMMARY_FILE}"
echo "# scheduler: ${SCHED}" >> "${SUMMARY_FILE}"
echo >> "${SUMMARY_FILE}"
# ---------------------------------------------------------------------------

TEMPLATE_FILE="kubelet-density-heavy.bookinfo.template.yml"
NAMESPACE="kubelet-density-heavy"     # kube-burner will use ${NAMESPACE}-0
SLEEP_BETWEEN_EXPS=45                
iterations=1

# ---------------------------------------------------------------------------
# Experiments configuration
# ---------------------------------------------------------------------------
experiments=(
  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=5"
  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=5"
  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=5"
  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=5"

  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=10"
  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=10"
  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=10"
  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=10"

  "jobIterations=1 qps=1 burst=1 bookinfo_replicas=40"
  "jobIterations=1 qps=100 burst=100 bookinfo_replicas=40"
  "jobIterations=1 qps=500 burst=500 bookinfo_replicas=40"
  "jobIterations=1 qps=1000 burst=1000 bookinfo_replicas=40"
)

# ---------------------------------------------------------------------------
# Tina Samizadeh: Collect Logs (improved & robust)
# ---------------------------------------------------------------------------
extract_podlatency_block() {
  local src_log="$1"
  local experiment_desc="$2"
  local run_id="$3"

  # Try to extract UUID from log
  local uuid
  uuid="$(grep -Eo 'UUID [0-9a-fA-F-]{36}' "${src_log}" 2>/dev/null | head -n 1 | awk '{print $2}')"
  uuid="${uuid:-NA}"

  {
    echo "============================================================"
    echo "ts=$(date -Is)"
    echo "run=${run_id}"
    echo "experiment=${experiment_desc}"
    echo "uuid=${uuid}"
    echo "log=${src_log}"
    echo "------------------------------------------------------------"

    # Extract podLatency block (best-effort):
    # Start when we see "Stopping measurement: podLatency"
    # Stop when we see either:
    #   - "Finished execution with UUID"
    #   - "👋 Exiting kube-burner"
    #   - end of file
    awk '
      /Stopping measurement: podLatency/ {p=1}
      p {print}
      /Finished execution with UUID:/ {if(p){exit}}
      /👋 Exiting kube-burner/ {if(p){exit}}
    ' "${src_log}"

    echo
  } >> "${SUMMARY_FILE}"
}
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Function: HIGH-ACCURACY deletion measurement (ms resolution, 3 decimals)
# ---------------------------------------------------------------------------
measure_delete_time() {
  local ns="${NAMESPACE}-0"
  local experiment_desc="$1"
  local run_id="$2"

  echo "------"
  echo "Starting deletion of resources in namespace '${ns}' for run=${run_id}"
  echo "Experiment: ${experiment_desc}"

  local start_ts_ms end_ts_ms duration_ms sec ms_rem duration
  start_ts_ms=$(date +%s%3N)

  # Delete deployments and services created by kube-burner
  kubectl delete deployment,svc -n "${ns}" --all --ignore-not-found=true >/dev/null 2>&1 || true

  # Poll until all pods, deployments, and services are gone
  while true; do
    local remaining
    remaining=$(kubectl get pods,deploy,svc -n "${ns}" --no-headers 2>/dev/null | wc -l || echo 0)
    if [ "${remaining}" -eq 0 ]; then
      break
    fi
    echo "Waiting for resources to be deleted... remaining objects: ${remaining}"
    sleep 0.2
  done

  end_ts_ms=$(date +%s%3N)
  duration_ms=$((end_ts_ms - start_ts_ms))
  sec=$((duration_ms / 1000))
  ms_rem=$((duration_ms % 1000))
  duration=$(printf "%d.%03d" "${sec}" "${ms_rem}")

  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s"
  echo "DeleteDurationSeconds run=${run_id} ${experiment_desc} duration=${duration}s" >> deletion_times.log

  echo "Finished deletion timing for run=${run_id} (${duration}s)"
  echo "------"
}

# ---------------------------------------------------------------------------
# Select the correct bookinfo manifest (qos vs def)
# ---------------------------------------------------------------------------
if [ "${SCHED}" = "def" ]; then
  cp -f bookinfo-microservices-def.yml bookinfo-microservices.yml
else
  cp -f bookinfo-microservices-qos.yml bookinfo-microservices.yml
fi

# ---------------------------------------------------------------------------
# Determine the starting log counter
# ---------------------------------------------------------------------------
if ls kubelet-density-heavy_*.log 1> /dev/null 2>&1; then
  counter=$(ls kubelet-density-heavy_*.log | grep -o '[0-9]*\.log' | grep -o '[0-9]*' | sort -n | tail -1)
  counter=$((counter + 1))
else
  counter=1
fi

# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
for (( run=1; run<=iterations; run++ )); do
  echo "============================================================"
  echo "Starting run ${run} of ${iterations}"
  echo "Using template file: ${TEMPLATE_FILE}"
  echo "Base Namespace: ${NAMESPACE} (kube-burner uses ${NAMESPACE}-0)"
  echo "Scheduler: ${SCHED}"
  echo "============================================================"

  for experiment in "${experiments[@]}"; do
    echo "------------------------------------------------------------"
    echo "Running experiment: ${experiment}"
    echo "------------------------------------------------------------"

    # Namespace cleanup before each experiment (delete BOTH base and -0)
    if kubectl get namespace "${NAMESPACE}-0" &> /dev/null; then
      echo "Namespace ${NAMESPACE}-0 exists. Deleting..."
      kubectl delete namespace "${NAMESPACE}-0"
      while kubectl get namespace "${NAMESPACE}-0" &> /dev/null; do
        echo "Waiting for namespace ${NAMESPACE}-0 cleanup..."
        sleep 1
      done
    fi

    if kubectl get namespace "${NAMESPACE}" &> /dev/null; then
      echo "Namespace ${NAMESPACE} exists. Deleting..."
      kubectl delete namespace "${NAMESPACE}"
      while kubectl get namespace "${NAMESPACE}" &> /dev/null; do
        echo "Waiting for namespace ${NAMESPACE} cleanup..."
        sleep 1
      done
    fi

    kubectl create namespace "${NAMESPACE}" >/dev/null 2>&1 || true

    # Parse experiment variables
    eval "${experiment}"

    export NAMESPACE="${NAMESPACE}"
    export JOB_ITERATIONS="${jobIterations}"
    export QPS="${qps}"
    export BURST="${burst}"
    export BOOKINFO_REPLICAS="${bookinfo_replicas}"

    # Generate kube-burner config from template
    envsubst < "${TEMPLATE_FILE}" > kubelet-density-heavy.yml

    # Run kube-burner
    kube-burner init -c kubelet-density-heavy.yml

    # Rename kube-burner log
    log_file=$(ls -t kube-burner-*.log | head -n 1)
    new_log_file="kubelet-density-heavy_bookinfo_${SCHED}_jobIterations${jobIterations}_qps${qps}_burst${burst}_replicas${bookinfo_replicas}_${counter}.log"
    mv "${log_file}" "${new_log_file}"

    # Tina: extract podLatency summary block
    extract_podlatency_block "${new_log_file}" "${experiment}" "${run}"

    # Measure precise deletion timing
    measure_delete_time "${experiment}" "${run}"

    counter=$((counter + 1))

    echo "Sleeping ${SLEEP_BETWEEN_EXPS} seconds before next experiment..."
    sleep "${SLEEP_BETWEEN_EXPS}"
  done
done

echo "All Bookinfo microservices experiments completed."

