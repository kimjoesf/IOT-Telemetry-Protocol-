import socket
import struct
import time
import csv
import argparse
import threading
from collections import defaultdict, deque
import heapq
from datetime import datetime
import sys
import os

# a try to import psutil for CPU metrics, but provide fallback
try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
    print("[WARN] psutil not installed. CPU metrics will be limited.")
    print(" Install with: pip install psutil")

 
# Protocol Definitions
VERSION = 1
MSG_HEARTBEAT = 0
MSG_DATA = 1

HEADER_FORMAT = "!BBHHIB"  # version, msg_type, device_id, seq, timestamp, flags
HEADER_SIZE = 11

 
# Device State Tracking with Reordering
class DeviceState:
    def __init__(self, device_id):
        self.device_id = device_id
        self.last_seq = None
        self.received_sequences = set()
        self.reorder_heap = []  # min-heap for timestamp-based reordering: (timestamp, seq, readings, arrival_time)
        self.last_processed_timestamp = 0
        self.total_packets = 0
        self.duplicate_count = 0
        self.gap_count = 0
        self.bytes_received = 0
        self.cpu_time_total = 0.0  # in milliseconds
        self.readings_received = 0
        
    def add_packet(self, seq, timestamp, readings, packet_size, arrival_time):
        """Add packet to reorder buffer"""
        heapq.heappush(self.reorder_heap, (timestamp, seq, readings, arrival_time))
        self.total_packets += 1
        self.bytes_received += packet_size
        self.readings_received += len(readings)
        
    def get_next_ordered(self):
        """Get next packet in timestamp order if available"""
        if not self.reorder_heap:
            return None
        
        # Peek at the earliest packet
        timestamp, seq, readings, arrival_time = self.reorder_heap[0]
        
        # Only return if this timestamp is >= last processed
        if timestamp >= self.last_processed_timestamp:
            heapq.heappop(self.reorder_heap)
            self.last_processed_timestamp = timestamp
            return seq, timestamp, readings, arrival_time
        return None
    
    def check_duplicate(self, seq):
        if seq in self.received_sequences:
            self.duplicate_count += 1
            return True
        return False
    
    def check_gap(self, seq):
        if self.last_seq is not None and seq != self.last_seq + 1:
            self.gap_count += 1
            return True
        return False
    
    def update_sequence(self, seq):
        self.received_sequences.add(seq)
        self.last_seq = seq
    
    def add_cpu_time(self, cpu_time_ms):
        """Add CPU processing time for this device"""
        self.cpu_time_total += cpu_time_ms
    
    def get_metrics(self):
        """Calculate metrics for this device"""
        duplicate_rate = (self.duplicate_count / max(self.total_packets, 1)) * 100
        avg_bytes_per_report = self.bytes_received / max(self.total_packets, 1)
        cpu_ms_per_report = self.cpu_time_total / max(self.total_packets, 1)
        
        return {
            'total_packets': self.total_packets,
            'readings_received': self.readings_received,
            'duplicate_count': self.duplicate_count,
            'duplicate_rate_percent': duplicate_rate,
            'gap_count': self.gap_count,
            'bytes_received': self.bytes_received,
            'avg_bytes_per_report': avg_bytes_per_report,
            'cpu_ms_per_report': cpu_ms_per_report,
            'reorder_buffer_size': len(self.reorder_heap)
        }

 
# Packet Processor with CPU Timing
class PacketProcessor:
    def __init__(self):
        self.process_time_total = 0.0
        self.packets_processed = 0
    
    def parse_header(self, packet):
        """Parse packet header with CPU timing"""
        if len(packet) < HEADER_SIZE:
            return None
        
        version, msg_type, dev_id, seq, timestamp, flags = struct.unpack(
            HEADER_FORMAT, packet[:HEADER_SIZE]
        )
        
        return version, msg_type, dev_id, seq, timestamp, flags
    
    def parse_data_payload(self, packet):
        """
        Format:
            count (1 byte)
            N x float readings (4 bytes each)
        """
        if len(packet) < HEADER_SIZE + 1:
            return []
        
        idx = HEADER_SIZE
        count = packet[idx]
        idx += 1
        
        readings = []
        for _ in range(count):
            if idx + 4 > len(packet):
                break
            (value,) = struct.unpack("!f", packet[idx: idx + 4])
            readings.append(round(value, 2))
            idx += 4
        
        return readings
    
    def is_batching_enabled(self, flags):
        """Check if batching flag is set"""
        return (flags & 0b00000001) != 0

 
# Metrics Collector
class MetricsCollector:
    def __init__(self):
        self.start_time = time.time()
        self.cpu_readings = []
        self.memory_readings = []
        self.packet_counts = defaultdict(int)
        self.lock = threading.Lock()
        
    def record_system_metrics(self):
        """Record current CPU and memory usage"""
        with self.lock:
            if PSUTIL_AVAILABLE:
                self.cpu_readings.append(psutil.cpu_percent(interval=None))
                self.memory_readings.append(psutil.virtual_memory().percent)
            else:
                self.cpu_readings.append(0)
                self.memory_readings.append(0)
            
            # Keep only last 1000 readings i guess more than enough
            if len(self.cpu_readings) > 1000:
                self.cpu_readings.pop(0)
                self.memory_readings.pop(0)
    
    def increment_packet_count(self, device_id):
        with self.lock:
            self.packet_counts[device_id] += 1
    
    def get_system_metrics(self):
        """Calculate system metrics"""
        if not self.cpu_readings:
            return 0, 0, 0, 0, 0, 0
        
        cpu_readings = self.cpu_readings.copy()
        mem_readings = self.memory_readings.copy()
        
        cpu_avg = sum(cpu_readings) / len(cpu_readings)
        cpu_sorted = sorted(cpu_readings)
        cpu_median = cpu_sorted[len(cpu_sorted) // 2]
        cpu_p95 = cpu_sorted[int(len(cpu_sorted) * 0.95)]
        
        mem_avg = sum(mem_readings) / len(mem_readings)
        
        return cpu_avg, cpu_median, cpu_p95, mem_avg
    
    def get_uptime(self):
        return time.time() - self.start_time

 

# Reorder Processor Thread
class ReorderProcessor(threading.Thread):
    def __init__(self, device_states, stop_event, csv_writer=None):
        super().__init__()
        self.device_states = device_states
        self.stop_event = stop_event
        self.csv_writer = csv_writer
        self.processed_count = 0
        self.reorder_events = 0
        
    def run(self):
        print("[REORDER] Reorder processor thread started")
        last_log_time = time.time()
        
        while not self.stop_event.is_set():
            reordered_this_cycle = 0
            
            for device_id, state in list(self.device_states.items()):
                result = state.get_next_ordered()
                while result is not None:
                    seq, timestamp, readings, arrival_time = result
                    self.processed_count += 1
                    reordered_this_cycle += 1
                    
                    # Log reordered packets (every 10th or first few)
                    if self.processed_count <= 5 or self.processed_count % 20 == 0:
                        latency = arrival_time - (timestamp / 1000.0) if timestamp > 1000000000 else 0
                        print(f"[REORDER] dev={device_id} seq={seq} | "
                              f"readings={len(readings)} | latency={latency*1000:.1f}ms")
                    
                    result = state.get_next_ordered()
            
            if reordered_this_cycle > 0:
                self.reorder_events += 1
            
            # Log status every 10 seconds
            current_time = time.time()
            if current_time - last_log_time > 10:
                print(f"[REORDER] Status: processed {self.processed_count} total, "
                      f"{self.reorder_events} reorder events")
                last_log_time = current_time
            
            # Sleep to prevent CPU spinning
            time.sleep(0.01)
        
        print(f"[REORDER] Processor stopped. Total reordered: {self.processed_count}")
 

# Write CSV with all required fields
def write_csv_row(csv_writer, dev_id, seq, timestamp, arrival_time, 
                  duplicate, gap, num_readings, is_batched, packet_size,
                  cpu_time_ms=0):
    csv_writer.writerow({
        "device_id": dev_id,
        "seq": seq,
        "timestamp": timestamp,
        "arrival_time": arrival_time,
        "duplicate_flag": int(duplicate),
        "gap_flag": int(gap),
        "num_readings": num_readings,
        "is_batched": int(is_batched),
        "packet_size": packet_size,
        "cpu_time_ms": cpu_time_ms
    })



# Main Server Loop
def run_server(port, csv_path, reorder_enabled=True):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(1.0)  # Timeout for responsive shutdown
    
    print(f"[INFO] µTP Collector Server v1")
    print(f"[INFO] Listening on UDP port {port}")
    print(f"[INFO] Logging to: {csv_path}")
    print(f"[INFO] Timestamp reordering: {'ENABLED' if reorder_enabled else 'DISABLED'}")
    print(f"[INFO] Started at {datetime.now()}")
    print("-" * 60)
    
    # Per-device state
    device_states = {}
    
    # Packet processor
    processor = PacketProcessor()
    
    # Metrics collection
    metrics = MetricsCollector()
    
    # Reorder processor thread
    stop_event = threading.Event()
    reorder_processor = None
    
    if reorder_enabled:
        reorder_processor = ReorderProcessor(device_states, stop_event)
        reorder_processor.start()
    
    # System metrics monitoring thread
    metrics_stop = threading.Event()
    
    def monitor_system_metrics():
        while not metrics_stop.is_set():
            metrics.record_system_metrics()
            time.sleep(0.5)
    
    metrics_thread = threading.Thread(target=monitor_system_metrics, daemon=True)
    metrics_thread.start()
    
    try:
        with open(csv_path, "w", newline="") as f:
            fieldnames = ["device_id", "seq", "timestamp", "arrival_time", 
                         "duplicate_flag", "gap_flag", "num_readings", 
                         "is_batched", "packet_size", "cpu_time_ms"]
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            
            packet_count = 0
            start_time = time.time()
            last_stats_time = start_time
            
            print("[INFO] Server ready. Press Ctrl+C to stop and generate report.")
            print("[INFO] Waiting for sensor data...")
            
            while True:
                try:
                    # Receive packet
                    packet_start_time = time.process_time()
                    packet, addr = sock.recvfrom(2048)
                    arrival_time = time.time()
                    packet_count += 1
                    
                    # Parse header
                    parsed = processor.parse_header(packet)
                    if parsed is None:
                        print("[WARN] Received malformed header")
                        continue
                    
                    version, msg_type, dev_id, seq, timestamp, flags = parsed
                    
                    # Validate version
                    if version != VERSION:
                        print(f"[WARN] Wrong protocol version {version} from device {dev_id}")
                        continue
                    
                    # Get or create device state
                    if dev_id not in device_states:
                        device_states[dev_id] = DeviceState(dev_id)
                        print(f"[INFO] New device connected: {dev_id}")
                    
                    state = device_states[dev_id]
                    metrics.increment_packet_count(dev_id)
                    
                    # Check duplicates
                    duplicate = state.check_duplicate(seq)
                    
                    # Sequence gap detection
                    gap = state.check_gap(seq)
                    
                    # Update sequence tracking (if not duplicate)
                    if not duplicate:
                        state.update_sequence(seq)
                    
                    # Parse message and measure CPU time
                    readings = []
                    is_batched = False
                    
                    if msg_type == MSG_DATA:
                        readings = processor.parse_data_payload(packet)
                        is_batched = processor.is_batching_enabled(flags) and len(readings) > 1
                        
                        if reorder_enabled:
                            # Added to reorder buffer with millisecond timestamp
                            # Convert timestamp if it's in seconds (likely < 1000000000)
                            if timestamp < 1000000000:  # Likely seconds since epoch
                                timestamp_ms = timestamp * 1000
                            else:
                                timestamp_ms = timestamp  # Assume already ms
                            
                            state.add_packet(seq, timestamp_ms, readings, len(packet), arrival_time)
                        
                     
                        if packet_count <= 5 or packet_count % 25 == 0:
                            batch_info = f" (batch: {len(readings)})" if is_batched else ""
                            sample = readings[:2]
                            sample_str = str(sample) + ("..." if len(readings) > 2 else "")
                            print(f"[DATA] dev={dev_id} seq={seq:03d}{batch_info} values={sample_str}")
                    
                    elif msg_type == MSG_HEARTBEAT:
                        if packet_count <= 5 or packet_count % 50 == 0:
                            print(f"[HB] dev={dev_id} seq={seq:03d}")
                    
                    # Calculate CPU time for this packet
                    packet_end_time = time.process_time()
                    cpu_time_ms = (packet_end_time - packet_start_time) * 1000
                    state.add_cpu_time(cpu_time_ms)
                    
                    # Write CSV
                    write_csv_row(writer, dev_id, seq, timestamp, arrival_time, 
                                 duplicate, gap, len(readings), is_batched, len(packet),
                                 cpu_time_ms)
                    f.flush()
                    
                    # Periodic statistics
                    current_time = time.time()
                    if current_time - last_stats_time > 5.0:
                        elapsed = current_time - start_time
                        rate = packet_count / elapsed if elapsed > 0 else 0
                        
                        cpu_avg, cpu_med, cpu_p95, mem_avg = metrics.get_system_metrics()
                        
                        print(f"[STATS] Time: {elapsed:.0f}s | "
                              f"Packets: {packet_count} ({rate:.1f}/s) | "
                              f"Devices: {len(device_states)} | "
                              f"CPU: {cpu_avg:.1f}% | Mem: {mem_avg:.1f}%")
                        
                        last_stats_time = current_time
                
                except socket.timeout:
                    continue
                except KeyboardInterrupt:
                    print("\n[INFO] Shutdown signal received...")
                    break
                except Exception as e:
                    print(f"[ERROR] Unexpected error: {e}")
                    continue
    
    except KeyboardInterrupt:
        print("\n[INFO] Server shutting down...")
    except Exception as e:
        print(f"[ERROR] Fatal error: {e}")
    
    finally:
        print("\n[INFO] Performing shutdown...")
        
        # Stop threads
        stop_event.set()
        metrics_stop.set()
        
        if reorder_enabled and reorder_processor:
            reorder_processor.join(timeout=2)
        
        metrics_thread.join(timeout=1)
        sock.close()
        
        # Generate final report
        generate_final_report(device_states, metrics, start_time)
 

# Generate Final Report
 
def generate_final_report(device_states, metrics, start_time):
    print("\n" + "="*70)
    print("FINAL PERFORMANCE REPORT")
    print("="*70)
    
    total_packets = sum(state.total_packets for state in device_states.values())
    total_duplicates = sum(state.duplicate_count for state in device_states.values())
    total_gaps = sum(state.gap_count for state in device_states.values())
    total_bytes = sum(state.bytes_received for state in device_states.values())
    total_readings = sum(state.readings_received for state in device_states.values())
    total_cpu_time = sum(state.cpu_time_total for state in device_states.values())
    
    runtime = time.time() - start_time
    
    print(f"\nOverall Statistics:")
    print(f"  Runtime: {runtime:.2f} seconds")
    print(f"  Total packets received: {total_packets}")
    print(f"  Total readings received: {total_readings}")
    print(f"  Total duplicates: {total_duplicates}")
    print(f"  Total sequence gaps: {total_gaps}")
    print(f"  Total bytes received: {total_bytes}")
    
    if total_packets > 0:
        duplicate_rate = (total_duplicates / total_packets) * 100
        avg_bytes = total_bytes / total_packets
        avg_cpu_per_packet = total_cpu_time / total_packets
        
        print(f"  Duplicate rate: {duplicate_rate:.2f}%")
        print(f"  Average bytes per report: {avg_bytes:.2f}")
        print(f"  Average CPU per packet: {avg_cpu_per_packet:.3f} ms")
        print(f"  Average packets per second: {total_packets/runtime:.2f}")
    
    # System metrics
    cpu_avg, cpu_med, cpu_p95, mem_avg = metrics.get_system_metrics()
    print(f"\nSystem Metrics:")
    print(f"  Average CPU usage: {cpu_avg:.1f}%")
    print(f"  Median CPU usage: {cpu_med:.1f}%")
    print(f"  95th percentile CPU: {cpu_p95:.1f}%")
    print(f"  Average memory usage: {mem_avg:.1f}%")
    
    print(f"\nConnected Devices: {len(device_states)}")
    if device_states:
        print("\nPer-device statistics:")
        for dev_id, state in sorted(device_states.items()):
            dev_metrics = state.get_metrics()
            print(f"\n  Device {dev_id}:")
            print(f"    Packets: {dev_metrics['total_packets']}")
            print(f"    Readings: {dev_metrics['readings_received']}")
            print(f"    Duplicates: {dev_metrics['duplicate_count']} ({dev_metrics['duplicate_rate_percent']:.2f}%)")
            print(f"    Gaps: {dev_metrics['gap_count']}")
            print(f"    Avg bytes/report: {dev_metrics['avg_bytes_per_report']:.2f}")
            print(f"    CPU ms/report: {dev_metrics['cpu_ms_per_report']:.3f}")
            print(f"    Pending reorder: {dev_metrics['reorder_buffer_size']}")
    
    print("\n" + "="*70)
    print("REQUIRED METRICS VALIDATION")
    print("="*70)
    

# CLI
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="µTP Collector Server")
    
    parser.add_argument("--port", type=int, default=9000,
                       help="UDP port to listen on (default: 9000)")
    parser.add_argument("--csv", type=str, default="telemetry_log.csv",
                       help="Path to CSV output file (default: telemetry_log.csv)")
    parser.add_argument("--no-reorder", action="store_true",
                       help="Disable timestamp-based reordering")
    parser.add_argument("--verbose", "-v", action="store_true",
                       help="Enable verbose logging")
    
    args = parser.parse_args()