#include <QCoreApplication>
#include <QTimer>
#include <QDebug>
#include <CommonAPI/CommonAPI.hpp>
#include <pigpio.h>

#include "PiRacerController.h"
#include "GamepadHandler.h"
#include "VehicleControlStubImpl.h"

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    app.setApplicationName("VehicleControlECU");
    app.setApplicationVersion("1.0");
    app.setOrganizationName("SEA-ME");
    
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "VehicleControlECU (ECU1) Starting...";
    qDebug() << "Service: VehicleControl (PiRacer Hardware Control)";
    qDebug() << "═══════════════════════════════════════════════════════";
    
    // ═══════════════════════════════════════════════════════
    // 1. Initialize pigpio (required for I2C/PWM)
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "🔧 Initializing GPIO library...";
    bool gpioOk = (gpioInitialise() >= 0);
    if (!gpioOk) {
        qWarning() << "⚠️  pigpio init failed - motor/servo control unavailable";
        qWarning() << "   CAN bus (ultrasonic distance) and vsomeip service will still run";
    } else {
        qDebug() << "✅ GPIO library initialized";
    }

    // ═══════════════════════════════════════════════════════
    // 2. Initialize PiRacer Hardware Controller
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "🚗 Initializing PiRacer hardware...";
    PiRacerController piracerController;
    piracerController.initialize();  // Non-fatal: CAN still works if I2C fails
    
    // ═══════════════════════════════════════════════════════
    // 3. Initialize Gamepad Handler
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "🎮 Initializing gamepad...";
    GamepadHandler gamepadHandler;
    if (gamepadHandler.initialize()) {
        // Connect gamepad to PiRacer controller
        QObject::connect(&gamepadHandler, &GamepadHandler::gearChangeRequested,
                        &piracerController, &PiRacerController::setGearPosition);
        
        QObject::connect(&gamepadHandler, &GamepadHandler::steeringChanged,
                        &piracerController, &PiRacerController::setSteeringPercent);
        
        QObject::connect(&gamepadHandler, &GamepadHandler::throttleChanged,
                        &piracerController, &PiRacerController::setThrottlePercent);
        
        gamepadHandler.start();
        qDebug() << "✅ Gamepad controls active";
        qDebug() << "   A = Drive, B = Park, X = Neutral, Y = Reverse";
        qDebug() << "   Left Stick = Steering, Right Stick = Throttle";
    } else {
        qWarning() << "⚠️  Gamepad not found - will use vsomeip RPC only";
    }
    
    // ═══════════════════════════════════════════════════════
    // 4. Initialize CommonAPI Runtime
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "🌐 Initializing vsomeip service...";
    
    std::shared_ptr<CommonAPI::Runtime> runtime = CommonAPI::Runtime::get();
    if (!runtime) {
        qCritical() << "❌ Failed to get CommonAPI Runtime!";
        gpioTerminate();
        return -1;
    }
    
    // ═══════════════════════════════════════════════════════
    // 5. Create and Register VehicleControl Service
    // ═══════════════════════════════════════════════════════
    std::shared_ptr<VehicleControlStubImpl> vehicleControlService =
        std::make_shared<VehicleControlStubImpl>(&piracerController);
    
    const std::string domain = "local";
    const std::string instance = "vehiclecontrol.VehicleControl";
    
    bool registered = runtime->registerService(domain, instance, vehicleControlService);
    
    if (!registered) {
        qCritical() << "❌ Failed to register VehicleControl service!";
        gpioTerminate();
        return -1;
    }
    
    qDebug() << "✅ VehicleControl service registered";
    qDebug() << "   Domain:" << QString::fromStdString(domain);
    qDebug() << "   Instance:" << QString::fromStdString(instance);
    
    // ═══════════════════════════════════════════════════════
    // 6. Setup Periodic Vehicle State Broadcast
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "📡 Setting up periodic state broadcast...";
    
    QTimer* stateTimer = new QTimer(&app);
    QObject::connect(stateTimer, &QTimer::timeout, [&piracerController]() {
        QString gear = piracerController.getCurrentGear();
        uint16_t speed = piracerController.getCurrentSpeed();
        uint8_t battery = piracerController.getBatteryLevel();
        
        emit piracerController.vehicleStateChanged(gear, speed, battery);
    });
    stateTimer->start(100);  // 10Hz update rate
    
    qDebug() << "✅ Broadcasting vehicle state at 10Hz";
    
    // ═══════════════════════════════════════════════════════
    // 7. Ready to Run
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "✅ VehicleControlECU is running!";
    qDebug() << "";
    qDebug() << "📌 Current State:";
    qDebug() << "   - Gear:" << piracerController.getCurrentGear();
    qDebug() << "   - Speed:" << piracerController.getCurrentSpeed() << "cm/s";
    qDebug() << "   - Battery:" << piracerController.getBatteryLevel() << "%";
    qDebug() << "";
    qDebug() << "🎮 Gamepad Controls:";
    qDebug() << "   A = Drive   B = Park   X = Neutral   Y = Reverse";
    qDebug() << "   Left Analog = Steering   Right Analog Y = Throttle";
    qDebug() << "";
    qDebug() << "Press Ctrl+C to stop...";
    qDebug() << "═══════════════════════════════════════════════════════";
    
    // ═══════════════════════════════════════════════════════
    // Run Event Loop
    // ═══════════════════════════════════════════════════════
    int result = app.exec();
    
    // ═══════════════════════════════════════════════════════
    // Cleanup
    // ═══════════════════════════════════════════════════════
    qDebug() << "";
    qDebug() << "Shutting down...";
    gamepadHandler.stop();
    gpioTerminate();
    qDebug() << "✅ Cleanup complete";
    
    return result;
}
