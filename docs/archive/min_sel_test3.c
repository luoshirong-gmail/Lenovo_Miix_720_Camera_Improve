// min_sel_test3.c — 对照: idle=videotestsrc black, cam=真实 libcamerasrc 链
// 验证 libcamerasrc 作为 selector 第二输入时, 切换后能否出真实画面
#include <gst/gst.h>
#include <stdio.h>
#include <unistd.h>

static GstElement *pipeline, *selector;
static GstPad *cam_pad;

#define CAM_ID "\\_SB_.PCI0.I2C2.CAM6"

static gboolean switch_cb(gpointer user_data) {
    (void)user_data;
    g_print("[switch] setting active-pad -> sink_1\n");
    g_object_set(selector, "active-pad", cam_pad, NULL);
    return G_SOURCE_REMOVE;
}

static gboolean quit_cb(gpointer user_data) {
    (void)user_data;
    g_print("[quit] exit\n");
    g_main_loop_quit((GMainLoop *)user_data);
    return G_SOURCE_REMOVE;
}

static gboolean add_cb(gpointer user_data) {
    (void)user_data;
    GstElement *src = gst_element_factory_make("libcamerasrc", "cam_src");
    GstElement *conv = gst_element_factory_make("videoconvert", "cam_conv");
    GstElement *capsf = gst_element_factory_make("capsfilter", "cam_caps");
    GstElement *q = gst_element_factory_make("queue", "cam_q");
    g_object_set(src, "camera-name", CAM_ID, NULL);
    g_object_set(q, "max-size-buffers", 2, "leaky", 2, NULL);
    gst_bin_add_many(GST_BIN(pipeline), src, conv, capsf, q, NULL);

    GstPad *srcpad = gst_element_get_static_pad(src, "src");
    if (srcpad) {
        g_object_set(srcpad, "stream-role", 1, NULL);  // still-capture
        gst_object_unref(srcpad);
    }

    gst_element_link(src, conv);
    gst_element_link(conv, capsf);
    gst_element_link(capsf, q);

    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "width", G_TYPE_INT, 2560, "height", G_TYPE_INT, 1920,
        "format", G_TYPE_STRING, "NV12",
        "framerate", GST_TYPE_FRACTION, 29, 1,
        "colorimetry", G_TYPE_STRING, "bt601", NULL);
    g_object_set(capsf, "caps", caps, NULL);
    gst_caps_unref(caps);

    cam_pad = gst_element_request_pad_simple(selector, "sink_%u");
    GstPad *qsrc = gst_element_get_static_pad(q, "src");
    g_print("[add] link q->%s: %d\n", GST_OBJECT_NAME(cam_pad), gst_pad_link(qsrc, cam_pad));
    gst_object_unref(qsrc);

    gst_element_sync_state_with_parent(src);
    gst_element_sync_state_with_parent(conv);
    gst_element_sync_state_with_parent(capsf);
    gst_element_sync_state_with_parent(q);
    gst_element_set_state(selector, GST_STATE_PLAYING);

    g_timeout_add(3000, switch_cb, NULL);
    g_timeout_add(12000, quit_cb, user_data);
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    gst_init(&argc, &argv);
    GstElement *idle = gst_element_factory_make("videotestsrc", "idle_src");
    GstElement *q0 = gst_element_factory_make("queue", "idle_q");
    selector = gst_element_factory_make("input-selector", "sel");
    GstElement *sink = gst_element_factory_make("v4l2sink", "sink");
    pipeline = gst_pipeline_new("p");
    g_object_set(idle, "pattern", 2, "is-live", TRUE, NULL);  // 2=black
    g_object_set(selector, "sync-streams", TRUE, NULL);
    g_object_set(sink, "device", "/dev/video98", "sync", FALSE, NULL);
    gst_bin_add_many(GST_BIN(pipeline), idle, q0, selector, sink, NULL);

    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "width", G_TYPE_INT, 2560, "height", G_TYPE_INT, 1920,
        "format", G_TYPE_STRING, "NV12", "framerate", GST_TYPE_FRACTION, 29, 1, NULL);
    gst_element_link_filtered(idle, q0, caps);
    gst_caps_unref(caps);
    gst_element_link(q0, selector);
    caps = gst_caps_new_simple("video/x-raw",
        "width", G_TYPE_INT, 2560, "height", G_TYPE_INT, 1920,
        "format", G_TYPE_STRING, "NV12", "framerate", GST_TYPE_FRACTION, 29, 1, NULL);
    gst_element_link_filtered(selector, sink, caps);
    gst_caps_unref(caps);

    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    GstState state;
    gst_element_get_state(pipeline, &state, NULL, 5 * GST_SECOND);
    g_print("[main] pipeline PLAYING\n");

    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(2000, add_cb, loop);
    g_main_loop_run(loop);

    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    return 0;
}
