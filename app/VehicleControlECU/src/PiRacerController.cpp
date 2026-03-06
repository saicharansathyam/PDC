#include "PiRacerController.h"
#include <QDebug>
#include <QThread>
#include <cmath>

PiRacerController::PiRacerController(QObject *parent)
    : QObject(parent)
    , m_currentGear("P")
    , m_currentSpeed(0)
    , m_currentDistance(200)  // Default to max distance (no obstacle)
    , m_currentThrottle(0.0f)
{
}

PiRacerController::~PiRacerController()
{
    // Stop motors before cleanup
    if (m_throttleController) {
        setThrottlePercent(0.0f);
    }
}

bool PiRacerController::initialize()
{
    // Initialize I2C hardware (steering/throttle/battery) — non-fatal if pigpio unavailable
    try {
        m_steeringController = std::make_unique<PCA9685>(1, 0x40);
        m_steeringController->setPWMFreq(PWM_FREQ_50HZ);
        m_throttleController = std::make_unique<PCA9685>(1, 0x60);
        m_throttleController->setPWMFreq(PWM_FREQ_50HZ);
        m_batteryMonitor = std::make_unique<BatteryMonitor>();
        m_batteryMonitor->initialize();
        qDebug() << "✅ PiRacer I2C hardware initialized (steering/throttle/battery)";
        warmUp();
    } catch (const std::exception& e) {
        qWarning() << "⚠️  PiRacer I2C hardware unavailable:" << e.what();
        qWarning() << "   Motor/servo control disabled - CAN distance data still active";
        m_steeringController.reset();
        m_throttleController.reset();
        m_batteryMonitor.reset();
    }

    // Initialize CAN interface separately — always attempted regardless of I2C result
    m_canInterface = std::make_unique<CANInterface>();
    if (m_canInterface->initialize("can0")) {
        qDebug() << "✅ CAN interface initialized (ultrasonic distance active)";
        connect(m_canInterface.get(), &CANInterface::speedDataReceived,
                this, &PiRacerController::onSpeedDataReceived);
        connect(m_canInterface.get(), &CANInterface::distanceDataReceived,
                this, &PiRacerController::onDistanceDataReceived);
    } else {
        qWarning() << "⚠️  CAN interface failed - speed/distance will be unavailable";
    }

    return true;
}

void PiRacerController::setGearPosition(const QString& gear)
{
    QString oldGear = m_currentGear;

    if (gear != oldGear) {
        m_currentGear = gear;
        qDebug() << "⚙️  Gear changed:" << oldGear << "→" << gear;

        // Stop throttle when changing gears
        setThrottlePercent(0.0f);

        emit gearDistanceChanged(gear, oldGear, m_currentDistance);
    }
}

void PiRacerController::setSteeringPercent(float percent)
{
    if (!m_steeringController) return;
    
    // Clamp to [-1.0, 1.0]
    percent = std::clamp(percent, -1.0f, 1.0f);
    
    float dutyCycle = get50HzDutyCycleFromPercent(-percent);
    int rawValue = static_cast<int>(PWM_MAX_RAW_VALUE * (dutyCycle / PWM_WAVELENGTH_50HZ));
    
    m_steeringController->setPWM(PWM_STEERING_CHANNEL, 0, rawValue);
}

void PiRacerController::setThrottlePercent(float percent)
{
    if (!m_throttleController) return;
    
    // Clamp to [-1.0, 1.0]
    percent = std::clamp(percent, -1.0f, 1.0f);
    m_currentThrottle = percent;
    
    // Only allow movement in appropriate gears
    if (m_currentGear == "P" || m_currentGear == "N") {
        percent = 0.0f;
    } else if (m_currentGear == "D" && percent < 0.0f) {
        percent = 0.0f;  // No reverse in Drive
    } else if (m_currentGear == "R" && percent > 0.0f) {
        percent = 0.0f;  // No forward in Reverse
    }
    
    // Set motor direction
    if (percent > 0) {
        // Forward
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_LEFT_MOTOR_IN_1, 0, PWM_MAX_RAW_VALUE);
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_LEFT_MOTOR_IN_2, 0, 0);
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_RIGHT_MOTOR_IN_1, 0, 0);
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_RIGHT_MOTOR_IN_2, 0, PWM_MAX_RAW_VALUE);
    } else if (percent < 0) {
        // Backward
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_LEFT_MOTOR_IN_1, 0, 0);
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_LEFT_MOTOR_IN_2, 0, PWM_MAX_RAW_VALUE);
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_RIGHT_MOTOR_IN_1, 0, PWM_MAX_RAW_VALUE);
        m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_RIGHT_MOTOR_IN_2, 0, 0);
    }
    
    // Set motor speed
    int pwmRawValue = PWM_MAX_RAW_VALUE * std::abs(percent);
    m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_LEFT_MOTOR_IN_PWM, 0, pwmRawValue);
    m_throttleController->setPWM(PWM_THROTTLE_CHANNEL_RIGHT_MOTOR_IN_PWM, 0, pwmRawValue);
    
    // Speed is now updated from CAN (not calculated from PWM)
}

void PiRacerController::onSpeedDataReceived(float speedCms)
{
    // Store speed in cm/s (no conversion)
    m_currentSpeed = static_cast<uint16_t>(speedCms);
}

void PiRacerController::onDistanceDataReceived(float distanceCm)
{
    // Store distance in cm
    uint16_t newDistance = static_cast<uint16_t>(distanceCm);

    // Always emit when in Reverse gear (for PDC continuous updates)
    // or when distance changes significantly
    if (m_currentGear == "R" || qAbs(static_cast<int>(newDistance) - static_cast<int>(m_currentDistance)) > 2) {
        m_currentDistance = newDistance;
        // Emit with current gear so PDCApp/RemoteSpeaker can receive continuous updates
        emit gearDistanceChanged(m_currentGear, m_currentGear, m_currentDistance);
    } else {
        m_currentDistance = newDistance;
    }
}

uint8_t PiRacerController::getBatteryLevel() const
{
    if (m_batteryMonitor) {
        return m_batteryMonitor->getPercentage();
    }
    return 0;
}

float PiRacerController::get50HzDutyCycleFromPercent(float value)
{
    return 0.0015f + (value * 0.001f);
}

void PiRacerController::warmUp()
{
    qDebug() << "🔧 Warming up motors...";
    setSteeringPercent(0.0f);
    setThrottlePercent(0.0f);
    QThread::msleep(1000);
    qDebug() << "✅ Warm-up complete";
}
