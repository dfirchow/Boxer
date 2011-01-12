/* 
 Boxer is copyright 2010-2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/GNU General Public License.txt, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXInputController.h"
#import "BXEventConstants.h"
#import "BXInputHandler.h"
#import "BXEmulator.h"
#import "BXAppController.h"
#import "BXGeometry.h"
#import "BXCursorFadeAnimation.h"
#import "BXDOSWindowController+BXRenderController.h"
#import "BXSession.h"

//For keycodes
#import <Carbon/Carbon.h>


#pragma mark -
#pragma mark Constants for configuring behaviour

//The number of seconds it takes for the cursor to fade out after entering the window.
//Cursor animation is flickery so a small duration helps mask this.
const NSTimeInterval BXCursorFadeDuration = 0.4;

//The framerate at which to animate the cursor fade.
//15fps is as fast as is really noticeable.
const float BXCursorFadeFrameRate = 15.0f;

//If the cursor is warped less than this distance (relative to a 0.0->1.0 square canvas) then
//the OS X cursor will not be warped to match. Because OS X cursor warping introduces a slight
//input delay, we use this tolerance to ignore small warps.
const CGFloat BXCursorWarpTolerance = 0.1f;

const float BXMouseLockSoundVolume = 0.5f;


//Flags for which mouse buttons we are currently faking (for Ctrl- and Opt-clicking.)
//Note that while these are ORed together, there will currently only ever be one of them active at a time.
enum {
	BXNoSimulatedButtons			= 0,
	BXSimulatedButtonRight			= 1,
	BXSimulatedButtonMiddle			= 2,
	BXSimulatedButtonLeftAndRight	= 4,
};


#pragma mark -
#pragma mark Private methods

@interface BXInputController ()

//Returns whether we should have control of the mouse cursor state.
//This is true if the mouse is within the view, the window is key,
//mouse input is in use by the DOS program, and the mouse is either
//locked or we track the mouse while it's unlocked.
- (BOOL) _controlsCursor;

//A quicker version of the above for when we already know/don't care
//if the mouse is inside the view.
- (BOOL) _controlsCursorWhileMouseInside;

//Converts a 0.0-1.0 relative canvas offset to a point on screen.
- (NSPoint) _pointOnScreen: (NSPoint)canvasPoint;

//Converts a point on screen to a 0.0-1.0 relative canvas offset.
- (NSPoint) _pointInCanvas: (NSPoint)screenPoint;

//Performs the fiddly internal work of locking/unlocking the mouse.
- (void) _applyMouseLockState: (BOOL)lock;

//Responds to the emulator moving the mouse cursor,
//either in response to our own signals or of its own accord.
- (void) _emulatorCursorMovedToPointInCanvas: (NSPoint)point;

//Warps the OS X cursor to the specified point on our virtual mouse canvas.
//Used when locking and unlocking the mouse and when DOS warps the mouse.
- (void) _syncOSXCursorToPointInCanvas: (NSPoint)point;

//Warps the DOS cursor to the specified point on our virtual mouse canvas.
//Used when unlocking the mouse while unlocked mouse tracking is disabled,
//to remove any latent mouse input from a leftover mouse position.
- (void) _syncDOSCursorToPointInCanvas: (NSPoint)pointInCanvas;

@end


@implementation BXInputController
@synthesize mouseLocked, mouseActive, trackMouseWhileUnlocked, mouseSensitivity;

- (BXDOSWindowController *) controller
{
	return (BXDOSWindowController *)[[[self view] window] windowController];
}

#pragma mark -
#pragma mark Initialization and cleanup

- (void) awakeFromNib
{	
	//Initialize mouse sensitivity and tracking options to a suitable default
	mouseSensitivity = 1.0f;
	trackMouseWhileUnlocked = YES;
	
	//DOSBox-triggered cursor warp distances which fit within this deadzone will be ignored
	//to prevent needless input delays. q.v. _emulatorCursorMovedToPointInCanvas:
	cursorWarpDeadzone = NSInsetRect(NSZeroRect, -BXCursorWarpTolerance, -BXCursorWarpTolerance);
	
	//The extent of our relative mouse canvas. Mouse coordinates passed to DOSBox will be
	//relative to this canvas and clamped to fit within it. q.v. mouseMoved:
	canvasBounds = NSMakeRect(0.0f, 0.0f, 1.0f, 1.0f);
	
	//Used for constraining where the mouse cursor will appear when we unlock the mouse.
	//This is inset slightly from canvasBounds, because a cursor that appears right at the
	//very edge of the window looks dumb. q.v. _applyMouseLockState:
	visibleCanvasBounds = NSMakeRect(0.01f, 0.01f, 0.98f, 0.98f);
	
	
	//Insert ourselves into the responder chain as our view's next responder
	[self setNextResponder: [[self view] nextResponder]];
	[[self view] setNextResponder: self];
	
	//Set up a cursor region in the view for mouse handling
	NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingEnabledDuringMouseDrag | NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingAssumeInside;
	
	NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect: NSZeroRect
																options: options
																  owner: self
															   userInfo: nil];
	
	[[self view] addTrackingArea: trackingArea];
	[trackingArea release];	
	 
	
	//Set up our cursor fade animation
	cursorFade = [[BXCursorFadeAnimation alloc] initWithDuration: BXCursorFadeDuration
												  animationCurve: NSAnimationEaseIn];
	[cursorFade setDelegate: self];
	[cursorFade setOriginalCursor: [NSCursor arrowCursor]];
	[cursorFade setAnimationBlockingMode: NSAnimationNonblocking];
	[cursorFade setFrameRate: BXCursorFadeFrameRate];
}

- (void) dealloc
{
	[cursorFade stopAnimation];
	[cursorFade release], cursorFade = nil;
	
	[super dealloc];
}


- (void) setRepresentedObject: (BXInputHandler *)representedObject
{
	if (representedObject != [self representedObject])
	{
		if ([self representedObject])
		{
			[self unbind: @"mouseSensitivity"];
			[self unbind: @"trackMouseWhileUnlocked"];
			[self unbind: @"mouseActive"];
			[[self representedObject] removeObserver: self forKeyPath: @"mousePosition"];
		}
		
		[super setRepresentedObject: representedObject];
		
		if (representedObject)
		{
			//Bind our sensitivity and tracking options to the session settings
			id session = [[[[self view] window] windowController] document];
			
			NSDictionary *trackingOptions = [NSDictionary dictionaryWithObject: [NSNumber numberWithBool: YES]
																		forKey: NSNullPlaceholderBindingOption];
			[self bind: @"trackMouseWhileUnlocked" toObject: session
		   withKeyPath: @"gameSettings.trackMouseWhileUnlocked"
			   options: trackingOptions];
			
			NSDictionary *sensitivityOptions = [NSDictionary dictionaryWithObject: [NSNumber numberWithFloat: 1.0f]
																		   forKey: NSNullPlaceholderBindingOption];
			[self bind: @"mouseSensitivity" toObject: session
		   withKeyPath: @"gameSettings.mouseSensitivity"
			   options: sensitivityOptions];
			
			//Sync our mouse state to the emulator’s own mouse state
			//TODO: eliminate these bindings as they won’t function across process boundaries
			[self bind: @"mouseActive" toObject: representedObject withKeyPath: @"mouseActive" options: nil];
			[representedObject addObserver: self forKeyPath: @"mousePosition" options: 0 context: nil];
		}
	}
}

- (void) observeValueForKeyPath: (NSString *)keyPath
					   ofObject: (id)object
						 change: (NSDictionary *)change
						context: (void *)context
{
	//This is the only value we're observing, so don't bother checking the key path
	[self _emulatorCursorMovedToPointInCanvas: [object mousePosition]];
}

	
#pragma mark -
#pragma mark Cursor and event state handling

- (BOOL) mouseInView
{
	if ([[self controller] isFullScreen] || [self mouseLocked]) return YES;
	
	NSPoint mouseLocation = [[[self view] window] mouseLocationOutsideOfEventStream];
	NSPoint pointInView = [[self view] convertPoint: mouseLocation fromView: nil];
	return [[self view] mouse: pointInView inRect: [[self view] bounds]];
}

- (void) cursorUpdate: (NSEvent *)theEvent
{
	if ([self _controlsCursor])
	{
		if (![cursorFade isAnimating])
		{
			//Make the cursor fade from the beginning rather than where it left off
			[cursorFade setCurrentProgress: 0.0f];
			[cursorFade startAnimation];
		}
	}
	else
	{
		[cursorFade stopAnimation];
	}
}

- (BOOL) animationShouldChangeCursor: (BXCursorFadeAnimation *)animation
{
	//If the mouse is still inside the view, let the cursor change proceed
	if ([self _controlsCursor]) return YES;
	//If the mouse has left the view, cancel the animation and don't change the cursor
	else
	{
		if ([animation isAnimating]) [animation stopAnimation];
		return NO;
	}
}

- (void) didResignKey
{
	[self setMouseLocked: NO];
	[[self representedObject] lostFocus];
}

#pragma mark -
#pragma mark Mouse events

- (void) mouseDown: (NSEvent *)theEvent
{		
	//Only respond to clicks if we're locked or tracking mouse input while unlocked
	if ([self _controlsCursorWhileMouseInside])
	{
		BXInputHandler *inputHandler = (BXInputHandler *)[self representedObject];

		NSUInteger modifiers = [theEvent modifierFlags];
		BOOL optModified	= (modifiers & NSAlternateKeyMask) > 0;
		BOOL ctrlModified	= (modifiers & NSControlKeyMask) > 0;
		BOOL cmdModified	= (modifiers & NSCommandKeyMask) > 0;
			
		//Cmd-clicking toggles mouse-locking
		if (cmdModified)
		{
			[self toggleMouseLocked: self];
		}		
		//Ctrl-Opt-clicking simulates a simultaneous left- and right-click
		//(for those rare games that need it, like Syndicate)
		else if (optModified && ctrlModified)
		{
			simulatedMouseButtons |= BXSimulatedButtonLeftAndRight;
			[inputHandler mouseButtonPressed: OSXMouseButtonLeft withModifiers: modifiers];
			[inputHandler mouseButtonPressed: OSXMouseButtonRight withModifiers: modifiers];
		}
		
		//Ctrl-clicking simulates a right mouse-click
		else if (ctrlModified)
		{
			simulatedMouseButtons |= BXSimulatedButtonRight;
			[inputHandler mouseButtonPressed: OSXMouseButtonRight withModifiers: modifiers];
		}
		
		//Opt-clicking simulates a middle mouse-click
		else if (optModified)
		{
			simulatedMouseButtons |= BXSimulatedButtonMiddle;
			[inputHandler mouseButtonPressed: OSXMouseButtonMiddle withModifiers: modifiers];
		}
		
		//Otherwise, pass the left click on as-is
		else [inputHandler mouseButtonPressed: OSXMouseButtonLeft withModifiers: modifiers];
	}
	//A single click on the window will lock the mouse if unlocked-tracking is disabled or we're in fullscreen mode
	else if (![self trackMouseWhileUnlocked])
	{
		[self toggleMouseLocked: self];
	}
	//Otherwise, let the mouse event pass on unmolested
	else
	{
		[super mouseDown: theEvent];
	}
}

- (void) rightMouseDown: (NSEvent *)theEvent
{
	if ([self _controlsCursorWhileMouseInside])
	{
		[[self representedObject] mouseButtonPressed: OSXMouseButtonRight
									   withModifiers: [theEvent modifierFlags]];
	}
	else
	{
		[super rightMouseDown: theEvent];
	}
}

- (void) otherMouseDown: (NSEvent *)theEvent
{
	if ([self _controlsCursorWhileMouseInside] && [theEvent buttonNumber] == OSXMouseButtonMiddle)
	{
		[[self representedObject] mouseButtonPressed: OSXMouseButtonMiddle
									   withModifiers: [theEvent modifierFlags]];
	}
	else
	{
		[super otherMouseDown: theEvent];
	}
}

- (void) mouseUp: (NSEvent *)theEvent
{
	if ([self _controlsCursorWhileMouseInside])
	{
		id inputHandler = [self representedObject];
		NSUInteger modifiers = [theEvent modifierFlags];

		if (simulatedMouseButtons)
		{
			if (simulatedMouseButtons & BXSimulatedButtonLeftAndRight)
			{
				[inputHandler mouseButtonReleased: OSXMouseButtonLeft withModifiers: modifiers];
				[inputHandler mouseButtonReleased: OSXMouseButtonRight withModifiers: modifiers];
			}
			if (simulatedMouseButtons & BXSimulatedButtonRight)
				[inputHandler mouseButtonReleased: OSXMouseButtonRight withModifiers: modifiers];
			if (simulatedMouseButtons & BXSimulatedButtonMiddle)
				[inputHandler mouseButtonReleased: OSXMouseButtonMiddle withModifiers: modifiers];
			
			simulatedMouseButtons = BXNoSimulatedButtons;
		}
		//Pass the mouse release as-is to our input handler
		else [inputHandler mouseButtonReleased: OSXMouseButtonLeft withModifiers: modifiers];
	}
	else
	{
		[super mouseUp: theEvent];
	}
}

- (void) rightMouseUp:(NSEvent *)theEvent
{
	if ([self _controlsCursorWhileMouseInside])
	{
		[[self representedObject] mouseButtonReleased: OSXMouseButtonRight
										withModifiers: [theEvent modifierFlags]];
	}
	else
	{
		[super rightMouseUp: theEvent];
	}

}

- (void) otherMouseUp:(NSEvent *)theEvent
{
	//Only pay attention to the middle mouse button; all others can do as they will
	if ([theEvent buttonNumber] == OSXMouseButtonMiddle && [self _controlsCursorWhileMouseInside])
	{
		[[self representedObject] mouseButtonReleased: OSXMouseButtonMiddle
										withModifiers: [theEvent modifierFlags]];
	}		
	else
	{
		[super otherMouseUp: theEvent];
	}
}

//Work out mouse motion relative to the view's canvas, passing on the current position
//and movement delta to the emulator's input handler.
//We represent position and delta as as a fraction of the canvas rather than as a fixed unit
//position, so that they stay consistent when the view size changes.
- (void) mouseMoved: (NSEvent *)theEvent
{	
	//Only apply mouse movement if we're locked or we're accepting unlocked mouse input
	if ([self _controlsCursorWhileMouseInside])
	{
		NSRect canvas = [[self view] bounds];
		CGFloat width = canvas.size.width;
		CGFloat height = canvas.size.height;
		
		NSPoint pointOnCanvas, delta;

		//Make the delta relative to the canvas
		delta = NSMakePoint([theEvent deltaX] / width,
							[theEvent deltaY] / height);		
		
		//If we have just warped the mouse, the delta above will include the distance warped
		//as well as the actual distance moved in this mouse event: so, we subtract the warp.
		if (!NSEqualPoints(distanceWarped, NSZeroPoint))
		{
			delta.x -= distanceWarped.x;
			delta.y -= distanceWarped.y;
		}
		
		if (![self mouseLocked])
		{
			NSPoint pointInView	= [[self view] convertPoint: [theEvent locationInWindow]
												   fromView: nil];
			pointOnCanvas = NSMakePoint(pointInView.x / width,
										pointInView.y / height);

			//Clamp the position to within the canvas.
			pointOnCanvas = clampPointToRect(pointOnCanvas, canvasBounds);
		}
		else
		{
			//While the mouse is locked, OS X won't update the absolute cursor position and
			//DOSBox won't pay attention to the absolute cursor position either, so we don't
			//bother calculating it.
			pointOnCanvas = NSZeroPoint;
			
			//While the mouse is locked, we apply our mouse sensitivity to the delta.
			delta.x *= mouseSensitivity;
			delta.y *= mouseSensitivity;
		}
		
		//Tells _emulatorCursorMovedToPointInCanvas: not to warp the mouse cursor based on
		//DOSBox mouse position updates from this call.
		updatingMousePosition = YES;
		
		[[self representedObject] mouseMovedToPoint: pointOnCanvas
										   byAmount: delta
										   onCanvas: canvas
										whileLocked: [self mouseLocked]];
		
		//Resume paying attention to mouse position updates
		updatingMousePosition = NO;
	}
	else
	{
		[super mouseMoved: theEvent];
	}
	//Always reset our internal warp tracking after every mouse movement event,
	//even if the event is not handled.
	distanceWarped = NSZeroPoint;
}

//Treat drag events as simple mouse movement
- (void) mouseDragged: (NSEvent *)theEvent		{ [self mouseMoved: theEvent]; }
- (void) rightMouseDragged: (NSEvent *)theEvent	{ return [self mouseDragged: theEvent]; }
- (void) otherMouseDragged: (NSEvent *)theEvent	{ return [self mouseDragged: theEvent]; }


- (void) mouseExited: (NSEvent *)theEvent
{
	[self willChangeValueForKey: @"mouseInView"];
	[super mouseExited: theEvent];
	[self didChangeValueForKey: @"mouseInView"];
}

- (void) mouseEntered: (NSEvent *)theEvent
{
	[self willChangeValueForKey: @"mouseInView"];
	[super mouseEntered: theEvent];
	[self didChangeValueForKey: @"mouseInView"];
}

#pragma mark -
#pragma mark Key events

- (void) keyDown: (NSEvent *)theEvent
{
	//Pressing ESC while in fullscreen mode and not running a program will exit fullscreen mode. 	
	if ([[theEvent charactersIgnoringModifiers] isEqualToString: @"\e"] &&
		[[self controller] isFullScreen] &&
		![[[self representedObject] emulator] isRunningProcess])
	{
		[NSApp sendAction: @selector(exitFullScreen:) to: nil from: self];
	}
	
	//If the keypress was command-modified, don't pass it on to the emulator as it indicates
	//a failed key equivalent.
	//(This is consistent with how other OS X apps with textinput handle Cmd-keypresses.)
	else if ([theEvent modifierFlags] & NSCommandKeyMask)
		[super keyDown: theEvent];
	
	//Otherwise, pass the keypress on to our input handler.
	else [[self representedObject] sendKeyEventWithCode: [theEvent keyCode]
												pressed: YES
										  withModifiers: [theEvent modifierFlags]];
}

- (void) keyUp: (NSEvent *)theEvent
{
	//If the keypress was command-modified, don't pass it on to the emulator as it indicates
	//a failed key equivalent.
	//(This is consistent with how other OS X apps with textinput handle Cmd-keypresses.)
	if ([theEvent modifierFlags] & NSCommandKeyMask)
		[super keyUp: theEvent];
	
	[[self representedObject] sendKeyEventWithCode: [theEvent keyCode]
										   pressed: NO withModifiers:
	 [theEvent modifierFlags]];
}

//Convert flag changes into proper key events
- (void) flagsChanged: (NSEvent *)theEvent
{
	unsigned short keyCode	= [theEvent keyCode];
	NSUInteger modifiers	= [theEvent modifierFlags];
	NSUInteger flag;
	
	//We can determine which modifier key was involved by its key code,
	//but we can't determine from the event whether it was pressed or released.
	//So, we check whether the corresponding modifier flag is active or not.	
	switch (keyCode)
	{
		case kVK_Control:		flag = BXLeftControlKeyMask;	break;
		case kVK_Option:		flag = BXLeftAlternateKeyMask;	break;
		case kVK_Shift:			flag = BXLeftShiftKeyMask;		break;
			
		case kVK_RightControl:	flag = BXRightControlKeyMask;	break;
		case kVK_RightOption:	flag = BXRightAlternateKeyMask;	break;
		case kVK_RightShift:	flag = BXRightShiftKeyMask;		break;
			
		case kVK_CapsLock:		flag = NSAlphaShiftKeyMask;		break;
			
		default:
			//Ignore all other modifier types
			return;
	}
	
	BOOL pressed = (modifiers & flag) == flag;
	
	//Implementation note: you might think that CapsLock has to be handled differently since
	//it's a toggle. However, DOSBox expects a keydown event when CapsLock is toggled on,
	//and a keyup event when CapsLock is toggled off, so this default behaviour is fine.
	
	[[self representedObject] sendKeyEventWithCode: keyCode
										   pressed: pressed
									 withModifiers: modifiers];
}


#pragma mark -
#pragma mark Simulating keyboard events

- (IBAction) sendEnter: (id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_Return]; }
- (IBAction) sendF1:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F1]; }
- (IBAction) sendF2:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F2]; }
- (IBAction) sendF3:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F3]; }
- (IBAction) sendF4:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F4]; }
- (IBAction) sendF5:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F5]; }
- (IBAction) sendF6:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F6]; }
- (IBAction) sendF7:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F7]; }
- (IBAction) sendF8:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F8]; }
- (IBAction) sendF9:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F9]; }
- (IBAction) sendF10:	(id)sender	{ [[self representedObject] sendKeypressWithCode: kVK_F10]; }


#pragma mark -
#pragma mark Mouse focus and locking 
	 
- (IBAction) toggleMouseLocked: (id)sender
{
	BOOL lock;
	BOOL wasLocked = [self mouseLocked];
	
	if ([sender respondsToSelector: @selector(boolValue)]) lock = [sender boolValue];
	else lock = !wasLocked;
	
	[self setMouseLocked: lock];
	
	//If the mouse state was actually toggled, play a sound to commemorate the occasion
	if ([self mouseLocked] != wasLocked)
	{
		NSString *lockSoundName	= (wasLocked) ? @"LockOpening" : @"LockClosing";
		[[NSApp delegate] playUISoundWithName: lockSoundName atVolume: BXMouseLockSoundVolume];
	}
}

- (IBAction) toggleTrackMouseWhileUnlocked: (id)sender
{
	BOOL track = [self trackMouseWhileUnlocked];
	[self setTrackMouseWhileUnlocked: !track];
}

- (BOOL) validateMenuItem: (NSMenuItem *)menuItem
{
	SEL theAction = [menuItem action];
	
	if (theAction == @selector(toggleMouseLocked:))
	{
		[menuItem setState: [self mouseLocked]];
		return [self canLockMouse];
	}
	else if (theAction == @selector(toggleTrackMouseWhileUnlocked:))
	{
		[menuItem setState: [self trackMouseWhileUnlocked]];
		return YES;
	}
	return YES;
}

- (void) setMouseLocked: (BOOL)lock
{	
	//Don't continue if we're already in the right lock state
	if (lock == [self mouseLocked]) return;
	
	//Don't allow the mouse to be locked unless we're the frontmost application
	//and the game has indicated mouse support
	if (lock && ![self canLockMouse]) return;
	
	//When locking, also activate the DOS window.
	if (lock) [[[self view] window] makeKeyAndOrderFront: self];
	
	[self _applyMouseLockState: lock];
	mouseLocked = lock;
	
	//Let everybody know we've grabbed the mouse
	NSString *notification = (lock) ? BXSessionDidLockMouseNotification : BXSessionDidUnlockMouseNotification;
	id session = [[[[self view] window] windowController] document];
	
	[[NSNotificationCenter defaultCenter] postNotificationName: notification object: session]; 
}

- (void) setMouseActive: (BOOL)active
{
	mouseActive = active;
	[self cursorUpdate: nil];
	//Release the mouse lock when the game stops using the mouse, unless we're in fullscreen mode
	if (!active && ![[self controller] isFullScreen]) [self setMouseLocked: NO];
}

- (void) setTrackMouseWhileUnlocked: (BOOL)track
{	
	trackMouseWhileUnlocked = track;
	
	//If we're disabling tracking, and the mouse is currently unlocked,
	//then warp the mouse to the center of the window as if we had just unlocked it.
	
	//Disabled for now because this makes the mouse jumpy and unpredictable.
	if (NO && !track && ![self mouseLocked])
		[self _syncDOSCursorToPointInCanvas: NSMakePoint(0.5f, 0.5f)];
}

- (BOOL) trackMouseWhileUnlocked
{
	//Tweak: when in fullscreen mode, ignore the current mouse-tracking setting.
	return trackMouseWhileUnlocked && ![[self controller] isFullScreen];
}

- (BOOL) canLockMouse
{
	return [NSApp isActive] && ([self mouseActive] || [[self controller] isFullScreen]); 
}

#pragma mark -
#pragma mark Private methods

- (BOOL) _controlsCursor
{
	return [self _controlsCursorWhileMouseInside] && [[[self view] window] isKeyWindow] && [self mouseInView];
}

- (BOOL) _controlsCursorWhileMouseInside
{
	return [self mouseActive] && ([self mouseLocked] || [self trackMouseWhileUnlocked]);
}

- (NSPoint) _pointOnScreen: (NSPoint)canvasPoint
{
	NSRect canvas = [[self view] bounds];
	NSPoint pointInView = NSMakePoint(canvasPoint.x * canvas.size.width,
									  canvasPoint.y * canvas.size.height);
	
	NSPoint pointInWindow = [[self view] convertPoint: pointInView toView: nil];
	NSPoint pointOnScreen = [[[self view] window] convertBaseToScreen: pointInWindow];
	
	return pointOnScreen;
}

- (NSPoint) _pointInCanvas: (NSPoint)screenPoint
{
	NSPoint pointInWindow	= [[[self view] window] convertScreenToBase: screenPoint];
	NSPoint pointInView		= [[self view] convertPoint: pointInWindow fromView: nil];
	
	NSRect canvas = [[self view] bounds];
	NSPoint pointInCanvas = NSMakePoint(pointInView.x / canvas.size.width,
										pointInView.y / canvas.size.height);
	
	return pointInCanvas;	
}

- (void) _applyMouseLockState: (BOOL)lock
{
	//Ensure we don't "over-hide" the cursor if it's already hidden,
	//since [NSCursor hide] stacks.
	//IMPLEMENTATION NOTE: we also used to check CGCursorIsVisible when
	//unhiding too, but this broke with Cmd-Tabbing and there's no danger
	//of "over-unhiding" anyway.
	if		(CGCursorIsVisible() && lock)	[NSCursor hide];
	else if (!lock)							[NSCursor unhide];
	
	//Reset any custom faded cursor to the default arrow cursor.
	[[NSCursor arrowCursor] set];
	
	//Associate/disassociate the mouse and the OS X cursor
	CGAssociateMouseAndMouseCursorPosition(!lock);
	
	if (lock)
	{
		//If we're locking the mouse and the cursor is outside of the view,
		//then warp it to the center of the DOS view.
		//This prevents mouse clicks from going to other windows.
		//(We avoid warping if the mouse is already over the view,
		//as this would cause an input delay.)
		if (![self mouseInView]) [self _syncOSXCursorToPointInCanvas: NSMakePoint(0.5f, 0.5f)];
		
		//If we weren't tracking the mouse while it was unlocked, then warp the DOS mouse cursor
		//Disabled for now, because this makes the mouse behaviour jumpy and unpredictable.
		
		if (NO && ![self trackMouseWhileUnlocked])
		{
			NSPoint mouseLocation = [NSEvent mouseLocation];
			NSPoint canvasLocation = [self _pointInCanvas: mouseLocation];
			
			[self _syncDOSCursorToPointInCanvas: canvasLocation];
		}
	}
	else
	{
		//If we're unlocking the mouse, then sync the OS X mouse cursor
		//to wherever DOSBox's cursor is located within the view.
		NSPoint mousePosition = [[self representedObject] mousePosition];
		
		//Constrain the cursor position to slightly inset within the view:
		//This ensures the mouse doesn't appear outside the view or right
		//at the view's edge, which looks ugly.
		mousePosition = clampPointToRect(mousePosition, visibleCanvasBounds);
		
		[self _syncOSXCursorToPointInCanvas: mousePosition];
		
		//If we don't track the mouse while unlocked, then also tell DOSBox
		//to warp the mouse to the center of the canvas; this will prevent
		//the leftover position from latently causing unintended input
		//(such as scrolling or turning).
		
		//Disabled for now because this makes the mouse jumpy and unpredictable.
		if (NO && ![self trackMouseWhileUnlocked])
		{
			[self _syncDOSCursorToPointInCanvas: NSMakePoint(0.5f, 0.5f)];
		}
	}
}

- (void) _emulatorCursorMovedToPointInCanvas: (NSPoint)pointInCanvas
{	
	//If the mouse warped of its own accord, and we have control of the cursor,
	//then sync the OS X mouse cursor to match DOSBox's.
	//(We only bother doing this if the mouse is unlocked; there's no point doing
	//otherwise, since we'll sync the cursors when we unlock.)
	if (!updatingMousePosition && ![self mouseLocked] && [self _controlsCursor])
	{
		//Don't sync if the mouse was warped to the 0, 0 point:
		//This indicates a game testing the extents of the mouse canvas.
		if (NSEqualPoints(pointInCanvas, NSZeroPoint)) return;
		
		//Don't sync if the mouse was warped outside the canvas:
		//This would place the mouse cursor beyond the confines of the window.
		if (!NSPointInRect(pointInCanvas, canvasBounds)) return;
		
		//Because syncing the OS X cursor causes a slight but noticeable input delay,
		//we check how far it moved and ignore small distances.
		NSPoint oldPointInCanvas = [self _pointInCanvas: [NSEvent mouseLocation]];
		NSPoint distance = deltaFromPointToPoint(oldPointInCanvas, pointInCanvas);

		if (!NSPointInRect(distance, cursorWarpDeadzone))
			[self _syncOSXCursorToPointInCanvas: pointInCanvas];
	}
}

- (void) _syncOSXCursorToPointInCanvas: (NSPoint)pointInCanvas
{
	NSPoint oldPointOnScreen	= [NSEvent mouseLocation];
	NSPoint pointOnScreen		= [self _pointOnScreen: pointInCanvas];
	
	//Warping the mouse won't generate a mouseMoved event, but it will mess up the delta on the 
	//next mouseMoved event to reflect the distance the mouse was warped. So, we determine how
	//far the mouse was warped, and will subtract that from the next mouse delta calculation.
	NSPoint oldPointInCanvas = [self _pointInCanvas: oldPointOnScreen];
	distanceWarped = deltaFromPointToPoint(oldPointInCanvas, pointInCanvas);
	
	
	CGPoint cgPointOnScreen = NSPointToCGPoint(pointOnScreen);
	//Flip the coordinates to compensate for AppKit's bottom-left screen origin
	NSRect screenFrame = [[[[self view] window] screen] frame];
	cgPointOnScreen.y = screenFrame.origin.y + screenFrame.size.height - cgPointOnScreen.y;
	
	//TODO: check that this behaves correctly across multiple displays.
	CGWarpMouseCursorPosition(cgPointOnScreen);
}

- (void) _syncDOSCursorToPointInCanvas: (NSPoint)pointInCanvas
{
	NSPoint delta = deltaFromPointToPoint([[self representedObject] mousePosition], pointInCanvas);
	[[self representedObject] mouseMovedToPoint: pointInCanvas
									   byAmount: delta
									   onCanvas: [[self view] bounds]
									whileLocked: NO];
}
@end
