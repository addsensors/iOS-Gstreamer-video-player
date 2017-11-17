#import "GStreamerBackend.h"

#include <gst/gst.h>
#include <gst/video/videooverlay.h>
#include <gst/video/video.h>

GST_DEBUG_CATEGORY_STATIC (debug_category);
#define GST_CAT_DEFAULT debug_category

/* Do not allow seeks to be performed closer than this distance. It is visually useless, and will probably
 * confuse some demuxers. */
#define SEEK_MIN_DELAY (500 * GST_MSECOND)

@interface GStreamerBackend()
-(void)setUIMessage:(gchar*) message;
-(void)app_function;
-(void)check_initialization_complete;
@end

@implementation GStreamerBackend {
    id ui_delegate;              /* Class that we use to interact with the user interface */
    GstElement *pipeline;        /* The running pipeline */
    GstElement *video_sink;      /* The video sink element which receives XOverlay commands */
    GMainContext *context;       /* GLib context used to run the main loop */
    GMainLoop *main_loop;        /* GLib main loop */
    gboolean initialized;        /* To avoid informing the UI multiple times about the initialization */
    EaglUIView *ui_video_view;   /* UIView that holds the video */
    GstState state;              /* Current pipeline state */
    GstState target_state;       /* Desired pipeline state, to be set once buffering is complete */
    gint64 duration;             /* Cached clip duration */
    gint64 desired_position;     /* Position to seek to, once the pipeline is running */
    GstClockTime last_seek_time; /* For seeking overflow prevention (throttling) */
    gboolean is_live;            /* Live streams do not use buffering */
    NSString *pipelineString;
}

/*
 * Interface methods
 */

-(id) init:(id) uiDelegate videoView:(EaglUIView *)video_view pipelineString:(NSString *)pipeline_String
{
    NSLog(@"[GStreamerBackend init]");
    
    if (self = [super init])
    {
        NSLog(@"GStreamerBackend=[super init]\n%@",pipeline_String);
        
        self->ui_delegate = uiDelegate;
        self->ui_video_view = video_view;
        self->duration = GST_CLOCK_TIME_NONE;
        
        self->pipelineString = pipeline_String;
        self->pipeline = NULL;
        self->video_sink = NULL;
        self->context = NULL;
        self->main_loop = NULL;
        self->initialized = FALSE;
        self->desired_position = 0;
        self->last_seek_time = 0;
        self->is_live = TRUE;

        GST_DEBUG_CATEGORY_INIT(debug_category, "Fishing FanCam", 0, "FFC");
        gst_debug_set_default_threshold(GST_LEVEL_NONE);
        gst_debug_set_threshold_for_name("glimagesink", GST_LEVEL_NONE);
        //gst_debug_set_default_threshold(GST_LEVEL_NONE);
        //gst_debug_set_threshold_for_name("glimagesink", GST_LEVEL_TRACE);
        
        /* Start the bus monitoring task */
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self app_function];
            NSLog(@"Stop GStreamer");
            [self setUIMessage:"Stop GStreamer\n"];
        });
    }

    return self;
}

-(void) deinit
{
    if (main_loop)
    {
        g_main_loop_quit(main_loop);
    }
}

-(void) play
{
    target_state = GST_STATE_PLAYING;
    is_live = (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_NO_PREROLL);
}

-(BOOL) is_initialized
{
    return self->initialized;
}

/*
 * Private methods
 */

/* Change the message on the UI through the UI delegate */
-(void)setUIMessage:(gchar*) message
{
    NSString *string = [NSString stringWithUTF8String:message];
    if(string!=nil && ui_delegate && [ui_delegate respondsToSelector:@selector(gstreamerSetUIMessage:)])
    {
        [ui_delegate gstreamerSetUIMessage:string];
    }
}

/* If we have pipeline and it is running, query the current position and clip duration and inform
 * the application */
static gboolean refresh_ui(GStreamerBackend *self)
{
    return TRUE;
}

/* Forward declaration for the delayed seek callback */
static gboolean delayed_seek_cb(GStreamerBackend *self);

/* Perform seek, if we are not too close to the previous seek. Otherwise, schedule the seek for
 * some time in the future. */
static void execute_seek(gint64 position, GStreamerBackend *self)
{
    gint64 diff;

    if (position == GST_CLOCK_TIME_NONE)
        return;

    diff = gst_util_get_timestamp() - self->last_seek_time;

    if (GST_CLOCK_TIME_IS_VALID(self->last_seek_time) && diff < SEEK_MIN_DELAY)
    {
        /* The previous seek was too close, delay this one */
        GSource *timeout_source;

        if (self->desired_position == GST_CLOCK_TIME_NONE)
        {
            /* There was no previous seek scheduled. Setup a timer for some time in the future */
            timeout_source = g_timeout_source_new( (guint)((SEEK_MIN_DELAY - diff)/GST_MSECOND) );
            g_source_set_callback(timeout_source, (GSourceFunc)delayed_seek_cb, (__bridge void *)self, NULL);
            g_source_attach(timeout_source, self->context);
            g_source_unref(timeout_source);
        }
        /* Update the desired seek position. If multiple petitions are received before it is time
         * to perform a seek, only the last one is remembered. */
        self->desired_position = position;
        GST_DEBUG("Throttling seek to %" GST_TIME_FORMAT ", will be in %" GST_TIME_FORMAT,
                   GST_TIME_ARGS(position), GST_TIME_ARGS(SEEK_MIN_DELAY - diff));
    }
    else
    {
        /* Perform the seek now */
        GST_DEBUG("Seeking to %" GST_TIME_FORMAT, GST_TIME_ARGS(position));
        self->last_seek_time = gst_util_get_timestamp();
        gst_element_seek_simple(self->pipeline, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT, position);
        self->desired_position = GST_CLOCK_TIME_NONE;
    }
}

/* Delayed seek callback. This gets called by the timer setup in the above function. */
static gboolean delayed_seek_cb(GStreamerBackend *self)
{
    NSLog(@"delayed_seek_cb");
    
    GST_DEBUG("Doing delayed seek to %" GST_TIME_FORMAT, GST_TIME_ARGS(self->desired_position));
    execute_seek(self->desired_position, self);
    return FALSE;
}

/* Retrieve errors from the bus and show them on the UI */
static void error_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    NSLog(@"error_cb");
    
    GError *err;
    gchar *debug_info;
    gchar *message_string;
    
    gst_message_parse_error(msg, &err, &debug_info);
    message_string = g_strdup_printf("Error received from element %s: %s", GST_OBJECT_NAME (msg->src), err->message);
    g_clear_error(&err);
    g_free(debug_info);
    [self setUIMessage:message_string];
    g_free(message_string);
    
    gst_element_set_state(self->pipeline, GST_STATE_NULL);
    
    if(self->ui_delegate && [self->ui_delegate respondsToSelector:@selector(gstreamerStoppedByError)])
    {
        [self->ui_delegate gstreamerStoppedByError];
    }
}

/* Called when the End Of the Stream is reached. Just move to the beginning of the media and pause. */
static void eos_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    NSLog(@"eos_cb");
    
    /*self->target_state = GST_STATE_PAUSED;
    self->is_live = (gst_element_set_state(self->pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_NO_PREROLL);
    execute_seek(0, self);*/
    if(self->ui_delegate && [self->ui_delegate respondsToSelector:@selector(gstreamerStoppedByError)])
    {
        [self->ui_delegate gstreamerStoppedByError];
    }
}

/* Called when the duration of the media changes. Just mark it as unknown, so we re-query it in the next UI refresh. */
static void duration_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    NSLog(@"duration_cb");
    
    self->duration = GST_CLOCK_TIME_NONE;
}

/* Called when buffering messages are received. We inform the UI about the current buffering level and
 * keep the pipeline paused until 100% buffering is reached. At that point, set the desired state. */
static void buffering_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    NSLog(@"buffering_cb");
    
    gint percent;

    if (self->is_live)
        return;

    gst_message_parse_buffering(msg, &percent);
    
    if (percent < 100 && self->target_state >= GST_STATE_PAUSED)
    {
        gchar * message_string = g_strdup_printf("Buffering %d%%", percent);
        gst_element_set_state(self->pipeline, GST_STATE_PAUSED);
        [self setUIMessage:message_string];
        g_free(message_string);
    }
    else if (self->target_state >= GST_STATE_PLAYING)
    {
        gst_element_set_state(self->pipeline, GST_STATE_PLAYING);
    }
    else if (self->target_state >= GST_STATE_PAUSED)
    {
        [self setUIMessage:"Buffering complete"];
    }
}

/* Called when the clock is lost */
static void clock_lost_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    NSLog(@"clock_lost_cb");
    
    if (self->target_state >= GST_STATE_PLAYING)
    {
        gst_element_set_state(self->pipeline, GST_STATE_PAUSED);
        gst_element_set_state(self->pipeline, GST_STATE_PLAYING);
    }
}

/* Notify UI about pipeline state changes */
static void state_changed_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    NSLog(@"state_changed_cb, msg=%d", msg->type);
    
    GstState old_state, new_state, pending_state;
    gst_message_parse_state_changed(msg, &old_state, &new_state, &pending_state);
    /* Only pay attention to messages coming from the pipeline, not its children */
    if (GST_MESSAGE_SRC(msg) == GST_OBJECT(self->pipeline))
    {
        NSLog(@"SRC = self->pipeline");
        
        self->state = new_state;
        gchar *message = g_strdup_printf("State changed to %s", gst_element_state_get_name(new_state));
        [self setUIMessage:message];
        g_free(message);
        
        NSLog(@"old_state=%d, new_state=%d", old_state, new_state);
        
        if (old_state == GST_STATE_READY && new_state == GST_STATE_PAUSED)
        {
            //check_media_size(self);
            NSLog(@"self->desired_position=%lld", self->desired_position);
            
            /* If there was a scheduled seek, perform it now that we have moved to the Paused state */
            if (GST_CLOCK_TIME_IS_VALID(self->desired_position))
            {
                NSLog(@"execute_seek");
                execute_seek(self->desired_position, self);
            }
        }
    }
}

/* Check if all conditions are met to report GStreamer as initialized.
 * These conditions will change depending on the application */
-(void) check_initialization_complete
{
    if (!initialized && main_loop)
    {
        GST_DEBUG("Initialization complete, notifying application.");
        if (ui_delegate && [ui_delegate respondsToSelector:@selector(gstreamerInitialized)])
        {
            [ui_delegate gstreamerInitialized];
        }
        initialized = TRUE;
    }
}

/* Main method for the bus monitoring code */
-(void) app_function
{
    GstBus *bus;
    GSource *timeout_source;
    GSource *bus_source;
    GError *error = NULL;

    GST_DEBUG("Creating pipeline");
    [self setUIMessage:"Creating pipeline"];

    /* Create our own GLib Main Context and make it the default one */
    context = g_main_context_new();
    g_main_context_push_thread_default(context);
    
    /* Build pipeline */
    pipeline = gst_parse_launch([self->pipelineString cStringUsingEncoding:NSASCIIStringEncoding], &error);
    [self setUIMessage:(gchar *)[self->pipelineString UTF8String]];
    
    if (error)
    {
        gchar *message = g_strdup_printf("Unable to build pipeline: %s", error->message);
        g_clear_error(&error);
        [self setUIMessage:message];
        g_free(message);
        return;
    }

    /* Set the pipeline to READY, so it can already accept a window handle */
    gst_element_set_state(pipeline, GST_STATE_READY);
    
    video_sink = gst_bin_get_by_interface(GST_BIN(pipeline), GST_TYPE_VIDEO_OVERLAY);
    if (!video_sink)
    {
        GST_ERROR("Could not retrieve video sink");
        [self setUIMessage:"Could not retrieve video sink"];
        return;
    }
    gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(video_sink), (guintptr) (id) ui_video_view);

    /* Instruct the bus to emit signals for each received message, and connect to the interesting signals */
    bus = gst_element_get_bus(pipeline);
    bus_source = gst_bus_create_watch(bus);
    g_source_set_callback(bus_source, (GSourceFunc) gst_bus_async_signal_func, NULL, NULL);
    g_source_attach(bus_source, context);
    g_source_unref(bus_source);
    g_signal_connect(G_OBJECT (bus), "message::error", (GCallback)error_cb, (__bridge void *)self);
    g_signal_connect(G_OBJECT (bus), "message::eos", (GCallback)eos_cb, (__bridge void *)self);
    g_signal_connect(G_OBJECT (bus), "message::state-changed", (GCallback)state_changed_cb, (__bridge void *)self);
    g_signal_connect(G_OBJECT (bus), "message::duration", (GCallback)duration_cb, (__bridge void *)self);
    g_signal_connect(G_OBJECT (bus), "message::buffering", (GCallback)buffering_cb, (__bridge void *)self);
    g_signal_connect(G_OBJECT (bus), "message::clock-lost", (GCallback)clock_lost_cb, (__bridge void *)self);
    gst_object_unref(bus);

    /* Register a function that GLib will call 4 times per second */
    timeout_source = g_timeout_source_new(250);
    g_source_set_callback(timeout_source, (GSourceFunc)refresh_ui, (__bridge void *)self, NULL);
    g_source_attach(timeout_source, context);
    g_source_unref(timeout_source);

    /* Create a GLib Main Loop and set it to run */
    GST_DEBUG("Entering main loop...");
    main_loop = g_main_loop_new(context, FALSE);
    [self check_initialization_complete];
    g_main_loop_run(main_loop);
    GST_DEBUG("Exited main loop");
    g_main_loop_unref(main_loop);
    main_loop = NULL;
    
    /* Free resources */
    gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(video_sink), 0);
    
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    pipeline = NULL;
    
    initialized = FALSE;
    ui_video_view = NULL;
    return;
}

@end

