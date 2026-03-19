#include "CANInterface.h"
#include <QDebug>
#include <QProcess>

CANInterface::CANInterface(QObject *parent)
    : QObject(parent)
    , m_canSocket(-1)
    , m_isConnected(false)
    , m_receiveTimer(new QTimer(this))
    , m_currentSpeedCms(0.0f)
    , m_currentDistanceCm(0.0f)
    , m_emaDistance(0.0f)
    , m_distanceFilterInitialized(false)
{
    // Timer to check CAN messages every 10ms
    m_receiveTimer->setSingleShot(false);
    m_receiveTimer->setInterval(10);
    connect(m_receiveTimer, &QTimer::timeout, this, &CANInterface::receiveCANMessages);
}

CANInterface::~CANInterface()
{
    shutdown();
}

bool CANInterface::setupCANInterface(const QString &interface)
{
    QProcess process;

    // Set CAN interface down
    process.start("ip", QStringList() << "link" << "set" << interface << "down");
    process.waitForFinished();

    // Set bitrate to 1000kbps (same as Arduino) — non-fatal for virtual interfaces (vcan)
    process.start("ip", QStringList() << "link" << "set" << interface
                                      << "type" << "can" << "bitrate" << "1000000");
    process.waitForFinished();

    if (process.exitCode() != 0) {
        qWarning() << "⚠️  Could not set CAN bitrate (OK for virtual interfaces):"
                   << QString(process.readAllStandardError()).trimmed();
    }

    // Set CAN interface up
    process.start("ip", QStringList() << "link" << "set" << interface << "up");
    process.waitForFinished();

    if (process.exitCode() != 0) {
        QString error = QString("Failed to activate CAN interface: %1")
                       .arg(QString(process.readAllStandardError()));
        qCritical() << error;
        emit canError(error);
        return false;
    }

    qDebug() << "✅ CAN interface" << interface << "configured (1000kbps)";
    return true;
}

bool CANInterface::initialize(const QString &interface)
{
    if (m_isConnected) {
        qWarning() << "CAN already connected";
        return true;
    }

    m_interfaceName = interface;

    // Setup CAN interface (bitrate, up)
    if (!setupCANInterface(interface)) {
        return false;
    }

    // Create socket
    m_canSocket = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    if (m_canSocket < 0) {
        QString error = "Failed to create CAN socket";
        qCritical() << error;
        emit canError(error);
        return false;
    }

    // Get interface index
    struct ifreq ifr;
    strcpy(ifr.ifr_name, interface.toLocal8Bit().data());

    if (ioctl(m_canSocket, SIOCGIFINDEX, &ifr) < 0) {
        QString error = "Failed to get CAN interface index";
        qCritical() << error;
        emit canError(error);
        close(m_canSocket);
        m_canSocket = -1;
        return false;
    }

    // Bind socket to CAN interface
    struct sockaddr_can addr;
    addr.can_family = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;

    if (bind(m_canSocket, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        QString error = "Failed to bind CAN socket";
        qCritical() << error;
        emit canError(error);
        close(m_canSocket);
        m_canSocket = -1;
        return false;
    }

    m_isConnected = true;
    m_receiveTimer->start();

    qDebug() << "✅ CAN interface connected and receiving";
    return true;
}

void CANInterface::shutdown()
{
    if (m_receiveTimer->isActive()) {
        m_receiveTimer->stop();
    }

    if (m_canSocket >= 0) {
        close(m_canSocket);
        m_canSocket = -1;
    }

    m_isConnected = false;
}

void CANInterface::receiveCANMessages()
{
    if (m_canSocket < 0 || !m_isConnected) {
        return;
    }

    struct can_frame frame;
    fd_set readfds;
    struct timeval timeout;

    FD_ZERO(&readfds);
    FD_SET(m_canSocket, &readfds);
    timeout.tv_sec = 0;
    timeout.tv_usec = 1000;  // 1ms timeout

    int result = select(m_canSocket + 1, &readfds, nullptr, nullptr, &timeout);

    if (result > 0 && FD_ISSET(m_canSocket, &readfds)) {
        ssize_t bytesRead = read(m_canSocket, &frame, sizeof(frame));

        if (bytesRead == sizeof(frame)) {
            processCANFrame(frame);
        }
    }
}

void CANInterface::processCANFrame(const struct can_frame &frame)
{
    if (frame.can_id == ARDUINO_SPEED_ID) {
        // Parse speed data (bytes 0-2) - UNCHANGED
        float speedCms = parseSpeedData(frame.data);

        // NEW: Parse distance data (bytes 3-6)
        float rawDistance = parseDistanceData(frame.data);
        float filteredDistance = filterDistance(rawDistance);

        {
            QMutexLocker locker(&m_dataMutex);
            m_currentSpeedCms = speedCms;
            m_currentDistanceCm = filteredDistance;  // NEW: Store filtered distance
        }

        // Debug log
        static int logCount = 0;
        if (++logCount % 100 == 0) {  // Every 1 second (10ms * 100)
            qDebug() << "📡 CAN Data:"
                     << "Speed:" << speedCms << "cm/s"
                     << "| Distance (raw):" << rawDistance << "cm"
                     << "| Distance (filtered):" << filteredDistance << "cm";
        }

        emit speedDataReceived(speedCms);
        emit distanceDataReceived(filteredDistance);  // NEW: Emit filtered distance
    }
}

float CANInterface::parseSpeedData(const uint8_t *data)
{
    // Parse Arduino speed format:
    // data[0] = int1_spd / 256
    // data[1] = int1_spd % 256
    // data[2] = int2_spd (decimal part * 100)
    int int1_spd = (data[0] << 8) | data[1];
    int int2_spd = data[2];
    
    float speedCms = int1_spd + (int2_spd / 100.0f);
    return qMax(0.0f, speedCms);
}

float CANInterface::getCurrentSpeedCms() const
{
    QMutexLocker locker(&m_dataMutex);
    return m_currentSpeedCms;
}

float CANInterface::getCurrentSpeedKmh() const
{
    QMutexLocker locker(&m_dataMutex);
    // Convert cm/s to km/h: (cm/s * 3600) / 100000 = cm/s * 0.036
    return m_currentSpeedCms * 0.036f;
}

// ============================================================================
// NEW: Distance Parsing and Filtering Methods
// ============================================================================

float CANInterface::parseDistanceData(const uint8_t *data)
{
    // Parse Arduino distance format from bytes 3-6 (float, 4 bytes, little-endian)
    // Arduino sends: distanceData.bytes[0-3] in bytes 3-6 of CAN message
    union {
        float value;
        uint8_t bytes[4];
    } distanceUnion;

    // Copy bytes 3-6 to float union
    memcpy(distanceUnion.bytes, &data[3], 4);

    return distanceUnion.value;
}

float CANInterface::filterDistance(float rawDistance)
{
    // Step 1: Validate reading (check range and special values)
    if (!isValidDistance(rawDistance)) {
        qDebug() << "⚠️  Invalid distance reading:" << rawDistance << "cm (ignored)";
        return m_currentDistanceCm;  // Return last valid filtered value
    }

    // Step 2: Initialize filter on first valid reading
    if (!m_distanceFilterInitialized) {
        m_emaDistance = rawDistance;
        m_currentDistanceCm = rawDistance;
        m_distanceFilterInitialized = true;
        qDebug() << "🔧 Distance filter initialized with:" << rawDistance << "cm";
        return rawDistance;
    }

    // Step 3: Apply EMA filter (Exponential Moving Average)
    // Formula: filtered = alpha * new + (1 - alpha) * old
    m_emaDistance = DISTANCE_EMA_ALPHA * rawDistance + (1.0f - DISTANCE_EMA_ALPHA) * m_emaDistance;

    return m_emaDistance;
}

bool CANInterface::isValidDistance(float distance) const
{
    // Check for Arduino sensor failure flag (-1.0)
    if (distance < 0.0f) {
        return false;
    }

    // Check physical sensor limits (HC-SR04: 2cm - 400cm, but we limit to 200cm for PDC)
    if (distance < DISTANCE_MIN_VALID || distance > DISTANCE_MAX_VALID) {
        return false;
    }

    return true;
}

float CANInterface::getCurrentDistanceCm() const
{
    QMutexLocker locker(&m_dataMutex);
    return m_currentDistanceCm;
}
