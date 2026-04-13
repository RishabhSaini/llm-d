#!/usr/bin/env bash
#
# Test SLO-deadline ordering within a single priority band.
# All requests use the same objective but different x-slo-ttft-ms values.
# Requests with tighter SLOs should get lower TTFT under contention.
#
# Strategy: Pre-saturate the system with long-running requests, VERIFY
# saturation is detected by the EPP via Prometheus, THEN send test requests
# in a staggered stream so they queue behind the saturation barrier.
#
# Usage: ./test-flow-control.sh [NAMESPACE] [GATEWAY_SVC]

set -uo pipefail

NAMESPACE="${1:-rsaini-dev}"
GATEWAY_SVC="${2:-infra-inference-scheduling-inference-gateway-istio}"
EPP_SVC="gaie-inference-scheduling-epp"
MODEL="Qwen/Qwen3-32B"

OBJECTIVE="critical"
N_TIGHT=40     # slo=5000ms
N_MEDIUM=80    # slo=30000ms
N_RELAXED=200  # slo=120000ms

# Stagger interval: delay between each test request (ms)
STAGGER_MS=50

RESULTS_DIR="/tmp/fc-test-$(date +%s)"
mkdir -p "${RESULTS_DIR}/traces"

echo "=== Flow Control Priority Test (Staggered + Saturation Verified) ==="
echo "Namespace:  ${NAMESPACE}"
echo "Gateway:    ${GATEWAY_SVC}"
echo "Model:      ${MODEL}"
echo "Stagger:    ${STAGGER_MS}ms between requests"
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
    for pid in "${WARMUP_PIDS[@]:-}"; do
        kill "${pid}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT

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

get_pool_saturation() {
    fetch_metrics | grep "^inference_extension_flow_control_pool_saturation{" | awk '{print $NF}' || echo "0"
}

# --- Phase 0: Warmup — saturate the system with LONG requests ---
# Use max_tokens=2000 so these requests keep vLLM busy for a long time.
# Send enough to fill KV cache above the 5% threshold.
N_WARMUP=150
WARMUP_PIDS=()

echo "Phase 0: Sending ${N_WARMUP} long warmup requests (max_tokens=2000)..."
for i in $(seq 1 "${N_WARMUP}"); do
    rand_id=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
    curl -s -N -X POST "${URL}" \
        -H "Content-Type: application/json" \
        -H "x-gateway-inference-objective: ${OBJECTIVE}" \
        -H "x-slo-ttft-ms: 120000" \
        -d "{\"model\":\"${MODEL}\",\"prompt\":\"[${rand_id}] Write an extremely detailed and comprehensive history of every major scientific discovery from ancient Greece through the modern era, covering physics, chemistry, biology, astronomy, and mathematics in exhaustive detail with dates and names.\",\"max_tokens\":2000,\"temperature\":0.7,\"stream\":true}" \
        --max-time 300 > /dev/null 2>&1 &
    WARMUP_PIDS+=($!)
    # Small stagger to avoid overwhelming envoy
    if (( i % 20 == 0 )); then
        sleep 0.2
    fi
done

# --- Phase 1: Wait for EPP to detect saturation ---
echo "Phase 1: Waiting for EPP to detect pool saturation..."
MAX_WAIT=60
WAIT_START=$(date +%s)
SATURATION="0"
while true; do
    SATURATION=$(get_pool_saturation)
    ELAPSED=$(( $(date +%s) - WAIT_START ))

    if awk "BEGIN {exit (${SATURATION} >= 1.0) ? 0 : 1}" 2>/dev/null; then
        echo "  Saturation detected: ${SATURATION} (after ${ELAPSED}s)"
        break
    fi

    if (( ELAPSED >= MAX_WAIT )); then
        echo "  WARNING: Saturation not detected after ${MAX_WAIT}s (current: ${SATURATION})"
        echo "  Proceeding anyway — results may not show SLO ordering."
        break
    fi

    printf "  Waiting... saturation=%s elapsed=%ds\r" "${SATURATION}" "${ELAPSED}"
    sleep 1
done

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

# --- Phase 2: Send test requests in a STAGGERED, INTERLEAVED stream ---
# Mix tight/medium/relaxed randomly so arrival order != SLO order.
# The flow controller should reorder them by SLO deadline.
echo ""
echo "Phase 2: Sending test requests (staggered, interleaved)..."
echo "  ${N_TIGHT} tight (slo=5s), ${N_MEDIUM} medium (slo=30s), ${N_RELAXED} relaxed (slo=120s)"

# Build a shuffled list of all requests
REQUEST_LIST=()
for i in $(seq 1 "${N_TIGHT}"); do
    REQUEST_LIST+=("tight,5000,tight-${i}")
done
for i in $(seq 1 "${N_MEDIUM}"); do
    REQUEST_LIST+=("medium,30000,medium-${i}")
done
for i in $(seq 1 "${N_RELAXED}"); do
    REQUEST_LIST+=("relaxed,120000,relaxed-${i}")
done

# Shuffle
SHUFFLED=($(printf '%s\n' "${REQUEST_LIST[@]}" | shuf))

REQUEST_PIDS=()
TOTAL=${#SHUFFLED[@]}
SENT=0

for entry in "${SHUFFLED[@]}"; do
    IFS=',' read -r slo_label slo_ttft req_id <<< "${entry}"
    send_streaming_request "${OBJECTIVE}" "${slo_ttft}" "${req_id}" "${slo_label}" &
    REQUEST_PIDS+=($!)
    SENT=$((SENT + 1))

    # Stagger: sleep between requests
    if (( SENT % 10 == 0 )); then
        printf "  Sent %d/%d requests\r" "${SENT}" "${TOTAL}"
    fi
    sleep "$(awk "BEGIN {print ${STAGGER_MS}/1000.0}")"
done
echo "  Sent ${TOTAL}/${TOTAL} requests — waiting for completion..."

# Sample model server metrics mid-test
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

# Sample saturation during test
(
    for s in $(seq 1 10); do
        sleep 2
        sat=$(get_pool_saturation)
        echo "t+${s}: saturation=${sat}" >> "${RESULTS_DIR}/saturation_samples.txt"
    done
) &

for pid in "${REQUEST_PIDS[@]}"; do
    wait "${pid}" 2>/dev/null || true
done

# Kill warmup requests
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

    p50_idx=$(( (count + 1) / 2 ))
    p99_idx=$(( (count * 99 + 99) / 100 ))
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
echo "Dispatch Order (by absolute first-token time):"
printf "%-15s %-7s %-12s %-12s %-12s\n" "SLO_BAND" "COUNT" "AVG_RANK" "FIRST_RANK" "LAST_RANK"
echo "--------------------------------------------------------------"

sorted_with_ranks=$(tail -n +2 "${RESULTS_DIR}/results.csv" | grep -v ",-1," | sort -t, -k8 -n | \
    awk -F, '{print NR","$0}')

for band in tight medium relaxed; do
    band_ranks=$(echo "${sorted_with_ranks}" | grep ",${band}," | cut -d, -f1)
    band_count=$(echo "${band_ranks}" | grep -c '[0-9]' || true)
    [[ "${band_count}" -eq 0 ]] && continue
    avg_rank=$(echo "${band_ranks}" | awk '{s+=$1} END {printf "%.1f", s/NR}')
    first_rank=$(echo "${band_ranks}" | head -1)
    last_rank=$(echo "${band_ranks}" | tail -1)
    printf "%-15s %-7s %-12s %-12s %-12s\n" "${band}" "${band_count}" "${avg_rank}" "${first_rank}" "${last_rank}"
done

echo ""
echo "============================================================"
echo "                  EPP PROMETHEUS METRICS"
echo "============================================================"

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
echo "Pool Saturation (final):"
grep "^inference_extension_flow_control_pool_saturation{" \
    "${RESULTS_DIR}/metrics_after.txt" | awk '{printf "  %s\n", $NF}' || echo "  (no data)"

echo ""
echo "Pool Saturation (sampled during test):"
cat "${RESULTS_DIR}/saturation_samples.txt" 2>/dev/null | sed 's/^/  /' || echo "  (not available)"

echo ""
echo "Model Server Metrics (sampled mid-test):"
cat "${RESULTS_DIR}/midtest_vllm_metrics.txt" 2>/dev/null || echo "  (not available)"

echo ""
echo "Results: ${RESULTS_DIR}/results.csv"
