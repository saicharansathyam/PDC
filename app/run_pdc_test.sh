#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# PDC Integration Test Script
# Tests PDC feature with HU_MainApp compositor, GearApp, and PDCApp
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$BASE_DIR/build_pdc_test"
COMMONAPI_GEN_DIR="$BASE_DIR/commonapi/generated"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "PDC Integration Test - Build & Run"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Base directory: $BASE_DIR"
echo "Build directory: $BUILD_DIR"
echo ""

# ───────────────────────────────────────────────────────────────────────────────
# Build Phase
# ───────────────────────────────────────────────────────────────────────────────
build_apps() {
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Building apps..."
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Build GearApp
    echo ""
    echo "Building GearApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p GearApp
    cd GearApp
    cmake "$SCRIPT_DIR/GearApp" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

    # Build PDCApp
    echo ""
    echo "Building PDCApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p PDCApp
    cd PDCApp
    cmake "$SCRIPT_DIR/PDCApp" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

    # Build HU_MainApp
    echo ""
    echo "Building HU_MainApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p HU_MainApp
    cd HU_MainApp
    cmake "$SCRIPT_DIR/HU_MainApp"
    make -j$(nproc)
    cd ..

    # Build RemoteSpeakerApp (optional)
    echo ""
    echo "Building RemoteSpeakerApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p RemoteSpeakerApp
    cd RemoteSpeakerApp
    cmake "$SCRIPT_DIR/RemoteSpeakerApp" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

    # Build HomeScreenApp
    echo ""
    echo "Building HomeScreenApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p HomeScreenApp
    cd HomeScreenApp
    cmake "$SCRIPT_DIR/HomeScreenApp" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

    # Build MediaApp
    echo ""
    echo "Building MediaApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p MediaApp
    cd MediaApp
    cmake "$SCRIPT_DIR/MediaApp" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

    # Build AmbientApp
    echo ""
    echo "Building AmbientApp..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p AmbientApp
    cd AmbientApp
    cmake "$SCRIPT_DIR/AmbientApp" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Build complete!"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────────
# Run Phase
# ───────────────────────────────────────────────────────────────────────────────
run_apps() {
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Launching apps..."
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""

    # Architecture detection
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
        QML_IMPORT="/usr/lib/aarch64-linux-gnu/qt5/qml"
    else
        QML_IMPORT="/usr/lib/x86_64-linux-gnu/qt5/qml"
    fi

    # Per-app CommonAPI configs — each specifies binding=someip for VehicleControl
    PDC_CAPI="$SCRIPT_DIR/PDCApp/config/commonapi_pdc.ini"
    ECU2_CAPI="$SCRIPT_DIR/GearApp/config/commonapi_ecu2.ini"
    XDG_RT="/run/user/$(id -u)"

    # Ensure multicast route exists for vsomeip SD
    sudo ip route add 224.0.0.0/4 dev enP8p1s0 2>/dev/null || true

    # Kill stale processes and lock files
    pkill -f HU_MainApp         2>/dev/null || true
    pkill -f GearApp            2>/dev/null || true
    pkill -f PDCApp             2>/dev/null || true
    pkill -f RemoteSpeakerApp   2>/dev/null || true
    pkill -f HomeScreenApp      2>/dev/null || true
    pkill -f MediaApp           2>/dev/null || true
    pkill -f AmbientApp         2>/dev/null || true
    rm -f /tmp/vsomeip.lck 2>/dev/null || true
    rm -f /tmp/vsomeip-0   2>/dev/null || true
    sleep 1

    # ── HU_MainApp Compositor ─────────────────────────────────────────────────
    # Detect display backend: prefer Wayland if wayland-0 socket exists, else X11
    echo "Starting HU_MainApp Compositor..."
    if [ -S "$XDG_RT/wayland-0" ]; then
        echo "  Display: Wayland (wayland-0 found)"
        QT_QPA_PLATFORM=wayland \
        WAYLAND_DISPLAY=wayland-0 \
        QML2_IMPORT_PATH="$QML_IMPORT" \
        XDG_RUNTIME_DIR="$XDG_RT" \
        "$BUILD_DIR/HU_MainApp/HU_MainApp_Compositor" > /tmp/hu_main.log 2>&1 &
    else
        echo "  Display: X11 (no wayland-0 socket)"
        QT_QPA_PLATFORM=xcb \
        QML2_IMPORT_PATH="$QML_IMPORT" \
        XDG_RUNTIME_DIR="$XDG_RT" \
        "$BUILD_DIR/HU_MainApp/HU_MainApp_Compositor" > /tmp/hu_main.log 2>&1 &
    fi

    echo "Waiting for compositor to create wayland-1 socket..."
    for i in {1..30}; do
        if [ -S "$XDG_RT/wayland-1" ]; then
            echo "wayland-1 socket ready!"
            break
        fi
        echo "  Waiting... ($i/30)"
        sleep 1
    done

    if [ ! -S "$XDG_RT/wayland-1" ]; then
        echo "ERROR: wayland-1 socket not created. Check /tmp/hu_main.log"
        exit 1
    fi

    sleep 1  # Extra time for compositor to fully initialize

    # ── GearApp ───────────────────────────────────────────────────────────────
    # QT_QUICK_BACKEND=software: avoids NVIDIA EGL nested Wayland surface errors
    echo "Starting GearApp..."
    QT_QPA_PLATFORM=wayland \
    WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 \
    QT_QUICK_BACKEND=software \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=GearApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json" \
    COMMONAPI_CONFIG="$ECU2_CAPI" \
    "$BUILD_DIR/GearApp/GearApp" > /tmp/gearapp.log 2>&1 &
    sleep 2  # GearApp is the vsomeip routing manager — wait for its socket

    # ── PDCApp ────────────────────────────────────────────────────────────────
    # QT_QUICK_BACKEND=software: avoids NVIDIA EGL nested Wayland surface errors
    echo "Starting PDCApp..."
    QT_QPA_PLATFORM=wayland \
    WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 \
    QT_QUICK_BACKEND=software \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=PDCApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/PDCApp/config/vsomeip_pdc.json" \
    COMMONAPI_CONFIG="$PDC_CAPI" \
    "$BUILD_DIR/PDCApp/PDCApp" > /tmp/pdcapp.log 2>&1 &
    sleep 1

    # ── HomeScreenApp ─────────────────────────────────────────────────────────
    echo "Starting HomeScreenApp..."
    QT_QPA_PLATFORM=wayland \
    WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=HomeScreenApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json" \
    COMMONAPI_CONFIG="$ECU2_CAPI" \
    "$BUILD_DIR/HomeScreenApp/HomeScreenApp" > /tmp/homescreen.log 2>&1 &
    sleep 1

    # ── MediaApp ──────────────────────────────────────────────────────────────
    echo "Starting MediaApp..."
    QT_QPA_PLATFORM=wayland \
    WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=MediaApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json" \
    COMMONAPI_CONFIG="$ECU2_CAPI" \
    "$BUILD_DIR/MediaApp/MediaApp" > /tmp/mediaapp.log 2>&1 &
    sleep 1

    # ── AmbientApp ────────────────────────────────────────────────────────────
    echo "Starting AmbientApp..."
    QT_QPA_PLATFORM=wayland \
    WAYLAND_DISPLAY=wayland-1 \
    QT_WAYLAND_DISABLE_WINDOWDECORATION=1 \
    XDG_RUNTIME_DIR="$XDG_RT" \
    VSOMEIP_APPLICATION_NAME=AmbientApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json" \
    COMMONAPI_CONFIG="$ECU2_CAPI" \
    "$BUILD_DIR/AmbientApp/AmbientApp" > /tmp/ambientapp.log 2>&1 &
    sleep 1

    # ── RemoteSpeakerApp ──────────────────────────────────────────────────────
    echo "Starting RemoteSpeakerApp..."
    VSOMEIP_APPLICATION_NAME=RemoteSpeakerApp \
    VSOMEIP_CONFIGURATION="$SCRIPT_DIR/RemoteSpeakerApp/config/vsomeip_speaker.json" \
    COMMONAPI_CONFIG="$SCRIPT_DIR/RemoteSpeakerApp/config/commonapi_speaker.ini" \
    "$BUILD_DIR/RemoteSpeakerApp/RemoteSpeakerApp" > /tmp/speakerapp.log 2>&1 &

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "All apps launched! Logs: /tmp/hu_main.log  /tmp/gearapp.log  /tmp/pdcapp.log"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Test Instructions:"
    echo "  1. Click on GearApp panel (left side of display) to change gear"
    echo "  2. Click 'R' (Reverse) to see PDCApp overlay appear"
    echo "  3. Watch distance simulation in /tmp/vcmock.log"
    echo "  4. Click 'P', 'N', or 'D' to hide PDCApp overlay"
    echo ""
    echo "To stop all processes:"
    echo "  pkill -f HU_MainApp; pkill -f GearApp; pkill -f PDCApp"
    echo "  pkill -f RemoteSpeakerApp; pkill -f HomeScreenApp; pkill -f MediaApp; pkill -f AmbientApp"
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────────
# Main
# ───────────────────────────────────────────────────────────────────────────────
case "${1:-all}" in
    build)
        build_apps
        ;;
    run)
        run_apps
        ;;
    all)
        build_apps
        run_apps
        ;;
    *)
        echo "Usage: $0 [build|run|all]"
        echo "  build - Build all apps"
        echo "  run   - Run all apps (assumes already built)"
        echo "  all   - Build and run (default)"
        exit 1
        ;;
esac
