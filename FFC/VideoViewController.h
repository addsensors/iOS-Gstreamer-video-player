#import <UIKit/UIKit.h>
#import "GStreamerBackendDelegate.h"

#import "EaglUIVIew.h"

@interface VideoViewController : UIViewController <GStreamerBackendDelegate>
{
    IBOutlet EaglUIView *video_view;
    IBOutlet UIView *video_container_view;
    IBOutlet NSLayoutConstraint *video_width_constraint;
    IBOutlet NSLayoutConstraint *video_height_constraint;
    IBOutlet UITextView *Logging;
    IBOutlet UIButton *LightButton;
    IBOutlet UIButton *VisibleButton;
    IBOutlet UIActivityIndicatorView *ProblemActivity;
    IBOutlet UITextField *PipelineString;
}
- (IBAction)LightButtonTouchUpInside:(id)sender;
- (IBAction)VisibleButtonTouchUpInside:(id)sender;
- (IBAction)PipelineStringChanged:(id)sender;
- (IBAction)PipelineStringEditDidEnd:(id)sender;
- (IBAction)PipelineStringEditDidBegin:(id)sender;

/* From GStreamerBackendDelegate */
-(void) gstreamerInitialized;
-(void) gstreamerStoppedByError;
-(void) gstreamerSetUIMessage:string;

@end
