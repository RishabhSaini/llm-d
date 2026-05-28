#!/bin/bash
# Eviction test script
# Uses iterative probing to find saturation point, then triggers eviction.

set -euo pipefail

EPP_SVC="${EPP_SVC:-optimized-baseline-epp}"
NAMESPACE="${NAMESPACE:-rsaini-dev}"
MODEL="${MODEL:-Qwen/Qwen3-32B}"
METRICS_PORT="${METRICS_PORT:-19091}"

IP=$(kubectl get service $EPP_SVC -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
echo "EPP Service IP: $IP"

# Port-forward metrics (background, kill on exit)
pkill -f "port-forward.*$METRICS_PORT" 2>/dev/null || true
sleep 1
kubectl port-forward -n $NAMESPACE deploy/$EPP_SVC $METRICS_PORT:9090 &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null; kubectl delete pods -n $NAMESPACE -l eviction-test=true --force 2>/dev/null" EXIT
sleep 3

get_saturation() {
    curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null \
        | grep '^llm_d_flow_control_pool_saturation ' \
        | awk '{print $2}' || echo "0"
}

get_inflight() {
    curl -s http://localhost:$METRICS_PORT/metrics 2>/dev/null \
        | grep 'inflight_requests_total' \
        | awk '{sum+=$2} END {print sum+0}' || echo "0"
}

send_sheddable() {
    local n=$1
    echo "[Phase] Sending $n sheddable streaming requests..."
    for i in $(seq 1 $n); do
        kubectl run "shed-$RANDOM" --rm -i --restart=Never -n $NAMESPACE \
            --labels="eviction-test=true" \
            --image=curlimages/curl:latest -- \
            curl -s --max-time 300 \
            -X POST "http://$IP:80/v1/completions" \
            -H 'Content-Type: application/json' \
            -H 'x-gateway-inference-objective: sheddable-test' \
            -d "{\"model\":\"$MODEL\",\"prompt\":\"Write an extremely detailed and comprehensive 10000 word essay covering every single aspect of the complete history of computer science from the earliest mechanical calculators of the 1600s through Charles Babbage and Ada Lovelace and the analytical engine through the development of Boolean algebra and formal logic through Alan Turing and the Enigma machine through ENIAC and the first electronic computers through the transistor revolution through integrated circuits through the development of UNIX and C through the personal computer revolution through the internet and world wide web through mobile computing through cloud computing through machine learning and artificial intelligence through modern large language models and quantum computing. Cover every major figure every breakthrough every company every programming language every operating system every hardware innovation.\",\"max_tokens\":4096,\"stream\":true}" \
            &>/dev/null &
    done
}

echo ""
echo "========================================="
echo " Phase 1: Probe saturation point"
echo "========================================="
echo ""

BATCH=5
TOTAL=0
MAX_WAVES=10

for wave in $(seq 1 $MAX_WAVES); do
    send_sheddable $BATCH
    TOTAL=$((TOTAL + BATCH))

    # Wait for requests to register and saturation to update
    sleep 8

    SAT=$(get_saturation)
    echo "[Wave $wave] Sent $TOTAL total sheddable. Saturation: $SAT"

    # Check if saturated (>= 0.9)
    if [ -n "$SAT" ] && [ "$SAT" != "0" ]; then
        SATURATED=$(echo "$SAT >= 0.9" | bc -l 2>/dev/null || python3 -c "print(1 if float('$SAT') >= 0.9 else 0)" 2>/dev/null || echo "0")
        if [ "$SATURATED" = "1" ]; then
            echo ""
            echo "[SUCCESS] Pool saturated at $SAT with $TOTAL requests"
            break
        fi
    fi

    # Increase batch size for next wave
    BATCH=$((BATCH + 5))
done

echo ""
echo "========================================="
echo " Phase 2: Check EPP logs for HoL blocking"
echo "========================================="
echo ""

EPPOD=$(kubectl get pods -n $NAMESPACE -l llm-d-router-standalone=$EPP_SVC -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
        kubectl get pods -n $NAMESPACE | grep "$EPP_SVC" | grep Running | head -1 | awk '{print $1}')
echo "EPP Pod: $EPPOD"

kubectl logs -n $NAMESPACE $EPPOD -c epp --tail=50 2>&1 | grep -i "blocking\|evict\|demand\|HoL\|saturat" | tail -10
echo ""

echo "========================================="
echo " Phase 3: Send normal-priority with SLO"
echo "========================================="
echo ""

echo "Sending normal-priority request with x-llm-d-slo-ttft-ms: 3000..."
kubectl run normal-slo --rm -i --restart=Never -n $NAMESPACE \
    --labels="eviction-test=true" \
    --image=curlimages/curl:latest -- \
    curl -s -w "\n---HTTP_CODE:%{http_code}---\n" --max-time 60 \
    -X POST "http://$IP:80/v1/completions" \
    -H 'Content-Type: application/json' \
    -H 'x-gateway-inference-objective: normal-test' \
    -H 'x-llm-d-slo-ttft-ms: 3000' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Hello\",\"max_tokens\":10}" 2>&1 | tail -5

echo ""
echo "========================================="
echo " Phase 4: Check eviction logs"
echo "========================================="
echo ""

sleep 5
kubectl logs -n $NAMESPACE $EPPOD -c epp --tail=50 2>&1 | grep -i "evict\|demand\|signal sent\|Request evicted\|Eviction" | tail -15

echo ""
echo "========================================="
echo " Phase 5: Final saturation"
echo "========================================="
echo ""
SAT=$(get_saturation)
echo "Final saturation: $SAT"

# Cleanup
echo ""
echo "Cleaning up test pods..."
kubectl delete pods -n $NAMESPACE -l eviction-test=true --force 2>/dev/null || true
echo "Done."
