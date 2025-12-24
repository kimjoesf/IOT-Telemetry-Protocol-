
# !!!!!!!!!!!!!!!!!!!! NOTE !!!!!!!!!!!!!!!!!!!!

# Usage: ./test_loss5.sh [interval] [batch_size] [duration] [seed]

# !!!!!!!!!!!!!!!!!!!! NOTE !!!!!!!!!!!!!!!!!!!!

set -e

# Default parameters
INTERVAL=${1:-1}          # Reporting interval in seconds
BATCH_SIZE=${2:-1}        # Batch size
DURATION=${3:-60}         # Test duration in seconds
SEED=${4:-42}             # Random seed
PORT=${5:-9001}           # UDP port (different from baseline)
LOSS_PERCENT=5            # 5% packet loss

# Create results directory
RESULTS_DIR="loss5_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "======================================================================"
echo "5% PACKET LOSS TEST"
echo "======================================================================"
echo "Parameters:"
echo "  Interval: ${INTERVAL}s"
echo "  Batch size: ${BATCH_SIZE}"
echo "  Duration: ${DURATION}s"
echo "  Seed: ${SEED}"
echo "  Port: ${PORT}"
echo "  Packet loss: ${LOSS_PERCENT}%"
echo "  Results: $RESULTS_DIR"
echo "======================================================================"

# Clean up any existing netem configuration
echo "Cleaning up any existing network impairments..."
sudo tc qdisc del dev lo root 2>/dev/null || true
sleep 1

# Apply 5% packet loss
echo "Applying ${LOSS_PERCENT}% packet loss..."
sudo tc qdisc add dev lo root netem loss ${LOSS_PERCENT}%
echo " Applied ${LOSS_PERCENT}% packet loss"

# Verify configuration
echo " Verifying network configuration..."
sudo tc qdisc show dev lo

# Start packet capture
echo "Starting packet capture..."
sudo tcpdump -i lo -w "$RESULTS_DIR/loss5_capture.pcap" \
    port $PORT -s 65535 > /dev/null 2>&1 &
TCPDUMP_PID=$!
echo " Packet capture started (PID: $TCPDUMP_PID)"

# Start server
echo "Starting server..."
python3 server.py --port $PORT \
    --csv "$RESULTS_DIR/loss5_results.csv" \
    > "$RESULTS_DIR/server.log" 2>&1 &
SERVER_PID=$!
echo " Server started (PID: $SERVER_PID)"
sleep 3

# Run client
echo "Starting client..."
echo "  Client will run for $DURATION seconds with ${LOSS_PERCENT}% packet loss"
python3 client.py \
    --server-port $PORT \
    --device-id 200 \
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
sudo tc qdisc del dev lo root 2>/dev/null || true
echo "Network impairment removed"
echo "Server stopped"
echo "Packet capture stopped"

# Analyze results
echo ""
echo "======================================================================"
echo "5% PACKET LOSS TEST RESULTS"
echo "======================================================================"

if [ -f "$RESULTS_DIR/loss5_results.csv" ]; then
    TOTAL_PACKETS=$(wc -l < "$RESULTS_DIR/loss5_results.csv" || echo "0")
    if [ "$TOTAL_PACKETS" -gt 0 ]; then
        ACTUAL_PACKETS=$((TOTAL_PACKETS - 1))
    else
        ACTUAL_PACKETS=0
    fi
    
    EXPECTED_PACKETS=$((DURATION / INTERVAL))
    THEORETICAL_LOSS=$((EXPECTED_PACKETS * LOSS_PERCENT / 100))
    THEORETICAL_RECEIVED=$((EXPECTED_PACKETS - THEORETICAL_LOSS))
    
    echo "  Expected packets (no loss): $EXPECTED_PACKETS"
    echo "  Theoretically lost (${LOSS_PERCENT}%): ~$THEORETICAL_LOSS"
    echo "  Theoretically received: ~$THEORETICAL_RECEIVED"
    echo "  Actually received: $ACTUAL_PACKETS"
    
    # Calculate actual loss rate
    if [ "$EXPECTED_PACKETS" -gt 0 ]; then
        ACTUAL_LOSS_RATE=$((100 - (ACTUAL_PACKETS * 100 / EXPECTED_PACKETS)))
        echo "  Actual loss rate: ${ACTUAL_LOSS_RATE}%"
    fi
    
    # Check for sequence gaps (should detect them)
    if [ "$ACTUAL_PACKETS" -gt 0 ]; then
        GAPS=$(awk -F, 'NR>1 && $7==1 {count++} END {print count}' "$RESULTS_DIR/loss5_results.csv" 2>/dev/null || echo "0")
        echo "ACCEPTANCE: Sequence gaps detected: $GAPS"
        
        if [ "$GAPS" -gt 0 ]; then
            echo "ACCEPTANCE: Sequence gaps detected"
        else
            echo "Warning: No sequence gaps detected (should see some with ${LOSS_PERCENT}% loss)"
        fi
    fi
    
    # Check duplicate suppression
    if [ "$ACTUAL_PACKETS" -gt 0 ]; then
        DUPLICATES=$(awk -F, 'NR>1 && $6==1 {count++} END {print count}' "$RESULTS_DIR/loss5_results.csv" 2>/dev/null || echo "0")
        DUPLICATE_RATE=$((DUPLICATES * 100 / ACTUAL_PACKETS))
        echo "  Duplicates suppressed: $DUPLICATES ($DUPLICATE_RATE%)"
        
        if [ "$DUPLICATE_RATE" -le 1 ]; then
            echo " ACCEPTANCE: Duplicate rate ≤1% "
        else
            echo "ACCEPTANCE: Duplicate rate >1%"
        fi
    fi
    
    # Check batching efficiency
    if [ "$BATCH_SIZE" -gt 1 ] && [ "$ACTUAL_PACKETS" -gt 0 ]; then
        AVG_READINGS=$(awk -F, 'NR>1 {sum+=$8; count++} END {if(count>0) print sum/count}' "$RESULTS_DIR/loss5_results.csv" 2>/dev/null || echo "1")
        echo "  Average readings per packet: ${AVG_READINGS%.*}"
        echo "  Batching efficiency: ~$(echo "scale=1; ${AVG_READINGS%.*} * 100 / $BATCH_SIZE" | bc)%"
    fi
else
    echo "  No results CSV file found"
fi

echo ""
echo "Results saved in: $RESULTS_DIR/"
echo "  - loss5_capture.pcap (packet capture with loss)"
echo "  - loss5_results.csv (detailed metrics)"
echo "  - server.log (server output)"
echo "  - client.log (client output)"
echo ""
echo "To analyze lost packets in capture:"
echo "  tshark -r $RESULTS_DIR/loss5_capture.pcap -Y \"udp.port == $PORT\" -T fields -e frame.number -e udp.srcport -e udp.dstport"
echo "======================================================================"