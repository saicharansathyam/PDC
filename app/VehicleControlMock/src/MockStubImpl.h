#ifndef MOCKSTUBIMPL_H
#define MOCKSTUBIMPL_H

#include <CommonAPI/CommonAPI.hpp>
#include <v1/vehiclecontrol/VehicleControlStubDefault.hpp>
#include <QObject>
#include <QTimer>
#include "CameraStreamer.h"

using namespace v1::vehiclecontrol;

/**
 * @brief Mock VehicleControl service for testing PDCApp and RemoteSpeakerApp
 *
 * Simulates:
 * - Gear set to "R" (Reverse)
 * - Distance decreasing from 60cm to 5cm slowly
 * - Broadcasts gearDistanceChanged events
 */
class MockStubImpl : public QObject, public VehicleControlStubDefault
{
    Q_OBJECT

public:
    explicit MockStubImpl(QObject *parent = nullptr);
    virtual ~MockStubImpl();

    // Override RPC method from FIDL
    virtual void setGearPosition(const std::shared_ptr<CommonAPI::ClientId> _client,
                                 std::string _gear,
                                 setGearPositionReply_t _reply) override;

    // Start the mock simulation
    void startSimulation();
    void stopSimulation();

private slots:
    void updateDistance();

private:
    QTimer* m_updateTimer;
    CameraStreamer* m_cameraStreamer;

    // Current mock state
    QString m_currentGear;
    int m_currentDistance;
    int m_targetDistance;
    int m_distanceStep;

    // Simulation parameters
    static const int START_DISTANCE = 60;    // Start at 60cm
    static const int END_DISTANCE = 5;       // End at 5cm
    static const int UPDATE_INTERVAL = 500;  // Update every 500ms
    static const int DISTANCE_STEP = 2;      // Decrease 2cm per update
};

#endif // MOCKSTUBIMPL_H
