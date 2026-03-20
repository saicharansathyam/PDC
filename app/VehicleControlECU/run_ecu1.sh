#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ECU1 Startup Script — Raspberry Pi 4
# Starts: virtual CAN, serial-to-CAN bridge, VehicleControlECU, camera stream
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SCRIPT="$HOME/serial_to_can_bridge.py"
SERIAL_PORT="/dev/ttyACM0"
JETSON_IP="192.168.1.101"
CAMERA_PORT="5000"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "ECU1 Startup — Raspberry Pi 4"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────────────────────────
# Step 1: Kill any stale processes
# ───────────────────────────────────────────────────────────────────────────────
echo "[1/5] Cleaning up stale processes..."
sudo pkill -f VehicleControlECU 2>/dev/null || true
pkill -f serial_to_can_bridge.py 2>/dev/null || true
pkill -f gst-launch 2>/dev/null || true
sleep 1

# ───────────────────────────────────────────────────────────────────────────────
# Step 2: Set up virtual CAN interface (can0)
# ───────────────────────────────────────────────────────────────────────────────
echo "[2/5] Setting up virtual CAN interface..."
sudo modprobe vcan 2>/dev/null || true
if ! ip link show can0 &>/dev/null; then
    sudo ip link add dev can0 type vcan
fi
sudo ip link set can0 up
echo "      can0 is UP"

# ───────────────────────────────────────────────────────────────────────────────
# Step 3: Detect Arduino serial port
# ───────────────────────────────────────────────────────────────────────────────
echo "[3/5] Detecting Arduino serial port..."
for port in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyUSB0 /dev/ttyUSB1; do
    if [ -e "$port" ]; then
        SERIAL_PORT="$port"
        echo "      Arduino found at $SERIAL_PORT"
        break
    fi
done

if [ ! -e "$SERIAL_PORT" ]; then
    echo "      ⚠️  Arduino not found — bridge will not start"
    echo "         Connect Arduino and re-run, or start bridge manually:"
    echo "         python3 $BRIDGE_SCRIPT"
else
    # Update bridge script with correct port if needed
    sed -i "s|SERIAL_PORT.*=.*\"/dev/ttyACM[0-9]*\"|SERIAL_PORT   = \"$SERIAL_PORT\"|" "$BRIDGE_SCRIPT" 2>/dev/null || true

    echo "[3/5] Starting serial-to-CAN bridge ($SERIAL_PORT → can0)..."
    python3 "$BRIDGE_SCRIPT" > /tmp/can_bridge.log 2>&1 &
    BRIDGE_PID=$!
    sleep 1
    if kill -0 $BRIDGE_PID 2>/dev/null; then
        echo "      Bridge running (PID $BRIDGE_PID) — log: /tmp/can_bridge.log"
    else
        echo "      ⚠️  Bridge failed to start — check /tmp/can_bridge.log"
    fi
fi

# ───────────────────────────────────────────────────────────────────────────────
# Step 4: Start VehicleControlECU
# ───────────────────────────────────────────────────────────────────────────────
echo "[4/5] Starting VehicleControlECU..."
VSOMEIP_APPLICATION_NAME=VehicleControlECU \
VSOMEIP_CONFIGURATION="$SCRIPT_DIR/config/vsomeip_ecu1.json" \
COMMONAPI_CONFIG="$SCRIPT_DIR/config/commonapi_ecu1.ini" \
sudo -E "$SCRIPT_DIR/build/VehicleControlECU" > /tmp/ecu1.log 2>&1 &
ECU_PID=$!
sleep 2
if kill -0 $ECU_PID 2>/dev/null; then
    echo "      VehicleControlECU running (PID $ECU_PID) — log: /tmp/ecu1.log"
else
    echo "      ❌ VehicleControlECU failed — check /tmp/ecu1.log"
    cat /tmp/ecu1.log | tail -20
    exit 1
fi

# ───────────────────────────────────────────────────────────────────────────────
# Step 5: Start camera stream to Jetson
# ───────────────────────────────────────────────────────────────────────────────
echo "[5/5] Starting camera stream → $JETSON_IP:$CAMERA_PORT..."
gst-launch-1.0 libcamerasrc \
    ! video/x-raw,width=1280,height=720,framerate=30/1 \
    ! videoconvert \
    ! x264enc tune=zerolatency bitrate=4000 speed-preset=ultrafast \
    ! h264parse config-interval=1 \
    ! rtph264pay pt=96 \
    ! udpsink host=$JETSON_IP port=$CAMERA_PORT sync=false async=false \
    > /tmp/camera.log 2>&1 &
CAM_PID=$!
sleep 1
if kill -0 $CAM_PID 2>/dev/null; then
    echo "      Camera streaming (PID $CAM_PID) — log: /tmp/camera.log"
else
    echo "      ⚠️  Camera stream failed — check /tmp/camera.log"
fi

# ───────────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "ECU1 is running!"
echo ""
echo "Logs:"
echo "  VehicleControlECU : /tmp/ecu1.log"
echo "  CAN bridge        : /tmp/can_bridge.log"
echo "  Camera stream     : /tmp/camera.log"
echo ""
echo "To stop all:"
echo "  sudo pkill -f VehicleControlECU"
echo "  pkill -f serial_to_can_bridge.py"
echo "  pkill -f gst-launch"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
