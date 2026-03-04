#ifndef GSTVIDEORECEIVER_H
#define GSTVIDEORECEIVER_H

#include <QObject>
#include <QImage>
#include <QQuickImageProvider>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>

/**
 * @brief GStreamer-based video receiver for PDC camera feed
 *
 * Receives H.264 video stream via UDP/RTP and provides frames to QML.
 * Uses appsink to extract frames and converts to QImage for display.
 */
class GstVideoReceiver : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool receiving READ isReceiving NOTIFY receivingChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY frameReady)

public:
    explicit GstVideoReceiver(QObject *parent = nullptr);
    ~GstVideoReceiver();

    /**
     * @brief Initialize the GStreamer receive pipeline
     * @param port UDP port to listen on (default: 5000)
     * @return true if initialization successful
     */
    bool initialize(int port = 5000);

    bool isReceiving() const { return m_isReceiving; }
    bool hasFrame() const { return !m_currentFrame.isNull(); }

    /**
     * @brief Get the current video frame
     * @return Current frame as QImage (may be null if no frame received)
     */
    QImage currentFrame() const { return m_currentFrame; }

public slots:
    void start();
    void stop();

signals:
    void receivingChanged();
    void frameReady();
    void error(const QString &message);

private:
    static GstFlowReturn onNewSample(GstAppSink *sink, gpointer userData);
    void processFrame(GstSample *sample);

    GstElement *m_pipeline;
    GstElement *m_appsink;
    bool m_isReceiving;
    bool m_initialized;
    int m_port;

    QImage m_currentFrame;
};

/**
 * @brief QML Image Provider for video frames
 *
 * Provides video frames to QML Image elements via "image://camera/frame"
 */
class CameraImageProvider : public QQuickImageProvider
{
public:
    CameraImageProvider(GstVideoReceiver *receiver);

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    GstVideoReceiver *m_receiver;
};

#endif // GSTVIDEORECEIVER_H
