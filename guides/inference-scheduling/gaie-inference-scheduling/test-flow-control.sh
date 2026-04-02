#!/usr/bin/env bash
#
# Test SLO-deadline ordering within a single priority band.
# All requests use the same objective but different x-slo-ttft-ms values.
# Requests with tighter SLOs should get lower TTFT under contention.
#
# Usage: ./test-flow-control.sh [NAMESPACE] [GATEWAY_SVC]

set -uo pipefail

NAMESPACE="${1:-rsaini-dev}"
GATEWAY_SVC="${2:-infra-inference-scheduling-inference-gateway-istio}"
EPP_SVC="gaie-inference-scheduling-epp"
MODEL="Qwen/Qwen3-32B"

# All requests use the same objective (critical, priority=10)
# but with different SLO targets
OBJECTIVE="critical"
N_TIGHT=40     # slo=5000ms  (tight deadline, should be served first)
N_MEDIUM=80    # slo=30000ms (medium deadline)
N_RELAXED=200  # slo=120000ms (relaxed deadline, should be served last)

RESULTS_DIR="/tmp/fc-test-$(date +%s)"
mkdir -p "${RESULTS_DIR}/traces"

echo "=== Flow Control Priority Test (Streaming + Prometheus) ==="
echo "Namespace:  ${NAMESPACE}"
echo "Gateway:    ${GATEWAY_SVC}"
echo "Model:      ${MODEL}"
echo "Results:    ${RESULTS_DIR}"
echo ""

# --- Port-forwards ---
echo "Setting up port-forwards..."
kubectl port-forward -n "${NAMESPACE}" "svc/${GATEWAY_SVC}" 8080:80 &>/dev/null &
PF_GW_PID=$!
kubectl port-forward -n "${NAMESPACE}" "svc/${EPP_SVC}" 9091:9090 &>/dev/null &
PF_EPP_PID=$!

cleanup() {
    kill "${PF_GW_PID}" "${PF_EPP_PID}" 2>/dev/null || true
    wait "${PF_GW_PID}" "${PF_EPP_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for port-forwards to be ready
echo "Waiting for port-forwards..."
for attempt in $(seq 1 10); do
    if curl -s -o /dev/null --max-time 1 http://localhost:8080/ 2>/dev/null; then
        break
    fi
    sleep 1
done

URL="http://localhost:8080/v1/completions"
METRICS_URL="http://localhost:9091/metrics"

# --- Metrics auth ---
METRICS_TOKEN=$(kubectl get secret -n "${NAMESPACE}" inference-scheduling-gateway-sa-metrics-reader-secret \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

fetch_metrics() {
    if [[ -n "${METRICS_TOKEN}" ]]; then
        curl -s -H "Authorization: Bearer ${METRICS_TOKEN}" "${METRICS_URL}" 2>/dev/null
    else
        curl -s "${METRICS_URL}" 2>/dev/null
    fi
}

# --- Snapshot metrics before test ---
echo "Snapshotting pre-test metrics..."
fetch_metrics > "${RESULTS_DIR}/metrics_before.txt"

# --- Streaming request sender ---
send_streaming_request() {
    local priority="$1"
    local slo_ttft="$2"
    local id="$3"
    local slo_label="$4"
    local trace_file="${RESULTS_DIR}/traces/${slo_label}_${id}.txt"

    # Randomize prompt to defeat prefix cache and KV cache reuse
    local rand_id
    rand_id=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
    local body
    body=$(cat <<EOF
{"model":"${MODEL}","prompt":"[${rand_id}] Write a detailed essay about the history of distributed systems covering key milestones from the 1960s to the present day.","max_tokens":500,"temperature":0.7,"stream":true}
EOF
)

    local start_ns
    start_ns=$(date +%s%N)
    echo "START ${start_ns}" > "${trace_file}"

    # Stream curl output, timestamp each token-bearing SSE chunk.
    # Only bash builtins + one date call per chunk for minimal overhead.
    curl -s -N \
        -X POST "${URL}" \
        -H "Content-Type: application/json" \
        -H "x-gateway-inference-objective: ${priority}" \
        -H "x-slo-ttft-ms: ${slo_ttft}" \
        -d "${body}" \
        --max-time 120 2>/dev/null | while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" == "data: [DONE]" ]] && continue
        [[ "${line}" != data:* ]] && continue
        [[ "${line}" != *'"text":"'* ]] && continue
        echo "$(date +%s%N)"
    done >> "${trace_file}"

    # Post-process trace file to compute TTFT/TPOT
    local timestamps
    timestamps=$(tail -n +2 "${trace_file}")
    local token_count
    token_count=$(echo "${timestamps}" | grep -c '[0-9]' || true)

    if [[ "${token_count}" -gt 1 ]]; then
        local first_ns last_ns
        first_ns=$(echo "${timestamps}" | head -1)
        last_ns=$(echo "${timestamps}" | tail -1)
        local ttft_ms=$(( (first_ns - start_ns) / 1000000 ))
        local total_ms=$(( (last_ns - start_ns) / 1000000 ))
        local generation_ms=$(( (last_ns - first_ns) / 1000000 ))
        local tpot_ms=$(( generation_ms / (token_count - 1) ))
        local first_token_epoch_ms=$(( first_ns / 1000000 ))
        echo "${slo_label},${id},${slo_ttft},${ttft_ms},${tpot_ms},${token_count},${total_ms},${first_token_epoch_ms}"
    elif [[ "${token_count}" -eq 1 ]]; then
        local first_ns
        first_ns=$(echo "${timestamps}" | head -1)
        local ttft_ms=$(( (first_ns - start_ns) / 1000000 ))
        local first_token_epoch_ms=$(( first_ns / 1000000 ))
        echo "${slo_label},${id},${slo_ttft},${ttft_ms},0,1,${ttft_ms},${first_token_epoch_ms}"
    else
        echo "${slo_label},${id},${slo_ttft},-1,-1,0,-1,0"
    fi >> "${RESULTS_DIR}/results.csv"
}

echo "slo_label,id,slo_ttft_ms,ttft_ms,tpot_ms,tokens,total_ms,first_token_epoch_ms" > "${RESULTS_DIR}/results.csv"

N_WARMUP=100
WARMUP_PIDS=()

# Phase 0: Warmup — saturate the system so the EPP detects backpressure
# These use relaxed SLOs and are not measured; they just fill the pipeline
echo "Warming up with ${N_WARMUP} requests to saturate the system..."
for i in $(seq 1 "${N_WARMUP}"); do
    rand_id=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
    curl -s -N -X POST "${URL}" \
        -H "Content-Type: application/json" \
        -H "x-gateway-inference-objective: ${OBJECTIVE}" \
        -H "x-slo-ttft-ms: 30000" \
        -d "{\"model\":\"${MODEL}\",\"prompt\":\"[${rand_id}] Describe the complete history of every programming language ever created in exhaustive detail.\",\"max_tokens\":500,\"temperature\":0.7,\"stream\":true}" \
        --max-time 120 > /dev/null 2>&1 &
    WARMUP_PIDS+=($!)
done

# Wait for metrics to reflect saturation (EPP scrapes every 50ms)
echo "Waiting for saturation to be detected..."
sleep 3

REQUEST_PIDS=()

# Now send the actual test requests — system is already saturated
# SLO ordering should now be visible since requests will queue at the EPP
echo "Sending all requests concurrently: ${N_TIGHT} tight (slo=5s), ${N_MEDIUM} medium (slo=30s), ${N_RELAXED} relaxed (slo=120s)"
echo "All using objective=${OBJECTIVE}"

for i in $(seq 1 "${N_TIGHT}"); do
    send_streaming_request "${OBJECTIVE}" 5000 "req-${i}" "tight" &
    REQUEST_PIDS+=($!)
done
for i in $(seq 1 "${N_MEDIUM}"); do
    send_streaming_request "${OBJECTIVE}" 30000 "req-${i}" "medium" &
    REQUEST_PIDS+=($!)
done
for i in $(seq 1 "${N_RELAXED}"); do
    send_streaming_request "${OBJECTIVE}" 120000 "req-${i}" "relaxed" &
    REQUEST_PIDS+=($!)
done

echo "Waiting for ${#REQUEST_PIDS[@]} requests..."

# Sample model server metrics mid-test to check actual saturation
(
    sleep 5
    echo "" >> "${RESULTS_DIR}/midtest_vllm_metrics.txt"
    for pod_ip in $(kubectl get pods -n "${NAMESPACE}" -l llm-d.ai/inference-serving=true \
        -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}' 2>/dev/null); do
        echo "=== ${pod_ip} ===" >> "${RESULTS_DIR}/midtest_vllm_metrics.txt"
        kubectl run "curl-mid-${RANDOM}" --image=curlimages/curl --rm -i --restart=Never \
            -n "${NAMESPACE}" -- curl -s "http://${pod_ip}:8000/metrics" 2>/dev/null | \
            grep -E "num_requests_waiting|num_requests_running|kv_cache_usage_perc" | \
            grep -v "^#" >> "${RESULTS_DIR}/midtest_vllm_metrics.txt" 2>/dev/null
    done
) &

for pid in "${REQUEST_PIDS[@]}"; do
    wait "${pid}" 2>/dev/null || true
done

# Kill warmup requests — they served their purpose
for pid in "${WARMUP_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
done

# --- Snapshot metrics after test ---
echo "Snapshotting post-test metrics..."
fetch_metrics > "${RESULTS_DIR}/metrics_after.txt"

echo ""
echo "============================================================"
echo "                    CLIENT-SIDE RESULTS"
echo "============================================================"
echo ""

printf "%-15s %-7s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
    "SLO_BAND" "COUNT" "AVG_TTFT" "P50_TTFT" "P99_TTFT" "AVG_TPOT" "P50_TPOT" "P99_TPOT" "AVG_TOTAL"
echo "------------------------------------------------------------------------------------------------------"

for band in tight medium relaxed; do
    data=$(grep "^${band}," "${RESULTS_DIR}/results.csv" | grep -v ",-1," || true)
    count=$(echo "${data}" | grep -c '[0-9]' || true)
    [[ "${count}" -eq 0 ]] && {
        printf "%-15s %-7s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
            "${band}" "0" "-" "-" "-" "-" "-" "-" "-"
        continue
    }

    ttfts=$(echo "${data}" | cut -d, -f4 | sort -n)
    tpots=$(echo "${data}" | cut -d, -f5 | sort -n)
    totals=$(echo "${data}" | cut -d, -f7 | sort -n)

    avg_ttft=$(echo "${ttfts}" | awk '{s+=$1} END {printf "%.0f", s/NR}')
    avg_tpot=$(echo "${tpots}" | awk '{s+=$1} END {printf "%.0f", s/NR}')
    avg_total=$(echo "${totals}" | awk '{s+=$1} END {printf "%.0f", s/NR}')

    # P50: ceil(n/2), P99: ceil(n*0.99)
    p50_idx=$(( (count + 1) / 2 ))
    p99_idx=$(( (count * 99 + 99) / 100 ))
    # Clamp p99 to count (for small sample sizes)
    [[ "${p99_idx}" -gt "${count}" ]] && p99_idx="${count}"

    p50_ttft=$(echo "${ttfts}" | sed -n "${p50_idx}p")
    p99_ttft=$(echo "${ttfts}" | sed -n "${p99_idx}p")
    p50_tpot=$(echo "${tpots}" | sed -n "${p50_idx}p")
    p99_tpot=$(echo "${tpots}" | sed -n "${p99_idx}p")

    printf "%-15s %-7s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
        "${band}" "${count}" "${avg_ttft}ms" "${p50_ttft}ms" "${p99_ttft}ms" \
        "${avg_tpot}ms" "${p50_tpot}ms" "${p99_tpot}ms" "${avg_total}ms"
done

echo ""
echo "First 10 Dispatched (by absolute first-token time):"
printf "%-5s %-15s %-10s %-12s %-12s\n" "RANK" "SLO_BAND" "SLO(ms)" "TTFT(ms)" "TPOT(ms)"
echo "------------------------------------------------------"

tail -n +2 "${RESULTS_DIR}/results.csv" | grep -v ",-1," | sort -t, -k8 -n | head -10 | \
    awk -F, '{printf "%-5d %-15s %-10s %-12s %-12s\n", NR, $1, $3, $4, $5}'

echo ""
echo "============================================================"
echo "                  EPP PROMETHEUS METRICS"
echo "============================================================"

# --- Flow Control: Queue Duration by Priority (THE KEY METRIC) ---
echo ""
echo "Queue Duration (this run only):"
sum_after=$(grep -E "flow_control_request_queue_duration_seconds_sum\{" \
    "${RESULTS_DIR}/metrics_after.txt" | awk '{s+=$NF} END {print s+0}')
sum_before=$(grep -E "flow_control_request_queue_duration_seconds_sum\{" \
    "${RESULTS_DIR}/metrics_before.txt" | awk '{s+=$NF} END {print s+0}')
cnt_after=$(grep -E "flow_control_request_queue_duration_seconds_count\{" \
    "${RESULTS_DIR}/metrics_after.txt" | awk '{s+=$NF} END {print s+0}')
cnt_before=$(grep -E "flow_control_request_queue_duration_seconds_count\{" \
    "${RESULTS_DIR}/metrics_before.txt" | awk '{s+=$NF} END {print s+0}')
sum=$(awk "BEGIN {print ${sum_after} - ${sum_before}}")
cnt=$(awk "BEGIN {print ${cnt_after} - ${cnt_before}}")
if awk "BEGIN {exit (${cnt} > 0) ? 0 : 1}"; then
    avg_ms=$(awk "BEGIN {printf \"%.3f\", (${sum}/${cnt})*1000}")
    total_ms=$(awk "BEGIN {printf \"%.3f\", ${sum}*1000}")
    printf "  requests=%-6s  avg_queue_wait=%sms  total_queue_time=%sms\n" "${cnt}" "${avg_ms}" "${total_ms}"
else
    echo "  (no requests)"
fi

echo ""
echo "Pool Saturation:"
grep "^inference_extension_flow_control_pool_saturation{" \
    "${RESULTS_DIR}/metrics_after.txt" | awk '{printf "  %s\n", $NF}' || echo "  (no data)"

echo ""
echo "Model Server Metrics (sampled mid-test):"
cat "${RESULTS_DIR}/midtest_vllm_metrics.txt" 2>/dev/null || echo "  (not available)"

echo ""
echo "Results: ${RESULTS_DIR}/results.csv"
