#include "GstVideoReceiver.h"
#include <QDebug>
#include <gst/video/video.h>

GstVideoReceiver::GstVideoReceiver(QObject *parent)
    : QObject(parent)
    , m_pipeline(nullptr)
    , m_appsink(nullptr)
    , m_isReceiving(false)
    , m_initialized(false)
    , m_port(5000)
{
    // Initialize GStreamer
    gst_init(nullptr, nullptr);
}

GstVideoReceiver::~GstVideoReceiver()
{
    stop();
    if (m_pipeline) {
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
    }
}

bool GstVideoReceiver::initialize(int port)
{
    m_port = port;

    // Runtime NVIDIA decoder detection: use nvv4l2decoder on Jetson if available,
    // fall back to avdec_h264 (software) on desktop.
    QString decoder;
    QString converter;
    GstElementFactory *nvFactory = gst_element_factory_find("nvv4l2decoder");
    if (nvFactory) {
        decoder = "nvv4l2decoder";
        // nvvidconv cannot output BGRA directly — cap it to RGBA, then videoconvert does RGBA→BGRA
        converter = "nvvidconv ! video/x-raw,format=RGBA ! videoconvert";
        gst_object_unref(nvFactory);
        qDebug() << "[GstVideoReceiver] Using NVIDIA hardware decoder (nvv4l2decoder)";
    } else {
        decoder = "avdec_h264";
        converter = "videoconvert";
        qDebug() << "[GstVideoReceiver] Using software decoder (avdec_h264)";
    }

    // Build receive pipeline
    // UDP source -> RTP depay -> H264 parse -> decode -> convert -> appsink
    QString pipelineStr = QString(
        "udpsrc port=%1 buffer-size=2097152 caps=\"application/x-rtp,encoding-name=H264,payload=96\" ! "
        "rtpjitterbuffer latency=100 ! "
        "rtph264depay ! "
        "h264parse ! "
        "%2 ! "
        "%3 ! "
        "video/x-raw,format=BGRA ! "
        "appsink name=sink emit-signals=true sync=false max-buffers=1 drop=true"
    ).arg(m_port).arg(decoder).arg(converter);

    qDebug() << "[GstVideoReceiver] Creating pipeline for port" << m_port;

    GError *error = nullptr;
    m_pipeline = gst_parse_launch(pipelineStr.toUtf8().constData(), &error);

    if (error) {
        QString errMsg = QString("Failed to create pipeline: %1").arg(error->message);
        qCritical() << "[GstVideoReceiver]" << errMsg;
        g_error_free(error);
        emit this->error(errMsg);
        return false;
    }

    if (!m_pipeline) {
        QString errMsg = "Failed to create pipeline (null)";
        qCritical() << "[GstVideoReceiver]" << errMsg;
        emit this->error(errMsg);
        return false;
    }

    // Get appsink element
    m_appsink = gst_bin_get_by_name(GST_BIN(m_pipeline), "sink");
    if (!m_appsink) {
        QString errMsg = "Failed to get appsink element";
        qCritical() << "[GstVideoReceiver]" << errMsg;
        emit this->error(errMsg);
        return false;
    }

    // Configure appsink
    g_object_set(m_appsink,
                 "emit-signals", TRUE,
                 "sync", FALSE,
                 nullptr);

    // Connect new-sample signal
    g_signal_connect(m_appsink, "new-sample", G_CALLBACK(onNewSample), this);

    m_initialized = true;
    qDebug() << "[GstVideoReceiver] Pipeline created successfully, listening on port" << m_port;
    return true;
}

void GstVideoReceiver::start()
{
    if (!m_initialized) {
        qWarning() << "[GstVideoReceiver] Not initialized, cannot start";
        return;
    }

    if (m_isReceiving) {
        qDebug() << "[GstVideoReceiver] Already receiving";
        return;
    }

    qDebug() << "[GstVideoReceiver] Starting receiver on port" << m_port;

    GstStateChangeReturn ret = gst_element_set_state(m_pipeline, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) {
        QString errMsg = "Failed to start pipeline";
        qCritical() << "[GstVideoReceiver]" << errMsg;
        emit error(errMsg);
        return;
    }

    m_isReceiving = true;
    qDebug() << "[GstVideoReceiver] Receiver started!";
    emit receivingChanged();
}

void GstVideoReceiver::stop()
{
    if (!m_isReceiving) {
        return;
    }

    qDebug() << "[GstVideoReceiver] Stopping receiver...";

    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
    }

    m_isReceiving = false;
    m_currentFrame = QImage();
    qDebug() << "[GstVideoReceiver] Receiver stopped";
    emit receivingChanged();
}

GstFlowReturn GstVideoReceiver::onNewSample(GstAppSink *sink, gpointer userData)
{
    GstVideoReceiver *self = static_cast<GstVideoReceiver*>(userData);

    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (sample) {
        self->processFrame(sample);
        gst_sample_unref(sample);
    }

    return GST_FLOW_OK;
}

void GstVideoReceiver::processFrame(GstSample *sample)
{
    GstCaps *caps = gst_sample_get_caps(sample);
    if (!caps) {
        return;
    }

    // Use GstVideoInfo to get proper stride information
    GstVideoInfo videoInfo;
    if (!gst_video_info_from_caps(&videoInfo, caps)) {
        return;
    }

    int width = GST_VIDEO_INFO_WIDTH(&videoInfo);
    int height = GST_VIDEO_INFO_HEIGHT(&videoInfo);

    if (width <= 0 || height <= 0) {
        return;
    }

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    if (!buffer) {
        return;
    }

    // Map using GstVideoFrame for proper stride handling
    GstVideoFrame videoFrame;
    if (gst_video_frame_map(&videoFrame, &videoInfo, buffer, GST_MAP_READ)) {
        // Get the actual stride (bytes per row) from the video frame
        int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&videoFrame, 0);
        guint8 *data = (guint8*)GST_VIDEO_FRAME_PLANE_DATA(&videoFrame, 0);

        // Create QImage with BGRA format (Format_ARGB32 on little-endian = BGRA in memory)
        QImage frame(data, width, height, stride, QImage::Format_ARGB32);
        m_currentFrame = frame.copy();  // Deep copy since buffer will be freed

        gst_video_frame_unmap(&videoFrame);

        emit frameReady();
    }
}

// CameraImageProvider implementation
CameraImageProvider::CameraImageProvider(GstVideoReceiver *receiver)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_receiver(receiver)
{
}

QImage CameraImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    Q_UNUSED(id)
    Q_UNUSED(requestedSize)

    QImage frame = m_receiver->currentFrame();

    if (frame.isNull()) {
        // Return a black placeholder image
        frame = QImage(640, 480, QImage::Format_ARGB32);
        frame.fill(Qt::black);
    }

    if (size) {
        *size = frame.size();
    }

    return frame;
}
