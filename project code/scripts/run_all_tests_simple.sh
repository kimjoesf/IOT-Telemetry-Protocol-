# testing on time 1s only
set -e

RESULTS_DIR="experiment_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR/pcaps" "$RESULTS_DIR/csvs" "$RESULTS_DIR/logs" "$RESULTS_DIR/reports"

echo "======================================================================"
echo "µTP/1 — Testing Start"
echo "Results → $RESULTS_DIR"
echo "======================================================================"

# run one iteration
run_one() {
    local scenario="$1"
    local batch_size="$2"
    local iter="$3"
    local port=$((9000 + iter + RANDOM % 1000))  # Avoid port conflicts
    local seed=$((42 + iter))
    
    echo ""
    echo "[$scenario] Batch=$batch_size Run $iter/5 — seed=$seed — port=$port"
    
    # Apply network condition
    case "$scenario" in
        baseline) sudo tc qdisc del dev lo root 2>/dev/null || true ;;
        loss5) sudo tc qdisc add dev lo root netem loss 5% ;;
        delay100) sudo tc qdisc add dev lo root netem delay 100ms 10ms ;;
    esac
    
    # Start packet capture
    sudo tcpdump -i lo -w "$RESULTS_DIR/pcaps/${scenario}_batch${batch_size}_run${iter}.pcap" \
        port $port -s 65535 > /dev/null 2>&1 &
    TCPDUMP_PID=$!
    
    # Start server
    python3 server.py --port $port \
        --csv "$RESULTS_DIR/csvs/${scenario}_batch${batch_size}_run${iter}.csv" \
        > "$RESULTS_DIR/logs/${scenario}_batch${batch_size}_run${iter}_server.log" 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    # Run client WITH BATCH SIZE PARAMETER
    python3 client.py --server-port $port \
        --device-id $((100 + iter)) \
        --interval 1 --duration 30 --batch-size "$batch_size" --seed $seed \
        > "$RESULTS_DIR/logs/${scenario}_batch${batch_size}_run${iter}_client.log" 2>&1
    
    # Cleanup
    sleep 5
    kill $SERVER_PID 2>/dev/null || true
    sudo kill $TCPDUMP_PID 2>/dev/null || true
    sudo tc qdisc del dev lo root 2>/dev/null || true
}

# Analyze results for one scenario
analyze() {
    local scenario="$1"
    local batch_size="$2"
    
    echo ""
    echo "=== ANALYZING $scenario (Batch=$batch_size, 5 runs) ==="
    
    # Create temporary Python script
    cat > /tmp/analyze_batch.py << 'PYTHON_EOF'
import pandas as pd, glob, statistics, json, os, sys
scenario = sys.argv[1]
batch_size = sys.argv[2]
results_dir = sys.argv[3]

files = sorted(glob.glob(f"{results_dir}/csvs/{scenario}_batch{batch_size}_run*.csv"))
data = []
for f in files:
    try:
        df = pd.read_csv(f)
        data.append({
            'run': os.path.basename(f),
            'packets': len(df),
            'dup_rate_%': df['duplicate_flag'].mean() * 100,
            'gaps': df['gap_flag'].sum(),
            'bytes_per_report': df['packet_size'].mean(),
            'cpu_ms_per_report': df.get('cpu_time_ms', pd.Series([0])).mean(),
            'avg_readings_per_packet': df['num_readings'].mean() if 'num_readings' in df.columns else 1
        })
    except Exception as e:
        print(f"Error reading {f}: {e}")

if not data:
    print(f"No data found for {scenario} batch={batch_size}")
    sys.exit(1)

df = pd.DataFrame(data)
print(f"SCENARIO: {scenario.upper()} | BATCH SIZE: {batch_size}")
print(f"Generated: {pd.Timestamp.now()}\n")

for col in ['packets', 'dup_rate_%', 'gaps', 'bytes_per_report', 'cpu_ms_per_report', 'avg_readings_per_packet']:
    vals = df[col].tolist()
    if vals:
        print(f"{col.replace('_', ' ').title():30}: "
              f"min={min(vals):.2f} median={statistics.median(vals):.2f} max={max(vals):.2f}")

print("\n" + "="*50)
PYTHON_EOF
    
    python3 /tmp/analyze_batch.py "$scenario" "$batch_size" "$RESULTS_DIR" > "$RESULTS_DIR/reports/${scenario}_batch${batch_size}_report.txt"
    
    echo "Report → $RESULTS_DIR/reports/${scenario}_batch${batch_size}_report.txt"
}

# Main test matrix
for scenario in baseline loss5 delay100; do
    for batch_size in 1 3; do  # Test without batching (1) and with batching (3)
        echo ""
        echo "======================================================================"
        echo "SCENARIO: $scenario | BATCH SIZE: $batch_size"
        echo "======================================================================"
        
        for i in {1..5}; do
            run_one "$scenario" "$batch_size" "$i"
        done
        
        analyze "$scenario" "$batch_size"
    done
done

echo ""
echo "======================================================================"
echo "ALL TESTS COMPLETED"
echo "======================================================================"
echo "Now generating comparison plots..."
echo ""

# Generate comparison plots - FIXED: Added sys import
cat > /tmp/generate_plots.py << 'PYTHON_EOF'
import pandas as pd, glob, matplotlib.pyplot as plt, os, numpy as np, sys

results_dir = sys.argv[1]

# Collect all data
all_data = []
for csv in glob.glob(f"{results_dir}/csvs/*.csv"):
    filename = os.path.basename(csv)
    # Parse scenario and batch size from filename
    parts = filename.replace('.csv', '').split('_')
    if len(parts) >= 3:
        scenario = parts[0]
        batch_size = int(parts[1].replace('batch', ''))
        
        try:
            df = pd.read_csv(csv)
            avg_bytes = df['packet_size'].mean()
            avg_readings = df.get('num_readings', pd.Series([1])).mean()
            dup_rate = df['duplicate_flag'].mean() * 100
            
            all_data.append({
                'scenario': scenario,
                'batch_size': batch_size,
                'avg_bytes': avg_bytes,
                'avg_readings': avg_readings,
                'dup_rate': dup_rate,
                'file': filename
            })
        except Exception as e:
            print(f"Error processing {filename}: {e}")
    else:
        print(f"Skipping {filename}: unexpected format")

if not all_data:
    print("No data found for plotting")
    sys.exit(1)

df_summary = pd.DataFrame(all_data)

# Plot 1: Bytes per report vs batching
plt.figure(figsize=(10, 6))
for scenario in df_summary['scenario'].unique():
    subset = df_summary[df_summary['scenario'] == scenario]
    subset = subset.sort_values('batch_size')
    plt.plot(subset['batch_size'], subset['avg_bytes'], 'o-', label=scenario, markersize=8, linewidth=2)

plt.xlabel('Batch Size')
plt.ylabel('Average Bytes per Report')
plt.title('Bytes per Report vs Batching Strategy')
plt.legend()
plt.grid(True, alpha=0.3)
plt.xticks([1, 3])
plt.savefig(f"{results_dir}/bytes_vs_batching.png", dpi=150, bbox_inches='tight')
plt.close()

print(f"Plot saved: {results_dir}/bytes_vs_batching.png")

# Plot 2: Efficiency comparison
plt.figure(figsize=(10, 6))
scenarios = sorted(df_summary['scenario'].unique())
x = np.arange(len(scenarios))
width = 0.35

for i, batch_size in enumerate([1, 3]):
    batch_data = []
    for scenario in scenarios:
        val = df_summary[(df_summary['scenario'] == scenario) & 
                        (df_summary['batch_size'] == batch_size)]['avg_readings']
        batch_data.append(val.mean() if not val.empty else 0)
    
    plt.bar(x + (i * width) - width/2, batch_data, width, label=f'Batch={batch_size}', alpha=0.7)

plt.xlabel('Scenario')
plt.ylabel('Average Readings per Packet')
plt.title('Batching Efficiency Across Scenarios')
plt.xticks(x, scenarios)
plt.legend()
plt.grid(True, alpha=0.3, axis='y')
plt.savefig(f"{results_dir}/readings_per_packet.png", dpi=150, bbox_inches='tight')
plt.close()

print(f"Plot saved: {results_dir}/readings_per_packet.png")

# Plot 3: Duplicate rate comparison
plt.figure(figsize=(10, 6))
for batch_size in sorted(df_summary['batch_size'].unique()):
    subset = df_summary[df_summary['batch_size'] == batch_size]
    if not subset.empty:
        plt.bar(subset['scenario'], subset['dup_rate'], label=f'Batch={batch_size}', alpha=0.7)

plt.xlabel('Scenario')
plt.ylabel('Duplicate Rate (%)')
plt.title('Duplicate Rate vs Batching Strategy')
plt.legend()
plt.grid(True, alpha=0.3, axis='y')
plt.axhline(y=1.0, color='r', linestyle='--', alpha=0.5, label='1% threshold')
plt.savefig(f"{results_dir}/duplicate_rate_vs_batching.png", dpi=150, bbox_inches='tight')
plt.close()

print(f"Plot saved: {results_dir}/duplicate_rate_vs_batching.png")

# Plot 4: Bytes per reading (efficiency)
plt.figure(figsize=(10, 6))
df_summary['bytes_per_reading'] = df_summary['avg_bytes'] / df_summary['avg_readings']
for scenario in df_summary['scenario'].unique():
    subset = df_summary[df_summary['scenario'] == scenario]
    subset = subset.sort_values('batch_size')
    plt.plot(subset['batch_size'], subset['bytes_per_reading'], 's-', label=scenario, markersize=8, linewidth=2)

plt.xlabel('Batch Size')
plt.ylabel('Bytes per Reading')
plt.title('Protocol Efficiency: Bytes per Reading')
plt.legend()
plt.grid(True, alpha=0.3)
plt.xticks([1, 3])
plt.savefig(f"{results_dir}/bytes_per_reading.png", dpi=150, bbox_inches='tight')
plt.close()

print(f"Plot saved: {results_dir}/bytes_per_reading.png")

print("\n=== SUMMARY ===")
for scenario in sorted(df_summary['scenario'].unique()):
    print(f"\n{scenario.upper()}:")
    for batch_size in [1, 3]:
        subset = df_summary[(df_summary['scenario'] == scenario) & 
                           (df_summary['batch_size'] == batch_size)]
        if not subset.empty:
            print(f"  Batch {batch_size}: {subset['avg_bytes'].iloc[0]:.1f} bytes, "
                  f"{subset['avg_readings'].iloc[0]:.1f} readings/packet, "
                  f"{subset['dup_rate'].iloc[0]:.2f}% duplicates")
PYTHON_EOF

python3 /tmp/generate_plots.py "$RESULTS_DIR"

echo ""
echo "======================================================================"
echo "ANALYSIS COMPLETE"
echo "======================================================================"
