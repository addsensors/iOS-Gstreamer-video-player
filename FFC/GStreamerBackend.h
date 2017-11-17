#import <Foundation/Foundation.h>
#import "GStreamerBackendDelegate.h"

#import "EaglUIVIew.h"

@interface GStreamerBackend : NSObject

/* Initialization method. Pass the delegate that will take care of the UI.
 * This delegate must implement the GStreamerBackendDelegate protocol.
 * Pass also the UIView object that will hold the video window. */
-(id) init:(id) uiDelegate videoView:(EaglUIView*)video_view pipelineString:(NSString *)pipeline_String;

/* Quit the main loop and free all resources, including the pipeline and
 * the references to the ui delegate and the UIView used for rendering, so
 * these objects can be deallocated. */
-(void) deinit;

/* Set the pipeline to PLAYING */
-(void) play;

-(BOOL) is_initialized;

@end
