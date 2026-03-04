import QtQuick 2.15
import QtQuick.Window 2.15

Window {
    id: root
    visible: true
    width: 874   // Match HU_MainApp PDC container: 1024 - 130 (gear panel) - 20 (margins)
    height: 500  // Match HU_MainApp PDC container: 600 - 80 (nav bar) - 20 (margins)
    color: "#000000"
    title: "PDC - Park Distance Control"

    // Distance thresholds (in cm)
    readonly property int greenThreshold: 50   // 30-50cm: Green zone
    readonly property int yellowThreshold: 30  // 15-30cm: Yellow zone
    readonly property int redThreshold: 15     // <15cm: Red zone (danger)

    // Current distance from vsomeip
    property int currentDistance: vehicleControlClient.currentDistance
    property string currentGear: vehicleControlClient.currentGear

    // No signal from sensor (service unavailable)
    property bool noSignal: !vehicleControlClient.serviceAvailable

    // Camera frame counter for image refresh
    property int frameCounter: 0

    // Determine which zone we're in
    property string distanceZone: {
        if (currentDistance > greenThreshold) return "safe"
        else if (currentDistance > yellowThreshold) return "green"
        else if (currentDistance > redThreshold) return "yellow"
        else return "red"
    }

    // Update frame counter when new frame is ready
    Connections {
        target: videoReceiver
        function onFrameReady() {
            frameCounter++
        }
    }

    // Main container
    Rectangle {
        anchors.fill: parent
        color: "#000000"

        // ═══════════════════════════════════════════════════════════
        // Split-Screen View (shown when gear is "R")
        // Left: Top-down car view with distance arcs
        // Right: Live rear camera feed with guide overlay
        // ═══════════════════════════════════════════════════════════
        Item {
            id: cameraView
            anchors.fill: parent
            visible: currentGear === "R"

            Row {
                anchors.fill: parent

                // ── Left Side: Top-down car view with PDC arcs (35%) ──
                Item {
                    width: parent.width * 0.35
                    height: parent.height

                    Rectangle {
                        anchors.fill: parent
                        color: "#1a1a1a"
                    }

                    // Car top-down image
                    Image {
                        id: carImageReverse
                        source: "qrc:/asset/car.png"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 20
                        width: parent.width * 0.8
                        fillMode: Image.PreserveAspectFit
                        height: Math.min(implicitHeight * (width / implicitWidth), parent.height * 0.6)
                    }

                    // PDC distance arcs below car (stacked: red closest, yellow middle, green outermost)
                    // Red arc - visible in red, yellow, green zones
                    Image {
                        source: "qrc:/asset/alter_red.png"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: carImageReverse.bottom
                        anchors.topMargin: -10
                        width: parent.width * 0.55
                        fillMode: Image.PreserveAspectFit
                        opacity: (noSignal || distanceZone === "safe") ? 0.0 : distanceZone === "red" ? 1.0 : 0.2
                        Behavior on opacity { NumberAnimation { duration: 300 } }

                        SequentialAnimation on opacity {
                            running: distanceZone === "red" && !noSignal
                            loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.3; duration: 400 }
                            NumberAnimation { from: 0.3; to: 1.0; duration: 400 }
                        }
                    }
                    // Yellow arc - visible in yellow and green zones
                    Image {
                        id: yellowArcLeft
                        source: "qrc:/asset/alter_yellow.png"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: carImageReverse.bottom
                        anchors.topMargin: 15
                        width: parent.width * 0.55
                        fillMode: Image.PreserveAspectFit
                        opacity: (noSignal || distanceZone === "safe" || distanceZone === "red") ? 0.0 : distanceZone === "yellow" ? 1.0 : 0.2
                        Behavior on opacity { NumberAnimation { duration: 300 } }

                        SequentialAnimation on opacity {
                            running: distanceZone === "yellow" && !noSignal
                            loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.3; duration: 400 }
                            NumberAnimation { from: 0.3; to: 1.0; duration: 400 }
                        }
                    }
                    // Green arc - visible only in green zone
                    Image {
                        source: "qrc:/asset/alter_green.png"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: carImageReverse.bottom
                        anchors.topMargin: 40
                        width: parent.width * 0.75
                        fillMode: Image.PreserveAspectFit
                        opacity: (!noSignal && distanceZone === "green") ? 1.0 : 0.0
                        Behavior on opacity { NumberAnimation { duration: 300 } }

                        SequentialAnimation on opacity {
                            running: distanceZone === "green" && !noSignal
                            loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.3; duration: 400 }
                            NumberAnimation { from: 0.3; to: 1.0; duration: 400 }
                        }
                    }

                    // Distance text on left panel
                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: 15
                        width: leftDistText.width + 30
                        height: leftDistText.height + 16
                        color: "#CC000000"
                        radius: 8
                        border.width: 2
                        border.color: {
                            if (distanceZone === "red") return "#FF0000"
                            else if (distanceZone === "yellow") return "#FFBB00"
                            else if (distanceZone === "green") return "#00FF00"
                            else return "#888888"
                        }

                        Text {
                            id: leftDistText
                            anchors.centerIn: parent
                            text: noSignal ? "No Signal" : currentDistance + " cm"
                            font.pixelSize: 28
                            font.bold: true
                            color: {
                                if (distanceZone === "red") return "#FF0000"
                                else if (distanceZone === "yellow") return "#FFBB00"
                                else if (distanceZone === "green") return "#00FF00"
                                else return "#FFFFFF"
                            }
                        }
                    }
                }

                // ── Right Side: Live camera feed (65%) ──
                Item {
                    width: parent.width * 0.65
                    height: parent.height

                    // Camera feed
                    Image {
                        id: cameraImage
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectCrop
                        cache: false
                        source: "image://camera/frame?" + frameCounter

                        // "No Signal" overlay
                        Rectangle {
                            anchors.centerIn: parent
                            width: noSignalText.width + 40
                            height: noSignalText.height + 20
                            color: "#80000000"
                            radius: 10
                            visible: !videoReceiver.receiving || !videoReceiver.hasFrame

                            Text {
                                id: noSignalText
                                anchors.centerIn: parent
                                text: videoReceiver.receiving ? "Waiting for video..." : "Camera Starting..."
                                font.pixelSize: 20
                                color: "#FFFFFF"
                            }
                        }
                    }

                    // Camera guide overlay - 3 zone layers drawn with Canvas
                    Item {
                        id: cameraGuide
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width * 0.75
                        height: parent.height * 0.85

                        // Trapezoid geometry (relative 0-1 coords)
                        readonly property real topLeftX: 0.30
                        readonly property real topRightX: 0.70
                        readonly property real bottomLeftX: 0.02
                        readonly property real bottomRightX: 0.98

                        // Zone boundaries (fraction of height from top)
                        readonly property real zone1End: 0.30
                        readonly property real zone2Start: 0.30
                        readonly property real zone2End: 0.63
                        readonly property real zone3Start: 0.63

                        function leftX(yFrac) { return topLeftX + (bottomLeftX - topLeftX) * yFrac }
                        function rightX(yFrac) { return topRightX + (bottomRightX - topRightX) * yFrac }

                        // Red zone guide (bottom third, visible in all active zones)
                        Canvas {
                            anchors.fill: parent
                            opacity: (noSignal || distanceZone === "safe" || distanceZone === "red") ? 0.85 : 0.2
                            Behavior on opacity { NumberAnimation { duration: 300 } }

                            SequentialAnimation on opacity {
                                running: distanceZone === "red" && !noSignal
                                loops: Animation.Infinite
                                NumberAnimation { from: 0.85; to: 0.2; duration: 400 }
                                NumberAnimation { from: 0.2; to: 0.85; duration: 400 }
                            }

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = "#FF0000"
                                ctx.lineWidth = 12
                                ctx.lineCap = "round"
                                var w = width, h = height
                                var y1 = cameraGuide.zone3Start, y2 = 1.0
                                var marker = w * 0.07
                                // Left diagonal
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.leftX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.leftX(y2) * w, y2 * h)
                                ctx.stroke()
                                // Left horizontal marker
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.leftX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.leftX(y1) * w + marker, y1 * h)
                                ctx.stroke()
                                // Right diagonal
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.rightX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.rightX(y2) * w, y2 * h)
                                ctx.stroke()
                                // Right horizontal marker
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.rightX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.rightX(y1) * w - marker, y1 * h)
                                ctx.stroke()
                            }
                        }

                        // Yellow zone guide (middle third, visible in yellow and green zones)
                        Canvas {
                            anchors.fill: parent
                            opacity: (noSignal || distanceZone === "safe" || distanceZone === "yellow") ? 0.85 : distanceZone === "green" ? 0.2 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 300 } }

                            SequentialAnimation on opacity {
                                running: distanceZone === "yellow" && !noSignal
                                loops: Animation.Infinite
                                NumberAnimation { from: 0.85; to: 0.2; duration: 400 }
                                NumberAnimation { from: 0.2; to: 0.85; duration: 400 }
                            }

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = "#FFBB00"
                                ctx.lineWidth = 12
                                ctx.lineCap = "round"
                                var w = width, h = height
                                var y1 = cameraGuide.zone2Start, y2 = cameraGuide.zone2End
                                var marker = w * 0.07
                                // Left diagonal
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.leftX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.leftX(y2) * w, y2 * h)
                                ctx.stroke()
                                // Left horizontal marker
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.leftX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.leftX(y1) * w + marker, y1 * h)
                                ctx.stroke()
                                // Right diagonal
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.rightX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.rightX(y2) * w, y2 * h)
                                ctx.stroke()
                                // Right horizontal marker
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.rightX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.rightX(y1) * w - marker, y1 * h)
                                ctx.stroke()
                            }
                        }

                        // Green zone guide (top third, visible only in green zone)
                        Canvas {
                            anchors.fill: parent
                            opacity: (noSignal || distanceZone === "safe" || distanceZone === "green") ? 0.85 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 300 } }

                            SequentialAnimation on opacity {
                                running: distanceZone === "green" && !noSignal
                                loops: Animation.Infinite
                                NumberAnimation { from: 0.85; to: 0.2; duration: 400 }
                                NumberAnimation { from: 0.2; to: 0.85; duration: 400 }
                            }

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = "#44FF44"
                                ctx.lineWidth = 12
                                ctx.lineCap = "round"
                                var w = width, h = height
                                var y1 = 0.0, y2 = cameraGuide.zone1End
                                var marker = w * 0.07
                                // Left diagonal
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.leftX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.leftX(y2) * w, y2 * h)
                                ctx.stroke()
                                // Left horizontal marker
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.leftX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.leftX(y1) * w + marker, y1 * h)
                                ctx.stroke()
                                // Right diagonal
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.rightX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.rightX(y2) * w, y2 * h)
                                ctx.stroke()
                                // Right horizontal marker
                                ctx.beginPath()
                                ctx.moveTo(cameraGuide.rightX(y1) * w, y1 * h)
                                ctx.lineTo(cameraGuide.rightX(y1) * w - marker, y1 * h)
                                ctx.stroke()
                            }
                        }
                    }

                    // REAR CAM indicator
                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 8
                        width: cameraIndicatorRow.width + 16
                        height: 26
                        color: "#80000000"
                        radius: 5

                        Row {
                            id: cameraIndicatorRow
                            anchors.centerIn: parent
                            spacing: 6

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                color: videoReceiver.receiving ? "#FF0000" : "#888888"
                                anchors.verticalCenter: parent.verticalCenter

                                SequentialAnimation on opacity {
                                    running: videoReceiver.receiving
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.3; duration: 500 }
                                    NumberAnimation { to: 1.0; duration: 500 }
                                }
                            }

                            Text {
                                text: "REAR CAM"
                                font.pixelSize: 12
                                font.bold: true
                                color: "#FFFFFF"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
            }
        }

        // ═══════════════════════════════════════════════════════════
        // Distance Display (shown when gear is NOT "R")
        // ═══════════════════════════════════════════════════════════
        Item {
            id: distanceView
            anchors.fill: parent
            visible: currentGear !== "R"

        // Distance display - on the left side of the car
        Text {
            id: distanceText
            anchors.left: parent.left
            anchors.leftMargin: 40
            anchors.verticalCenter: parent.verticalCenter
            text: noSignal ? "No Signal" : currentDistance + " cm"
            font.pixelSize: 32
            font.bold: true
            color: {
                if (distanceZone === "red") return "#FF0000"
                else if (distanceZone === "yellow") return "#FFBB00"
                else if (distanceZone === "green") return "#00FF00"
                else return "#888888"
            }
        }

        // Car and distance indicator container
        Item {
            id: carContainer
            anchors.top: parent.top
            anchors.topMargin: 20
            anchors.horizontalCenter: parent.horizontalCenter

            width: parent.width * 0.9
            height: parent.height * 0.8

            // Car image (rear view - positioned at center) - Made even larger
            Image {
                id: carImage
                source: "qrc:/asset/car.png"
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width * 0.95
                fillMode: Image.PreserveAspectFit
                height: Math.min(implicitHeight * (width / implicitWidth), parent.height * 0.7)
            }

            // Distance indicator arcs (positioned below car)
            Item {
                id: arcContainer
                anchors.top: carImage.bottom
                anchors.topMargin: -30
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width * 0.85
                height: 120

                // Red arc - visible in red, yellow, green zones
                Image {
                    id: redArc
                    source: "qrc:/asset/alter_red.png"
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: -10
                    width: 250
                    fillMode: Image.PreserveAspectFit
                    opacity: (noSignal || distanceZone === "safe") ? 0.0 : distanceZone === "red" ? 1.0 : 0.2
                    Behavior on opacity { NumberAnimation { duration: 300 } }

                    SequentialAnimation on opacity {
                        running: distanceZone === "red" && !noSignal
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 400 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 400 }
                    }
                }

                // Yellow arc - visible in yellow and green zones
                Image {
                    id: yellowArc
                    source: "qrc:/asset/alter_yellow.png"
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 25
                    width: 250
                    fillMode: Image.PreserveAspectFit
                    opacity: (noSignal || distanceZone === "safe" || distanceZone === "red") ? 0.0 : distanceZone === "yellow" ? 1.0 : 0.2
                    Behavior on opacity { NumberAnimation { duration: 300 } }

                    SequentialAnimation on opacity {
                        running: distanceZone === "yellow" && !noSignal
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 400 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 400 }
                    }
                }

                // Green arc - visible only in green zone
                Image {
                    id: greenArc
                    source: "qrc:/asset/alter_green.png"
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 60
                    width: 340
                    fillMode: Image.PreserveAspectFit
                    opacity: (!noSignal && distanceZone === "green") ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 300 } }

                    SequentialAnimation on opacity {
                        running: distanceZone === "green" && !noSignal
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 400 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 400 }
                    }
                }
            }
        }
        } // End of distanceView Item

        // Service status indicator (always visible)
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.margins: 10
            width: 15
            height: 15
            radius: 7.5
            color: vehicleControlClient.serviceAvailable ? "#00ff00" : "#ff0000"

            Text {
                anchors.right: parent.left
                anchors.rightMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                text: vehicleControlClient.serviceAvailable ? "Connected" : "Disconnected"
                font.pixelSize: 12
                color: "#888888"
            }
        }
    }
}
