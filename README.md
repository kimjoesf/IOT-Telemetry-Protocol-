µTP v1

µTP v1 is a lightweight UDP-based telemetry protocol designed for simple IoT sensor reporting and network experimentation.
The project focuses on observing packet loss, delay, and packet reordering rather than providing reliable delivery.

Build Instructions
Requirements

Python 3.8 or newer

Works on Linux, Windows, or macOS
(Linux is recommended for network impairment experiments)

Install Dependencies
pip install psutil matplotlib numpy pandas


No additional external libraries are required.
The client and server primarily rely on Python standard libraries such as socket, struct, and argparse.

Usage Examples
Start the Server
python3 server.py --port 9000 --csv telemetry.csv


Optional flags:

--no-reorder : Disable packet reordering correction

--verbose : Enable detailed logging

Run the Client (No Batching)
python3 client.py \
  --server-ip 127.0.0.1 \
  --server-port 9000 \
  --device-id 1 \
  --interval 1 \
  --duration 30 \
  --batch-size 1

Run the Client with Batching
python3 client.py \
  --server-ip 127.0.0.1 \
  --server-port 9000 \
  --device-id 3 \
  --interval 5 \
  --duration 60 \
  --batch-size 4

Client Arguments
Argument	Description
--server-ip	Server IP address
--server-port	Server UDP port
--device-id	16-bit device identifier
--interval	Reporting interval in seconds
--duration	Total runtime in seconds
--batch-size	Number of readings per packet
--seed	Random seed for deterministic runs
Batching Strategy

Batching is used to reduce packet overhead by grouping multiple sensor readings into a single UDP packet.

Batching is disabled when batch-size = 1

A packet is sent when either:

the reporting interval expires, or

the batch size limit is reached

A header flag indicates whether a packet contains multiple readings

Payload size is limited to remain within the maximum packet size constraint

Each sensor reading retains its own timestamp for accurate delay and jitter analysis

This design reduces packet rate while making the impact of packet loss on grouped telemetry data observable.

Field-Packing Strategy

The protocol uses a compact binary encoding to minimize overhead and simplify parsing.

Fixed-size binary header defined as !BBHHIB (11 bytes)

Big-endian network byte order for interoperability

Header fields include protocol version, message type, device ID, sequence number, timestamp, and flags

DATA message payload format:

1 byte for the number of readings

4 bytes (float32) per sensor reading

This approach avoids text-based encodings and keeps packets small, efficient, and easy to analyze in packet captures.
