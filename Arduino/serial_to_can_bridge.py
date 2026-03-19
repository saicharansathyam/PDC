#!/usr/bin/env python3
"""
Bridge: Arduino USB serial → virtual CAN (can0)

Arduino sends over USB serial (115200 baud):
  "Speed: X.XX cm/s, Distance: Y.YY cm [Sent]"

This script parses that and injects CAN frames with ID 0x0F6
in the exact format VehicleControlECU's CANInterface expects:
  data[0] = int1_spd // 256
  data[1] = int1_spd % 256
  data[2] = round((speed - int1_spd) * 100)
  data[3:7] = distance as float (little-endian)
  data[7] = 0x00
"""

import socket
import struct
import serial
import re
import sys

SERIAL_PORT   = "/dev/ttyACM1"
SERIAL_BAUD   = 115200
CAN_INTERFACE = "can0"
ARDUINO_ID    = 0x0F6

pattern = re.compile(r'Speed:\s*([\d.]+)\s*cm/s,\s*Distance:\s*([-\d.]+)\s*cm')

def main():
    # Open CAN socket
    try:
        can_sock = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
        can_sock.bind((CAN_INTERFACE,))
        print(f"[bridge] CAN socket open on {CAN_INTERFACE}")
    except Exception as e:
        print(f"[bridge] ERROR opening CAN socket: {e}")
        print(f"         Make sure 'can0' is up: sudo modprobe vcan && sudo ip link add dev can0 type vcan && sudo ip link set can0 up")
        sys.exit(1)

    # Open serial port
    try:
        ser = serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=1)
        print(f"[bridge] Serial open on {SERIAL_PORT} at {SERIAL_BAUD} baud")
    except Exception as e:
        print(f"[bridge] ERROR opening serial port: {e}")
        sys.exit(1)

    print("[bridge] Running — Ctrl+C to stop\n")

    log_count = 0
    while True:
        try:
            line = ser.readline().decode('utf-8', errors='ignore').strip()
        except Exception as e:
            print(f"[bridge] Serial read error: {e}")
            continue

        m = pattern.search(line)
        if not m:
            continue

        speed    = float(m.group(1))
        distance = float(m.group(2))

        # Pack data matching Arduino's CAN frame layout
        int1_spd = int(speed)
        int2_spd = round((speed - int1_spd) * 100) & 0xFF

        data = bytearray(8)
        data[0] = (int1_spd // 256) & 0xFF
        data[1] = (int1_spd % 256) & 0xFF
        data[2] = int2_spd
        struct.pack_into('<f', data, 3, distance)  # float little-endian at bytes 3-6
        data[7] = 0x00

        # SocketCAN frame: can_id(4B) + dlc(1B) + pad(3B) + data(8B)
        frame = struct.pack("=IB3x8s", ARDUINO_ID, 8, bytes(data))
        try:
            can_sock.send(frame)
        except Exception as e:
            print(f"[bridge] CAN send error: {e}")
            continue

        log_count += 1
        if log_count % 10 == 0:
            print(f"[bridge] Speed={speed:.1f} cm/s  Distance={distance:.1f} cm  (frame #{log_count})")

if __name__ == "__main__":
    main()
