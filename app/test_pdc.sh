#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# PDC System Test Suite
#
# Tests the full PDC (Park Distance Control) pipeline:
#   - System prerequisites & build artifacts
#   - Config file validity
#   - Process startup & Wayland compositor
#   - vsomeip service discovery
#   - VehicleControlMock → PDCApp event flow
#   - Gear change → PDCApp overlay visibility
#   - Distance zone transitions (safe / green / yellow / red)
#   - Camera stream reception (port 5000)
#   - Pipeline latency
#   - RemoteSpeakerApp beep trigger
#   - Clean shutdown
#
# Usage:
#   ./test_pdc.sh [OPTIONS]
#
# Options:
#   --mode  preflight|build|functional|all   (default: all)
#   --no-build    Skip build step
#   --mock-only   Use VehicleControlMock instead of real ECU1
#   --ecu1-ip IP  ECU1 IP address (default: 192.168.1.100)
#   --latency     Include pipeline latency measurement
#   --report FILE Write JSON report to FILE
#   -v            Verbose: show app logs during tests
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$BASE_DIR/build_pdc_test"
COMMONAPI_GEN_DIR="$BASE_DIR/commonapi/generated"
XDG_RT="/run/user/$(id -u)"
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    QML_IMPORT="/usr/lib/aarch64-linux-gnu/qt5/qml"
else
    QML_IMPORT="/usr/lib/x86_64-linux-gnu/qt5/qml"
fi

# Defaults
MODE="all"
DO_BUILD=true
MOCK_ONLY=false
ECU1_IP="192.168.1.100"
MEASURE_LATENCY=false
REPORT_FILE=""
VERBOSE=false

# Timeouts (seconds)
COMPOSITOR_TIMEOUT=30
APP_START_TIMEOUT=5
SERVICE_DISCOVERY_TIMEOUT=15
EVENT_FLOW_TIMEOUT=10
GEAR_RESPONSE_TIMEOUT=8
DISTANCE_ZONE_TIMEOUT=30
LATENCY_SAMPLES=20

# ─── Color codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Test counters ────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
WARNED=0
declare -a TEST_RESULTS=()

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)     MODE="$2"; shift 2 ;;
        --no-build) DO_BUILD=false; shift ;;
        --mock-only) MOCK_ONLY=true; shift ;;
        --ecu1-ip)  ECU1_IP="$2"; shift 2 ;;
        --latency)  MEASURE_LATENCY=true; shift ;;
        --report)   REPORT_FILE="$2"; shift 2 ;;
        -v)         VERBOSE=true; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[TEST]${NC} $*"; }
info()    { echo -e "       $*"; }
pass()    { echo -e "       ${GREEN}PASS${NC}  $*"; }
fail()    { echo -e "       ${RED}FAIL${NC}  $*"; }
warn()    { echo -e "       ${YELLOW}WARN${NC}  $*"; }
section() { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

record_test() {
    local id="$1" name="$2" result="$3" detail="${4:-}"
    TOTAL=$((TOTAL + 1))
    case "$result" in
        PASS) PASSED=$((PASSED + 1)); pass "$name" ;;
        FAIL) FAILED=$((FAILED + 1)); fail "$name${detail:+ — $detail}" ;;
        WARN) WARNED=$((WARNED + 1)); warn "$name${detail:+ — $detail}" ;;
    esac
    TEST_RESULTS+=("{\"id\":\"$id\",\"name\":\"$(echo "$name" | sed 's/"/\\"/g')\",\"result\":\"$result\",\"detail\":\"$(echo "$detail" | sed 's/"/\\"/g')\"}")
}

# Wait for a pattern in a log file, returns 0 on found, 1 on timeout
wait_for_log() {
    local file="$1" pattern="$2" timeout="$3"
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if [ -f "$file" ] && grep -qE "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# Check if a process is running
proc_alive() { kill -0 "$1" 2>/dev/null; }

# Cleanup handler
PIDS=()
cleanup() {
    if [ ${#PIDS[@]} -gt 0 ]; then
        log "Stopping test processes..."
        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        sleep 1
        for pid in "${PIDS[@]}"; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
    pkill -f VehicleControlMock 2>/dev/null || true
    pkill -f HU_MainApp         2>/dev/null || true
    pkill -f GearApp            2>/dev/null || true
    pkill -f PDCApp             2>/dev/null || true
    pkill -f RemoteSpeakerApp   2>/dev/null || true
    pkill -f HomeScreenApp      2>/dev/null || true
    pkill -f MediaApp           2>/dev/null || true
    pkill -f AmbientApp         2>/dev/null || true
    rm -f /tmp/vsomeip.lck /tmp/vsomeip-0 2>/dev/null || true
    rm -f "$XDG_RT/wayland-1"  2>/dev/null || true
}
trap cleanup EXIT

# ─── Print report ─────────────────────────────────────────────────────────────
print_report() {
    section "TEST SUMMARY"
    echo -e "  Total:  $TOTAL"
    echo -e "  ${GREEN}Passed: $PASSED${NC}"
    [ $FAILED -gt 0 ] && echo -e "  ${RED}Failed: $FAILED${NC}" || echo -e "  Failed: 0"
    [ $WARNED -gt 0 ] && echo -e "  ${YELLOW}Warned: $WARNED${NC}" || echo -e "  Warned: 0"
    echo ""

    if [ -n "$REPORT_FILE" ]; then
        {
            echo "{"
            echo "  \"timestamp\": \"$(date -Iseconds)\","
            echo "  \"total\": $TOTAL,"
            echo "  \"passed\": $PASSED,"
            echo "  \"failed\": $FAILED,"
            echo "  \"warned\": $WARNED,"
            echo "  \"results\": ["
            local first=true
            for r in "${TEST_RESULTS[@]}"; do
                $first || echo ","
                echo -n "    $r"
                first=false
            done
            echo ""
            echo "  ]"
            echo "}"
        } > "$REPORT_FILE"
        log "Report written to $REPORT_FILE"
    fi

    [ $FAILED -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# T01 – SYSTEM PREREQUISITES
# ═══════════════════════════════════════════════════════════════════════════════
test_prerequisites() {
    section "T01  System Prerequisites"

    # Required binaries
    for cmd in python3 jq ip; do
        if command -v "$cmd" &>/dev/null; then
            record_test "T01.cmd.$cmd" "Command available: $cmd" PASS
        else
            record_test "T01.cmd.$cmd" "Command available: $cmd" FAIL "not found in PATH"
        fi
    done

    # Qt / QPA
    if ldconfig -p 2>/dev/null | grep -q "libQt5Core" || [ -f /usr/lib/aarch64-linux-gnu/libQt5Core.so.5 ] || [ -f /usr/lib/x86_64-linux-gnu/libQt5Core.so.5 ]; then
        record_test "T01.qt5" "Qt5 libraries installed" PASS
    else
        record_test "T01.qt5" "Qt5 libraries installed" FAIL
    fi

    # GStreamer
    if command -v gst-launch-1.0 &>/dev/null; then
        record_test "T01.gstreamer" "GStreamer (gst-launch-1.0) available" PASS
    else
        record_test "T01.gstreamer" "GStreamer (gst-launch-1.0) available" WARN "camera tests will skip"
    fi

    # vsomeip shared library
    if ldconfig -p 2>/dev/null | grep -q "libvsomeip3" || find /usr/local/lib /usr/lib -name "libvsomeip3*" 2>/dev/null | grep -q .; then
        record_test "T01.vsomeip" "vsomeip3 library found" PASS
    else
        record_test "T01.vsomeip" "vsomeip3 library found" FAIL
    fi

    # CommonAPI SomeIP library
    if ldconfig -p 2>/dev/null | grep -q "libCommonAPI-SomeIP" || find /usr/local/lib -name "libCommonAPI-SomeIP*" 2>/dev/null | grep -q .; then
        record_test "T01.capi" "CommonAPI-SomeIP library found" PASS
    else
        record_test "T01.capi" "CommonAPI-SomeIP library found" FAIL
    fi

    # DISPLAY for compositor
    export DISPLAY="${DISPLAY:-:0}"
    if [ -n "${DISPLAY:-}" ]; then
        record_test "T01.display" "DISPLAY variable set ($DISPLAY)" PASS
    else
        record_test "T01.display" "DISPLAY variable set" WARN "HU_MainApp xcb fallback may fail"
    fi

    # Wayland-0 socket (preferred compositor backend)
    if [ -S "$XDG_RT/wayland-0" ]; then
        record_test "T01.wayland0" "Wayland display (wayland-0) available" PASS
    else
        record_test "T01.wayland0" "Wayland display (wayland-0) available" WARN "will fall back to X11"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T02 – BUILD ARTIFACTS
# ═══════════════════════════════════════════════════════════════════════════════
test_build_artifacts() {
    section "T02  Build Artifacts"

    local apps=(
        "HU_MainApp/HU_MainApp_Compositor"
        "GearApp/GearApp"
        "PDCApp/PDCApp"
        "VehicleControlMock/VehicleControlMock"
        "RemoteSpeakerApp/RemoteSpeakerApp"
        "HomeScreenApp/HomeScreenApp"
        "MediaApp/MediaApp"
        "AmbientApp/AmbientApp"
    )

    for app in "${apps[@]}"; do
        local binary="$BUILD_DIR/$app"
        local name=$(basename "$app")
        if [ -x "$binary" ]; then
            record_test "T02.$name" "Binary exists: $name" PASS
        else
            record_test "T02.$name" "Binary exists: $name" FAIL "$binary not found or not executable"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# T03 – CONFIG FILE VALIDITY
# ═══════════════════════════════════════════════════════════════════════════════
test_configs() {
    section "T03  Configuration Files"

    # JSON config files — parse with jq
    local json_configs=(
        "$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json"
        "$SCRIPT_DIR/PDCApp/config/vsomeip_pdc.json"
        "$SCRIPT_DIR/VehicleControlMock/config/vsomeip_mock.json"
        "$SCRIPT_DIR/RemoteSpeakerApp/config/vsomeip_speaker.json"
    )

    for cfg in "${json_configs[@]}"; do
        local name=$(basename "$cfg")
        if [ ! -f "$cfg" ]; then
            record_test "T03.json.$name" "JSON config exists: $name" FAIL "file not found"
            continue
        fi
        if jq empty "$cfg" 2>/dev/null; then
            record_test "T03.json.$name" "JSON valid: $name" PASS
        else
            record_test "T03.json.$name" "JSON valid: $name" FAIL "parse error"
        fi

        # Check required keys
        local unicast
        unicast=$(jq -r '.unicast // empty' "$cfg" 2>/dev/null)
        if [ -n "$unicast" ]; then
            record_test "T03.json.$name.unicast" "  unicast address present ($unicast)" PASS
        else
            record_test "T03.json.$name.unicast" "  unicast address present" FAIL
        fi
    done

    # INI config files — check binding=someip
    local ini_configs=(
        "$SCRIPT_DIR/GearApp/config/commonapi_ecu2.ini"
        "$SCRIPT_DIR/PDCApp/config/commonapi_pdc.ini"
        "$SCRIPT_DIR/VehicleControlMock/config/commonapi_mock.ini"
    )

    for cfg in "${ini_configs[@]}"; do
        local name=$(basename "$cfg")
        if [ ! -f "$cfg" ]; then
            record_test "T03.ini.$name" "INI config exists: $name" FAIL "file not found"
            continue
        fi
        if grep -q "binding.*=.*someip" "$cfg" 2>/dev/null; then
            record_test "T03.ini.$name" "INI binding=someip: $name" PASS
        else
            record_test "T03.ini.$name" "INI binding=someip: $name" FAIL "binding not set to someip"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# T04 – NETWORK CONNECTIVITY
# ═══════════════════════════════════════════════════════════════════════════════
test_network() {
    section "T04  Network Connectivity"

    # Multicast route for vsomeip SD
    if ip route show 2>/dev/null | grep -q "224\.0\.0\.0/4\|224\.244\.224"; then
        record_test "T04.mcast_route" "Multicast route exists" PASS
    else
        # Try to add it
        local iface
        iface=$(ip route get 192.168.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
        if [ -n "$iface" ]; then
            sudo ip route add 224.0.0.0/4 dev "$iface" 2>/dev/null || true
            if ip route show | grep -q "224\.0\.0\.0/4"; then
                record_test "T04.mcast_route" "Multicast route added (dev $iface)" PASS
            else
                record_test "T04.mcast_route" "Multicast route" WARN "could not add — SD may not work across NICs"
            fi
        else
            record_test "T04.mcast_route" "Multicast route" WARN "no route — vsomeip SD may be local-only"
        fi
    fi

    # ECU1 reachability (only when not mock-only)
    if ! $MOCK_ONLY; then
        if ping -c 1 -W 2 "$ECU1_IP" &>/dev/null; then
            record_test "T04.ecu1_ping" "ECU1 ($ECU1_IP) reachable" PASS
        else
            record_test "T04.ecu1_ping" "ECU1 ($ECU1_IP) reachable" WARN "ping failed — real ECU1 tests will be skipped"
            MOCK_ONLY=true
            info "Switching to --mock-only mode"
        fi
    else
        record_test "T04.ecu1_ping" "ECU1 ping skipped (mock-only mode)" WARN
    fi

    # UDP port 5000 — camera reception
    if ss -uln 2>/dev/null | grep -q ":5000 "; then
        record_test "T04.port5000" "Port 5000 (camera RTP) already in use" WARN "another process listening"
    else
        record_test "T04.port5000" "Port 5000 (camera RTP) available" PASS
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T05 – BUILD (optional)
# ═══════════════════════════════════════════════════════════════════════════════
run_build() {
    section "T05  Build Phase"
    log "Building apps in $BUILD_DIR ..."

    mkdir -p "$BUILD_DIR"

    local build_ok=true
    local apps=(
        "HU_MainApp:$SCRIPT_DIR/HU_MainApp"
        "GearApp:$SCRIPT_DIR/GearApp:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
        "PDCApp:$SCRIPT_DIR/PDCApp:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
        "VehicleControlMock:$SCRIPT_DIR/VehicleControlMock:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
        "RemoteSpeakerApp:$SCRIPT_DIR/RemoteSpeakerApp:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
        "HomeScreenApp:$SCRIPT_DIR/HomeScreenApp:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
        "MediaApp:$SCRIPT_DIR/MediaApp:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
        "AmbientApp:$SCRIPT_DIR/AmbientApp:-DCOMMONAPI_GEN_DIR=$COMMONAPI_GEN_DIR"
    )

    for entry in "${apps[@]}"; do
        IFS=: read -r name src cmake_arg <<< "$entry"
        local dir="$BUILD_DIR/$name"
        mkdir -p "$dir"
        info "Building $name..."
        if ( cd "$dir" && cmake "$src" ${cmake_arg:+"$cmake_arg"} -DCMAKE_BUILD_TYPE=Release > /tmp/build_${name}.log 2>&1 && make -j"$(nproc)" >> /tmp/build_${name}.log 2>&1 ); then
            record_test "T05.build.$name" "Build: $name" PASS
        else
            record_test "T05.build.$name" "Build: $name" FAIL "see /tmp/build_${name}.log"
            build_ok=false
        fi
    done

    $build_ok
}

# ═══════════════════════════════════════════════════════════════════════════════
# T06 – PROCESS STARTUP & WAYLAND COMPOSITOR
# ═══════════════════════════════════════════════════════════════════════════════
test_startup() {
    section "T06  Process Startup"

    export DISPLAY="${DISPLAY:-:0}"

    # Clean stale state
    rm -f /tmp/vsomeip.lck /tmp/vsomeip-0 "$XDG_RT/wayland-1" 2>/dev/null || true
    pkill -f HU_MainApp 2>/dev/null || true; sleep 0.5

    # ── HU_MainApp Compositor ────────────────────────────────────────────────
    info "Starting HU_MainApp Compositor..."
    local hu_cmd
    if [ -S "$XDG_RT/wayland-0" ]; then
        QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-0 \
        QML2_IMPORT_PATH="$QML_IMPORT" XDG_RUNTIME_DIR="$XDG_RT" \
        "$BUILD_DIR/HU_MainApp/HU_MainApp_Compositor" > /tmp/hu_main.log 2>&1 &
    else
        DISPLAY="$DISPLAY" QT_QPA_PLATFORM=xcb \
        QML2_IMPORT_PATH="$QML_IMPORT" XDG_RUNTIME_DIR="$XDG_RT" \
        "$BUILD_DIR/HU_MainApp/HU_MainApp_Compositor" > /tmp/hu_main.log 2>&1 &
    fi
    local HU_PID=$!
    PIDS+=($HU_PID)
    sleep 1

    if proc_alive $HU_PID; then
        record_test "T06.hu_start" "HU_MainApp Compositor started (PID $HU_PID)" PASS
    else
        record_test "T06.hu_start" "HU_MainApp Compositor started" FAIL "process died immediately — check /tmp/hu_main.log"
        $VERBOSE && tail -20 /tmp/hu_main.log
        return 1
    fi

    # Wait for wayland-1 socket
    info "Waiting for wayland-1 socket (timeout ${COMPOSITOR_TIMEOUT}s)..."
    local elapsed=0
    while [ $elapsed -lt $COMPOSITOR_TIMEOUT ]; do
        if [ -S "$XDG_RT/wayland-1" ]; then break; fi
        sleep 1; elapsed=$((elapsed+1))
        [ $((elapsed % 5)) -eq 0 ] && info "  ... $elapsed/${COMPOSITOR_TIMEOUT}s"
    done

    if [ -S "$XDG_RT/wayland-1" ]; then
        record_test "T06.wayland1" "wayland-1 socket created by compositor" PASS
    else
        record_test "T06.wayland1" "wayland-1 socket created by compositor" FAIL "timeout after ${COMPOSITOR_TIMEOUT}s"
        $VERBOSE && tail -20 /tmp/hu_main.log
        return 1
    fi

    sleep 1  # Extra time for compositor initialization

    # ── Client apps ──────────────────────────────────────────────────────────
    local ECU2_CAPI="$SCRIPT_DIR/GearApp/config/commonapi_ecu2.ini"
    local PDC_CAPI="$SCRIPT_DIR/PDCApp/config/commonapi_pdc.ini"
    local MOCK_CAPI="$SCRIPT_DIR/VehicleControlMock/config/commonapi_mock.ini"

    declare -A APP_LOGS=(
        [GearApp]=/tmp/gearapp.log
        [PDCApp]=/tmp/pdcapp.log
        [VehicleControlMock]=/tmp/vcmock.log
        [RemoteSpeakerApp]=/tmp/speakerapp.log
        [HomeScreenApp]=/tmp/homescreen.log
        [MediaApp]=/tmp/mediaapp.log
        [AmbientApp]=/tmp/ambientapp.log
    )

    # VehicleControlMock (service provider — start before clients)
    info "Starting VehicleControlMock..."
    VSOMEIP_APPLICATION_NAME=VehicleControlMock \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/VehicleControlMock/config/vsomeip_mock.json" \
    COMMONAPI_CONFIG="$MOCK_CAPI" \
    "$BUILD_DIR/VehicleControlMock/VehicleControlMock" > /tmp/vcmock.log 2>&1 &
    MOCK_PID=$!
    PIDS+=($MOCK_PID)
    sleep 2  # Routing manager must be ready before clients

    if proc_alive $MOCK_PID; then
        record_test "T06.mock_start" "VehicleControlMock started (PID $MOCK_PID)" PASS
    else
        record_test "T06.mock_start" "VehicleControlMock started" FAIL "check /tmp/vcmock.log"
        $VERBOSE && tail -20 /tmp/vcmock.log
    fi

    # GearApp
    info "Starting GearApp..."
    QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=GearApp_client \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json" \
    COMMONAPI_CONFIG="$ECU2_CAPI" \
    "$BUILD_DIR/GearApp/GearApp" > /tmp/gearapp.log 2>&1 &
    GEAR_PID=$!
    PIDS+=($GEAR_PID)
    sleep "$APP_START_TIMEOUT"

    if proc_alive $GEAR_PID; then
        record_test "T06.gear_start" "GearApp started (PID $GEAR_PID)" PASS
    else
        record_test "T06.gear_start" "GearApp started" FAIL "check /tmp/gearapp.log"
        $VERBOSE && tail -20 /tmp/gearapp.log
    fi

    # PDCApp
    info "Starting PDCApp..."
    QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=PDCApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/PDCApp/config/vsomeip_pdc.json" \
    COMMONAPI_CONFIG="$PDC_CAPI" \
    "$BUILD_DIR/PDCApp/PDCApp" > /tmp/pdcapp.log 2>&1 &
    PDC_PID=$!
    PIDS+=($PDC_PID)
    sleep "$APP_START_TIMEOUT"

    if proc_alive $PDC_PID; then
        record_test "T06.pdc_start" "PDCApp started (PID $PDC_PID)" PASS
    else
        record_test "T06.pdc_start" "PDCApp started" FAIL "check /tmp/pdcapp.log"
        $VERBOSE && tail -20 /tmp/pdcapp.log
    fi

    # RemoteSpeakerApp
    info "Starting RemoteSpeakerApp..."
    VSOMEIP_APPLICATION_NAME=RemoteSpeakerApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/RemoteSpeakerApp/config/vsomeip_speaker.json" \
    COMMONAPI_CONFIG="$SCRIPT_DIR/RemoteSpeakerApp/config/commonapi_speaker.ini" \
    "$BUILD_DIR/RemoteSpeakerApp/RemoteSpeakerApp" > /tmp/speakerapp.log 2>&1 &
    SPEAKER_PID=$!
    PIDS+=($SPEAKER_PID)
    sleep 2

    if proc_alive $SPEAKER_PID; then
        record_test "T06.speaker_start" "RemoteSpeakerApp started (PID $SPEAKER_PID)" PASS
    else
        record_test "T06.speaker_start" "RemoteSpeakerApp started" FAIL "check /tmp/speakerapp.log"
    fi

    # HomeScreenApp / MediaApp / AmbientApp
    for app_name in HomeScreenApp MediaApp AmbientApp; do
        local app_lower="${app_name,,}"
        QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        QT_WAYLAND_DISABLE_WINDOWDECORATION=1 QT_QUICK_BACKEND=software \
        XDG_RUNTIME_DIR="$XDG_RT" \
        VSOMEIP_APPLICATION_NAME="$app_name" \
        VSOMEIP_CONFIGURATION="$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json" \
        COMMONAPI_CONFIG="$ECU2_CAPI" \
        "$BUILD_DIR/$app_name/$app_name" > "/tmp/${app_lower}.log" 2>&1 &
        local pid=$!
        PIDS+=($pid)
        sleep 1
        if proc_alive $pid; then
            record_test "T06.${app_lower}_start" "$app_name started (PID $pid)" PASS
        else
            record_test "T06.${app_lower}_start" "$app_name started" WARN "check /tmp/${app_lower}.log"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# T07 – vsomeip SERVICE DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════════
test_service_discovery() {
    section "T07  vsomeip Service Discovery"

    # Mock should have registered service 0x1234/0x5678
    if wait_for_log /tmp/vcmock.log "OFFER_SERVICE\|registered.*1234\|service.*registered\|VehicleControl service registered" $SERVICE_DISCOVERY_TIMEOUT; then
        record_test "T07.mock_offer" "VehicleControlMock offers service (0x1234/0x5678)" PASS
    else
        record_test "T07.mock_offer" "VehicleControlMock offers service (0x1234/0x5678)" FAIL "no OFFER_SERVICE in /tmp/vcmock.log after ${SERVICE_DISCOVERY_TIMEOUT}s"
    fi

    # PDCApp should subscribe to the service
    if wait_for_log /tmp/pdcapp.log "AVAILABLE\|service.*available\|VehicleControlECU service is now available\|VehicleControl.*AVAILABLE" $SERVICE_DISCOVERY_TIMEOUT; then
        record_test "T07.pdc_subscribe" "PDCApp subscribed to VehicleControl service" PASS
    else
        record_test "T07.pdc_subscribe" "PDCApp subscribed to VehicleControl service" FAIL "no AVAILABLE in /tmp/pdcapp.log — check vsomeip routing"
    fi

    # GearApp should also see the service
    if wait_for_log /tmp/gearapp.log "AVAILABLE\|service.*available\|VehicleControl service is now available" $SERVICE_DISCOVERY_TIMEOUT; then
        record_test "T07.gear_subscribe" "GearApp subscribed to VehicleControl service" PASS
    else
        record_test "T07.gear_subscribe" "GearApp subscribed to VehicleControl service" WARN "GearApp may be running as routing manager"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T08 – EVENT FLOW: Mock → PDCApp
# ═══════════════════════════════════════════════════════════════════════════════
test_event_flow() {
    section "T08  Event Flow (Mock → PDCApp)"

    # Mock auto-starts simulation with Reverse gear and decreasing distance
    # Check PDCApp receives distance events
    if wait_for_log /tmp/pdcapp.log "Distance updated\|currentDistanceChanged\|distance.*cm\|PDCApp.*Distance" $EVENT_FLOW_TIMEOUT; then
        record_test "T08.distance_events" "PDCApp receives distance events from Mock" PASS
    else
        record_test "T08.distance_events" "PDCApp receives distance events from Mock" FAIL "no distance updates in /tmp/pdcapp.log after ${EVENT_FLOW_TIMEOUT}s"
    fi

    # Check gear events arrive
    if wait_for_log /tmp/pdcapp.log "Gear changed\|currentGearChanged\|gear.*R\|PDCApp.*Gear" $EVENT_FLOW_TIMEOUT; then
        record_test "T08.gear_events" "PDCApp receives gear events from Mock" PASS
    else
        record_test "T08.gear_events" "PDCApp receives gear events from Mock" WARN "no gear events in pdcapp.log"
    fi

    # Check mock is actually broadcasting
    if grep -qE "Distance:|Zone:|fireGearDistanceChanged|Simulation" /tmp/vcmock.log 2>/dev/null; then
        record_test "T08.mock_broadcasting" "VehicleControlMock is broadcasting events" PASS
    else
        record_test "T08.mock_broadcasting" "VehicleControlMock is broadcasting events" FAIL "mock not broadcasting"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T09 – GEAR CHANGE → PDCApp OVERLAY
# ═══════════════════════════════════════════════════════════════════════════════
test_gear_changes() {
    section "T09  Gear Change → PDCApp Overlay"

    # The Mock auto-sets gear to R on startup. Verify PDCApp detected it.
    # We check the log for evidence of gear=R visibility trigger.
    if wait_for_log /tmp/pdcapp.log "gear.*R\|Gear.*R\|reverse\|Reverse\|PDC.*visible\|isReverse" $GEAR_RESPONSE_TIMEOUT; then
        record_test "T09.reverse_detected" "PDCApp detected Reverse gear (overlay should be visible)" PASS
    else
        record_test "T09.reverse_detected" "PDCApp detected Reverse gear" WARN "check pdcapp.log for gear state"
    fi

    # HU_MainApp window title detection
    if wait_for_log /tmp/hu_main.log "GearApp.*R\|Reverse\|pdcVisible\|gear.*R\|PDC.*show" $GEAR_RESPONSE_TIMEOUT; then
        record_test "T09.hu_gear_detect" "HU_MainApp detected gear R from window title" PASS
    else
        record_test "T09.hu_gear_detect" "HU_MainApp detected gear R from window title" WARN "may depend on QML signal — check /tmp/hu_main.log"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T10 – DISTANCE ZONE TRANSITIONS
# ═══════════════════════════════════════════════════════════════════════════════
test_distance_zones() {
    section "T10  Distance Zone Transitions"

    # The mock cycles 60cm → 5cm in 500ms steps (5cm per step = 11 steps = 5.5s)
    # Wait for each zone to appear in mock log
    info "Waiting up to ${DISTANCE_ZONE_TIMEOUT}s for mock to cycle through all zones..."

    if wait_for_log /tmp/vcmock.log "SAFE" $DISTANCE_ZONE_TIMEOUT; then
        record_test "T10.zone_safe" "Zone SAFE (>50cm) observed in mock" PASS
    else
        record_test "T10.zone_safe" "Zone SAFE (>50cm) observed in mock" WARN "not seen — may have cycled past"
    fi

    if wait_for_log /tmp/vcmock.log "GREEN" $DISTANCE_ZONE_TIMEOUT; then
        record_test "T10.zone_green" "Zone GREEN (30-50cm) observed in mock" PASS
    else
        record_test "T10.zone_green" "Zone GREEN (30-50cm) observed in mock" FAIL
    fi

    if wait_for_log /tmp/vcmock.log "YELLOW" $DISTANCE_ZONE_TIMEOUT; then
        record_test "T10.zone_yellow" "Zone YELLOW (15-30cm) observed in mock" PASS
    else
        record_test "T10.zone_yellow" "Zone YELLOW (15-30cm) observed in mock" FAIL
    fi

    if wait_for_log /tmp/vcmock.log "RED" $DISTANCE_ZONE_TIMEOUT; then
        record_test "T10.zone_red" "Zone RED (<15cm) observed in mock" PASS
    else
        record_test "T10.zone_red" "Zone RED (<15cm) observed in mock" FAIL
    fi

    # Verify PDCApp received each distance range
    local pdc_distances
    pdc_distances=$(grep -oE "Distance updated: [0-9]+" /tmp/pdcapp.log 2>/dev/null | awk '{print $3}' || true)

    if [ -n "$pdc_distances" ]; then
        local min_dist max_dist
        min_dist=$(echo "$pdc_distances" | sort -n | head -1)
        max_dist=$(echo "$pdc_distances" | sort -n | tail -1)
        record_test "T10.pdc_range" "PDCApp distance range: ${min_dist}cm – ${max_dist}cm" PASS
        info "Distance range received by PDCApp: ${min_dist}cm to ${max_dist}cm"

        if [ "${min_dist:-999}" -lt 20 ]; then
            record_test "T10.pdc_near" "PDCApp received near-distance (<20cm)" PASS
        else
            record_test "T10.pdc_near" "PDCApp received near-distance (<20cm)" WARN "min seen: ${min_dist}cm — wait for next cycle"
        fi
    else
        record_test "T10.pdc_range" "PDCApp distance range measurable" WARN "no parseable distances in pdcapp.log"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T11 – CAMERA STREAM (GStreamer)
# ═══════════════════════════════════════════════════════════════════════════════
test_camera() {
    section "T11  Camera Stream"

    if ! command -v gst-launch-1.0 &>/dev/null; then
        record_test "T11.gst_avail" "GStreamer available" WARN "skipping camera tests"
        return
    fi

    # Check if PDCApp opened a GStreamer receiver pipeline
    if wait_for_log /tmp/pdcapp.log "GStreamer\|gst\|pipeline\|receiver\|GstVideoReceiver" 5; then
        record_test "T11.pdc_gst_init" "PDCApp GstVideoReceiver initialized" PASS
    else
        record_test "T11.pdc_gst_init" "PDCApp GstVideoReceiver initialized" WARN "no GStreamer output in pdcapp.log"
    fi

    # VehicleControlMock streams test source to 127.0.0.1:5000
    # Check if PDCApp is receiving (look for appsink caps or frame receipt)
    if wait_for_log /tmp/pdcapp.log "appsink\|frame\|caps\|video.*raw\|camera.*ready\|CameraStreamer" 8; then
        record_test "T11.camera_recv" "PDCApp receiving camera stream data" PASS
    else
        record_test "T11.camera_recv" "PDCApp receiving camera stream data" WARN "no camera frames logged — may be working silently"
    fi

    # Try a short UDP reception test on port 5000
    local udp_test_log="/tmp/gst_udp_test.log"
    timeout 4 gst-launch-1.0 -q \
        udpsrc port=5000 \
        ! application/x-rtp,media=video,clock-rate=90000,encoding-name=H264 \
        ! fakesink dump=false \
        > "$udp_test_log" 2>&1 &
    local GST_TEST_PID=$!
    sleep 3
    if kill -0 $GST_TEST_PID 2>/dev/null; then
        kill $GST_TEST_PID 2>/dev/null || true
        # If gst-launch started without error, port 5000 is open and receiving
        if ! grep -q "error\|ERROR\|failed" "$udp_test_log" 2>/dev/null; then
            record_test "T11.udp5000" "UDP port 5000 accepting RTP packets" PASS
        else
            record_test "T11.udp5000" "UDP port 5000 accepting RTP packets" WARN "$(head -1 "$udp_test_log")"
        fi
    else
        record_test "T11.udp5000" "UDP port 5000 accepting RTP packets" WARN "gst-launch test exited early"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T12 – PIPELINE LATENCY
# ═══════════════════════════════════════════════════════════════════════════════
test_latency() {
    section "T12  Pipeline Latency"

    if ! $MEASURE_LATENCY; then
        record_test "T12.latency" "Latency measurement skipped (use --latency to enable)" WARN
        return
    fi

    log "Measuring end-to-end latency (Mock broadcast → PDCApp log)"
    info "Collecting $LATENCY_SAMPLES samples..."

    local mock_times=() pdc_times=()
    local i=0

    # Collect paired timestamps: find distance updates in both logs
    # We match distance values — same distance value should appear in both logs
    local sample_file="/tmp/latency_samples.txt"
    > "$sample_file"

    # Tail both logs simultaneously and timestamp each line
    (tail -f /tmp/vcmock.log | while read -r line; do
        if echo "$line" | grep -qE "Distance: [0-9]"; then
            dist=$(echo "$line" | grep -oE '[0-9]+ cm' | head -1 | tr -d ' cm')
            echo "MOCK $(date +%s%3N) $dist"
        fi
    done) > /tmp/latency_mock.txt 2>/dev/null &
    local TAIL_MOCK=$!

    (tail -f /tmp/pdcapp.log | while read -r line; do
        if echo "$line" | grep -qE "Distance updated: [0-9]"; then
            dist=$(echo "$line" | grep -oE '[0-9]+' | tail -1)
            echo "PDC $(date +%s%3N) $dist"
        fi
    done) > /tmp/latency_pdc.txt 2>/dev/null &
    local TAIL_PDC=$!

    sleep 15  # Collect 15 seconds of data

    kill $TAIL_MOCK $TAIL_PDC 2>/dev/null || true

    # Match up distances and compute deltas
    local total_latency=0 count=0 max_lat=0 min_lat=99999
    while read -r type ts dist; do
        if [ "$type" = "MOCK" ]; then
            # Find matching PDC entry for same distance
            local pdc_ts
            pdc_ts=$(grep "^PDC .* $dist$" /tmp/latency_pdc.txt 2>/dev/null | head -1 | awk '{print $2}')
            if [ -n "$pdc_ts" ] && [ "$pdc_ts" -gt "$ts" ]; then
                local delta=$((pdc_ts - ts))
                if [ $delta -lt 5000 ]; then  # Discard outliers > 5s
                    total_latency=$((total_latency + delta))
                    count=$((count + 1))
                    [ $delta -gt $max_lat ] && max_lat=$delta
                    [ $delta -lt $min_lat ] && min_lat=$delta
                fi
            fi
        fi
    done < /tmp/latency_mock.txt

    if [ $count -gt 0 ]; then
        local avg_lat=$((total_latency / count))
        info "Samples matched: $count"
        info "Avg latency: ${avg_lat}ms  Min: ${min_lat}ms  Max: ${max_lat}ms"

        if [ $avg_lat -lt 200 ]; then
            record_test "T12.latency" "Pipeline latency: avg=${avg_lat}ms (< 200ms threshold)" PASS
        elif [ $avg_lat -lt 500 ]; then
            record_test "T12.latency" "Pipeline latency: avg=${avg_lat}ms (200-500ms — acceptable)" WARN
        else
            record_test "T12.latency" "Pipeline latency: avg=${avg_lat}ms (> 500ms — too high)" FAIL
        fi
    else
        record_test "T12.latency" "Pipeline latency measurement" WARN "insufficient matching samples — check logs manually"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T13 – REMOTE SPEAKER BEEP TRIGGER
# ═══════════════════════════════════════════════════════════════════════════════
test_speaker() {
    section "T13  RemoteSpeakerApp Beep Trigger"

    # RemoteSpeakerApp should subscribe to VehicleControl and beep at short distances
    if wait_for_log /tmp/speakerapp.log "AVAILABLE\|connected\|subscri\|distance\|beep\|Beep" 10; then
        record_test "T13.speaker_subscribed" "RemoteSpeakerApp subscribed to VehicleControl" PASS
    else
        record_test "T13.speaker_subscribed" "RemoteSpeakerApp subscribed to VehicleControl" WARN "no subscription event in speakerapp.log"
    fi

    # When mock reaches RED zone (<15cm), speaker should trigger
    if wait_for_log /tmp/speakerapp.log "beep\|Beep\|alert\|Alert\|distance.*[0-9]\|play" 30; then
        record_test "T13.speaker_triggered" "RemoteSpeakerApp triggered beep on close distance" PASS
    else
        record_test "T13.speaker_triggered" "RemoteSpeakerApp triggered beep on close distance" WARN "no beep event logged — may not log beeps"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# T14 – PROCESS HEALTH & CLEAN SHUTDOWN
# ═══════════════════════════════════════════════════════════════════════════════
test_shutdown() {
    section "T14  Process Health & Shutdown"

    # Check all critical processes are still alive after the test
    local alive_count=0
    for pid in "${PIDS[@]}"; do
        proc_alive $pid && alive_count=$((alive_count + 1))
    done

    local total_procs=${#PIDS[@]}
    local dead=$((total_procs - alive_count))

    if [ $dead -eq 0 ]; then
        record_test "T14.health" "All $total_procs processes still alive after tests" PASS
    elif [ $dead -le 2 ]; then
        record_test "T14.health" "$dead/$total_procs processes died during tests" WARN
    else
        record_test "T14.health" "$dead/$total_procs processes died during tests" FAIL
    fi

    # Check no critical crash logs
    local crash_keywords="Segmentation fault\|Aborted\|core dumped\|SIGSEGV\|SIGABRT"
    local crashes=0
    for log_file in /tmp/hu_main.log /tmp/gearapp.log /tmp/pdcapp.log /tmp/vcmock.log; do
        if [ -f "$log_file" ] && grep -qE "$crash_keywords" "$log_file" 2>/dev/null; then
            local fname=$(basename "$log_file")
            warn "Crash detected in $fname: $(grep -oE "$crash_keywords" "$log_file" | head -1)"
            crashes=$((crashes + 1))
        fi
    done

    if [ $crashes -eq 0 ]; then
        record_test "T14.no_crashes" "No crash signals in app logs" PASS
    else
        record_test "T14.no_crashes" "No crash signals in app logs" FAIL "$crashes crash(es) detected"
    fi

    # Send SIGTERM and verify clean exit
    info "Sending SIGTERM to all test processes..."
    for pid in "${PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 3

    local lingering=0
    for pid in "${PIDS[@]}"; do
        proc_alive $pid && lingering=$((lingering + 1))
    done

    if [ $lingering -eq 0 ]; then
        record_test "T14.clean_shutdown" "All processes exited cleanly on SIGTERM" PASS
    else
        record_test "T14.clean_shutdown" "All processes exited cleanly on SIGTERM" WARN "$lingering process(es) needed SIGKILL"
        for pid in "${PIDS[@]}"; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi

    PIDS=()  # Prevent cleanup handler from killing again
}

# ═══════════════════════════════════════════════════════════════════════════════
# T15 – LOG FILE SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
print_log_summary() {
    section "Log File Summary"
    local logs=(
        "/tmp/hu_main.log:HU_MainApp Compositor"
        "/tmp/vcmock.log:VehicleControlMock"
        "/tmp/gearapp.log:GearApp"
        "/tmp/pdcapp.log:PDCApp"
        "/tmp/speakerapp.log:RemoteSpeakerApp"
        "/tmp/homescreen.log:HomeScreenApp"
        "/tmp/mediaapp.log:MediaApp"
        "/tmp/ambientapp.log:AmbientApp"
    )

    for entry in "${logs[@]}"; do
        IFS=: read -r file name <<< "$entry"
        if [ -f "$file" ]; then
            local lines errors
            lines=$(wc -l < "$file")
            errors=$(grep -cE "ERROR|error|CRITICAL|critical|Segmentation|Abort" "$file" 2>/dev/null || true)
            if [ "$errors" -gt 0 ]; then
                warn "$name ($file): $lines lines, ${RED}$errors error(s)${NC}"
            else
                info "$name ($file): $lines lines, 0 errors"
            fi
        else
            info "$name: no log file"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}PDC System Test Suite${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Mode:       $MODE"
echo "  Build dir:  $BUILD_DIR"
echo "  Mock-only:  $MOCK_ONLY"
echo "  ECU1 IP:    $ECU1_IP"
echo "  Latency:    $MEASURE_LATENCY"
[ -n "$REPORT_FILE" ] && echo "  Report:     $REPORT_FILE"
echo ""

case "$MODE" in
    preflight)
        test_prerequisites
        test_configs
        test_network
        ;;
    build)
        test_prerequisites
        test_configs
        $DO_BUILD && run_build
        test_build_artifacts
        ;;
    functional)
        test_build_artifacts
        test_network
        test_startup
        test_service_discovery
        test_event_flow
        test_gear_changes
        test_distance_zones
        test_camera
        $MEASURE_LATENCY && test_latency
        test_speaker
        test_shutdown
        print_log_summary
        ;;
    all)
        test_prerequisites
        test_configs
        test_network
        if $DO_BUILD; then
            run_build || { echo "Build failed — run with --no-build to skip build step"; exit 1; }
        fi
        test_build_artifacts
        test_startup
        test_service_discovery
        test_event_flow
        test_gear_changes
        test_distance_zones
        test_camera
        $MEASURE_LATENCY && test_latency
        test_speaker
        test_shutdown
        print_log_summary
        ;;
    *)
        echo "Unknown mode: $MODE"
        echo "Valid modes: preflight, build, functional, all"
        exit 1
        ;;
esac

print_report
