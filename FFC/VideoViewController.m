#import "VideoViewController.h"
#import "GStreamerBackend.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

@interface VideoViewController () {
    GStreamerBackend *gst_backend;
    NSTimer *Timer;
}
@end
@implementation VideoViewController {
    BOOL is_light_on;
    BOOL is_visible_elements;
    BOOL is_string_changed;
    BOOL is_string_edit;
    NSUserDefaults *userDefaults;
}

/*
 * Methods from UIViewController
 */

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    Logging.userInteractionEnabled = YES;
    CGRect noneRect;
    noneRect.origin.x = 0;
    noneRect.origin.y = 0;
    noneRect.size.width = 0;
    noneRect.size.height = 0;
    UIView *invisibleView = [[UIView alloc] initWithFrame:noneRect];
    Logging.inputView = invisibleView;
    
    //LightButton = [UIButton buttonWithType:UIButtonTypeCustom];
    //VisibleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    
    [LightButton setImage:[UIImage imageNamed:@"light-64-grey.png"] forState:UIControlStateNormal];
    [LightButton setImage:[UIImage imageNamed:@"light-64-white.png"] forState:UIControlStateSelected];
    
    [VisibleButton setImage:[UIImage imageNamed:@"eye-64-grey.png"] forState:UIControlStateNormal];
    [VisibleButton setImage:[UIImage imageNamed:@"eye-64-white.png"] forState:UIControlStateSelected];
    
    LightButton.selected = NO;
    LightButton.highlighted = NO;
    VisibleButton.selected = NO;
    VisibleButton.highlighted = NO;
    Logging.hidden = YES;
    PipelineString.hidden = YES;
    
    is_light_on = NO;
    is_visible_elements = NO;
    is_string_changed = NO;
    is_string_edit = NO;
    
    [self gstreamerSetUIMessage:@"viewDidLoad"];
    
    //rtspsrc location=rtsp://192.168.0.1:554 latency=333 ! rtph264depay ! h264parse ! vtdec ! glimagesink
    //rtspsrc location=rtsp://192.168.1.1:554/live/ch00_1 latency=555 ! rtph264depay ! h264parse ! vtdec ! glimagesink
    // ! decodebin ! autovideosink
    // ! rtph264depay ! h264parse ! vtdec ! glimagesink
    //rtspsrc location=rtsp://192.168.1.1:554/live/ch00_1 latency=555 ! rtph264depay ! h264parse ! vtdec ! videoconvert ! autovideosink
    
    userDefaults = [NSUserDefaults standardUserDefaults];
    if(![userDefaults stringForKey:@"savedPipelineString"])
    {
        [userDefaults setObject:@"rtspsrc location=rtsp://192.168.0.1:554 latency=555 ! rtph264depay ! h264parse ! vtdec ! glimagesink" forKey:@"savedPipelineString"];
        [self gstreamerSetUIMessage:@"First launch, default pipeline loaded"];
    }
    PipelineString.text = [userDefaults stringForKey:@"savedPipelineString"];;
    
    [self gstreamerInitStart];
}

- (void)gstreamerInitStart
{
    [self gstreamerSetUIMessage:@"Start GStreamer"];
    
    
    
    if(!gst_backend)
        gst_backend = [GStreamerBackend alloc];
    gst_backend = [gst_backend init:self videoView:video_view pipelineString:PipelineString.text];
}

- (void)viewDidDisappear:(BOOL)animated
{
    if (gst_backend)
    {
        [gst_backend deinit];
    }
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

/* Called when the size of the main view has changed, so we can
 * resize the sub-views in ways not allowed by storyboarding. */
- (void)viewDidLayoutSubviews
{
    video_width_constraint.constant = self.view.bounds.size.width;
    video_height_constraint.constant = self.view.bounds.size.height;
    
    CGRect tempFrame;
    
    tempFrame.size.height = 30;
    tempFrame.size.width = video_width_constraint.constant - 15*2;
    tempFrame.origin.y = PipelineString.frame.size.height;
    tempFrame.origin.x = 15;
    PipelineString.frame = tempFrame;
    
    tempFrame.size.height = 38;
    tempFrame.size.width = 38;
    tempFrame.origin.y = video_height_constraint.constant/2 - ProblemActivity.frame.size.height/2;
    tempFrame.origin.x = video_width_constraint.constant/2 - ProblemActivity.frame.size.width/2;
    ProblemActivity.frame = tempFrame;
    
    tempFrame.size.height = 32;
    tempFrame.size.width = 32;
    tempFrame.origin.y = video_height_constraint.constant - 15 - 32;
    tempFrame.origin.x = 15;
    LightButton.frame = tempFrame;
    
    tempFrame.size.height = 32;
    tempFrame.size.width = 32;
    tempFrame.origin.y = video_height_constraint.constant - 15 - 32;
    tempFrame.origin.x = video_width_constraint.constant - 15 - 32;
    VisibleButton.frame = tempFrame;
    
    tempFrame.size.height = video_height_constraint.constant/4;
    tempFrame.size.width = video_width_constraint.constant - 15*4 - 32*2;
    tempFrame.origin.y = video_height_constraint.constant - 15 - tempFrame.size.height;
    tempFrame.origin.x = 15*2 + 32;
    Logging.frame = tempFrame;
}

/*
 * Methods from GstreamerBackendDelegate
 */

-(void) gstreamerInitialized
{
    [gst_backend play];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    /*dispatch_async(dispatch_get_main_queue(), ^{
        [ProblemActivity stopAnimating];
    });*/
}

-(void) gstreamerStoppedByError
{
    [gst_backend deinit];
    dispatch_async(dispatch_get_main_queue(), ^{
        [ProblemActivity startAnimating];
    });
}

-(void) gstreamerSetUIMessage:(NSString *)message;
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([message  isEqual: @"Stop GStreamer\n"] && !is_string_edit)
        {
            Timer = [NSTimer scheduledTimerWithTimeInterval:1.0f target:self selector:@selector(gstreamerInitStart) userInfo:nil repeats:NO];
        }
        if ([message  isEqual: @"State changed to PLAYING"])
            [ProblemActivity stopAnimating];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"HH:mm:ss"];
        NSString *dateString = [formatter stringFromDate:[NSDate date]];
        dateString = [dateString stringByAppendingString:@" > "];
        
        NSMutableString *log = [[NSMutableString alloc] initWithString:Logging.text];
        [log appendString:dateString];
        [log appendString:message];
        [log appendString:@"\n"];
        
        if(log.length>2000)
        {
            NSRange replaced = NSMakeRange(0, log.length-2000);
            [log deleteCharactersInRange:replaced];
        }
        
        Logging.text = (NSString *)log;
        
        [Logging layoutIfNeeded];
        NSRange range = NSMakeRange(Logging.text.length - 2, 1);
        [Logging scrollRangeToVisible:range];
    });
}

- (IBAction)LightButtonTouchUpInside:(id)sender
{
    CFSocketRef socket;
    socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, NULL, NULL);
    if ( socket == NULL) {
        NSLog(@"CfSocketCreate Failed");
    }
    else
    {
        if( socket )
        {
            NSLog(@"Socket created :)");
            
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_len = sizeof(addr);
            addr.sin_family = AF_INET;
            addr.sin_port = htons(8045); //port
            inet_aton("192.168.0.1", &addr.sin_addr); //ip address
            CFDataRef Addr = CFDataCreate(kCFAllocatorDefault,(UInt8*)&addr,sizeof(addr));
            
            if (is_light_on)
            {
                const unsigned char data[] = {57,51,75,65,1,0,0,0,21,0,0,0,1,7,1,0,0};
                CFDataRef Data = CFDataCreate(kCFAllocatorDefault, (const UInt8*)data, sizeof(data));
                if ( kCFSocketSuccess == CFSocketSendData(socket,Addr,Data,0) )
                {
                    is_light_on = NO;
                    LightButton.selected = NO;
                }
            }
            else
            {
                const unsigned char data[] = {57,51,75,65,1,0,0,0,21,0,0,0,1,7,1,0,1};
                CFDataRef Data = CFDataCreate(kCFAllocatorDefault, (const UInt8*)data, sizeof(data));
                if ( kCFSocketSuccess == CFSocketSendData(socket,Addr,Data,0) )
                {
                    is_light_on = YES;
                    LightButton.selected = YES;
                }
            }
        }
    }
}

- (IBAction)VisibleButtonTouchUpInside:(id)sender
{
    if (is_visible_elements)
    {
        is_visible_elements = NO;
        VisibleButton.selected = NO;
        Logging.hidden = YES;
        PipelineString.hidden = YES;
    }
    else
    {
        is_visible_elements = YES;
        VisibleButton.selected = YES;
        Logging.hidden = NO;
        PipelineString.hidden = NO;
    }
}

- (IBAction)PipelineStringChanged:(id)sender
{
    is_string_changed = YES;
}

- (IBAction)PipelineStringEditDidEnd:(id)sender
{
    is_string_edit = NO;
    if(is_string_changed)
    {
        [userDefaults setObject:PipelineString.text forKey:@"savedPipelineString"];
        if([gst_backend is_initialized])
            [gst_backend deinit];
        else
            [self gstreamerInitStart];
        is_string_changed = NO;
    }
}

- (IBAction)PipelineStringEditDidBegin:(id)sender
{
    is_string_edit = YES;
}

-(BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    if(is_string_changed)
    {
        [userDefaults setObject:PipelineString.text forKey:@"savedPipelineString"];
        if([gst_backend is_initialized])
            [gst_backend deinit];
        else
            [self gstreamerInitStart];
        is_string_changed = NO;
    }
    return YES;
}

@end
