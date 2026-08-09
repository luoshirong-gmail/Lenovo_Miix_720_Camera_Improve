// min_sel_test.c — 最小验证: gst 1.28 input-selector 动态添加输入 + 切换 active-pad
// 结构: videotestsrc(black) → selector(sink_0) → fakesink
//       动态: videotestsrc(smpte) → request pad(sink_1) → 切换
#include <gst/gst.h>
#include <stdio.h>
#include <unistd.h>

static GstElement *pipeline, *selector;
static GstPad *idle_pad, *cam_pad;

static gboolean switch_cb(gpointer user_data) {
    (void)user_data;
    g_object_set(selector, "active-pad", cam_pad, NULL);
    GstPad *cur = NULL;
    g_object_get(selector, "active-pad", &cur, NULL);
    g_print("[switch] active-pad -> %s (cur=%s)\n",
            cam_pad ? GST_OBJECT_NAME(cam_pad) : "NULL",
            cur ? GST_OBJECT_NAME(cur) : "NULL");
    if (cur) gst_object_unref(cur);
    return G_SOURCE_REMOVE;
}

static gboolean tick_cb(gpointer user_data) {
    static int n = 0;
    (void)user_data;
    if (n == 0) {
        // 动态添加第二输入
        GstElement *src = gst_element_factory_make("videotestsrc", "cam_src");
        GstElement *q = gst_element_factory_make("queue", "cam_q");
        g_object_set(src, "pattern", 1, "is-live", TRUE, NULL);  // 1=smpte
        gst_bin_add_many(GST_BIN(pipeline), src, q, NULL);
        gst_element_link(src, q);
        cam_pad = gst_element_request_pad_simple(selector, "sink_%u");
        GstPad *qsrc = gst_element_get_static_pad(q, "src");
        g_print("[tick] link q->%s: %d\n", GST_OBJECT_NAME(cam_pad),
                gst_pad_link(qsrc, cam_pad));
        gst_object_unref(qsrc);
        gst_element_sync_state_with_parent(src);
        gst_element_sync_state_with_parent(q);
        gst_element_set_state(selector, GST_STATE_PLAYING);
        // 等 1.5s 让第二输入出帧, 再切换
        g_timeout_add(1500, switch_cb, NULL);
        n++;
    } else if (n == 1) {
        GstPad *cur = NULL;
        g_object_get(selector, "active-pad", &cur, NULL);
        g_print("[tick+1s] active-pad = %s\n", cur ? GST_OBJECT_NAME(cur) : "NULL");
        if (cur) gst_object_unref(cur);
        g_print("[tick+1s] 主循环退出\n");
        g_main_loop_quit((GMainLoop *)user_data);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv) {
    gst_init(&argc, &argv);
    GstElement *idle = gst_element_factory_make("videotestsrc", "idle_src");
    GstElement *q0 = gst_element_factory_make("queue", "idle_q");
    selector = gst_element_factory_make("input-selector", "sel");
    GstElement *sink = gst_element_factory_make("fakesink", "sink");
    pipeline = gst_pipeline_new("p");
    g_object_set(idle, "pattern", 2, "is-live", TRUE, NULL);  // 2=black
    g_object_set(selector, "sync-streams", TRUE, NULL);
    gst_bin_add_many(GST_BIN(pipeline), idle, q0, selector, sink, NULL);
    gst_element_link(idle, q0);
    gst_element_link(q0, selector);
    gst_element_link(selector, sink);

    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    GstState state;
    gst_element_get_state(pipeline, &state, NULL, 5 * GST_SECOND);
    g_object_set(selector, "active-pad", NULL, NULL);  // 默认 sink_0
    idle_pad = gst_element_get_static_pad(selector, "sink_0");
    g_print("[main] pipeline PLAYING, idle_pad=%s\n", GST_OBJECT_NAME(idle_pad));

    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(2000, tick_cb, loop);
    g_main_loop_run(loop);

    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    return 0;
}
