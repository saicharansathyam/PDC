#ifndef CAMERASTREAMER_H
#define CAMERASTREAMER_H

#include <QObject>
#include <gst/gst.h>

/**
 * @brief GStreamer-based camera streamer for PDC
 *
 * Streams video via UDP/RTP when activated.
 * - Desktop: Uses videotestsrc (test pattern)
 * - Raspberry Pi: Uses libcamerasrc (real camera)
 */
class CameraStreamer : public QObject
{
    Q_OBJECT

public:
    explicit CameraStreamer(QObject *parent = nullptr);
    ~CameraStreamer();

    /**
     * @brief Initialize GStreamer pipeline
     * @param targetHost IP address of the receiver (e.g., "127.0.0.1" for local test)
     * @param targetPort UDP port (default: 5000)
     * @param useTestSrc Use videotestsrc instead of real camera (for desktop testing)
     * @return true if initialization successful
     */
    bool initialize(const QString &targetHost = "127.0.0.1",
                    int targetPort = 5000,
                    bool useTestSrc = true);

    bool isStreaming() const { return m_isStreaming; }

public slots:
    void start();
    void stop();

signals:
    void streamingStarted();
    void streamingStopped();
    void error(const QString &message);

private:
    GstElement *m_pipeline;
    bool m_isStreaming;
    bool m_initialized;

    QString m_targetHost;
    int m_targetPort;
    bool m_useTestSrc;
};

#endif // CAMERASTREAMER_H
