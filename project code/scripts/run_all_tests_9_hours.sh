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
    local interval="$3"
    local iter="$4"
    local port=$((9000 + iter + RANDOM % 1000))  # Avoid port conflicts
    local seed=$((42 + iter))
    
    # Calculate duration based on interval 
    local duration=$((interval * 30))  # 30 reports minimum
    
    echo ""
    echo "[$scenario] Batch=$batch_size Interval=${interval}s Run $iter/5 — seed=$seed — port=$port"
    
    # Apply network condition
    case "$scenario" in
        baseline) sudo tc qdisc del dev lo root 2>/dev/null || true ;;
        loss5) sudo tc qdisc add dev lo root netem loss 5% ;;
        delay100) sudo tc qdisc add dev lo root netem delay 100ms 10ms ;;
    esac
    
    # Start packet capture
    sudo tcpdump -i lo -w "$RESULTS_DIR/pcaps/${scenario}_batch${batch_size}_int${interval}_run${iter}.pcap" \
        port $port -s 65535 > /dev/null 2>&1 &
    TCPDUMP_PID=$!
    
    # Start server
    python3 server.py --port $port \
        --csv "$RESULTS_DIR/csvs/${scenario}_batch${batch_size}_int${interval}_run${iter}.csv" \
        > "$RESULTS_DIR/logs/${scenario}_batch${batch_size}_int${interval}_run${iter}_server.log" 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    # Run client WITH BATCH SIZE AND INTERVAL PARAMETERS
    python3 client.py --server-port $port \
        --device-id $((100 + iter)) \
        --interval "$interval" --duration "$duration" --batch-size "$batch_size" --seed $seed \
        > "$RESULTS_DIR/logs/${scenario}_batch${batch_size}_int${interval}_run${iter}_client.log" 2>&1
    
    # Cleanup
    sleep 5
    kill $SERVER_PID 2>/dev/null || true
    sudo kill $TCPDUMP_PID 2>/dev/null || true
    sudo tc qdisc del dev lo root 2>/dev/null || true
}

# Analyze results for one scenario configuration
analyze() {
    local scenario="$1"
    local batch_size="$2"
    local interval="$3"
    
    echo ""
    echo "=== ANALYZING $scenario (Batch=$batch_size, Interval=${interval}s, 5 runs) ==="
    
    # temporary Python script
    cat > /tmp/analyze_config.py << 'PYTHON_EOF'
import pandas as pd, glob, statistics, json, os, sys
scenario = sys.argv[1]
batch_size = sys.argv[2]
interval = sys.argv[3]
results_dir = sys.argv[4]

pattern = f"{results_dir}/csvs/{scenario}_batch{batch_size}_int{interval}_run*.csv"
files = sorted(glob.glob(pattern))
data = []
for f in files:
    try:
        df = pd.read_csv(f)
        total_packets = len(df)
        expected_packets = 30  # We expect 30 reports (duration/interval = 30)
        delivery_rate = (total_packets / expected_packets) * 100 if expected_packets > 0 else 0
        
        data.append({
            'run': os.path.basename(f),
            'packets': total_packets,
            'expected_packets': expected_packets,
            'delivery_rate_%': delivery_rate,
            'dup_rate_%': df['duplicate_flag'].mean() * 100,
            'gaps': df['gap_flag'].sum(),
            'bytes_per_report': df['packet_size'].mean(),
            'cpu_ms_per_report': df.get('cpu_time_ms', pd.Series([0])).mean(),
            'avg_readings_per_packet': df['num_readings'].mean() if 'num_readings' in df.columns else 1
        })
    except Exception as e:
        print(f"Error reading {f}: {e}")

if not data:
    print(f"No data found for {scenario} batch={batch_size} interval={interval}s")
    sys.exit(1)

df = pd.DataFrame(data)
print(f"SCENARIO: {scenario.upper()} | BATCH SIZE: {batch_size} | INTERVAL: {interval}s")
print(f"Generated: {pd.Timestamp.now()}\n")

print("REQUIRED METRICS:")
for col in ['packets', 'delivery_rate_%', 'dup_rate_%', 'gaps', 'bytes_per_report', 'cpu_ms_per_report', 'avg_readings_per_packet']:
    vals = df[col].tolist()
    if vals:
        print(f"{col.replace('_', ' ').title():30}: "
              f"min={min(vals):.2f} median={statistics.median(vals):.2f} max={max(vals):.2f}")

print("\nACCEPTANCE CRITERIA CHECK:")
# Check baseline requirements
if scenario == "baseline":
    delivery_median = statistics.median(df['delivery_rate_%'].tolist())
    if delivery_median >= 99.0:
        print(" Baseline: ≥99% delivery rate MET")
    else:
        print(f" Baseline: {delivery_median:.1f}% delivery (should be ≥99%)")

# Check loss scenario requirements
if scenario == "loss5":
    dup_median = statistics.median(df['dup_rate_%'].tolist())
    if dup_median <= 1.0:
        print(" Loss 5%: Duplicate rate ≤1% MET")
    else:
        print(f" Loss 5%: {dup_median:.1f}% duplicates (should be ≤1%)")
    
    gaps_detected = any(df['gaps'] > 0)
    if gaps_detected:
        print(" Loss 5%: Sequence gaps detected")
    else:
        print(" Loss 5%: No gaps detected (expected with 5% loss)")

# Check packet size limits
bytes_median = statistics.median(df['bytes_per_report'].tolist())
if bytes_median <= 200:
    print(f" Packet size: {bytes_median:.1f} bytes ≤ 200 limit")
else:
    print(f" Packet size: {bytes_median:.1f} bytes > 200 limit")

print("\n" + "="*50)
PYTHON_EOF
    
    python3 /tmp/analyze_config.py "$scenario" "$batch_size" "$interval" "$RESULTS_DIR" > "$RESULTS_DIR/reports/${scenario}_batch${batch_size}_int${interval}_report.txt"
    
    echo "Report → $RESULTS_DIR/reports/${scenario}_batch${batch_size}_int${interval}_report.txt"
}

# Main test matrix - NOW INCLUDES ALL INTERVALS
for scenario in baseline loss5 delay100; do
    for interval in 1 5 30; do  # Test all required intervals
        for batch_size in 1 3; do  # Test without batching (1) and with batching (3)
            echo ""
            echo "======================================================================"
            echo "SCENARIO: $scenario | INTERVAL: ${interval}s | BATCH SIZE: $batch_size"
            echo "======================================================================"
            
            for i in {1..5}; do
                run_one "$scenario" "$batch_size" "$interval" "$i"
            done
            
            analyze "$scenario" "$batch_size" "$interval"
        done
    done
done

echo ""
echo "======================================================================"
echo "ALL TESTS COMPLETED A5ERN"
echo "======================================================================"
echo "Now generating comprehensive comparison plots..."
echo ""

# Generating comparison plots
cat > /tmp/generate_comprehensive_plots.py << 'PYTHON_EOF'
import pandas as pd, glob, matplotlib.pyplot as plt, os, numpy as np, sys
from matplotlib import cm

results_dir = sys.argv[1]

# Collect all data
all_data = []
for csv in glob.glob(f"{results_dir}/csvs/*.csv"):
    filename = os.path.basename(csv)
    # Parse scenario, batch size, and interval from filename
    # Format: scenario_batchX_intY_runZ.csv
    parts = filename.replace('.csv', '').split('_')
    if len(parts) >= 4:
        scenario = parts[0]
        batch_size = int(parts[1].replace('batch', ''))
        interval = int(parts[2].replace('int', ''))
        
        try:
            df = pd.read_csv(csv)
            total_packets = len(df)
            expected_packets = 30  # 30 reports expected
            delivery_rate = (total_packets / expected_packets) * 100 if expected_packets > 0 else 0
            
            all_data.append({
                'scenario': scenario,
                'batch_size': batch_size,
                'interval': interval,
                'avg_bytes': df['packet_size'].mean(),
                'avg_readings': df.get('num_readings', pd.Series([1])).mean(),
                'dup_rate': df['duplicate_flag'].mean() * 100,
                'gaps': df['gap_flag'].sum(),
                'delivery_rate': delivery_rate,
                'cpu_ms_per_report': df.get('cpu_time_ms', pd.Series([0])).mean(),
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

print(f"Total configurations tested: {len(df_summary)}")
print(f"Scenarios: {df_summary['scenario'].unique()}")
print(f"Intervals: {sorted(df_summary['interval'].unique())}")
print(f"Batch sizes: {sorted(df_summary['batch_size'].unique())}")

# ========== PLOT 1: Bytes per report vs reporting interval (REQUIRED) ==========
plt.figure(figsize=(12, 8))
colors = cm.tab10.colors
markers = ['o', 's', '^', 'D', 'v', '<', '>', 'p', '*', 'h']

# Separate by scenario and batch size
for idx, scenario in enumerate(sorted(df_summary['scenario'].unique())):
    for jdx, batch_size in enumerate([1, 3]):
        subset = df_summary[(df_summary['scenario'] == scenario) & 
                          (df_summary['batch_size'] == batch_size)]
        if not subset.empty:
            subset = subset.sort_values('interval')
            label = f"{scenario} (batch={batch_size})"
            color_idx = idx * 2 + jdx
            plt.plot(subset['interval'], subset['avg_bytes'], 
                    marker=markers[color_idx % len(markers)],
                    color=colors[color_idx % len(colors)],
                    linewidth=2, markersize=8, label=label)

plt.xlabel('Reporting Interval (seconds)')
plt.ylabel('Average Bytes per Report')
plt.title('REQUIRED: Bytes per Report vs Reporting Interval')
plt.legend(bbox_to_anchor=(1.05, 1), loc='upper left')
plt.grid(True, alpha=0.3)
plt.xticks([1, 5, 30])
plt.axhline(y=200, color='r', linestyle='--', alpha=0.5, label='200 byte limit')
plt.tight_layout()
plt.savefig(f"{results_dir}/bytes_vs_interval.png", dpi=150, bbox_inches='tight')
plt.close()

print(f" REQUIRED Plot saved: {results_dir}/bytes_vs_interval.png")

# ========== PLOT 2: Duplicate rate vs loss (REQUIRED) ==========
plt.figure(figsize=(12, 8))
# Focus on loss scenario
loss_data = df_summary[df_summary['scenario'] == 'loss5']

if not loss_data.empty:
    # Group by interval and batch size
    intervals = sorted(loss_data['interval'].unique())
    x = np.arange(len(intervals))
    width = 0.35
    
    for i, batch_size in enumerate([1, 3]):
        batch_rates = []
        for interval in intervals:
            val = loss_data[(loss_data['batch_size'] == batch_size) & 
                          (loss_data['interval'] == interval)]['dup_rate']
            batch_rates.append(val.mean() if not val.empty else 0)
        
        plt.bar(x + (i * width) - width/2, batch_rates, width, 
                label=f'Batch={batch_size}', alpha=0.7)
    
    plt.xlabel('Reporting Interval (seconds)')
    plt.ylabel('Duplicate Rate (%)')
    plt.title('REQUIRED: Duplicate Rate vs Loss (5% loss scenario)')
    plt.xticks(x, intervals)
    plt.legend()
    plt.grid(True, alpha=0.3, axis='y')
    plt.axhline(y=1.0, color='r', linestyle='--', alpha=0.5, label='1% threshold')
    plt.tight_layout()
    plt.savefig(f"{results_dir}/duplicate_rate_vs_loss.png", dpi=150, bbox_inches='tight')
    plt.close()
    print(f" REQUIRED Plot saved: {results_dir}/duplicate_rate_vs_loss.png")
else:
    print("No loss5 data found for required plot")

# ========== PLOT 3: Delivery rate across scenarios ==========
plt.figure(figsize=(12, 8))
scenarios = ['baseline', 'loss5', 'delay100']
x = np.arange(len(scenarios))
width = 0.25

for i, interval in enumerate([1, 5, 30]):
    delivery_rates = []
    for scenario in scenarios:
        val = df_summary[(df_summary['scenario'] == scenario) & 
                        (df_summary['interval'] == interval) & 
                        (df_summary['batch_size'] == 1)]['delivery_rate']  # Use batch=1 for consistency
        delivery_rates.append(val.mean() if not val.empty else 0)
    
    plt.bar(x + (i * width) - width, delivery_rates, width, 
            label=f'Interval={interval}s', alpha=0.7)

plt.xlabel('Scenario')
plt.ylabel('Delivery Rate (%)')
plt.title('Packet Delivery Rate Across Scenarios')
plt.xticks(x, [s.upper() for s in scenarios])
plt.legend()
plt.grid(True, alpha=0.3, axis='y')
plt.axhline(y=99, color='g', linestyle='--', alpha=0.5, label='99% threshold')
plt.tight_layout()
plt.savefig(f"{results_dir}/delivery_rate.png", dpi=150, bbox_inches='tight')
plt.close()

print(f" Plot saved: {results_dir}/delivery_rate.png")

# ========== PLOT 4: Batching efficiency comparison ==========
plt.figure(figsize=(12, 8))
# Compare batch=1 vs batch=3 for each scenario and interval
for idx, scenario in enumerate(scenarios):
    plt.subplot(1, 3, idx+1)
    
    for batch_size in [1, 3]:
        subset = df_summary[(df_summary['scenario'] == scenario) & 
                          (df_summary['batch_size'] == batch_size)]
        if not subset.empty:
            subset = subset.sort_values('interval')
            plt.plot(subset['interval'], subset['avg_readings'], 
                    'o-' if batch_size == 1 else 's--',
                    label=f'Batch={batch_size}', linewidth=2, markersize=6)
    
    plt.title(f'{scenario.upper()}')
    plt.xlabel('Interval (s)')
    if idx == 0:
        plt.ylabel('Avg Readings per Packet')
    plt.grid(True, alpha=0.3)
    plt.xticks([1, 5, 30])
    plt.legend()

plt.suptitle('Batching Efficiency: Readings per Packet')
plt.tight_layout()
plt.savefig(f"{results_dir}/batching_efficiency.png", dpi=150, bbox_inches='tight')
plt.close()

print(f" Plot saved: {results_dir}/batching_efficiency.png")

# ========== PLOT 5: CPU efficiency ==========
plt.figure(figsize=(12, 8))
for idx, batch_size in enumerate([1, 3]):
    plt.subplot(1, 2, idx+1)
    
    for scenario in scenarios:
        subset = df_summary[(df_summary['scenario'] == scenario) & 
                          (df_summary['batch_size'] == batch_size)]
        if not subset.empty:
            subset = subset.sort_values('interval')
            plt.plot(subset['interval'], subset['cpu_ms_per_report'], 
                    'o-', label=scenario, linewidth=2, markersize=6)
    
    plt.title(f'Batch Size = {batch_size}')
    plt.xlabel('Interval (s)')
    plt.ylabel('CPU ms per Report')
    plt.grid(True, alpha=0.3)
    plt.xticks([1, 5, 30])
    plt.legend()

plt.suptitle('Processing Efficiency: CPU Time per Report')
plt.tight_layout()
plt.savefig(f"{results_dir}/cpu_efficiency.png", dpi=150, bbox_inches='tight')
plt.close()

print(f" Plot saved: {results_dir}/cpu_efficiency.png")

# ========== Generate comprehensive summary report ==========
print("\n" + "="*70)
print("COMPREHENSIVE SUMMARY REPORT")
print("="*70)

for scenario in scenarios:
    print(f"\n{scenario.upper()}:")
    for interval in [1, 5, 30]:
        print(f"\n  Interval {interval}s:")
        for batch_size in [1, 3]:
            subset = df_summary[(df_summary['scenario'] == scenario) & 
                              (df_summary['interval'] == interval) & 
                              (df_summary['batch_size'] == batch_size)]
            if not subset.empty:
                avg_bytes = subset['avg_bytes'].mean()
                avg_readings = subset['avg_readings'].mean()
                dup_rate = subset['dup_rate'].mean()
                delivery = subset['delivery_rate'].mean()
                gaps = subset['gaps'].mean()
                
                print(f"    Batch {batch_size}: {avg_bytes:.1f} bytes, "
                      f"{avg_readings:.1f} readings/packet, "
                      f"{delivery:.1f}% delivered, "
                      f"{dup_rate:.2f}% duplicates, "
                      f"{gaps:.1f} gaps")
PYTHON_EOF

python3 /tmp/generate_comprehensive_plots.py "$RESULTS_DIR"