# !!!!!!!!!!!!!!!!!!!! NOTE !!!!!!!!!!!!!!!!!!!!

# Usage: ./test_delay100.sh [interval] [batch_size] [duration] [seed]

# !!!!!!!!!!!!!!!!!!!! NOTE !!!!!!!!!!!!!!!!!!!!

set -e

# Default parameters
INTERVAL=${1:-1}          # Reporting interval in seconds
BATCH_SIZE=${2:-1}        # Batch size
DURATION=${3:-60}         # Test duration in seconds
SEED=${4:-42}             # Random seed
PORT=${5:-9002}           # UDP port (different from others)
DELAY_MS=100              # 100ms delay
JITTER_MS=10              # ±10ms jitter

# Create results directory
RESULTS_DIR="delay100_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "======================================================================"
echo "DELAY + JITTER TEST (${DELAY_MS}ms ± ${JITTER_MS}ms)"
echo "======================================================================"
echo "Parameters:"
echo "  Interval: ${INTERVAL}s"
echo "  Batch size: ${BATCH_SIZE}"
echo "  Duration: ${DURATION}s"
echo "  Seed: ${SEED}"
echo "  Port: ${PORT}"
echo "  Delay: ${DELAY_MS}ms ± ${JITTER_MS}ms"
echo "  Results: $RESULTS_DIR"
echo "======================================================================"

# Clean up any existing netem configuration
echo "Cleaning up any existing network impairments..."
sudo tc qdisc del dev lo root 2>/dev/null || true
sleep 1

# Apply delay + jitter
echo "Applying ${DELAY_MS}ms delay with ${JITTER_MS}ms jitter..."
sudo tc qdisc add dev lo root netem delay ${DELAY_MS}ms ${JITTER_MS}ms
echo " Applied ${DELAY_MS}ms ± ${JITTER_MS}ms delay"

# Verify configuration
echo "Verifying network configuration..."
sudo tc qdisc show dev lo

# Start packet capture
echo "Starting packet capture..."
sudo tcpdump -i lo -w "$RESULTS_DIR/delay100_capture.pcap" \
    port $PORT -s 65535 > /dev/null 2>&1 &
TCPDUMP_PID=$!
echo "  Packet capture started (PID: $TCPDUMP_PID)"

# Start server with reordering enabled
echo "Starting server (with reordering enabled)..."
python3 server.py --port $PORT \
    --csv "$RESULTS_DIR/delay100_results.csv" \
    > "$RESULTS_DIR/server.log" 2>&1 &
SERVER_PID=$!
echo "Server started (PID: $SERVER_PID)"
sleep 5  # Extra time for delayed packets

# Run client
echo "Starting client..."
echo "  Client will run for $DURATION seconds with ${DELAY_MS}ms delay"
python3 client.py \
    --server-port $PORT \
    --device-id 300 \
    --interval "$INTERVAL" \
    --duration "$DURATION" \
    --batch-size "$BATCH_SIZE" \
    --seed "$SEED" \
    > "$RESULTS_DIR/client.log" 2>&1

echo "======================================================================"
echo "TEST COMPLETE - Cleaning up..."
echo "======================================================================"

# Let delayed packets arrive
echo "Waiting for delayed packets to arrive..."
sleep $((DELAY_MS / 1000 + 2))

# Cleanup
kill $SERVER_PID 2>/dev/null || true
sudo kill $TCPDUMP_PID 2>/dev/null || true
sudo tc qdisc del dev lo root 2>/dev/null || true
echo " Network impairment removed"
echo " Server stopped"
echo " Packet capture stopped"

# Analyze results
echo ""
echo "======================================================================"
echo "DELAY + JITTER TEST RESULTS"
echo "======================================================================"

if [ -f "$RESULTS_DIR/delay100_results.csv" ]; then
    TOTAL_PACKETS=$(wc -l < "$RESULTS_DIR/delay100_results.csv" || echo "0")
    if [ "$TOTAL_PACKETS" -gt 0 ]; then
        ACTUAL_PACKETS=$((TOTAL_PACKETS - 1))
    else
        ACTUAL_PACKETS=0
    fi
    
    EXPECTED_PACKETS=$((DURATION / INTERVAL))
    DELIVERY_RATE=$((ACTUAL_PACKETS * 100 / EXPECTED_PACKETS))
    
    echo "Expected packets: $EXPECTED_PACKETS"
    echo "Received packets: $ACTUAL_PACKETS"
    echo "Delivery rate: $DELIVERY_RATE%"
    
    # Check server logs for reordering
    if [ -f "$RESULTS_DIR/server.log" ]; then
        REORDER_EVENTS=$(grep -c "REORDER" "$RESULTS_DIR/server.log" 2>/dev/null || echo "0")
        echo "Reordering events in server log: $REORDER_EVENTS"
        
        if [ "$REORDER_EVENTS" -gt 0 ]; then
            echo "ACCEPTANCE: Packets being reordered by timestamp"
        else
            echo "Warning: No reordering events logged (check if reordering is enabled)"
        fi
        
        # Check for buffer issues
        BUFFER_ISSUES=$(grep -i "overflow\|crash\|error" "$RESULTS_DIR/server.log" | wc -l)
        if [ "$BUFFER_ISSUES" -eq 0 ]; then
            echo "ACCEPTANCE: No buffer overrun or crash"
        else
            echo "ACCEPTANCE: Buffer issues detected"
        fi
    fi
    
    # Analyze timestamps for jitter
    if [ "$ACTUAL_PACKETS" -gt 2 ]; then
        # Extract arrival times and calculate jitter
        echo "  Analyzing packet timing..."
        
        # simple Python script to analyze jitter
        cat > /tmp/analyze_jitter.py << 'PYTHON_JITTER'
import pandas as pd, sys, statistics, math
csv_file = sys.argv[1]
try:
    df = pd.read_csv(csv_file)
    if len(df) > 2:
        # Calculate inter-arrival times
        df['arrival_time'] = pd.to_datetime(df['arrival_time'], unit='s')
        df = df.sort_values('arrival_time')
        df['inter_arrival'] = df['arrival_time'].diff().dt.total_seconds() * 1000  # ms
        
        # Remove first row (NaN) and filter reasonable values
        iat = df['inter_arrival'].iloc[1:].dropna()
        iat = iat[(iat > 0) & (iat < 5000)]  # Filter outliers
        
        if len(iat) > 1:
            mean_iat = iat.mean()
            std_iat = iat.std()
            jitter = std_iat  # Simple jitter as standard deviation
            
            print(f"    Mean inter-arrival: {mean_iat:.1f}ms")
            print(f"    Jitter (std dev): {jitter:.1f}ms")
            print(f"    Expected interval: {float(sys.argv[2])*1000:.0f}ms")
            
            # Check if jitter is reasonable
            if jitter < 50:  # Less than 50ms jitter is reasonable
                print("    Jitter within reasonable bounds")
            else:
                print(f"  High jitter detected: {jitter:.1f}ms")
except Exception as e:
    print(f"    Error analyzing jitter: {e}")
PYTHON_JITTER
        
        python3 /tmp/analyze_jitter.py "$RESULTS_DIR/delay100_results.csv" "$INTERVAL"
    fi
    
    # Check packet order by sequence numbers
    if [ "$ACTUAL_PACKETS" -gt 0 ]; then
        OUT_OF_ORDER=$(awk -F, 'NR>1 {print $2}' "$RESULTS_DIR/delay100_results.csv" | \
            awk '{if(NR>1 && $1 <= prev) out_of_order++} {prev=$1} END {print out_of_order+0}')
        echo "  Packets out of sequence order: $OUT_OF_ORDER"
        
        if [ "$OUT_OF_ORDER" -gt 0 ]; then
            echo "Packets arrived out of order (expected with delay+jitter)"
        fi
    fi
    
else
    echo "  No results CSV file found"
fi

echo ""
echo "Results saved in: $RESULTS_DIR/"
echo "  - delay100_capture.pcap (packet capture with delay)"
echo "  - delay100_results.csv (detailed metrics with timestamps)"
echo "  - server.log (server output with reordering info)"
echo "  - client.log (client output)"
echo ""
echo "To analyze packet timing in capture:"
echo "  tshark -r $RESULTS_DIR/delay100_capture.pcap -Y \"udp.port == $PORT\" -T fields -e frame.time_epoch -e udp.srcport"
echo "======================================================================"