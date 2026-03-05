#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>
#include <QFileInfo>
#include "VehicleControlClient.h"
#include "GstVideoReceiver.h"

int main(int argc, char *argv[])
{
    // ═══════════════════════════════════════════════════════════
    // Environment variables - use deployment paths if not already set
    // ═══════════════════════════════════════════════════════════
    // vsomeip app name
    if (qgetenv("VSOMEIP_APPLICATION_NAME").isEmpty()) {
        qputenv("VSOMEIP_APPLICATION_NAME", "PDCApp");
    }

    // vsomeip config - check if already set by environment, otherwise use default
    if (qgetenv("VSOMEIP_CONFIGURATION").isEmpty()) {
        QString appDir = QFileInfo("/proc/self/exe").absolutePath();
        qputenv("VSOMEIP_CONFIGURATION",
                (appDir + "/../../app/PDCApp/config/vsomeip_pdc.json").toLocal8Bit());
    }

    // commonapi config - check if already set by environment, otherwise use default
    if (qgetenv("COMMONAPI_CONFIG").isEmpty()) {
        QString appDir = QFileInfo("/proc/self/exe").absolutePath();
        qputenv("COMMONAPI_CONFIG",
                (appDir + "/../../app/PDCApp/config/commonapi_pdc.ini").toLocal8Bit());
    }

    // Wayland settings - only set if not already configured
    if (qgetenv("XDG_RUNTIME_DIR").isEmpty()) {
        qputenv("XDG_RUNTIME_DIR", "/run/user/0");
    }
    if (qgetenv("QT_QPA_PLATFORM").isEmpty()) {
        qputenv("QT_QPA_PLATFORM", "wayland");
    }
    if (qgetenv("QT_WAYLAND_DISABLE_WINDOWDECORATION").isEmpty()) {
        qputenv("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1");
    }
    if (qgetenv("WAYLAND_DISPLAY").isEmpty()) {
        qputenv("WAYLAND_DISPLAY", "wayland-1");
    }

    QGuiApplication app(argc, argv);
    app.setApplicationName("PDCApp");
    app.setApplicationVersion("1.0");
    app.setOrganizationName("SEA-ME");

    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "PDCApp Process Starting...";
    qDebug() << "Service: Park Distance Control Visualization";
    qDebug() << "═══════════════════════════════════════════════════════";
    qDebug() << "Environment Configuration:";
    qDebug() << "   VSOMEIP_CONFIGURATION:" << qgetenv("VSOMEIP_CONFIGURATION");
    qDebug() << "   COMMONAPI_CONFIG:" << qgetenv("COMMONAPI_CONFIG");
    qDebug() << "   QT_QPA_PLATFORM:" << qgetenv("QT_QPA_PLATFORM");
    qDebug() << "   WAYLAND_DISPLAY:" << qgetenv("WAYLAND_DISPLAY");
    qDebug() << "═══════════════════════════════════════════════════════";

    // ═══════════════════════════════════════════════════════════
    // VehicleControlClient (vsomeip) creation and initialization
    // ═══════════════════════════════════════════════════════════
    VehicleControlClient vehicleControlClient;
    vehicleControlClient.initialize();

    qDebug() << "";
    qDebug() << "VehicleControlClient initialized";
    qDebug() << "   - Service Available:" << vehicleControlClient.serviceAvailable();
    qDebug() << "   - Current Gear:" << vehicleControlClient.currentGear();
    qDebug() << "   - Current Distance:" << vehicleControlClient.currentDistance() << "cm";
    qDebug() << "";

    // ═══════════════════════════════════════════════════════════
    // GstVideoReceiver (camera stream) initialization
    // ═══════════════════════════════════════════════════════════
    GstVideoReceiver videoReceiver;
    if (videoReceiver.initialize(5000)) {
        qDebug() << "GstVideoReceiver initialized (listening on UDP port 5000)";
        // Start receiving immediately — HU_MainApp compositor shows PDCApp only when gear=R
        videoReceiver.start();
        qDebug() << "GstVideoReceiver started (awaiting stream on UDP port 5000)";
    } else {
        qWarning() << "Failed to initialize GstVideoReceiver";
    }

    qDebug() << "";

    // ═══════════════════════════════════════════════════════════
    // QML GUI Load
    // ═══════════════════════════════════════════════════════════
    QQmlApplicationEngine engine;

    // Register camera image provider
    engine.addImageProvider("camera", new CameraImageProvider(&videoReceiver));

    // Expose C++ objects to QML
    engine.rootContext()->setContextProperty("vehicleControlClient", &vehicleControlClient);
    engine.rootContext()->setContextProperty("videoReceiver", &videoReceiver);

    // Load QML file
    const QUrl url(QStringLiteral("qrc:/qml/PDCDisplay.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl) {
            qCritical() << "Failed to load QML file!";
            QCoreApplication::exit(-1);
        }
    }, Qt::QueuedConnection);
    engine.load(url);

    if (!engine.rootObjects().isEmpty()) {
        qDebug() << "QML GUI loaded: PDCDisplay.qml";
    }

    qDebug() << "";
    qDebug() << "PDCApp is running...";
    qDebug() << "═══════════════════════════════════════════════════════";

    return app.exec();
}
