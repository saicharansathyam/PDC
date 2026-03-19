#include "VehicleControlClient.h"
#include <QDebug>
#include <QDateTime>
#include <functional>

VehicleControlClient::VehicleControlClient(QObject *parent)
    : QObject(parent)
    , m_currentGear("P")
    , m_currentSpeed(0)
    , m_batteryLevel(0)
    , m_currentDistance(200)
    , m_isConnected(false)
{
    qDebug() << "VehicleControlClient created";
}

VehicleControlClient::~VehicleControlClient()
{
    disconnectFromService();
    qDebug() << "VehicleControlClient destroyed";
}

void VehicleControlClient::connectToService()
{
    qDebug() << "🔌 Connecting to VehicleControl service...";
    
    // Get CommonAPI runtime
    m_runtime = CommonAPI::Runtime::get();
    if (!m_runtime) {
        qCritical() << "❌ Failed to get CommonAPI runtime!";
        emit connectedChanged(false);
        return;
    }
    
    // Build proxy
    const std::string domain = "local";
    const std::string instance = "vehiclecontrol.VehicleControl";
    const std::string connection = "GearApp_vc";
    
    m_proxy = m_runtime->buildProxy<VehicleControlProxy>(domain, instance, connection);
    
    if (!m_proxy) {
        qCritical() << "❌ Failed to build VehicleControl proxy!";
        emit connectedChanged(false);
        return;
    }
    
    qDebug() << "✅ Proxy created successfully";
    
    // Subscribe to availability status
    m_proxy->getProxyStatusEvent().subscribe(
        std::bind(&VehicleControlClient::onAvailabilityChanged, this, std::placeholders::_1)
    );
    
    // Setup event subscriptions
    setupEventSubscriptions();
    
    qDebug() << "✅ Connected to VehicleControl service";
    qDebug() << "   Domain:" << QString::fromStdString(domain);
    qDebug() << "   Instance:" << QString::fromStdString(instance);
}

void VehicleControlClient::disconnectFromService()
{
    if (m_proxy) {
        qDebug() << "🔌 Disconnecting from VehicleControl service...";
        m_proxy.reset();
        m_isConnected = false;
        emit connectedChanged(false);
    }
}

void VehicleControlClient::setupEventSubscriptions()
{
    if (!m_proxy) {
        qWarning() << "Cannot setup subscriptions: proxy is null";
        return;
    }
    
    qDebug() << "📡 Subscribing to VehicleControl events...";
    
    // Subscribe to gearDistanceChanged event
    m_proxy->getGearDistanceChangedEvent().subscribe(
        [this](std::string newGear, std::string oldGear, uint16_t distance, uint64_t timestamp) {
            this->onGearDistanceChanged(newGear, oldGear, distance, timestamp);
        }
    );
    
    // Subscribe to vehicleStateChanged event
    m_proxy->getVehicleStateChangedEvent().subscribe(
        [this](std::string gear, uint16_t speed, uint8_t battery, uint64_t timestamp) {
            this->onVehicleStateChanged(gear, speed, battery, timestamp);
        }
    );
    
    qDebug() << "✅ Event subscriptions setup complete";
}

void VehicleControlClient::requestGearChange(const QString& gear)
{
    if (!m_proxy) {
        qWarning() << "❌ Cannot request gear change: not connected to service";
        emit gearChangeFailed("Not connected to service");
        return;
    }
    
    if (!m_isConnected) {
        qWarning() << "❌ Cannot request gear change: service not available";
        emit gearChangeFailed("Service not available");
        return;
    }
    
    qDebug() << "📞 [RPC] Requesting gear change to:" << gear;
    
    // Call setGearPosition RPC
    CommonAPI::CallStatus callStatus;
    bool success = false;
    
    m_proxy->setGearPosition(
        gear.toStdString(),
        callStatus,
        success
    );
    
    if (callStatus != CommonAPI::CallStatus::SUCCESS) {
        qCritical() << "❌ RPC call failed! CallStatus:" << static_cast<int>(callStatus);
        emit gearChangeFailed("RPC call failed");
        return;
    }
    
    if (!success) {
        qWarning() << "❌ Gear change rejected by service";
        emit gearChangeFailed("Rejected by service");
        return;
    }
    
    qDebug() << "✅ Gear change request accepted:" << gear;
    emit gearChangeSuccess(gear);
}

void VehicleControlClient::onGearDistanceChanged(std::string newGear, std::string oldGear, uint16_t distance, uint64_t timestamp)
{
    QString qNewGear = QString::fromStdString(newGear);
    QString qOldGear = QString::fromStdString(oldGear);

    // Update gear if changed
    if (m_currentGear != qNewGear) {
        m_currentGear = qNewGear;
        emit currentGearChanged(m_currentGear);
        qDebug() << "📡 [Event] gearDistanceChanged - Gear:"
                 << qOldGear << "→" << qNewGear;
    }

    // Update distance
    if (m_currentDistance != static_cast<int>(distance)) {
        m_currentDistance = static_cast<int>(distance);
        emit currentDistanceChanged(m_currentDistance);
    }
}

void VehicleControlClient::onVehicleStateChanged(std::string gear, uint16_t speed, uint8_t battery, uint64_t timestamp)
{
    QString qGear = QString::fromStdString(gear);
    
    // Update state
    bool changed = false;
    
    if (m_currentGear != qGear) {
        m_currentGear = qGear;
        emit currentGearChanged(m_currentGear);
        changed = true;
    }
    
    if (m_currentSpeed != speed) {
        m_currentSpeed = speed;
        emit currentSpeedChanged(m_currentSpeed);
        changed = true;
    }
    
    if (m_batteryLevel != battery) {
        m_batteryLevel = battery;
        emit batteryLevelChanged(m_batteryLevel);
        changed = true;
    }
    
    // Log periodically (every 10 updates = 1 second at 10Hz)
    static int updateCount = 0;
    if (changed || (++updateCount % 10 == 0)) {
        qDebug() << "📡 [Event] vehicleStateChanged:"
                 << "Gear:" << m_currentGear
                 << "Speed:" << m_currentSpeed << "km/h"
                 << "Battery:" << m_batteryLevel << "%";
    }
}

void VehicleControlClient::onAvailabilityChanged(CommonAPI::AvailabilityStatus status)
{
    bool wasConnected = m_isConnected;
    m_isConnected = (status == CommonAPI::AvailabilityStatus::AVAILABLE);
    
    if (m_isConnected != wasConnected) {
        qDebug() << "🔗 Service availability changed:"
                 << (m_isConnected ? "AVAILABLE" : "NOT AVAILABLE");
        emit connectedChanged(m_isConnected);
    }
    
    if (m_isConnected) {
        qDebug() << "✅ VehicleControl service is now available!";
    } else {
        qWarning() << "⚠️  VehicleControl service is not available";
    }
}
