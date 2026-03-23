# PDC — Park Distance Control System

A distributed automotive Park Distance Control system built on two embedded ECUs communicating over **vSOME/IP**. The system detects reverse gear, measures rear obstacle distance via ultrasonic sensor, streams live camera footage, and displays a real-time warning overlay on the Head Unit.

---

## 1. System Architecture

> Two ECUs connected over Ethernet. ECU1 (RPi4) owns all physical sensors and publishes data as a vSOME/IP service. ECU2 (Jetson) runs the Head Unit UI apps that consume that service.

```mermaid
graph LR
    subgraph ECU1["ECU1 — Raspberry Pi 4 (Yocto Linux) · 192.168.1.100"]
        direction TB
        ARD["🔌 Arduino Uno\nHC-SR04 · Hall sensor\nMCP2515 CAN shield"]
        BRIDGE["serial_to_can_bridge.py\nUSB Serial → can0"]
        VCE["⚙️ VehicleControlECU\nvsomeip Service Provider\n0x1234 / 0x5678"]
        CAM["📷 OV5647 Camera (CSI)\n/dev/video0"]
        GST_TX["GStreamer TX\nlibcamerasrc → x264enc\nrtph264pay → udpsink"]
        GP["🎮 Gamepad\n(Shanwan wireless)"]
        BAT["🔋 INA219\nBattery Monitor"]

        ARD -->|"115200 baud\nSpeed + Distance"| BRIDGE
        BRIDGE -->|"CAN ID 0x0F6\n8-byte frame"| VCE
        GP -->|USB HID| VCE
        BAT -->|I²C| VCE
        CAM --> GST_TX
    end

    subgraph ECU2["ECU2 — Jetson Nano (Ubuntu 22.04) · 192.168.1.101"]
        direction TB
        HU["🖥️ HU_MainApp\nWayland Compositor"]
        GEAR["⚙️ GearApp\nRouting Manager\nP · R · N · D"]
        PDC["🚗 PDCApp\nDistance Arcs\nCamera Overlay"]
        HOME["🏠 HomeScreenApp"]
        MEDIA["🎵 MediaApp"]
        AMBIENT["💡 AmbientApp"]
        SPEAKER["🔊 RemoteSpeakerApp\nProximity Beep"]
        GST_RX["GStreamer RX\nnvv4l2decoder (HW)\nappsink → PDCApp"]

        HU --> GEAR
        HU --> PDC
        HU --> HOME
        HU --> MEDIA
        HU --> AMBIENT
        GST_RX --> PDC
    end

    VCE -->|"vSOME/IP / UDP 30501\ngearDistanceChanged\nvehicleStateChanged"| GEAR
    VCE -->|"vSOME/IP"| PDC
    VCE -->|"vSOME/IP"| AMBIENT
    VCE -->|"vSOME/IP"| SPEAKER
    GEAR -->|"setGearPosition RPC\nvSOME/IP"| VCE
    GST_TX -->|"H264 / RTP / UDP\nport 5000"| GST_RX

    style ECU1 fill:#0d1b2a,stroke:#4a90d9,color:#e0e0e0
    style ECU2 fill:#0d2a0d,stroke:#4ad94a,color:#e0e0e0
```

---

## 2. ECU1 Internal — Sensor Data Flow

> How raw sensor data flows from hardware into the vSOME/IP broadcast.

```mermaid
flowchart TD
    HC["HC-SR04\nUltrasonic Sensor\nTRIG=8 ECHO=7"]
    HALL["Hall Effect\nSpeed Sensor\nPin 3 interrupt"]
    MCP["MCP2515\nCAN Shield\n1000 Kbps CS=9"]

    HC -->|"100ms pulse\necho time → cm"| ARD
    HALL -->|"20 pulses/rev\n20.083cm circumference"| ARD

    ARD["Arduino Uno\npdc.ino"]
    ARD -->|"CAN frame ID 0x0F6\nByte0-2: speed\nByte3-6: distance float LE"| MCP
    MCP -->|"SocketCAN\ncan0"| VCE

    subgraph VCE["VehicleControlECU (Qt application)"]
        CAN["CANInterface\nreceiveCANMessages()\n10ms poll timer"]
        EMA["EMA Filter\nα=0.3\nsmooths distance"]
        STUB["VehicleControlStubImpl\nCommonAPI stub"]
        TIMER["10Hz Broadcast Timer\n100ms interval"]

        CAN -->|"speedCms\ndistanceCm"| EMA
        EMA -->|filtered| STUB
        STUB --> TIMER
    end

    TIMER -->|"fireGearDistanceChangedEvent()\nfireVehicleStateChangedEvent()"| SOMEIP["vSOME/IP\nNetwork"]

    style VCE fill:#0d1b2a,stroke:#4a90d9,color:#e0e0e0
```

---

## 3. ECU2 Internal — App Communication

> How the Jetson apps communicate with each other and with ECU1.

```mermaid
graph TD
    ECU1["ECU1\nVehicleControlECU\n192.168.1.100"]

    subgraph ECU2["ECU2 — Jetson Nano"]
        GEAR["GearApp\n(vsomeip routing manager)\nApp ID: 0x0100"]
        PDC["PDCApp\nApp ID: 0x0300"]
        SPEAKER["RemoteSpeakerApp"]
        AMBIENT["AmbientApp"]
        MEDIA["MediaApp"]
        HOME["HomeScreenApp"]
        HU["HU_MainApp\nWayland Compositor"]

        GEAR -->|"AmbientControl\nbroadcast"| AMBIENT
        MEDIA -->|"MediaControl\nbroadcast"| HOME
        MEDIA -->|"MediaControl"| AMBIENT
        AMBIENT -->|"AmbientControl"| HOME
        HU -->|"Wayland protocol\nwindow title detection"| GEAR
        HU -->|"Wayland protocol"| PDC
    end

    ECU1 -->|"gearDistanceChanged\nvehicleStateChanged\nvSOME/IP UDP"| GEAR
    ECU1 -->|"gearDistanceChanged\nvSOME/IP UDP"| PDC
    ECU1 -->|"gearDistanceChanged\nvSOME/IP UDP"| SPEAKER
    ECU1 -->|"gearDistanceChanged\nvSOME/IP UDP"| AMBIENT
    GEAR -->|"setGearPosition RPC"| ECU1

    style ECU2 fill:#0d2a0d,stroke:#4ad94a,color:#e0e0e0
```

---

## 4. vSOME/IP Service Discovery Sequence

> How ECU1 and ECU2 find each other on the network at startup.

```mermaid
sequenceDiagram
    participant ECU1 as ECU1<br/>VehicleControlECU<br/>192.168.1.100
    participant NET as Network<br/>Multicast<br/>224.244.224.245:30490
    participant GEAR as ECU2<br/>GearApp<br/>(Routing Manager)
    participant PDC as ECU2<br/>PDCApp
    participant SPEAKER as ECU2<br/>RemoteSpeakerApp

    Note over ECU1: Boot → camera-streaming.service<br/>vehiclecontrol-ecu.service start

    ECU1->>NET: SD OfferService<br/>Service 0x1234 Instance 0x5678<br/>UDP port 30501

    Note over GEAR: GearApp starts first<br/>becomes routing manager

    GEAR->>NET: SD FindService<br/>Service 0x1234 Instance 0x5678
    PDC->>NET: SD FindService<br/>Service 0x1234
    SPEAKER->>NET: SD FindService<br/>Service 0x1234

    NET-->>GEAR: OfferService received
    NET-->>PDC: OfferService received
    NET-->>SPEAKER: OfferService received

    GEAR->>ECU1: SD SubscribeEventgroup<br/>gearDistanceChanged
    PDC->>ECU1: SD SubscribeEventgroup<br/>gearDistanceChanged<br/>vehicleStateChanged
    SPEAKER->>ECU1: SD SubscribeEventgroup<br/>gearDistanceChanged

    ECU1-->>GEAR: SD SubscribeAck ✓
    ECU1-->>PDC: SD SubscribeAck ✓
    ECU1-->>SPEAKER: SD SubscribeAck ✓

    Note over ECU1,SPEAKER: All clients AVAILABLE<br/>Events begin flowing at 10Hz
```

---

## 5. Gear Change Sequence

> Full flow when driver engages Reverse gear via gamepad.

```mermaid
sequenceDiagram
    participant GP as 🎮 Gamepad<br/>(RPi4 USB)
    participant VCE as VehicleControlECU<br/>(ECU1)
    participant GEAR as GearApp<br/>(ECU2)
    participant HU as HU_MainApp<br/>Compositor
    participant PDC as PDCApp
    participant AMB as AmbientApp
    participant SPK as RemoteSpeakerApp

    GP->>VCE: HID event: button R pressed
    VCE->>VCE: PiRacerController<br/>setGearPosition("R")

    Note over VCE: Fires vSOME/IP broadcasts

    VCE->>GEAR: gearDistanceChanged<br/>(newGear="R", distance=Xcm)
    VCE->>PDC: gearDistanceChanged<br/>(newGear="R", distance=Xcm)
    VCE->>AMB: gearDistanceChanged<br/>(newGear="R")
    VCE->>SPK: gearDistanceChanged<br/>(newGear="R")

    GEAR->>GEAR: Update QML gear display<br/>highlight "R" button
    GEAR->>HU: setWindowTitle("GearApp - R")

    HU->>HU: Detect title contains " - R"<br/>pdcVisible = true
    HU->>PDC: Show PDCApp surface<br/>(Wayland layer)

    PDC->>PDC: Show distance arcs<br/>Show camera view<br/>isReverse = true

    AMB->>AMB: Change ambient color<br/>to reverse mode
    SPK->>SPK: Start monitoring distance<br/>for beep threshold

    Note over PDC: PDCApp overlay now visible<br/>Camera + distance arcs active
```

---

## 6. Distance Alert Sequence

> How ultrasonic sensor data travels from Arduino to the display.

```mermaid
sequenceDiagram
    participant HC as HC-SR04<br/>Sensor
    participant ARD as Arduino Uno<br/>pdc.ino
    participant CAN as can0<br/>(SocketCAN)
    participant VCE as VehicleControlECU<br/>CANInterface
    participant NET as vSOME/IP<br/>Network
    participant PDC as PDCApp<br/>QML
    participant SPK as RemoteSpeakerApp

    loop Every 100ms
        ARD->>HC: TRIG pulse (10µs)
        HC-->>ARD: ECHO pulse (duration → distance)
        ARD->>ARD: Calculate distance (cm)<br/>Calculate speed (cm/s)
        ARD->>CAN: CAN frame ID=0x0F6<br/>Byte[0-2]: speed<br/>Byte[3-6]: distance (float LE)
    end

    loop Every 10ms (poll timer)
        VCE->>CAN: recv() socket
        CAN-->>VCE: CAN frame
        VCE->>VCE: parseSpeedData()<br/>parseDistanceData()<br/>EMA filter (α=0.3)
    end

    loop Every 100ms (10Hz broadcast)
        VCE->>NET: fireGearDistanceChangedEvent<br/>(gear, distance_cm, timestamp)
        NET->>PDC: gearDistanceChanged event
        NET->>SPK: gearDistanceChanged event

        PDC->>PDC: Update arc color<br/>>50cm → hidden<br/>30-50cm → green<br/>15-30cm → yellow<br/><15cm → red

        alt distance < 15cm
            SPK->>SPK: Play continuous beep
        else distance < 30cm
            SPK->>SPK: Play fast beep
        else distance < 50cm
            SPK->>SPK: Play slow beep
        end
    end
```

---

## 7. Camera Streaming Pipeline

> How video frames travel from the OV5647 lens to the PDCApp display.

```mermaid
flowchart LR
    subgraph RPi4["ECU1 — Raspberry Pi 4"]
        OV["OV5647\nCSI Camera\n/dev/video0"]
        LC["libcamerasrc\nor v4l2src"]
        VC["videoconvert\nYUV → I420"]
        X264["x264enc\nzerolatency\n4000 kbps"]
        H264P["h264parse\nconfig-interval=1"]
        RTP["rtph264pay\npt=96"]
        UDP_TX["udpsink\nhost=192.168.1.101\nport=5000"]

        OV -->|"raw frames\n1280×720 @ 30fps"| LC
        LC --> VC
        VC --> X264
        X264 -->|"H.264 NAL units"| H264P
        H264P --> RTP
        RTP -->|"RTP packets\n~1400 byte MTU"| UDP_TX
    end

    subgraph Jetson["ECU2 — Jetson Nano"]
        UDP_RX["udpsrc\nport=5000"]
        DEPAY["rtph264depay"]
        PARSE["h264parse"]
        DEC["nvv4l2decoder\nTegra HW decode"]
        CONV["nvvidconv\n→ RGBA"]
        SINK["appsink\nGstVideoReceiver.cpp"]
        QML["PDCApp QML\nImage provider\nrear camera view"]

        UDP_RX -->|"RTP packets"| DEPAY
        DEPAY -->|"H.264 bitstream"| PARSE
        PARSE -->|"NAL units"| DEC
        DEC -->|"NvBuffer"| CONV
        CONV -->|"RGBA frames"| SINK
        SINK -->|"QImage / texture"| QML
    end

    UDP_TX -->|"Ethernet\n192.168.1.100 → .101\n~0.3ms latency"| UDP_RX

    style RPi4 fill:#0d1b2a,stroke:#4a90d9,color:#e0e0e0
    style Jetson fill:#0d2a0d,stroke:#4ad94a,color:#e0e0e0
```

---

## 8. PDCApp State Machine

> PDCApp visibility and behavior based on gear state.

```mermaid
stateDiagram-v2
    [*] --> Initializing

    Initializing --> WaitingForService : App started
    WaitingForService --> Connected : vSOME/IP AVAILABLE

    Connected --> Hidden : gear = P / N / D
    Connected --> Visible : gear = R

    Hidden --> Visible : gearDistanceChanged\nnewGear = "R"
    Visible --> Hidden : gearDistanceChanged\nnewGear ≠ "R"

    state Visible {
        [*] --> Safe
        Safe --> Green : distance ≤ 50cm
        Green --> Safe : distance > 50cm
        Green --> Yellow : distance ≤ 30cm
        Yellow --> Green : distance > 30cm
        Yellow --> Red : distance ≤ 15cm
        Red --> Yellow : distance > 15cm

        state Safe {
            arcs : arcs hidden
            cam : camera visible
        }
        state Green {
            arcs_g : green arcs
            beep_g : slow beep
        }
        state Yellow {
            arcs_y : yellow arcs
            beep_y : fast beep
        }
        state Red {
            arcs_r : red arcs
            beep_r : continuous beep
        }
    }

    state Hidden {
        idle : camera + arcs hidden
        listen : still receiving events
    }
```

---

## 9. CAN Frame Format

> Arduino → RPi4 data encoding for speed and distance.

```mermaid
packet-beta
    0-7: "speed_int // 256"
    8-15: "speed_int % 256"
    16-23: "decimal × 100"
    24-31: "dist byte 0 (LSB)"
    32-39: "dist byte 1"
    40-47: "dist byte 2"
    48-55: "dist byte 3 (MSB)"
    56-63: "0x00 padding"
```

**CAN ID:** `0x0F6` &nbsp;|&nbsp; **DLC:** 8 bytes &nbsp;|&nbsp; **Rate:** 100ms &nbsp;|&nbsp; **Bus speed:** 1000 Kbps

| Bytes | Field | Encoding |
|---|---|---|
| 0–1 | Speed integer part | `(data[0] << 8) \| data[1]` → cm/s |
| 2 | Speed decimal part | `data[2] / 100.0` → cm/s fraction |
| 3–6 | Distance | `float` little-endian → cm |
| 7 | Padding | `0x00` |

---

## 10. Software Stack

```mermaid
graph TD
    subgraph HW["Hardware Layer"]
        H1["HC-SR04\nUltrasonic"]
        H2["Hall Sensor\nSpeed"]
        H3["OV5647\nCamera"]
        H4["INA219\nBattery"]
        H5["PCA9685\nServo PWM"]
        H6["Gamepad\nUSB HID"]
    end

    subgraph ARD["Arduino (pdc.ino)"]
        A1["Sensor Reading\n100ms cycle"]
        A2["MCP2515\nCAN TX"]
    end

    subgraph ECU1SW["ECU1 Software (C++/Qt)"]
        S1["CANInterface\nSocketCAN read"]
        S2["EMA Filter\nα=0.3"]
        S3["GamepadHandler"]
        S4["BatteryMonitor"]
        S5["VehicleControlStubImpl\nCommonAPI"]
        S6["vsomeip3\nService Provider"]
    end

    subgraph CAPI["CommonAPI / vSOME/IP"]
        C1["FIDL Interface\nVehicleControl v1.0"]
        C2["SOME/IP Binding\nUDP 30501 / TCP 30502"]
        C3["SD Multicast\n224.244.224.245:30490"]
    end

    subgraph ECU2SW["ECU2 Software (C++/Qt/QML)"]
        E1["GearApp\nRouting Manager"]
        E2["PDCApp\nGstVideoReceiver"]
        E3["HU_MainApp\nWayland Compositor"]
        E4["AmbientApp\nRemoteSpeakerApp"]
    end

    H1 & H2 --> ARD
    H3 --> S1
    H4 --> S4
    H5 & H6 --> S3
    ARD --> S1
    S1 --> S2 --> S5
    S3 & S4 --> S5
    S5 --> S6 --> CAPI
    CAPI --> ECU2SW
    E1 & E2 --> E3

    style HW fill:#1a1a00,stroke:#d4d400,color:#e0e0e0
    style ARD fill:#1a0d00,stroke:#d47a00,color:#e0e0e0
    style ECU1SW fill:#0d1b2a,stroke:#4a90d9,color:#e0e0e0
    style CAPI fill:#1a001a,stroke:#d44ad4,color:#e0e0e0
    style ECU2SW fill:#0d2a0d,stroke:#4ad94a,color:#e0e0e0
```

---

## Features

- **Park Distance Control** — real-time ultrasonic distance measurement (0–200 cm) with color-coded arc overlay
- **Reverse camera** — live H.264 video stream from OV5647 displayed in PDCApp when reverse gear is engaged
- **Gear control** — wireless gamepad on RPi4 changes gear; GearApp UI on Jetson reflects it instantly via vSOME/IP
- **Proximity beep** — RemoteSpeakerApp triggers audio alerts as obstacle distance decreases
- **Ambient lighting** — AmbientApp changes lighting color based on gear and vehicle state
- **Speed & battery monitoring** — Hall effect wheel speed sensor + INA219 battery monitor, broadcast at 10 Hz
- **Service-oriented architecture** — all ECU and app communication via CommonAPI/vSOME/IP
- **Wayland compositor** — HU_MainApp multiplexes all Qt/QML apps onto a single display surface

---

## Repository Structure

```
PDC/
├── app/
│   ├── VehicleControlECU/      # ECU1: sensor fusion, CAN, gamepad, vsomeip service provider
│   ├── VehicleControlMock/     # Standalone mock of ECU1 for Jetson-only testing
│   ├── HU_MainApp/             # ECU2: Wayland compositor / Head Unit shell
│   ├── GearApp/                # Gear selector UI + vsomeip routing manager
│   ├── PDCApp/                 # Distance arc overlay + live camera (GStreamer appsink)
│   ├── RemoteSpeakerApp/       # Proximity beep audio controller
│   ├── AmbientApp/             # Ambient lighting control
│   ├── MediaApp/               # Media player
│   ├── HomeScreenApp/          # Home/idle screen
│   ├── IC_MainApp/             # Instrument Cluster compositor (separate display)
│   ├── run_pdc_test.sh         # Build & launch all ECU2 apps
│   └── test_pdc.sh             # Automated integration test suite (T01–T14)
├── Arduino/
│   ├── pdc/pdc.ino             # Arduino sketch: HC-SR04 + Hall sensor + MCP2515 CAN
│   └── serial_to_can_bridge.py # USB serial → virtual CAN bridge (non-Yocto fallback)
├── commonapi/
│   ├── fidl/                   # Service interface definitions (.fidl + .fdepl)
│   │   ├── VehicleControl.fidl
│   │   ├── AmbientControl.fidl
│   │   └── MediaControl.fidl
│   └── generated/              # Auto-generated CommonAPI stubs and proxies
├── deps/                       # vsomeip and CommonAPI built from source
└── install_folder/             # Compiled shared libraries and headers
```


---

## Hardware

### ECU1 — Raspberry Pi 4

| Component | Details |
|---|---|
| OS | Yocto Linux (custom image with `camera-streaming.service` + `vehiclecontrol-ecu.service`) |
| Camera | OV5647 via CSI — GStreamer `libcamerasrc` pipeline |
| CAN | `can0` built into Yocto image |
| Gamepad | Shanwan wireless controller (USB) |
| Servo driver | Adafruit PCA9685 (I²C PWM) |
| Battery monitor | INA219 (I²C) |

### ECU2 — Jetson Nano

| Component | Details |
|---|---|
| OS | Ubuntu 22.04 (JetPack) |
| Display | HDMI via Wayland (HU_MainApp compositor) |
| H.264 decode | `nvv4l2decoder` (Tegra hardware accelerated) |

### Arduino Uno + MCP2515 Shield

| Sensor | Pin | Details |
|---|---|---|
| HC-SR04 ultrasonic | TRIG=8, ECHO=7 | Range 2–200 cm, 100 ms sample interval |
| Hall effect speed | Pin 3 (interrupt) | 20 pulses/rev, wheel circumference 20.083 cm |
| MCP2515 CAN | CS=9 | 1000 Kbps, CAN ID `0x0F6` |

---

## Network

| Link | Interface | Addresses | Purpose |
|---|---|---|---|
| Wired Ethernet | RPi4 `eth0` ↔ Jetson `enP8p1s0` | `192.168.1.100` ↔ `192.168.1.101` | vSOME/IP + camera RTP stream |
| WiFi (optional) | RPi4 `wlan0` ↔ Jetson `wlP1p1s0` | DHCP | SSH / development only |

---

## Getting Started

### Prerequisites — ECU2 (Jetson Nano)

```bash
sudo apt install qt5-default qtwayland5 \
    gstreamer1.0-tools gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
# CommonAPI + vsomeip built from source (see deps/)
```

### Prerequisites — ECU1 (Raspberry Pi 4)

Flash the Yocto image. Both services start automatically on boot.

```bash
systemctl status camera-streaming.service    # OV5647 → H264/RTP → 192.168.1.101:5000
systemctl status vehiclecontrol-ecu.service  # vsomeip service provider
```

### Build — ECU2

```bash
git clone <repo-url> && cd PDC/app
./run_pdc_test.sh build
```

### Run — ECU2

```bash
export DISPLAY=:1 && xhost +local:
cd ~/PDC/app && ./run_pdc_test.sh run
```

**Usage:** Click **R** in GearApp → PDCApp overlay appears with live camera and distance arcs. Move object in front of sensor to see zone changes. Click **P / N / D** → overlay hides.

---

## vSOME/IP Parameters

| Parameter | Value |
|---|---|
| Service ID | `0x1234` |
| Instance ID | `0x5678` |
| UDP port | `30501` |
| TCP port | `30502` |
| SD multicast group | `224.244.224.245:30490` |
| ECU1 unicast | `192.168.1.100` |
| ECU2 unicast | `192.168.1.101` |
| Routing manager (ECU2) | `GearApp` |

---

## Troubleshooting

**`could not connect to display`**
```bash
export DISPLAY=:1 && xhost +local:
```

**Camera busy on RPi4**
```bash
systemctl restart camera-streaming.service
```

**vsomeip service not discovered**
```bash
sudo ip route add 224.0.0.0/4 dev enP8p1s0
```

**No CAN interface (development machine)**
```bash
sudo modprobe vcan
sudo ip link add dev can0 type vcan && sudo ip link set can0 up
python3 Arduino/serial_to_can_bridge.py
```

**VehicleControlMock routing conflict**
```bash
pkill -f GearApp && sleep 2
./test_pdc.sh --no-build --mock-only
```

---

## License

Developed as part of the **SEAME ** automotive embedded systems program.
