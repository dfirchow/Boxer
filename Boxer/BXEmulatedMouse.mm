/* 
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXEmulatedMouse.h"

#import "config.h"
#import "video.h"
#import "mouse.h"


#pragma mark -
#pragma mark Private method declarations

@interface BXEmulatedMouse ()
@property (readwrite, assign) NSUInteger pressedButtons;

- (void) setButton: (BXMouseButton)button toState: (BOOL)pressed;
- (void) releaseButton: (NSNumber *)button;

@end


#pragma mark -
#pragma mark Implementation

@implementation BXEmulatedMouse
@synthesize active, position, pressedButtons;

- (id) init
{
	if ((self = [super init]))
	{
		active			= NO;
		position		= NSMakePoint(0.5f, 0.5f);
		pressedButtons	= BXNoMouseButtonsMask;
        
        lastButtonDown[BXMouseButtonLeft] = 0;
        lastButtonDown[BXMouseButtonRight] = 0;
        lastButtonDown[BXMouseButtonMiddle] = 0;
	}
	return self;
}

#pragma mark -
#pragma mark Controlling response state

- (void) clearInput
{
	[self buttonUp: BXMouseButtonLeft];
	[self buttonUp: BXMouseButtonRight];
	[self buttonUp: BXMouseButtonMiddle];
}

- (void) setActive: (BOOL)flag
{
	if (active != flag)
	{
		//If mouse support is disabled while we still have mouse buttons pressed,
		//then release those buttons before continuing.
		if (!flag) [self clearInput];
		
		active = flag;
	}
}

- (void) movedTo: (NSPoint)point
			  by: (NSPoint)delta
		onCanvas: (NSRect)canvas
	 whileLocked: (BOOL)locked
{
	if ([self isActive])
	{
		//In DOSBox land, absolute position is from 0.0 to 1.0 but delta is in raw pixels,
		//for some silly reason.
		//TODO: try making this relative to the DOS driver's max mouse position instead.
		NSPoint canvasDelta = NSMakePoint(delta.x * canvas.size.width,
										  delta.y * canvas.size.height);
		
		Mouse_CursorMoved(canvasDelta.x,
						  canvasDelta.y,
						  point.x,
						  point.y,
						  locked);
	}
}

- (void) setButton: (BXMouseButton)button
		   toState: (BOOL)pressed
{
    NSAssert1(button < BXMouseButtonMax,
              @"Invalid mouse button number %d passed to setButton:toState:", button);
    
	//Ignore button presses while we're inactive
	if (![self isActive]) return;
	
	NSUInteger buttonMask = 1U << button;

    //Whether or not we actually need to toggle the button,
    //cancel any pending button release in response.
    [NSObject cancelPreviousPerformRequestsWithTarget: self
                                             selector: @selector(releaseButton:)
                                               object: [NSNumber numberWithUnsignedInteger: button]];
    
    //If we do actually need to toggle the button, then update DOSBox's state
	if ([self buttonIsDown: button] != pressed)
	{
		if (pressed)
		{
			Mouse_ButtonPressed(button);
			[self setPressedButtons: pressedButtons | buttonMask];
            
            lastButtonDown[button] = [NSDate timeIntervalSinceReferenceDate];
		}
        else
        {
            //Check how long the button was held down before releasing.
            //If it's been soon enough that the game may not have had time
            //to register the press, then hold the release until our minimum
            //duration is up.
            
            //This fixes games that poll the current state of the mouse
            //instead of looking at the mouse event queue, and so which may
            //overlook very quick clicks like those generated by touchpads.
            
            NSTimeInterval buttonPressDuration = [NSDate timeIntervalSinceReferenceDate] - lastButtonDown[button];
            NSTimeInterval durationRemaining = BXMouseButtonPressDurationMinimum - buttonPressDuration;
            
            if (durationRemaining > 0)
            {
                [self performSelector: @selector(releaseButton:)
                           withObject: [NSNumber numberWithUnsignedInteger: button]
                           afterDelay: durationRemaining];
            }
            else
            {
                Mouse_ButtonReleased(button);
                [self setPressedButtons: pressedButtons & ~buttonMask];
                
                lastButtonDown[button] = 0;
            }
        }
	}
}

- (void) buttonDown: (BXMouseButton)button
{
	[self setButton: button toState: YES];
}

- (void) buttonUp: (BXMouseButton)button
{
	[self setButton: button toState: NO];
}

- (BOOL) buttonIsDown: (BXMouseButton)button
{
    NSAssert1(button < BXMouseButtonMax,
              @"Invalid mouse button number %d passed to setButton:toState:", button);
    
	NSUInteger buttonMask = 1U << button;
	
	return (pressedButtons & buttonMask) == buttonMask;
}


- (void) buttonPressed: (BXMouseButton)button
{
	[self buttonPressed: button forDuration: BXMouseButtonPressDurationDefault];
}

- (void) buttonPressed: (BXMouseButton)button forDuration: (NSTimeInterval)duration
{
	[self buttonDown: button];
	
	[self performSelector: @selector(releaseButton:)
			   withObject: [NSNumber numberWithUnsignedInteger: button]
			   afterDelay: duration];
}

- (void) releaseButton: (NSNumber *)button
{
	[self buttonUp: [button unsignedIntegerValue]];
}

@end
