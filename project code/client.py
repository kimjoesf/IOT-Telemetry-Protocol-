import socket
import struct
import time
import argparse
import random
import sys
import datetime

 
# Protocol Definitions
VERSION = 1
MSG_HEARTBEAT = 0
MSG_DATA = 1

HEADER_FORMAT = "!BBHHIB"   # version, type, device_id, seq_num, timestamp, flags
HEADER_SIZE = 11

# Flags
FLAG_BATCHING = 0b00000001
MAX_PAYLOAD_BYTES = 200
MAX_READINGS_PER_PACKET = (MAX_PAYLOAD_BYTES - HEADER_SIZE - 1) // 4  # 1 byte for count

 
# Build Packet
def build_header(msg_type, device_id, seq_num, flags, timestamp=None):
    if timestamp is None:
        timestamp = int(time.time())  # seconds since epoch
    return struct.pack(
        HEADER_FORMAT,
        VERSION,
        msg_type,
        device_id,
        seq_num,
        timestamp,
        flags
    )

def validate_packet_size(packet):
    """Validate packet doesn't exceed max payload size"""
    payload_size = len(packet) - HEADER_SIZE
    if payload_size > MAX_PAYLOAD_BYTES:
        raise ValueError(f"Payload too large: {payload_size} > {MAX_PAYLOAD_BYTES}")
    return True

def build_data_packet(device_id, seq_num, readings, timestamp=None):
    """
    readings: list of floats
    Format:
       header (11 bytes)
       count (1 byte)
       readings (4 bytes each float)
    """
    if len(readings) > MAX_READINGS_PER_PACKET:
        readings = readings[:MAX_READINGS_PER_PACKET]
    
    flags = FLAG_BATCHING if len(readings) > 1 else 0
    header = build_header(MSG_DATA, device_id, seq_num, flags, timestamp)
    
    count = len(readings)
    payload = struct.pack("!B", count)  # number of readings
    
    # 4 bytes per float (IEEE 754 binary32)
    for r in readings:
        payload += struct.pack("!f", r)
    
    packet = header + payload
    validate_packet_size(packet)
    return packet

def build_heartbeat_packet(device_id, seq_num, timestamp=None):
    flags = 0
    header = build_header(MSG_HEARTBEAT, device_id, seq_num, flags, timestamp)
    return header

 
# Sensor Simulation
class SensorSimulator:
    def __init__(self, seed=42):
        self.seed = seed
        random.seed(seed)
        self.reading_id = 0
    
    def generate_sensor_reading(self):
        """Simulate a reading (temperature, humidity, voltage, etc.)"""
        self.reading_id += 1
        # Deterministic but varied readings
        sensor_type = self.reading_id % 3
        
        if sensor_type == 0:
            # Temperature: 20-40°C with small deterministic variations
            base = 20.0 + (self.reading_id % 20)
            variation = random.uniform(-0.5, 0.5)
            return round(base + variation, 2)
        elif sensor_type == 1:
            # Humidity: 30-90%
            base = 30.0 + (self.reading_id % 60)
            variation = random.uniform(-1.0, 1.0)
            return round(base + variation, 2)
        else:
            # Voltage: 3.0-5.0V
            base = 3.0 + (self.reading_id % 20) * 0.1
            variation = random.uniform(-0.05, 0.05)
            return round(base + variation, 2)

 
# Batch Manager  
 
class BatchManager:
    def __init__(self, max_batch_size):
        self.max_batch_size = max_batch_size
        self.buffer = []
        self.last_send_time = time.time()
    
    def add_reading(self, reading):
        self.buffer.append(reading)
    
    def should_send(self, current_time, interval):
        """Determine if we should send based on time OR buffer full"""
        time_elapsed = current_time - self.last_send_time >= interval
        buffer_full = len(self.buffer) >= self.max_batch_size
        return time_elapsed or buffer_full
    
    def get_batch_and_reset(self):
        batch = self.buffer.copy()
        self.buffer = []
        self.last_send_time = time.time()
        return batch
    
    def has_data(self):
        return len(self.buffer) > 0
    
    def clear(self):
        """Clear buffer without sending"""
        self.buffer = []
 

# Client Main Logic  
def run_client(server_ip, server_port, device_id, interval, duration, batch_size, seed):
    # Set deterministic seed
    random.seed(seed)
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.1)  # Small timeout for responsiveness
    
    seq_num = 0
    start_time = time.time()
    end_time = start_time + duration
    
    batch_manager = BatchManager(batch_size)
    sensor = SensorSimulator(seed)
    
    # Statistics
    packets_sent = 0
    bytes_sent = 0
    readings_sent = 0
    heartbeats_sent = 0
    

    valid_intervals = [1, 5, 30]
    if interval not in valid_intervals:
        print(f"[WARN] Interval {interval}s not in {valid_intervals}. Using anyway.")
    
    print(f"[INFO] Sensor started at {datetime.datetime.now()}")
    print(f"[INFO] Duration: {duration}s | Interval: {interval}s")
    print(f"[INFO] Device ID: {device_id} | Seed: {seed}")
    print(f"[INFO] Batching: up to {batch_size} readings per packet")
    print(f"[INFO] Max readings per packet: {MAX_READINGS_PER_PACKET}")
    print("-" * 50)
    
    # proper interval timing
    next_send_time = start_time
    
    try:
        while time.time() < end_time:
            current_time = time.time()
            
            # Check if it's time to generate and send
            if current_time >= next_send_time:
                # Generate a reading
                reading = sensor.generate_sensor_reading()
                batch_manager.add_reading(reading)
                
                # Check if we should send (time-based OR buffer full)
                if batch_manager.should_send(current_time, interval):
                    if batch_manager.has_data():
                        seq_num += 1
                        readings = batch_manager.get_batch_and_reset()
                        
                        # Optional slight timestamp variation for testing
                        timestamp_variation = random.randint(0, 10)
                        packet = build_data_packet(device_id, seq_num, readings)
                        
                        sock.sendto(packet, (server_ip, server_port))
                        
                        packets_sent += 1
                        bytes_sent += len(packet)
                        readings_sent += len(readings)
                        
                        if seq_num % 10 == 0 or seq_num <= 3:
                            print(f"[DATA] seq={seq_num:03d} | readings={len(readings)} | bytes={len(packet)}")
                    else:
                        # Send heartbeat if no data (shouldn't happen with batching)
                        seq_num += 1
                        packet = build_heartbeat_packet(device_id, seq_num)
                        sock.sendto(packet, (server_ip, server_port))
                        
                        packets_sent += 1
                        bytes_sent += len(packet)
                        heartbeats_sent += 1
                        
                        if seq_num % 20 == 0:
                            print(f"[HB] seq={seq_num:03d} (heartbeat)")
                
                # Schedule next send time
                next_send_time += interval
                
                # If we fell behind, skip ahead to current time
                if next_send_time < current_time:
                    next_send_time = current_time + interval
            
            # Calculate sleep time until next interval
            sleep_time = max(0.001, next_send_time - time.time())
            time.sleep(sleep_time)
    
    except KeyboardInterrupt:
        print("\n[INFO] Client interrupted by user")
    except Exception as e:
        print(f"\n[ERROR] Client error: {e}")
    
    # Send any remaining data
    if batch_manager.has_data():
        seq_num += 1
        readings = batch_manager.get_batch_and_reset()
        packet = build_data_packet(device_id, seq_num, readings)
        sock.sendto(packet, (server_ip, server_port))
        packets_sent += 1
        bytes_sent += len(packet)
        readings_sent += len(readings)
        print(f"[FINAL] seq={seq_num} | readings={len(readings)}")
    
    # Final statistics
    actual_duration = time.time() - start_time
    print("\n" + "="*50)
    print("CLIENT STATISTICS")
    print("="*50)
    print(f"Requested duration: {duration}s")
    print(f"Actual runtime: {actual_duration:.2f}s")
    print(f"Packets sent: {packets_sent}")
    print(f"  - Data packets: {packets_sent - heartbeats_sent}")
    print(f"  - Heartbeats: {heartbeats_sent}")
    print(f"Readings sent: {readings_sent}")
    print(f"Total bytes sent: {bytes_sent}")
    
    if packets_sent > 0:
        print(f"Average bytes per packet: {bytes_sent/packets_sent:.2f}")
        print(f"Average readings per data packet: {readings_sent/max(packets_sent - heartbeats_sent, 1):.2f}")
        print(f"Effective send rate: {packets_sent/actual_duration:.2f} packets/second")
    
    print(f"Final sequence number: {seq_num}")
    print("[INFO] Sensor finished.")

 
# CLI
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="µTP Sensor Client")
    
    parser.add_argument("--server-ip", type=str, default="127.0.0.1",
                       help="Server IP address")
    parser.add_argument("--server-port", type=int, default=9000,
                       help="Server UDP port")
    
    parser.add_argument("--device-id", type=int, default=1,
                       help="Unique device identifier (1-65535)")
    parser.add_argument("--interval", type=float, default=1.0,
                       help="Seconds between reports (1, 5, or 30)")
    parser.add_argument("--duration", type=int, default=60,
                       help="Total run time in seconds")
    parser.add_argument("--batch-size", type=int, default=1,
                       help="Maximum number of readings per DATA packet")
    parser.add_argument("--seed", type=int, default=42,
                       help="Random seed for reproducible tests")
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.batch_size < 1:
        print("[ERROR] Batch size must be at least 1")
        sys.exit(1)
    
    if args.device_id < 1 or args.device_id > 65535:
        print("[ERROR] Device ID must be between 1 and 65535")
        sys.exit(1)
    
    if args.interval <= 0:
        print("[ERROR] Interval must be positive")
        sys.exit(1)
    
    run_client(
        args.server_ip,
        args.server_port,
        args.device_id,
        args.interval,
        args.duration,
        args.batch_size,
        args.seed
    )