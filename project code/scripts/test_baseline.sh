# !!!!!!!!!!!!!!!!!!!! NOTE !!!!!!!!!!!!!!!!!!!!

# Usage: ./test_baseline.sh [interval] [batch_size] [duration] [seed]

# !!!!!!!!!!!!!!!!!!!! NOTE !!!!!!!!!!!!!!!!!!!!

set -e

# Default parameters
INTERVAL=${1:-1}          # Reporting interval in seconds (1, 5, or 30)
BATCH_SIZE=${2:-1}        # Batch size (1 = no batching, 3 = with batching)
DURATION=${3:-60}         # Test duration in seconds
SEED=${4:-42}             # Random seed for reproducibility
PORT=${5:-9000}           # UDP port

# Create results directory
RESULTS_DIR="baseline_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "======================================================================"
echo "BASELINE TEST - No Network Impairment"
echo "======================================================================"
echo "Parameters:"
echo "  Interval: ${INTERVAL}s"
echo "  Batch size: ${BATCH_SIZE}"
echo "  Duration: ${DURATION}s"
echo "  Seed: ${SEED}"
echo "  Port: ${PORT}"
echo "  Results: $RESULTS_DIR"
echo "======================================================================"

# Clean up any existing netem configuration
echo "Cleaning up any existing network impairments..."
sudo tc qdisc del dev lo root 2>/dev/null || true
sudo tc qdisc del dev eth0 root 2>/dev/null || true
sudo tc qdisc del dev wlan0 root 2>/dev/null || true
sleep 1

# Verify no impairment
echo "Verifying network is clean..."
sudo tc qdisc show dev lo
echo "   Network is clean (no netem rules)"

# Start packet capture
echo "Starting packet capture..."
sudo tcpdump -i lo -w "$RESULTS_DIR/baseline_capture.pcap" \
    port $PORT -s 65535 > /dev/null 2>&1 &
TCPDUMP_PID=$!
echo "   Packet capture started (PID: $TCPDUMP_PID)"

# Start server
echo "Starting server..."
python3 server.py --port $PORT \
    --csv "$RESULTS_DIR/baseline_results.csv" \
    > "$RESULTS_DIR/server.log" 2>&1 &
SERVER_PID=$!
echo "Server started (PID: $SERVER_PID)"
sleep 3

# Run client
echo "Starting client..."
echo "Client will run for $DURATION seconds with interval ${INTERVAL}s"
python3 client.py \
    --server-port $PORT \
    --device-id 100 \
    --interval "$INTERVAL" \
    --duration "$DURATION" \
    --batch-size "$BATCH_SIZE" \
    --seed "$SEED" \
    > "$RESULTS_DIR/client.log" 2>&1

echo "======================================================================"
echo "TEST COMPLETE - Cleaning up..."
echo "======================================================================"

# Cleanup
sleep 2
kill $SERVER_PID 2>/dev/null || true
sudo kill $TCPDUMP_PID 2>/dev/null || true

echo "Server stopped"
echo "Packet capture stopped"

# Analyze results
echo ""
echo "======================================================================"
echo "BASELINE TEST RESULTS"
echo "======================================================================"

if [ -f "$RESULTS_DIR/baseline_results.csv" ]; then
    TOTAL_PACKETS=$(wc -l < "$RESULTS_DIR/baseline_results.csv" || echo "0")
    # Subtract 1 for header
    if [ "$TOTAL_PACKETS" -gt 0 ]; then
        ACTUAL_PACKETS=$((TOTAL_PACKETS - 1))
    else
        ACTUAL_PACKETS=0
    fi
    
    EXPECTED_PACKETS=$((DURATION / INTERVAL))
    DELIVERY_RATE=$(echo "scale=2; $ACTUAL_PACKETS * 100 / $EXPECTED_PACKETS" | bc 2>/dev/null || echo "0")
    
    echo "  Expected packets: $EXPECTED_PACKETS"
    echo "  Received packets: $ACTUAL_PACKETS"
    echo "  Delivery rate: $DELIVERY_RATE%"
    
    if [ "$ACTUAL_PACKETS" -ge $((EXPECTED_PACKETS * 99 / 100)) ]; then
        echo "ACCEPTANCE: ≥99% delivery rate"
    else
        echo "warning: <99% delivery rate"
    fi
    
    # Check for duplicates
    if [ "$ACTUAL_PACKETS" -gt 0 ]; then
        DUPLICATES=$(grep -c ",1$" "$RESULTS_DIR/baseline_results.csv" 2>/dev/null || echo "0")
        DUPLICATE_RATE=$(echo "scale=2; $DUPLICATES * 100 / $ACTUAL_PACKETS" | bc 2>/dev/null || echo "0")
        echo "  Duplicates: $DUPLICATES ($DUPLICATE_RATE%)"
        
        if [ $(echo "$DUPLICATE_RATE <= 1.0" | bc 2>/dev/null || echo "1") -eq 1 ]; then
            echo "ACCEPTANCE: Duplicate rate ≤1%"
        else
            echo "warning: Duplicate rate >1%"
        fi
    fi
    
    # Check packet sizes
    if [ "$ACTUAL_PACKETS" -gt 0 ]; then
        AVG_SIZE=$(awk -F, 'NR>1 {sum+=$9; count++} END {if(count>0) print sum/count}' "$RESULTS_DIR/baseline_results.csv" 2>/dev/null || echo "0")
        echo "  Average packet size: ${AVG_SIZE%.*} bytes"
        
        if [ $(echo "${AVG_SIZE%.*} <= 200" | bc 2>/dev/null || echo "1") -eq 1 ]; then
            echo "ACCEPTANCE: Packet size ≤200 bytes"
        else
            echo "warning: Packet size >200 bytes"
        fi
    fi
else
    echo "  No results CSV file found"
fi

echo "======================================================================"
echo "Results saved in: $RESULTS_DIR/"
echo "  - baseline_capture.pcap (packet capture)"
echo "  - baseline_results.csv (detailed metrics)"
echo "  - server.log (server output)"
echo "  - client.log (client output)"
echo ""
echo "To view packet capture:"
echo "  wireshark $RESULTS_DIR/baseline_capture.pcap"
echo "  or"
echo "  tcpdump -r $RESULTS_DIR/baseline_capture.pcap -nn"
echo "======================================================================"