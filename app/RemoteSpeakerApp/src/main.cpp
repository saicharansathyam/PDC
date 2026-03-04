#include <QCoreApplication>
#include <QDebug>
#include <QFileInfo>
#include "VehicleControlClient.h"
#include "BeepController.h"

int main(int argc, char *argv[])
{
    // ═══════════════════════════════════════════════════════════
    // Environment variables
    // ═══════════════════════════════════════════════════════════
    if (qgetenv("VSOMEIP_APPLICATION_NAME").isEmpty()) {
        qputenv("VSOMEIP_APPLICATION_NAME", "RemoteSpeakerApp");
    }

    if (qgetenv("VSOMEIP_CONFIGURATION").isEmpty()) {
        QString appDir = QFileInfo("/proc/self/exe").absolutePath();
        qputenv("VSOMEIP_CONFIGURATION",
                (appDir + "/../../app/RemoteSpeakerApp/config/vsomeip_speaker.json").toLocal8Bit());
    }

    if (qgetenv("COMMONAPI_CONFIG").isEmpty()) {
        QString appDir = QFileInfo("/proc/self/exe").absolutePath();
        qputenv("COMMONAPI_CONFIG",
                (appDir + "/../../app/RemoteSpeakerApp/config/commonapi_speaker.ini").toLocal8Bit());
    }

    QCoreApplication app(argc, argv);
    app.setApplicationName("RemoteSpeakerApp");
    app.setApplicationVersion("1.0");

    qDebug() << "";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "RemoteSpeakerApp - PDC Beep Controller";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "";
    qDebug() << "Environment Configuration:";
    qDebug() << "   VSOMEIP_APPLICATION_NAME:" << qgetenv("VSOMEIP_APPLICATION_NAME");
    qDebug() << "   VSOMEIP_CONFIGURATION:" << qgetenv("VSOMEIP_CONFIGURATION");
    qDebug() << "   COMMONAPI_CONFIG:" << qgetenv("COMMONAPI_CONFIG");
    qDebug() << "";

    // ═══════════════════════════════════════════════════════════
    // Create components
    // ═══════════════════════════════════════════════════════════
    VehicleControlClient vehicleControlClient;
    BeepController beepController;

    // Configure speaker host (can be set via environment variable or command line args)
    // Default: 192.168.1.102 (Raspberry Pi speaker device)
    QString speakerHost = qgetenv("SPEAKER_HOST").isEmpty() ? "192.168.1.102" : qgetenv("SPEAKER_HOST");
    QString speakerUser = qgetenv("SPEAKER_USER").isEmpty() ? "seame" : qgetenv("SPEAKER_USER");
    beepController.setSpeakerHost(speakerHost);
    beepController.setSpeakerUser(speakerUser);

    // ═══════════════════════════════════════════════════════════
    // Connect signals
    // ═══════════════════════════════════════════════════════════
    QObject::connect(&vehicleControlClient, &VehicleControlClient::currentGearChanged,
                     &beepController, &BeepController::onGearChanged);

    QObject::connect(&vehicleControlClient, &VehicleControlClient::currentDistanceChanged,
                     &beepController, &BeepController::onDistanceChanged);

    qDebug() << "Signal connections established:";
    qDebug() << "   VehicleControlClient -> BeepController (gear, distance)";
    qDebug() << "";

    // ═══════════════════════════════════════════════════════════
    // Initialize vsomeip client
    // ═══════════════════════════════════════════════════════════
    vehicleControlClient.initialize();

    qDebug() << "";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "RemoteSpeakerApp running...";
    qDebug() << "";
    qDebug() << "Distance zones:";
    qDebug() << "   >50cm  : No beep (safe)";
    qDebug() << "   30-50cm: Slow beep (green zone)";
    qDebug() << "   15-30cm: Fast beep (yellow zone)";
    qDebug() << "   <15cm  : Continuous beep (red zone)";
    qDebug() << "";
    qDebug() << "Press Ctrl+C to stop.";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "";

    return app.exec();
}
