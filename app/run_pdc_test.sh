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

    # Build VehicleControlMock
    echo "Building VehicleControlMock..."
    echo "────────────────────────────────────────────────────────────────────────────────"
    mkdir -p VehicleControlMock
    cd VehicleControlMock
    cmake "$SCRIPT_DIR/VehicleControlMock" \
        -DCOMMONAPI_GEN_DIR="$COMMONAPI_GEN_DIR"
    make -j$(nproc)
    cd ..

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

    # Terminal 1: VehicleControlMock
    echo "Starting VehicleControlMock..."
    gnome-terminal --title="VehicleControlMock" -- bash -c "
cd '$BUILD_DIR/VehicleControlMock'
export VSOMEIP_APPLICATION_NAME=VehicleControlMock
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/VehicleControlMock/config/vsomeip_mock.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./VehicleControlMock
exec bash" &

    sleep 2

    # Terminal 2: HU_MainApp Compositor (runs on X11/xcb for local testing)
    echo "Starting HU_MainApp Compositor..."
    gnome-terminal --title="HU_MainApp Compositor" -- bash -c "
cd '$BUILD_DIR/HU_MainApp'
export QT_QPA_PLATFORM=xcb
export QML2_IMPORT_PATH=/usr/lib/x86_64-linux-gnu/qt5/qml
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
./HU_MainApp_Compositor
exec bash" &

    echo "Waiting for compositor to create wayland-1 socket..."
    XDG_RUNTIME_DIR=/run/user/$(id -u)
    for i in {1..30}; do
        if [ -S "$XDG_RUNTIME_DIR/wayland-1" ]; then
            echo "wayland-1 socket found!"
            break
        fi
        echo "  Waiting... ($i/30)"
        sleep 1
    done

    if [ ! -S "$XDG_RUNTIME_DIR/wayland-1" ]; then
        echo "ERROR: wayland-1 socket not created. HU_MainApp may have failed."
        echo "Check the HU_MainApp terminal for errors."
        exit 1
    fi

    sleep 2  # Extra time for compositor to fully initialize

    # Terminal 3: GearApp (connects to HU_MainApp compositor via wayland-1)
    echo "Starting GearApp..."
    gnome-terminal --title="GearApp" -- bash -c "
cd '$BUILD_DIR/GearApp'
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export WAYLAND_DISPLAY=wayland-1
export VSOMEIP_APPLICATION_NAME=GearApp
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./GearApp
exec bash" &

    sleep 1

    # Terminal 4: PDCApp (connects to HU_MainApp compositor via wayland-1)
    echo "Starting PDCApp..."
    gnome-terminal --title="PDCApp" -- bash -c "
cd '$BUILD_DIR/PDCApp'
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export WAYLAND_DISPLAY=wayland-1
export VSOMEIP_APPLICATION_NAME=PDCApp
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/PDCApp/config/vsomeip_pdc.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./PDCApp
exec bash" &

    sleep 1

    # Terminal 5: RemoteSpeakerApp (optional - for beep sounds)
    echo "Starting RemoteSpeakerApp..."
    gnome-terminal --title="RemoteSpeakerApp" -- bash -c "
cd '$BUILD_DIR/RemoteSpeakerApp'
export VSOMEIP_APPLICATION_NAME=RemoteSpeakerApp
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/RemoteSpeakerApp/config/vsomeip_speaker.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./RemoteSpeakerApp
exec bash" &

    sleep 1

    # Terminal 6: HomeScreenApp (dashboard - connects to compositor via wayland-1)
    echo "Starting HomeScreenApp..."
    gnome-terminal --title="HomeScreenApp" -- bash -c "
cd '$BUILD_DIR/HomeScreenApp'
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export WAYLAND_DISPLAY=wayland-1
export VSOMEIP_APPLICATION_NAME=HomeScreenApp
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./HomeScreenApp
exec bash" &

    sleep 1

    # Terminal 7: MediaApp (media player - connects to compositor via wayland-1)
    echo "Starting MediaApp..."
    gnome-terminal --title="MediaApp" -- bash -c "
cd '$BUILD_DIR/MediaApp'
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export WAYLAND_DISPLAY=wayland-1
export VSOMEIP_APPLICATION_NAME=MediaApp
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./MediaApp
exec bash" &

    sleep 1

    # Terminal 8: AmbientApp (ambient lighting - connects to compositor via wayland-1)
    echo "Starting AmbientApp..."
    gnome-terminal --title="AmbientApp" -- bash -c "
cd '$BUILD_DIR/AmbientApp'
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export WAYLAND_DISPLAY=wayland-1
export VSOMEIP_APPLICATION_NAME=AmbientApp
export VSOMEIP_CONFIGURATION='$SCRIPT_DIR/GearApp/config/vsomeip_ecu2.json'
export COMMONAPI_CONFIG='$BASE_DIR/commonapi/commonapi.ini'
./AmbientApp
exec bash" &

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "All apps launched!"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Test Instructions:"
    echo "  1. Click on GearApp panel (left side) to change gear"
    echo "  2. Click 'R' (Reverse) to see PDCApp overlay appear"
    echo "  3. Watch distance simulation in VehicleControlMock terminal"
    echo "  4. Click 'P', 'N', or 'D' to hide PDCApp overlay"
    echo ""
    echo "To stop all processes:"
    echo "  pkill -f VehicleControlMock; pkill -f HU_MainApp; pkill -f GearApp; pkill -f PDCApp; pkill -f RemoteSpeakerApp; pkill -f HomeScreenApp; pkill -f MediaApp; pkill -f AmbientApp"
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
