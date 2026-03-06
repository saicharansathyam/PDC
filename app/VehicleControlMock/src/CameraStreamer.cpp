#include "CameraStreamer.h"
#include <QDebug>

CameraStreamer::CameraStreamer(QObject *parent)
    : QObject(parent)
    , m_pipeline(nullptr)
    , m_isStreaming(false)
    , m_initialized(false)
    , m_targetHost("127.0.0.1")
    , m_targetPort(5000)
    , m_useTestSrc(true)
{
    // Initialize GStreamer (safe to call multiple times)
    gst_init(nullptr, nullptr);
}

CameraStreamer::~CameraStreamer()
{
    stop();
    if (m_pipeline) {
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
    }
}

bool CameraStreamer::initialize(const QString &targetHost, int targetPort, bool useTestSrc)
{
    m_targetHost = targetHost;
    m_targetPort = targetPort;
    m_useTestSrc = useTestSrc;

    // Build pipeline string based on source type
    QString pipelineStr;

    if (m_useTestSrc) {
        // Test source: GStreamer videotestsrc (works on any machine, no camera needed)
        // key-int-max=15 sends keyframe every 15 frames (0.5s at 30fps) for faster recovery
        pipelineStr = QString(
            "videotestsrc pattern=smpte ! "
            "video/x-raw,width=640,height=480,framerate=30/1 ! "
            "videoconvert ! "
            "x264enc tune=zerolatency bitrate=2000 speed-preset=ultrafast key-int-max=15 ! "
            "h264parse config-interval=1 ! "
            "rtph264pay pt=96 config-interval=1 ! "
            "udpsink host=%1 port=%2 sync=false async=false"
        ).arg(m_targetHost).arg(m_targetPort);
    } else {
        // Raspberry Pi: use libcamerasrc (for real camera)
        pipelineStr = QString(
            "libcamerasrc ! "
            "video/x-raw,width=1280,height=720,framerate=30/1 ! "
            "videoconvert ! "
            "x264enc tune=zerolatency bitrate=4000 speed-preset=ultrafast ! "
            "h264parse config-interval=1 ! "
            "rtph264pay pt=96 ! "
            "udpsink host=%1 port=%2 sync=false async=false"
        ).arg(m_targetHost).arg(m_targetPort);
    }

    qDebug() << "[CameraStreamer] Creating pipeline:";
    qDebug() << "   Source:" << (m_useTestSrc ? "videotestsrc (test)" : "libcamerasrc (camera)");
    qDebug() << "   Target:" << m_targetHost << ":" << m_targetPort;

    // Parse and create pipeline
    GError *error = nullptr;
    m_pipeline = gst_parse_launch(pipelineStr.toUtf8().constData(), &error);

    if (error) {
        QString errMsg = QString("Failed to create pipeline: %1").arg(error->message);
        qCritical() << "[CameraStreamer]" << errMsg;
        g_error_free(error);
        emit this->error(errMsg);
        return false;
    }

    if (!m_pipeline) {
        QString errMsg = "Failed to create pipeline (null)";
        qCritical() << "[CameraStreamer]" << errMsg;
        emit this->error(errMsg);
        return false;
    }

    m_initialized = true;
    qDebug() << "[CameraStreamer] Pipeline created successfully";
    return true;
}

void CameraStreamer::start()
{
    if (!m_initialized) {
        qWarning() << "[CameraStreamer] Not initialized, cannot start";
        return;
    }

    if (m_isStreaming) {
        qDebug() << "[CameraStreamer] Already streaming";
        return;
    }

    qDebug() << "[CameraStreamer] Starting stream to" << m_targetHost << ":" << m_targetPort;

    GstStateChangeReturn ret = gst_element_set_state(m_pipeline, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) {
        QString errMsg = "Failed to start pipeline";
        qCritical() << "[CameraStreamer]" << errMsg;
        emit error(errMsg);
        return;
    }

    m_isStreaming = true;
    qDebug() << "[CameraStreamer] Stream started!";
    emit streamingStarted();
}

void CameraStreamer::stop()
{
    if (!m_isStreaming) {
        return;
    }

    qDebug() << "[CameraStreamer] Stopping stream...";

    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
    }

    m_isStreaming = false;
    qDebug() << "[CameraStreamer] Stream stopped";
    emit streamingStopped();
}
