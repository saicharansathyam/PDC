#include "MockStubImpl.h"
#include <QDebug>
#include <QDateTime>

MockStubImpl::MockStubImpl(QObject *parent)
    : QObject(parent)
    , m_updateTimer(new QTimer(this))
    , m_cameraStreamer(new CameraStreamer(this))
    , m_currentGear("P")
    , m_currentDistance(START_DISTANCE)
    , m_targetDistance(END_DISTANCE)
    , m_distanceStep(DISTANCE_STEP)
{
    connect(m_updateTimer, &QTimer::timeout, this, &MockStubImpl::updateDistance);

    // Initialize camera streamer (use test source for desktop, target localhost)
    if (m_cameraStreamer->initialize("127.0.0.1", 5000, true)) {
        qDebug() << "[Mock] CameraStreamer initialized (test source -> 127.0.0.1:5000)";
    } else {
        qWarning() << "[Mock] Failed to initialize CameraStreamer";
    }

    qDebug() << "[Mock] MockStubImpl created";
}

MockStubImpl::~MockStubImpl()
{
    stopSimulation();
    qDebug() << "[Mock] MockStubImpl destroyed";
}

void MockStubImpl::setGearPosition(const std::shared_ptr<CommonAPI::ClientId> _client,
                                   std::string _gear,
                                   setGearPositionReply_t _reply)
{
    Q_UNUSED(_client);

    QString gear = QString::fromStdString(_gear);
    qDebug() << "[Mock] setGearPosition RPC called:" << gear;

    // Validate gear
    if (gear != "P" && gear != "R" && gear != "N" && gear != "D") {
        qWarning() << "[Mock] Invalid gear:" << gear;
        _reply(false);
        return;
    }

    QString oldGear = m_currentGear;
    m_currentGear = gear;

    // Broadcast gear change
    uint64_t timestamp = QDateTime::currentMSecsSinceEpoch();
    fireGearDistanceChangedEvent(m_currentGear.toStdString(),
                                  oldGear.toStdString(),
                                  static_cast<uint16_t>(m_currentDistance),
                                  timestamp);

    qDebug() << "[Mock] Gear changed:" << oldGear << "->" << m_currentGear;
    qDebug() << "[Mock] Timer active:" << m_updateTimer->isActive() << "Current distance:" << m_currentDistance;

    // Start/stop PDC simulation and camera based on gear
    // Use QMetaObject::invokeMethod to ensure timer operations happen in the correct thread
    if (gear == "R") {
        if (!m_updateTimer->isActive()) {
            qDebug() << "";
            qDebug() << "═══════════════════════════════════════════════════════";
            qDebug() << "[Mock] Reverse gear engaged - starting PDC distance simulation";
            qDebug() << "[Mock] Distance will decrease from" << START_DISTANCE << "cm to" << END_DISTANCE << "cm";
            qDebug() << "[Mock] Starting camera stream...";
            qDebug() << "═══════════════════════════════════════════════════════";
            qDebug() << "";
            m_currentDistance = START_DISTANCE;
            // Start timer in the main thread (Qt event loop thread)
            QMetaObject::invokeMethod(m_updateTimer, "start", Qt::QueuedConnection,
                                      Q_ARG(int, 500));  // UPDATE_INTERVAL = 500ms
            // Start camera streaming
            m_cameraStreamer->start();
        }
    } else if (oldGear == "R") {
        qDebug() << "[Mock] Reverse gear disengaged - stopping PDC simulation and camera";
        QMetaObject::invokeMethod(m_updateTimer, "stop", Qt::QueuedConnection);
        m_currentDistance = START_DISTANCE;
        // Stop camera streaming
        m_cameraStreamer->stop();
    }

    _reply(true);
}

void MockStubImpl::startSimulation()
{
    qDebug() << "";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "[Mock] Starting PDC simulation...";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "";

    // Reset state
    m_currentDistance = START_DISTANCE;

    // Set gear to Reverse
    QString oldGear = m_currentGear;
    m_currentGear = "R";

    qDebug() << "[Mock] Setting gear to REVERSE (R)";
    qDebug() << "[Mock] Initial distance:" << m_currentDistance << "cm";
    qDebug() << "[Mock] Target distance:" << m_targetDistance << "cm";
    qDebug() << "[Mock] Distance step:" << m_distanceStep << "cm every" << UPDATE_INTERVAL << "ms";
    qDebug() << "";

    // Broadcast initial state
    uint64_t timestamp = QDateTime::currentMSecsSinceEpoch();
    fireGearDistanceChangedEvent(m_currentGear.toStdString(),
                                  oldGear.toStdString(),
                                  static_cast<uint16_t>(m_currentDistance),
                                  timestamp);

    // Also broadcast vehicle state
    fireVehicleStateChangedEvent(m_currentGear.toStdString(),
                                  0,    // speed = 0
                                  80,   // battery = 80%
                                  timestamp);

    // Start timer
    m_updateTimer->start(UPDATE_INTERVAL);

    // Start camera streaming
    qDebug() << "[Mock] Starting camera stream...";
    m_cameraStreamer->start();
}

void MockStubImpl::stopSimulation()
{
    m_updateTimer->stop();
    m_cameraStreamer->stop();
    qDebug() << "[Mock] Simulation stopped";
}

void MockStubImpl::updateDistance()
{
    // Decrease distance
    m_currentDistance -= m_distanceStep;

    // Check if we reached target
    if (m_currentDistance <= m_targetDistance) {
        m_currentDistance = m_targetDistance;
        m_updateTimer->stop();

        qDebug() << "";
        qDebug() << "═══════════════════════════════════════════════════════";
        qDebug() << "[Mock] Simulation complete! Final distance:" << m_currentDistance << "cm";
        qDebug() << "[Mock] Restarting simulation in 3 seconds...";
        qDebug() << "═══════════════════════════════════════════════════════";
        qDebug() << "";

        // Restart simulation after 3 seconds
        QTimer::singleShot(3000, this, [this]() {
            m_currentDistance = START_DISTANCE;
            m_updateTimer->start(UPDATE_INTERVAL);
            qDebug() << "[Mock] Simulation restarted from" << m_currentDistance << "cm";
        });
    }

    // Determine zone for logging
    QString zone;
    if (m_currentDistance > 50) {
        zone = "SAFE (>50cm)";
    } else if (m_currentDistance > 30) {
        zone = "GREEN (30-50cm)";
    } else if (m_currentDistance > 15) {
        zone = "YELLOW (15-30cm)";
    } else {
        zone = "RED (<15cm)";
    }

    qDebug() << "[Mock] Distance:" << m_currentDistance << "cm - Zone:" << zone;

    // Broadcast gearDistanceChanged event
    uint64_t timestamp = QDateTime::currentMSecsSinceEpoch();
    fireGearDistanceChangedEvent(m_currentGear.toStdString(),
                                  m_currentGear.toStdString(),  // same gear
                                  static_cast<uint16_t>(m_currentDistance),
                                  timestamp);
}
