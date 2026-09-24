/* Functions for GUI implemented with Cocoa AppKit on macOS.
   Copyright (C) 2008-2025  YAMAMOTO Mitsuharu

This file is part of GNU Emacs Mac port.

GNU Emacs Mac port is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs Mac port is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs Mac port.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>
#include "lisp.h"
#include "blockinput.h"

#include "macterm.h"

#include <sys/socket.h>
#include <execinfo.h>

#include "character.h"
#include "frame.h"
#include "dispextern.h"
#include "fontset.h"
#include "termhooks.h"
#include "buffer.h"
#include "window.h"
#include "keyboard.h"
#include "keymap.h"
#include "macfont.h"
#include "menu.h"
#include "atimer.h"
#include "regex-emacs.h"

#import "macappkit.h"
#import <objc/runtime.h>

#ifdef USE_METAL_RENDERING
#include "macmetal.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

#if USE_ARC
#define MRC_RETAIN(receiver)		((id) (receiver))
#define MRC_RELEASE(receiver)
#define MRC_AUTORELEASE(receiver)	((id) (receiver))
#define CF_ESCAPING_BRIDGE		CFBridgingRetain
#else
#define MRC_RETAIN(receiver)		[(receiver) retain]
#define MRC_RELEASE(receiver)		[(receiver) release]
#define MRC_AUTORELEASE(receiver)	[(receiver) autorelease]
#define CF_ESCAPING_BRIDGE(X)		((CFTypeRef) (X))
#endif

/************************************************************************
			       General
 ************************************************************************/

enum {
  ANY_MOUSE_EVENT_MASK = (NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
			  | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp
			  | NSEventMaskMouseMoved
			  | NSEventMaskLeftMouseDragged
			  | NSEventMaskRightMouseDragged
			  | NSEventMaskMouseEntered | NSEventMaskMouseExited
			  | NSEventMaskScrollWheel
			  | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp
			  | NSEventMaskOtherMouseDragged),
  ANY_MOUSE_DOWN_EVENT_MASK = (NSEventMaskLeftMouseDown
			       | NSEventMaskRightMouseDown
			       | NSEventMaskOtherMouseDown),
  ANY_MOUSE_UP_EVENT_MASK = (NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp
			     | NSEventMaskOtherMouseUp)
};

enum {
  ANY_KEY_MODIFIER_FLAGS_MASK = (NSEventModifierFlagCapsLock
				 | NSEventModifierFlagShift
				 | NSEventModifierFlagControl
				 | NSEventModifierFlagOption
				 | NSEventModifierFlagCommand
				 | NSEventModifierFlagNumericPad
				 | NSEventModifierFlagHelp
				 | NSEventModifierFlagFunction)
};

#define CFOBJECT_TO_LISP_FLAGS_FOR_EVENT			\
  (CFOBJECT_TO_LISP_WITH_TAG					\
   | CFOBJECT_TO_LISP_DONT_DECODE_STRING			\
   | CFOBJECT_TO_LISP_DONT_DECODE_DICTIONARY_KEY)

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101300
#define NS_TOUCH_BAR	NSTouchBar
#define NS_CUSTOM_TOUCH_BAR_ITEM NSCustomTouchBarItem
#define NS_CANDIDATE_LIST_TOUCH_BAR_ITEM	NSCandidateListTouchBarItem
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CHARACTER_PICKER	\
  NSTouchBarItemIdentifierCharacterPicker
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST \
  NSTouchBarItemIdentifierCandidateList
#else
#define NS_TOUCH_BAR	(NSClassFromString (@"NSTouchBar"))
#define NS_CUSTOM_TOUCH_BAR_ITEM (NSClassFromString (@"NSCustomTouchBarItem"))
#define NS_CANDIDATE_LIST_TOUCH_BAR_ITEM \
  (NSClassFromString (@"NSCandidateListTouchBarItem"))
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CHARACTER_PICKER \
  (@"NSTouchBarItemIdentifierCharacterPicker")
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST \
  (@"NSTouchBarItemIdentifierCandidateList")
#endif

static void mac_within_gui_and_here (void (^) (void),
				     void (^) (void));
static void mac_within_gui_allowing_inner_lisp (void (^) (void));
static void mac_within_lisp (void (^) (void));
static void mac_within_lisp_deferred_unless_popup (void (^) (void));

static void mac_draw_queue_sync(void);

/* True if the persistent event loop is selected for this process.
   The GUI thread then runs -[NSApplication run] for the process
   lifetime and touches Lisp state only with "Lisp access"; see the
   "Persistent event loop" section.  Decided once in `main'.  */
static bool mac_persistent_loop_p;
static bool mac_trace_loop_p;

#define MAC_TRACE_LOOP(...)						\
  do {									\
    if (mac_trace_loop_p)						\
      {									\
	fprintf (stderr, "mac-loop: %.3f %s ", mac_system_uptime (),	\
		 pthread_main_np () ? "G" : "L");			\
	fprintf (stderr, __VA_ARGS__);					\
      }									\
  } while (false)

/* Kinds of Lisp access of the GUI thread.  */
enum
  {
    MAC_LOOP_NO_ACCESS = 0,
    MAC_LOOP_BORROWED_ACCESS = 1,
    MAC_LOOP_LOCKED_ACCESS = 2
  };

static int mac_loop_begin_lisp_access (void);
static void mac_loop_end_lisp_access (int);
static bool mac_loop_gui_has_lisp_access (void);
static void mac_loop_with_lisp_access_or_defer (void (^) (void));
static void mac_loop_send_event (NSEvent *);
static void mac_loop_queue_input_event (const struct input_event *);
static void mac_loop_wake_lisp (void);
static int mac_loop_read_socket_events (struct input_event *);
static void mac_loop_complete_launch (void);
static void mac_loop_note_menu_selection (NSInteger);
static void mac_loop_with_access_now_or_later (void (^) (void));
static bool mac_loop_quit_begin (void);
static void mac_loop_quit_clear (void);
static void mac_loop_resolve_pending_indicators (void);

/* Persistent loop (W7/W8): number of pending close/Quit requests not
   yet resolved by Lisp.  mac_loop_select checks this so idle Lisp
   clears them without walking frames when nothing is pending.  */
static int mac_loop_pending_indicator_count;

/* Use at the start of a query method (accessibility, text input) that
   reads Lisp or buffer state and returns a value of TYPE.  Without Lisp
   access it takes access by try-lock for CALL, or returns FALLBACK
   when Lisp is busy.  */
#define MAC_LOOP_QUERY_NEEDS_LISP(type, fallback, call)			\
  do {									\
    if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())	\
      {									\
	int token_ = mac_loop_begin_lisp_access ();			\
									\
	if (token_ == MAC_LOOP_NO_ACCESS)				\
	  return fallback;						\
	type result_ = call;						\
	mac_loop_end_lisp_access (token_);				\
	return result_;							\
      }									\
  } while (false)

/* Use at the start of an AppKit callback that touches Lisp or
   redisplay state.  Without Lisp access, re-run the callback later on
   the GUI thread with access and return.  */
#define MAC_LOOP_CALLBACK_NEEDS_LISP(call)				\
  do {									\
    if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())	\
      {									\
	mac_loop_with_access_now_or_later (^{call;});			\
	return;								\
      }									\
  } while (false)
/* Like MAC_LOOP_CALLBACK_NEEDS_LISP, for a callback that only brings
   Lisp up to date with the current state of an AppKit object (W1, W6,
   W10).  Such a callback reads that state when it runs, so a deferred
   one replaces any pending callback with the same KEY (a string
   literal) for the same receiver, instead of queueing another one.  */
#define MAC_LOOP_STATE_CALLBACK_NEEDS_LISP(key, call)			\
  do {									\
    if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())	\
      {									\
	mac_loop_with_access_now_or_later_coalesced (self, key,	\
						     ^{call;});		\
	return;								\
      }									\
  } while (false)
static void mac_loop_with_access_now_or_later_coalesced (id, const char *,
							 void (^) (void));
static void mac_loop_within_gui (void (^) (void));
static bool mac_loop_within_lisp (void (^) (void));
static bool mac_loop_defer_to_request (void (^) (void));
static void mac_loop_queue_lisp_block (void (^) (void));

/* Nonzero while the GUI thread handles an event with Lisp access, so
   that nested -[NSApplication sendEvent:] calls go to AppKit.  */
static int mac_loop_dispatch_depth;

/* Holds a quit event met while the GUI thread handles events outside
   read_socket; forwarded to the Lisp thread afterwards.  */
static struct input_event mac_loop_gui_hold_quit;
static struct input_event *mac_loop_lisp_hold_quit;
static int mac_loop_request_depth;
static bool mac_loop_test_recording_p;
static void mac_loop_test_record (const char *, ...);

/* Access tokens of nested mac_try_buffer_and_glyph_matrix_access.  */
static int mac_loop_access_tokens[16];
static int mac_loop_access_token_depth;

static int mac_loop_select (int, fd_set *, fd_set *, fd_set *,
			    struct timespec *, sigset_t *);
static void mac_loop_begin_launch (void);

#define MAC_SELECT_ALLOW_LISP_EVALUATION 1
#if MAC_SELECT_ALLOW_LISP_EVALUATION
static bool mac_select_allow_lisp_evaluation;
#endif

/* A configured default enables both paths for Finder/Dock launches.
   Environment flags remain available for opt-in testing of other builds.  */
static bool
mac_native_menus_enabled_p (void)
{
  /* The persistent loop does not use the native-menu experiments.  */
  if (mac_persistent_loop_p)
    return false;
#ifdef MAC_NATIVE_MENUS_DEFAULT
  return true;
#else
  return getenv ("EMACS_MAC_NATIVE_MENUS") != NULL;
#endif
}

static bool
mac_worker_menus_enabled_p (void)
{
  if (mac_persistent_loop_p)
    return false;
#ifdef MAC_NATIVE_MENUS_DEFAULT
  return true;
#else
  return getenv ("EMACS_MAC_WORKER_MENUS") != NULL;
#endif
}

/* Opt-in diagnostics for native menu activation.  Do not log menu titles
   or Lisp contents: only lifecycle ordering and callback eligibility.  */
static void
mac_trace_menu_lifecycle (const char *phase, NSMenu *menu, NSInteger tag)
{
  if (getenv ("EMACS_MAC_TRACE_MENUS"))
    NSLog (@"Emacs menu: %s menu=%p main=%d popup=%d lisp=%d tag=%ld",
           phase, menu, menu == [NSApp mainMenu], popup_activated (),
           mac_select_allow_lisp_evaluation, (long) tag);
}

@implementation NSData (Emacs)

/* Return a unibyte Lisp string.  */

- (Lisp_Object)lispString
{
  return cfdata_to_lisp ((__bridge CFDataRef) self);
}

@end				// NSData (Emacs)

@implementation NSString (Emacs)

/* Return a string created from the Lisp string.  May cause GC.  */

+ (instancetype)stringWithLispString:(Lisp_Object)lispString
{
  return CFBridgingRelease (cfstring_create_with_string (lispString));
}

/* Return a string created from the unibyte Lisp string in UTF 8.  */

+ (instancetype)stringWithUTF8LispString:(Lisp_Object)lispString
{
  return CFBridgingRelease (cfstring_create_with_string_noencode
			    (lispString));
}

/* Like -[NSString stringWithUTF8String:], but fall back on Mac-Roman
   if BYTES cannot be interpreted as UTF-8 bytes and FLAG is YES. */

+ (instancetype)stringWithUTF8String:(const char *)bytes fallback:(BOOL)flag
{
  id string = [self stringWithUTF8String:bytes];

  if (string == nil && flag)
    string = CFBridgingRelease (CFStringCreateWithCString
				(NULL, bytes, kCFStringEncodingMacRoman));

  return string;
}

/* Return a multibyte Lisp string.  May cause GC.  */

- (Lisp_Object)lispString
{
  return cfstring_to_lisp ((__bridge CFStringRef) self);
}

/* Return a unibyte Lisp string in UTF 8.  */

- (Lisp_Object)UTF8LispString
{
  return cfstring_to_lisp_nodecode ((__bridge CFStringRef) self);
}

/* Return a unibyte Lisp string in UTF 16 (native byte order, no BOM).  */

- (Lisp_Object)UTF16LispString
{
  return cfstring_to_lisp_utf_16 ((__bridge CFStringRef) self);
}

/* Return an array containing substrings from the receiver that have
   been divided by "camelcasing".  If SEPARATOR is non-nil, it
   specifies separating characters that are used instead of upper case
   letters.  */

- (NSArrayOf (NSString *) *)componentsSeparatedByCamelCasingWithCharactersInSet:(NSCharacterSet *)separator
{
  NSMutableArrayOf (NSString *) *result = [NSMutableArray arrayWithCapacity:0];
  NSUInteger length = [self length];
  NSRange upper = NSMakeRange (0, 0), rest = NSMakeRange (0, length);

  if (separator == nil)
    separator = [NSCharacterSet uppercaseLetterCharacterSet];

  while (rest.length != 0)
    {
      NSRange next = [self rangeOfCharacterFromSet:separator options:0
					     range:rest];

      if (next.location == rest.location)
	upper.length = next.location - upper.location;
      else
	{
	  NSRange capitalized;

	  if (next.location == NSNotFound)
	    next.location = length;
	  if (upper.length)
	    [result addObject:[self substringWithRange:upper]];
	  capitalized.location = NSMaxRange (upper);
	  capitalized.length = next.location - capitalized.location;
	  [result addObject:[self substringWithRange:capitalized]];
	  upper = NSMakeRange (next.location, 0);
	  if (next.location == length)
	    break;
	}
      rest.location = NSMaxRange (next);
      rest.length = length - rest.location;
    }

  if (rest.length == 0 && length != 0)
    {
      upper.length = length - upper.location;
      [result addObject:[self substringWithRange:upper]];
    }

  return result;
}

@end				// NSString (Emacs)

@implementation NSMutableArray (Emacs)

- (void)enqueue:(id)obj
{
  @synchronized (self)
  {
    [self addObject:(obj ? obj : NSNull.null)];
  }
}

- (id)dequeue
{
  id obj;

  @synchronized (self)
  {
    obj = self[0];
    obj = (obj == NSNull.null) ? nil : MRC_AUTORELEASE (MRC_RETAIN (obj));
    [self removeObjectAtIndex:0];
  }

  return obj;
}

@end				// NSMutableArray (Emacs)

@implementation NSFont (Emacs)

/* Return an NSFont object for the specified FACE.  */

+ (NSFont *)fontWithFace:(struct face *)face
{
  if (face == NULL || face->font == NULL)
    return nil;

  return (__bridge NSFont *) macfont_get_nsctfont (face->font);
}

@end				// NSFont (Emacs)

@implementation NSEvent (Emacs)

- (NSEvent *)mouseEventByChangingType:(NSEventType)type
			  andLocation:(NSPoint)location
{
  NSInteger clickCount = [self clickCount];

  /* Dragging via Screen Sharing.app sets clickCount to 0, and it
     disables updating screen during resize on macOS 10.12.  */
  return [NSEvent
	   mouseEventWithType:type location:location
		modifierFlags:[self modifierFlags]
		    timestamp:(mac_system_uptime ())
		 windowNumber:[self windowNumber]
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101200
		      context:nil
#else
		      context:[self context]
#endif
		  eventNumber:[self eventNumber]
		   clickCount:(clickCount ? clickCount : 1)
		     pressure:[self pressure]];
}

static void
mac_cgevent_set_unicode_string_from_event_ref (CGEventRef cgevent,
					       EventRef eventRef)
{
  ByteCount size;

  if (GetEventParameter (eventRef, kEventParamKeyUnicodes,
			 typeUnicodeText, NULL, 0, &size, NULL) == noErr)
    {
      UniChar *text = alloca (size);

      if (GetEventParameter (eventRef, kEventParamKeyUnicodes,
			     typeUnicodeText, NULL, size, NULL, text) == noErr)
	CGEventKeyboardSetUnicodeString (cgevent, size / sizeof (UniChar),
					 text);
    }
}

- (CGEventRef)coreGraphicsEvent
{
  CGEventRef event;
  NSEventType type = [self type];

  event = [self CGEvent];
  if (event)
    {
      /* Unicode string is not set if the keyboard event comes from
	 Screen Sharing on Mac OS X 10.6 and later.  */
      if (NSEventMaskFromType (type) & (NSEventMaskKeyDown | NSEventMaskKeyUp))
	{
	  UniCharCount length;

	  CGEventKeyboardGetUnicodeString (event, 0, &length, NULL);
	  if (length == 0)
	    {
	      EventRef eventRef = (EventRef) [self eventRef];

	      mac_cgevent_set_unicode_string_from_event_ref (event, eventRef);
	    }
	}
      return event;
    }

  event = NULL;
  if (NSEventMaskFromType (type) & ANY_MOUSE_EVENT_MASK)
    {
      CGPoint position = CGPointZero;

      GetEventParameter ((EventRef) [self eventRef], kEventParamMouseLocation,
			 typeHIPoint, NULL, sizeof (CGPoint), NULL, &position);
      event = CGEventCreateMouseEvent (NULL, (CGEventType) type, position,
				       [self buttonNumber]);
      /* CGEventCreateMouseEvent on Mac OS X 10.4 does not set
	 type.  */
      CGEventSetType (event, (CGEventType) type);
      if (NSEventMaskFromType (type)
	  & (ANY_MOUSE_DOWN_EVENT_MASK | ANY_MOUSE_UP_EVENT_MASK))
	{
	  CGEventSetIntegerValueField (event, kCGMouseEventClickState,
				       [self clickCount]);
	  CGEventSetDoubleValueField (event, kCGMouseEventPressure,
				      [self pressure]);
	}
    }
  else if (NSEventMaskFromType (type) & (NSEventMaskKeyDown | NSEventMaskKeyUp))
    {
      event = CGEventCreateKeyboardEvent (NULL, [self keyCode],
					  type == NSEventTypeKeyDown);
      CGEventSetIntegerValueField (event, kCGKeyboardEventAutorepeat,
				   [self isARepeat]);
#if __LP64__
      /* This seems to be unnecessary for 32-bit executables.  */
      {
	UInt32 keyboard_type;
	EventRef eventRef = (EventRef) [self eventRef];

	mac_cgevent_set_unicode_string_from_event_ref (event, eventRef);
	if (GetEventParameter (eventRef, kEventParamKeyboardType,
			       typeUInt32, NULL, sizeof (UInt32), NULL,
			       &keyboard_type) == noErr)
	  CGEventSetIntegerValueField (event, kCGKeyboardEventKeyboardType,
				       keyboard_type);
      }
#endif
    }
  if (event == NULL)
    {
      event = CGEventCreate (NULL);
      CGEventSetType (event, (CGEventType) type);
    }
  CGEventSetFlags (event, (CGEventFlags) [self modifierFlags]);
  CGEventSetTimestamp (event, [self timestamp] * kSecondScale);

  return (CGEventRef) CFAutorelease (event);
}

@end				// NSEvent (Emacs)

@implementation NSAttributedString (Emacs)

/* Return a unibyte Lisp string with text properties, in UTF 16
   (native byte order, no BOM).  */

- (Lisp_Object)UTF16LispString
{
  Lisp_Object result = [[self string] UTF16LispString];
  NSUInteger length = [self length];
  NSRange range = NSMakeRange (0, 0);

  while (NSMaxRange (range) < length)
    {
      Lisp_Object attrs = Qnil;
      NSDictionaryOf (NSString *, id) *attributes =
	[self attributesAtIndex:NSMaxRange (range) effectiveRange:&range];

      if (attributes)
	attrs = cfobject_to_lisp ((__bridge CFTypeRef) attributes,
				  CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
      if (CONSP (attrs) && EQ (XCAR (attrs), Qdictionary))
	{
	  Lisp_Object props = Qnil, start, end;

	  for (attrs = XCDR (attrs); CONSP (attrs); attrs = XCDR (attrs))
	    props = Fcons (Fintern (XCAR (XCAR (attrs)), Qnil),
			   Fcons (XCDR (XCAR (attrs)), props));

	  XSETINT (start, range.location * sizeof (unichar));
	  XSETINT (end, NSMaxRange (range) * sizeof (unichar));
	  Fadd_text_properties (start, end, props, result);
	}
    }

  return result;
}

@end				// NSAttributedString (Emacs)

@implementation NSColor (Emacs)

+ (NSColor *)colorWithEmacsColorPixel:(unsigned long)pixel
{
  return [self colorWithSRGBRed:((CGFloat) RED_FROM_ULONG (pixel) / 255.0f)
			  green:((CGFloat) GREEN_FROM_ULONG (pixel) / 255.0f)
			   blue:((CGFloat) BLUE_FROM_ULONG (pixel) / 255.0f)
			  alpha:1.0f];
}

- (BOOL)getSRGBComponents:(CGFloat *)components
{
  NSColor *color = [self colorUsingColorSpace:NSColorSpace.sRGBColorSpace];

  if (color == nil)
    return NO;

  [color getComponents:components];

  return YES;
}

@end				// NSColor (Emacs)

@implementation NSImage (Emacs)

/* Create an image object from a Quartz 2D image.  */

+ (NSImage *)imageWithCGImage:(CGImageRef)cgImage exclusive:(BOOL)flag
{
  NSImage *image;

  if (flag)
    image = [[self alloc] initWithCGImage:cgImage size:NSZeroSize];
  else
    {
      NSBitmapImageRep *rep =
	[[NSBitmapImageRep alloc] initWithCGImage:cgImage];

      image = [[self alloc] initWithSize:[rep size]];
      [image addRepresentation:rep];
      MRC_RELEASE (rep);
    }

  return MRC_AUTORELEASE (image);
}

@end				// NSImage (Emacs)

@implementation NSApplication (Emacs)

- (void)postDummyEvent
{
  NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
			    location:NSZeroPoint modifierFlags:0
			    timestamp:0 windowNumber:0 context:nil
			    subtype:0 data1:0 data2:0];

  [self postEvent:event atStart:YES];
}

- (void)stopAfterCallingBlock:(void (NS_NOESCAPE ^)(void))block
{
  block ();
  [self stop:nil];
  [self postDummyEvent];
}

/* Temporarily run the main event loop during the call of the given
   block.  */

- (void)runTemporarilyWithBlock:(void (^)(void))block
{
  [[NSRunLoop currentRunLoop]
    performSelector:@selector(stopAfterCallingBlock:) target:self
#if USE_ARC && defined (__clang__) && __clang_major__ < 5
    /* `copy' is unnecessary for ARC on clang Apple LLVM version 5.0.
       Without `copy', earlier versions leak memory.  */
	   argument:[block copy]
#else
	   argument:block
#endif
	      order:0 modes:@[NSDefaultRunLoopMode]];
  [self run];
}

@end				// NSApplication (Emacs)

static void
mac_within_app (void (^block) (void))
{
  if (mac_persistent_loop_p)
    {
      /* The application is always running.  */
      if (!pthread_main_np ())
	mac_within_gui (block);
      else
	block ();
      return;
    }
  if (!pthread_main_np ())
    mac_within_gui (^{[NSApp runTemporarilyWithBlock:block];});
  else if (![NSApp isRunning])
    [NSApp runTemporarilyWithBlock:block];
  else
    block ();
}

@implementation NSScreen (Emacs)

+ (NSScreen *)screenContainingPoint:(NSPoint)aPoint
{
  for (NSScreen *screen in [NSScreen screens])
    if (NSMouseInRect (aPoint, [screen frame], NO))
      return screen;

  return nil;
}

+ (NSScreen *)closestScreenForRect:(NSRect)aRect
{
  NSPoint centerPoint = NSMakePoint (NSMidX (aRect), NSMidY (aRect));
  CGFloat maxArea = 0, minSquareDistance = CGFLOAT_MAX;
  NSScreen *maxAreaScreen = nil, *minDistanceScreen = nil;

  for (NSScreen *screen in [NSScreen screens])
    {
      NSRect frame = [screen frame];
      NSRect intersectionFrame = NSIntersectionRect (frame, aRect);
      CGFloat area, diffX, diffY, squareDistance;

      area = NSWidth (intersectionFrame) * NSHeight (intersectionFrame);
      if (area > maxArea)
	{
	  maxAreaScreen = screen;
	  maxArea = area;
	}

      diffX = NSMidX (frame) - centerPoint.x;
      diffY = NSMidY (frame) - centerPoint.y;
      squareDistance = diffX * diffX + diffY * diffY;
      if (squareDistance < minSquareDistance)
	{
	  minDistanceScreen = screen;
	  minSquareDistance = squareDistance;
	}
    }

  return maxAreaScreen ? maxAreaScreen : minDistanceScreen;
}

- (BOOL)containsDock
{
  /* On macOS 10.13, screen's visibleFrame occupies full frame when
     the Dock is hidden.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_12))
    return YES;
  else
    {
      NSRect frame = [self frame], visibleFrame = [self visibleFrame];

      return (NSMinY (frame) != NSMinY (visibleFrame)
	      || NSMinX (frame) != NSMinX (visibleFrame)
	      || NSMaxX (frame) != NSMaxX (visibleFrame));
    }
}

- (BOOL)canShowMenuBar
{
  return ([self isEqual:NSScreen.screens[0]]
	  /* OS X 10.9 may have menu bars on non-main screens (in an
	     inactive appearance) if
	     NSScreen.screensHaveSeparateSpaces returns YES.  */
	  || NSScreen.screensHaveSeparateSpaces);
}

@end				// NSScreen (Emacs)

/* Default implementation.  Will be overridden in EmacsWindow.  */

@implementation NSWindow (Emacs)

- (Lisp_Object)lispFrame
{
  return Qnil;
}

- (NSWindow *)topLevelWindow
{
  NSWindow *current = self, *parent;

  while ((parent = current.parentWindow) != nil)
    current = parent;

  return current;
}

/* Execute the specified block for each of the receiver's child and
   descendant windows.  Set *stop to YES in the block to abort further
   processing of the child windows subtree.  */

- (void)enumerateChildWindowsUsingBlock:(void
					 (NS_NOESCAPE ^)(NSWindow *child, BOOL *stop))block
{
  for (NSWindow *childWindow in self.childWindows)
    {
      BOOL stop = NO;

      block (childWindow, &stop);
      if (!stop)
	[childWindow enumerateChildWindowsUsingBlock:block];
    }
}

@end				// NSWindow (Emacs)

@implementation NSCursor (Emacs)

+ (NSCursor *)cursorWithThemeCursor:(ThemeCursor)themeCursor
{
  /* We don't use a mapping from ThemeCursor to SEL together with
     performSelector: because ARC cannot know whether the return
     value should be retained or not at compile time.  */
  switch (themeCursor)
    {
    case kThemeArrowCursor:
      return [NSCursor arrowCursor];
    case kThemeCopyArrowCursor:
      return [NSCursor dragCopyCursor];
    case kThemeAliasArrowCursor:
      return [NSCursor dragLinkCursor];
    case kThemeContextualMenuArrowCursor:
      return [NSCursor contextualMenuCursor];
    case kThemeIBeamCursor:
      return [NSCursor IBeamCursor];
    case kThemeCrossCursor:
      return [NSCursor crosshairCursor];
    case kThemeClosedHandCursor:
      return [NSCursor closedHandCursor];
    case kThemeOpenHandCursor:
      return [NSCursor openHandCursor];
    case kThemePointingHandCursor:
      return [NSCursor pointingHandCursor];
    case kThemeResizeLeftCursor:
      return [NSCursor resizeLeftCursor];
    case kThemeResizeRightCursor:
      return [NSCursor resizeRightCursor];
    case kThemeResizeLeftRightCursor:
      return [NSCursor resizeLeftRightCursor];
    case kThemeNotAllowedCursor:
      return [NSCursor operationNotAllowedCursor];
    case kThemeResizeUpCursor:
      return [NSCursor resizeUpCursor];
    case kThemeResizeDownCursor:
      return [NSCursor resizeDownCursor];
    case kThemeResizeUpDownCursor:
      return [NSCursor resizeUpDownCursor];
    case kThemePoofCursor:
      return [NSCursor disappearingItemCursor];
    case THEME_RESIZE_NORTHWEST_SOUTHEAST_CURSOR:
      return [NSCursor _windowResizeNorthWestSouthEastCursor];
    case THEME_RESIZE_NORTHEAST_SOUTHWEST_CURSOR:
      return [NSCursor _windowResizeNorthEastSouthWestCursor];
    case THEME_RESIZE_NORTH_SOUTH_CURSOR:
      return [NSCursor _windowResizeNorthSouthCursor];
    case THEME_RESIZE_NORTH_CURSOR:
      return [NSCursor _windowResizeNorthCursor];
    case THEME_RESIZE_SOUTH_CURSOR:
      return [NSCursor _windowResizeSouthCursor];
    case THEME_RESIZE_EAST_WEST_CURSOR:
      return [NSCursor _windowResizeEastWestCursor];
    case THEME_RESIZE_EAST_CURSOR:
      return [NSCursor _windowResizeEastCursor];
    case THEME_RESIZE_WEST_CURSOR:
      return [NSCursor _windowResizeWestCursor];
    case THEME_RESIZE_NORTHWEST_CURSOR:
      return [NSCursor _windowResizeNorthWestCursor];
    case THEME_RESIZE_NORTHEAST_CURSOR:
      return [NSCursor _windowResizeNorthEastCursor];
    case THEME_RESIZE_SOUTHWEST_CURSOR:
      return [NSCursor _windowResizeSouthWestCursor];
    case THEME_RESIZE_SOUTHEAST_CURSOR:
      return [NSCursor _windowResizeSouthEastCursor];
    default:
      return nil;
    }
}

@end				// NSCursor (Emacs)

@implementation EmacsPosingWindow

/* Variables to save implementations of the original -[NSWindow close]
   and -[NSWindow orderOut:].  */
/* ARC requires a precise return type.  */
static void (*impClose) (id, SEL);
static void (*impOrderOut) (id, SEL, id);

+ (void)setup
{
  Method methodCloseNew =
    class_getInstanceMethod (self.class, @selector(close));
  Method methodOrderOutNew =
    class_getInstanceMethod (self.class, @selector(orderOut:));
  IMP impCloseNew = method_getImplementation (methodCloseNew);
  IMP impOrderOutNew = method_getImplementation (methodOrderOutNew);
  const char *typeCloseNew = method_getTypeEncoding (methodCloseNew);
  const char *typeOrderOutNew = method_getTypeEncoding (methodOrderOutNew);

  impClose = ((void (*) (id, SEL))
	      class_replaceMethod (NSWindow.class, @selector(close),
				   impCloseNew, typeCloseNew));
  impOrderOut = ((void (*) (id, SEL, id))
		 class_replaceMethod (NSWindow.class, @selector(orderOut:),
				      impOrderOutNew, typeOrderOutNew));
}

/* Close the receiver with running the main event loop if not.  Just
   closing the window outside the application loop does not activate
   the next window.  */

- (void)close
{
  mac_within_app (^{(*impClose) (self, _cmd);});
}

/* Hide the receiver with running the main event loop if not.  Just
   hiding the window outside the application loop does not activate
   the next window.  */

- (void)orderOut:(id)sender
{
  mac_within_app (^{(*impOrderOut) (self, _cmd, sender);});
}

@end				// EmacsPosingWindow

/* Return a pair of a type tag and a Lisp object converted form the
   NSValue object OBJ.  If the object is not an NSValue object or not
   created from NSRange, NSPoint, NSSize, or NSRect, then return
   nil.  */

static Lisp_Object
mac_nsvalue_to_lisp (CFTypeRef obj)
{
  Lisp_Object result = Qnil;

  if ([(__bridge id)obj isKindOfClass:NSValue.class])
    {
      NSValue *value = (__bridge NSValue *) obj;
      const char *type = [value objCType];
      Lisp_Object tag = Qnil;

      if (strcmp (type, @encode (NSRange)) == 0)
	{
	  NSRange range = [value rangeValue];

	  tag = Qrange;
	  result = Fcons (make_int (range.location), make_int (range.length));
	}
      else if (strcmp (type, @encode (NSPoint)) == 0)
	{
	  NSPoint point = [value pointValue];

	  tag = Qpoint;
	  result = Fcons (make_float (point.x), make_float (point.y));
	}
      else if (strcmp (type, @encode (NSSize)) == 0)
	{
	  NSSize size = [value sizeValue];

	  tag = Qsize;
	  result = Fcons (make_float (size.width), make_float (size.height));
	}
      else if (strcmp (type, @encode (NSRect)) == 0)
	{
	  NSRect rect = [value rectValue];

	  tag = Qrect;
	  result = list4 (make_float (NSMinX (rect)),
			  make_float (NSMinY (rect)),
			  make_float (NSWidth (rect)),
			  make_float (NSHeight (rect)));
	}

      if (!NILP (tag))
	result = Fcons (tag, result);
    }

  return result;
}

static Lisp_Object
mac_nsfont_to_lisp (CFTypeRef obj)
{
  Lisp_Object result = Qnil;

  if ([(__bridge id)obj isKindOfClass:NSFont.class])
    {
      result = macfont_nsctfont_to_spec ((void *) obj);
      if (!NILP (result))
	result = Fcons (Qfont, result);
    }

  return result;
}

Lisp_Object
mac_nsobject_to_lisp (CFTypeRef obj)
{
  Lisp_Object result;

  result = mac_nsvalue_to_lisp (obj);
  if (!NILP (result))
    return result;
  result = mac_nsfont_to_lisp (obj);

  return result;
}

static bool
has_system_appearance_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
  return true;
#else
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_13);
#endif
}

static bool
can_auto_hide_menu_bar_without_hiding_dock_p (void)
{
  /* Needs to be linked on OS X 10.11 or later.  */
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101100
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max);
#else
  return false;
#endif
}

static bool
has_notch_support_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 120000
  return true;
#else
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber11_0);
#endif
}

/* Autorelease pool.  */

#if __clang_major__ >= 3
#define BEGIN_AUTORELEASE_POOL	@autoreleasepool {
#define END_AUTORELEASE_POOL	}
#define BEGIN_AUTORELEASE_POOL_BLOCK_INPUT	\
  @autoreleasepool {
#define END_AUTORELEASE_POOL_BLOCK_INPUT	\
  block_input (); } unblock_input ()
#else
#define BEGIN_AUTORELEASE_POOL					\
  { NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init]
#define END_AUTORELEASE_POOL			\
  [pool release]; }
#define BEGIN_AUTORELEASE_POOL_BLOCK_INPUT				\
  block_input ();							\
  { NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];		\
  unblock_input ()
#define END_AUTORELEASE_POOL_BLOCK_INPUT		\
  block_input (); [pool release]; } unblock_input ()
#endif

#if MAC_USE_AUTORELEASE_LOOP
void
mac_autorelease_loop (Lisp_Object (^body) (void))
{
  Lisp_Object val;

  do
    {
      BEGIN_AUTORELEASE_POOL_BLOCK_INPUT;
      val = body ();
      END_AUTORELEASE_POOL_BLOCK_INPUT;
    }
  while (!NILP (val));
}

#else

void *
mac_alloc_autorelease_pool (void)
{
  NSAutoreleasePool *pool;

  block_input ();
  pool = [[NSAutoreleasePool alloc] init];
  unblock_input ();

  return pool;
}

void
mac_release_autorelease_pool (void *pool)
{
  block_input ();
  [(NSAutoreleasePool *)pool release];
  unblock_input ();
}
#endif

void
mac_alert_sound_play (void)
{
  NSBeep ();
}

double
mac_appkit_version (void)
{
  return NSAppKitVersionNumber;
}

double
mac_system_uptime (void)
{
  return [[NSProcessInfo processInfo] systemUptime];
}

bool
mac_is_current_process_frontmost (void)
{
  return [[NSRunningApplication currentApplication] isActive];
}

void
mac_bring_current_process_to_front (bool front_window_only_p)
{
  NSApplicationActivationOptions options;

  if (
#if __clang_major__ >= 9
      @available (macOS 14.0, *)
#else
      [NSApp respondsToSelector:@selector(activate:)]
#endif
      )
    options = 0;
  else
    {
      /* Suppress warnings about deprecated declarations.  This #if
	 shouldn't be necessary if the compiler can handle @available
	 above properly.  */
#if MAC_OS_X_VERSION_MIN_REQUIRED < 140000
      options = NSApplicationActivateIgnoringOtherApps;
#else
      emacs_abort ();
#endif
    }
  if (!front_window_only_p)
    options |= NSApplicationActivateAllWindows;
  [NSRunningApplication.currentApplication activateWithOptions:options];
}

/* Move FILENAME to the trash without using the Finder and return
   whether it succeeded.  If CFERROR is non-NULL, *CFERROR is set on
   failure.  If trashing functionality is not available, return false
   and set *CFERROR to NULL.  */

bool
mac_trash_file (const char *filename, CFErrorRef *cferror)
{
  bool result;
  NSError * __autoreleasing error;
  NSURL *url =
    (CFBridgingRelease
     (CFURLCreateFromFileSystemRepresentation (NULL,
					       (const UInt8 *) filename,
					       strlen (filename), false)));

  result = [[NSFileManager defaultManager] trashItemAtURL:url
					 resultingItemURL:NULL
						    error:&error];
  if (!result && cferror)
    *cferror = (CFErrorRef) CFBridgingRetain (error);

  return result;
}

static void
mac_with_current_drawing_appearance (NSAppearance *appearance,
                                     void (NS_NOESCAPE ^block) (void))
{
  if (
#if __clang_major__ >= 9
      /* We use 10.16 instead of 11 because the binary compiled with
	 SDK 10.15 and earlier thinks the OS version as 10.16 rather
	 than 11 if it is executed on Big Sur.  */
      @available (macOS 10.16, *)
#else
      [appearance
	respondsToSelector:@selector(performAsCurrentDrawingAppearance:)]
#endif
      )
    [appearance performAsCurrentDrawingAppearance:block];
  else
    {
      /* Suppress warnings about deprecated declarations.  This #if
	 shouldn't be necessary if the compiler can handle @available
	 above properly.  */
#if MAC_OS_X_VERSION_MIN_REQUIRED < 110000
      NSAppearance *oldAppearance = NSAppearance.currentAppearance;

      NSAppearance.currentAppearance = appearance;
      block ();
      NSAppearance.currentAppearance = oldAppearance;
#else
      emacs_abort ();
#endif
    }
}

CFStringRef
mac_uti_create_with_mime_type (CFStringRef mime_type)
{
#if HAVE_UNIFORM_TYPE_IDENTIFIERS
  return CFBridgingRetain ([UTType typeWithMIMEType:((__bridge NSString *)
						     mime_type)]
			   .identifier);
#else
  return UTTypeCreatePreferredIdentifierForTag (kUTTagClassMIMEType,
						mime_type, kUTTypeData);
#endif
}

CFStringRef
mac_uti_create_with_filename_extension (CFStringRef extension)
{
#if HAVE_UNIFORM_TYPE_IDENTIFIERS
  return CFBridgingRetain ([UTType
			     typeWithFilenameExtension:((__bridge NSString *)
							extension)]
			   .identifier);
#else
  return UTTypeCreatePreferredIdentifierForTag (kUTTagClassFilenameExtension,
						extension, kUTTypeData);
#endif
}

CFStringRef
mac_uti_copy_filename_extension (CFStringRef uti)
{
#if HAVE_UNIFORM_TYPE_IDENTIFIERS
  return CFBridgingRetain ([UTType typeWithIdentifier:((__bridge NSString *)
						       uti)]
			   .preferredFilenameExtension);
#else
  return UTTypeCopyPreferredTagWithClass (uti, kUTTagClassFilenameExtension);
#endif
}

CFStringRef
mac_uti_copy_mime_type (CFStringRef uti)
{
#if HAVE_UNIFORM_TYPE_IDENTIFIERS
  return CFBridgingRetain ([UTType typeWithIdentifier:((__bridge NSString *)
						       uti)].preferredMIMEType);
#else
  return UTTypeCopyPreferredTagWithClass (uti, kUTTagClassMIMEType);
#endif
}


/************************************************************************
			     Application
 ************************************************************************/

#define FRAME_CONTROLLER(f) ((__bridge EmacsFrameController *)	\
			     FRAME_MAC_WINDOW (f))
#define FRAME_MAC_WINDOW_OBJECT(f) ([FRAME_CONTROLLER(f) emacsWindow])

static EmacsController *emacsController;

static void init_menu_bar (void);
static void init_apple_event_handler (void);
static void init_accessibility (void);

static BOOL is_action_selector (SEL);
static BOOL is_services_handler_selector (SEL);
static NSMethodSignature *action_signature (void);
static NSMethodSignature *services_handler_signature (void);
static void handle_action_invocation (NSInvocation *);
static void handle_services_invocation (NSInvocation *);

static void mac_flush_1 (struct frame *);

static void mac_update_accessibility_display_options (void);

static EventRef mac_peek_next_event (void);

/* True if we are executing handleQueuedNSEventsWithHoldingQuitIn:.  */
static bool handling_queued_nsevents_p;

@implementation EmacsApplication

- (void)sendEvent:(NSEvent *)event
{
  if (mac_persistent_loop_p && mac_loop_dispatch_depth == 0)
    mac_loop_send_event (event);
  else
    [super sendEvent:event];
}

/* Dispatch EVENT to AppKit without Emacs's event handling.  */

- (void)sendEventToAppKit:(NSEvent *)event
{
  [super sendEvent:event];
}

- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask
			untilDate:(NSDate *)expiration
			   inMode:(NSRunLoopMode)mode
			  dequeue:(BOOL)dequeue
{
  NSEvent *event = [super nextEventMatchingMask:mask untilDate:expiration
				       inMode:mode dequeue:dequeue];
  /* Native tracking can consume keys without asking menu key-equivalent
     delegates.  Do not intercept peeks or evaluate Lisp in this loop.  */
  if (dequeue && event.type == NSEventTypeKeyDown
      && [self.mainMenu isKindOfClass:EmacsMenu.class]
      && [(EmacsMenu *) self.mainMenu cancelNativeTrackingForQuitEvent:event])
    return nil;
  return event;
}

/* Don't use the "applicationShouldTerminate: - NSTerminateLater -
   replyToApplicationShouldTerminate:" mechanism provided by
   -[NSApplication terminate:] for deferring the termination, as it
   does not allow us to go back to the Lisp evaluation loop.  */

- (void)terminate:(id)sender
{
  if (mac_persistent_loop_p)
    {
      /* W8: at most one pending Quit; drop repeats while Lisp has not
	 resolved the previous one (prompted, cancelled, or exited).  */
      if (!mac_loop_quit_begin ())
	return;

      /* The raw event below is disposed of when dispatching returns,
	 so it must not be suspended for later; dispatch it only with
	 Lisp access.  */
      if (!mac_loop_gui_has_lisp_access ())
	{
	  mac_loop_with_access_now_or_later (^{
	      [self dispatchQuitAppleEvent];
	    });
	  return;
	}
    }

  [self dispatchQuitAppleEvent];
}

- (void)dispatchQuitAppleEvent
{
  OSErr err;
  NSAppleEventManager *manager = [NSAppleEventManager sharedAppleEventManager];
  AppleEvent appleEvent, reply;

  err = create_apple_event (kCoreEventClass, kAEQuitApplication, &appleEvent);
  if (err == noErr)
    {
      AEInitializeDesc (&reply);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
      [manager dispatchRawAppleEvent:&appleEvent withRawReply:&reply
	       handlerRefCon:0];
#pragma clang diagnostic pop
      AEDisposeDesc (&reply);
      AEDisposeDesc (&appleEvent);
    }
}

- (void)setMainMenu:(NSMenu *)mainMenu
{
  NSMenu *currentMainMenu = [self mainMenu];

  if (![mainMenu isEqual:currentMainMenu])
    {
      mac_trace_menu_lifecycle ("replace-root-old", currentMainMenu, 0);
      mac_trace_menu_lifecycle ("replace-root-new", mainMenu, 0);
      if ([currentMainMenu isKindOfClass:EmacsMenu.class])
	[[NSNotificationCenter defaultCenter] removeObserver:currentMainMenu];
      if ([mainMenu isKindOfClass:EmacsMenu.class])
	{
	  [[NSNotificationCenter defaultCenter]
	  addObserver:mainMenu
	     selector:@selector(menuDidBeginTracking:)
		 name:NSMenuDidBeginTrackingNotification
	       object:mainMenu];
	  [[NSNotificationCenter defaultCenter]
	    addObserver:mainMenu
	       selector:@selector(menuDidEndTracking:)
		   name:NSMenuDidEndTrackingNotification
		 object:mainMenu];
	}
      [super setMainMenu:mainMenu];
      mac_trace_menu_lifecycle ("replace-root-done", mainMenu, 0);
    }
}

@end				// EmacsApplication

@implementation EmacsController

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  for (NSString *keyPath in observedKeyPaths)
    [NSApp removeObserver:self forKeyPath:keyPath];
#if !USE_ARC
  [observedKeyPaths release];
  [super dealloc];
#endif
}

/* Delegate Methods  */

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
  [EmacsPosingWindow setup];
  [NSFontManager setFontPanelFactory:EmacsFontPanel.class];
  serviceProviderRegistered = mac_service_provider_registered_p ();
  init_menu_bar ();
  init_apple_event_handler ();
  init_accessibility ();
  observedKeyPaths = [[NSSet alloc] init];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  /* Try to suppress the warning "CFMessagePort: bootstrap_register():
     failed" displayed by the second instance of Emacs.  Strictly
     speaking, there's a race condition, but it is not critical
     anyway.  */
  if (!serviceProviderRegistered)
    [NSApp setServicesProvider:self];

  macfont_update_antialias_threshold ();
  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(antialiasThresholdDidChange:)
	   name:NSAntialiasThresholdChangedNotification
	 object:nil];

  mac_update_accessibility_display_options ();
  [[[NSWorkspace sharedWorkspace] notificationCenter]
    addObserver:self
       selector:@selector(accessibilityDisplayOptionsDidChange:)
	   name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
	 object:nil];

  [[[NSWorkspace sharedWorkspace] notificationCenter]
    addObserver:self
       selector:@selector(willSleep:)
	   name:NSWorkspaceWillSleepNotification
	 object:nil];

  [NSApp registerUserInterfaceItemSearchHandler:self];
  Vmac_help_topics = Qnil;

  /* Initialize spell checker for ispell and jinx enchant-2 using
     AppleSpell.  See https://github.com/minad/jinx/pull/91 */
  (void) [NSSpellChecker sharedSpellChecker];

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101500
  /* Work around animation effect glitches for executables linked on
     macOS 10.15.  */
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_15)
    setenv ("CAVIEW_USE_GL", "1", 0);
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED < 110000
  /* Work around bogus view bounds/frame values on some versions of
     macOS 11.x (x >= 3?) when using system image tool bar icons in
     the `expanded' style, which is default for the executable
     compiled with macOS 10.* SDKs.  Probably it is related to the
     following warning about layout recursion:

       It's not legal to call -layoutSubtreeIfNeeded on a view which
       is already being laid out.  If you are implementing the view's
       -layout method, you can call -[super layout] instead. Break on
       void _NSDetectedLayoutRecursion(void) to debug.  This will be
       logged only once.  This may break in the future.  */
  /* NSWindowSupportsAutomaticInlineTitle has no effect on macOS 12.  */
  if (floor (NSAppKitVersionNumber) == NSAppKitVersionNumber11_0
      && [[NSUserDefaults standardUserDefaults]
	   objectForKey:@"NSWindowSupportsAutomaticInlineTitle"] == nil)
    [NSUserDefaults.standardUserDefaults
      registerDefaults:@{@"NSWindowSupportsAutomaticInlineTitle" : @"YES"}];
#endif

  /* Some functions/methods in CoreFoundation/Foundation increase the
     maximum number of open files for the process in their first call.
     We make dummy calls to them and then reduce the resource limit
     here, since pselect cannot handle file descriptors that are
     greater than or equal to FD_SETSIZE.  */
  CFSocketGetTypeID ();
  CFFileDescriptorGetTypeID ();
  MRC_RELEASE ([[NSFileHandle alloc] init]);
  struct rlimit rlim;
  if (getrlimit (RLIMIT_NOFILE, &rlim) == 0 && rlim.rlim_cur > FD_SETSIZE)
    {
      rlim.rlim_cur = FD_SETSIZE;
      setrlimit (RLIMIT_NOFILE, &rlim);
    }

  if (mac_persistent_loop_p)
    {
      /* Keep running; let the waiting Lisp thread continue.  */
      mac_loop_complete_launch ();
      return;
    }

  /* Exit from the main event loop.  */
  [NSApp stop:nil];
  [NSApp postDummyEvent];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
  return YES;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self applicationDidBecomeActive:
					notification]);

  if (needsUpdatePresentationOptionsOnBecomingActive)
    {
      [self updatePresentationOptions];
      needsUpdatePresentationOptionsOnBecomingActive = NO;
    }
}

#if HAVE_MAC_METAL || defined (USE_METAL_RENDERING)
- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("screen-parameters", [self applicationDidChangeScreenParameters:notification]);

  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f))
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

#ifdef USE_METAL_RENDERING
	  [frameController updateBackingScaleFactor];
#else
	  [frameController updateEmacsViewMTLObjects];
#endif
	}
    }
}
#endif

- (void)antialiasThresholdDidChange:(NSNotification *)notification
{
  macfont_update_antialias_threshold ();
}

- (void)willSleep:(NSNotification *)notification {
  // Do quick pre-sleep work here
  NSLog(@"Entering sleep");
  mac_draw_queue_sync();
}

- (void)updateObservedKeyPaths
{
  Lisp_Object keymap = get_keymap (Vmac_apple_event_map, 0, 0);

  if (!NILP (keymap))
    keymap = get_keymap (access_keymap (keymap, Qapplication_kvo, 0, 1),
			 0, 0);
  if (!NILP (keymap))
    {
      NSMutableSetOf (NSString *) *work =
	[[NSMutableSet alloc] initWithCapacity:0];

      mac_map_keymap (keymap, false, ^(Lisp_Object key, Lisp_Object binding) {
	  if (!NILP (binding) && !EQ (binding, Qundefined) && SYMBOLP (key))
	    [work addObject:[NSString
			      stringWithUTF8LispString:(SYMBOL_NAME (key))]];
	});

      NSSetOf (NSString *) *oldObservedKeyPaths = observedKeyPaths;
      observedKeyPaths = [[NSSet alloc] initWithSet:work];

      for (NSString *keyPath in oldObservedKeyPaths)
	if ([work member:keyPath])
	  [work removeObject:keyPath];
	else
	  [NSApp removeObserver:self forKeyPath:keyPath];
      MRC_RELEASE (oldObservedKeyPaths);

      for (NSString *keyPath in work)
	[NSApp addObserver:self forKeyPath:keyPath
		   options:(NSKeyValueObservingOptionOld
			    | NSKeyValueObservingOptionNew)
		   context:nil];
      MRC_RELEASE (work);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionaryOf (NSKeyValueChangeKey, id) *)change
                       context:(void *)context
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self observeValueForKeyPath:keyPath
					       ofObject:object
						 change:change
						context:context]);

  if ([observedKeyPaths containsObject:keyPath])
    {
      struct input_event inev;
      Lisp_Object tag_Lisp = build_string ("Lisp");
      Lisp_Object change_value =
	cfobject_to_lisp ((__bridge CFTypeRef) change,
			  CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
      Lisp_Object arg = Qnil;

      arg = Fcons (Fcons (Qchange, Fcons (tag_Lisp, change_value)), arg);
      EVENT_INIT (inev);
      inev.kind = MAC_APPLE_EVENT;
      inev.x = Qapplication_kvo;
      inev.y = Fintern (keyPath.UTF8LispString, Qnil);
      inev.frame_or_window = mac_event_frame ();
      inev.arg = Fcons (build_string ("aevt"), arg);
      [self storeEvent:&inev];
    }
}

- (int)getAndClearMenuItemSelection
{
  int selection = menuItemSelection;

  menuItemSelection = 0;

  return selection;
}

/* Action methods  */

/* Store SENDER's inputEvent to kbd_buffer.  */

- (void)storeInputEvent:(id)sender
{
  [self storeEvent:[sender inputEvent]];
}

/* Set the instance variable menuItemSelection to the value of
   SENDER's tag.  */

- (void)setMenuItemSelectionToTag:(id)sender
{
  mac_trace_menu_lifecycle ("action", [sender menu], [sender tag]);
  NSMenu *root = [sender menu];
  while ([root supermenu])
    root = [root supermenu];
  if ([root isKindOfClass:EmacsMenu.class]
      && [(EmacsMenu *) root nativeNeedsPreparation] && !popup_activated ())
    return;
  if ([root isKindOfClass:EmacsMenu.class]
      && [(EmacsMenu *) root nativeGeneration] && !popup_activated ())
    {
      unsigned long generation = [(EmacsMenu *) root nativeGeneration];
      int selection = [sender tag];
      mac_within_lisp_deferred_if_gui_thread (^{
          mac_native_menubar_selection (generation, selection);
        });
      [NSApp postDummyEvent];
      return;
    }
  if (mac_persistent_loop_p && !popup_activated ())
    {
      /* Menu-bar tracking is not intercepted by the persistent loop,
	 so nothing polls menuItemSelection.  Prefer the snapshot bound
	 to ROOT when the deep menu-bar fill that created it stamped a
	 generation (see mac_fill_menubar); this revalidates the frame,
	 window and buffer at execution time (D5/D17 in the mac-app-loop
	 menu design).  Fall back to the unvalidated selected-frame path
	 only when no snapshot was ever published for this root.  */
      unsigned long generation
	= ([root isKindOfClass:EmacsMenu.class]
	   ? [(EmacsMenu *) root persistentMenuGeneration] : 0);
      int selection = [sender tag];

      if (generation)
	mac_loop_queue_lisp_block (^{
	    mac_persistent_menubar_selection (generation, selection);
	  });
      else
	mac_loop_note_menu_selection (selection);
      return;
    }
  menuItemSelection = [sender tag];
}

/* Equivalent of (ns-hide-emacs 'active).  */
- (void)activate:(id)sender
{
  if (
#if __clang_major__ >= 9
      @available (macOS 14.0, *)
#else
      [NSApp respondsToSelector:@selector(activate:)]
#endif
      )
    [NSApp activate];
  else
    {
      /* Suppress warnings about deprecated declarations.  This #if
	 shouldn't be necessary if the compiler can handle @available
	 above properly.  */
#if MAC_OS_X_VERSION_MIN_REQUIRED < 140000
      [NSApp activateIgnoringOtherApps:YES];
#else
      emacs_abort ();
#endif
    }
}

/* Event handling  */

static EventRef peek_if_next_event_activates_menu_bar (void);

/* Store BUFP to kbd_buffer.  */

- (void)storeEvent:(struct input_event *)bufp
{
  if (mac_persistent_loop_p)
    {
      if (!pthread_main_np ())
	{
	  /* A callback queued to the Lisp thread.  */
	  if (bufp->kind != HELP_EVENT)
	    kbd_buffer_store_event_hold (bufp, mac_loop_lisp_hold_quit);
	  return;
	}
      if (!mac_loop_gui_has_lisp_access ())
	{
	  /* Only events without fresh Lisp objects are stored without
	     access; help echo needs Lisp and is dropped.  */
	  if (bufp->kind != HELP_EVENT)
	    mac_loop_queue_input_event (bufp);
	  return;
	}
      if (hold_quit == NULL && bufp->kind != HELP_EVENT)
	{
	  /* Never call handle_interrupt on the GUI thread.  */
	  kbd_buffer_store_event_hold (bufp, &mac_loop_gui_hold_quit);
	  count++;
	  if (mac_loop_request_depth == 0)
	    mac_loop_wake_lisp ();
	  return;
	}
    }
  if (bufp->kind == HELP_EVENT)
    {
      do_help = 1;
      emacsHelpFrame = XFRAME (bufp->frame_or_window);
    }
  else
    {
      kbd_buffer_store_event_hold (bufp, hold_quit);
      count++;
    }
}

/* Handle EVENT with holding a quit event in BUFP (or the GUI-thread
   holder if BUFP and the current holder are NULL).  Return the number
   of stored Emacs events.  Used by the persistent loop.  */

- (int)handleNSEventWithHoldingQuitIn:(struct input_event *)bufp
				event:(NSEvent *)event
{
  struct input_event *savedHoldQuit = hold_quit;
  int savedCount = count, result;

  if (bufp)
    hold_quit = bufp;
  else if (hold_quit == NULL)
    hold_quit = &mac_loop_gui_hold_quit;
  count = 0;
  [self handleOneNSEvent:event];
  result = count;
  hold_quit = savedHoldQuit;
  count = savedCount;

  return result;
}

- (void)setHoldQuit:(struct input_event *)bufp
{
  hold_quit = bufp;
}

- (void)setTrackingResumeBlock:(void (^)(void))block
{
  MRC_RELEASE (trackingResumeBlock);
  trackingResumeBlock = [block copy];
}

#define MOUSE_TRACKING_SET_RESUMPTION(controller, obj, sel_name)	\
  [(controller) setTrackingResumeBlock:^{[(obj) sel_name];}]

/* These macros can only be used inside EmacsController.  */
#define MOUSE_TRACKING_SUSPENDED_P()	(trackingResumeBlock != nil)
#define MOUSE_TRACKING_RESUME()		trackingResumeBlock ()
#define MOUSE_TRACKING_RESET()		[self setTrackingResumeBlock:nil]

- (BOOL)isMouseTrackingSuspended
{
  return MOUSE_TRACKING_SUSPENDED_P ();
}

/* Minimum time interval between successive mac_read_socket calls.  */

#define READ_SOCKET_MIN_INTERVAL (1/60.0)

static BOOL extendReadSocketIntervalOnce;

- (NSTimeInterval)minimumIntervalForReadSocket
{
  NSTimeInterval interval = READ_SOCKET_MIN_INTERVAL;

  if (MOUSE_TRACKING_SUSPENDED_P () || extendReadSocketIntervalOnce)
    interval *= 6;
  else if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    /* A large interval value affects responsiveness on OS X
       10.11.  */
    interval *= .1;

  return interval;
}

/* Handle the NSEvent EVENT.  */

- (void)handleOneNSEvent:(NSEvent *)event
{
  struct input_event inev;

  do_help = 0;
  emacsHelpFrame = NULL;

  EVENT_INIT (inev);
  inev.arg = Qnil;
  inev.frame_or_window = mac_event_frame ();

  switch ([event type])
    {
    case NSEventTypeKeyDown:
      {
	CGEventRef cgevent = [event coreGraphicsEvent];
	NSEventModifierFlags flags = [event modifierFlags];
	unsigned short key_code = [event keyCode];

	if (!(mac_cgevent_to_input_event (cgevent, NULL)
	      & ~(mac_pass_command_to_system ? kCGEventFlagMaskCommand : 0)
	      & ~(mac_pass_control_to_system ? kCGEventFlagMaskControl : 0))
	    && ([NSApp keyWindow] || (flags & NSEventModifierFlagCommand))
	    /* Avoid activating context help mode with `help' key.  */
	    && !([[[NSApp keyWindow] firstResponder]
		   isMemberOfClass:EmacsMainView.class]
		 && key_code == kVK_Help
		 && (flags & (NSEventModifierFlagControl
			      | NSEventModifierFlagOption
			      | NSEventModifierFlagCommand)) == 0))
	  goto OTHER;

	mac_cgevent_to_input_event (cgevent, &inev);
	if (inev.kind != NO_EVENT)
	  [self storeEvent:&inev];
      }
      break;

    default:
    OTHER:
      if (mac_loop_test_recording_p && [NSApp keyWindow] == nil
	  && event.window
	  && (event.type == NSEventTypeKeyDown
	      || event.type == NSEventTypeKeyUp))
	/* Scheduled test input while the application cannot become
	   active: deliver to the target window's first responder.  */
	[event.window sendEvent:event];
      else
	[NSApp sendEvent:event];
      break;
    }

  if (do_help
      && !(hold_quit && hold_quit->kind != NO_EVENT))
    {
      Lisp_Object frame;

      if (emacsHelpFrame)
	XSETFRAME (frame, emacsHelpFrame);
      else
	frame = Qnil;

      if (do_help > 0)
	{
	  any_help_event_p = true;
	  gen_help_event (help_echo_string, frame, help_echo_window,
			  help_echo_object, help_echo_pos);
	}
      else
	{
	  help_echo_string = Qnil;
	  gen_help_event (Qnil, frame, Qnil, Qnil, 0);
	}
      count++;
    }
}

/* Handle NSEvents in the queue with holding quit event in *BUFP.
   Return the number of stored Emacs events.

   We handle them inside the application loop in order to avoid the
   hang in the following situation:

     1. Save some file in Emacs.
     2. Remove the file in Terminal.
     3. Try to drag the proxy icon in the Emacs title bar.
     4. "Document Drag Error" window will pop up, but can't pop it
        down by clicking the OK button.  */

- (int)handleQueuedNSEventsWithHoldingQuitIn:(struct input_event *)bufp
{
  int __block result;

  mac_within_app (^{
      /* Mac OS X 10.2 doesn't regard untilDate:nil as polling.  */
      NSDate *expiration = [NSDate distantPast];
      struct mac_display_info *dpyinfo = &one_mac_display_info;

      hold_quit = bufp;
      count = 0;

      if (MOUSE_TRACKING_SUSPENDED_P ())
	{
	  NSEvent *leftMouseEvent =
	    [NSApp
	      nextEventMatchingMask:(NSEventMaskLeftMouseDragged
				     | NSEventMaskLeftMouseUp)
			  untilDate:expiration
			     inMode:NSDefaultRunLoopMode dequeue:NO];

	  if (leftMouseEvent)
	    {
	      if ([leftMouseEvent type] == NSEventTypeLeftMouseDragged)
		MOUSE_TRACKING_RESUME ();
	      MOUSE_TRACKING_RESET ();
	    }
	}

      while (1)
	{
	  NSEvent *event;
	  NSUInteger mask;

	  if (dpyinfo->saved_menu_event == NULL)
	    {
	      EventRef menu_event = peek_if_next_event_activates_menu_bar ();

	      if (menu_event)
		{
		  struct input_event inev;

		  dpyinfo->saved_menu_event = RetainEvent (menu_event);
		  RemoveEventFromQueue (GetMainEventQueue (), menu_event);

		  EVENT_INIT (inev);
		  inev.arg = Qnil;
		  inev.frame_or_window = mac_event_frame ();
		  inev.kind = MENU_BAR_ACTIVATE_EVENT;
		  [self storeEvent:&inev];
		}
	    }

	  mask = ((!MOUSE_TRACKING_SUSPENDED_P ()
		   && dpyinfo->saved_menu_event == NULL)
		  ? NSEventMaskAny : (NSEventMaskAny & ~ANY_MOUSE_EVENT_MASK));
	  event = [NSApp nextEventMatchingMask:mask untilDate:expiration
			 inMode:NSDefaultRunLoopMode dequeue:YES];

	  if (event == nil)
	    break;
	  [self handleOneNSEvent:event];
	}

      hold_quit = NULL;

      result = count;
    });

  return result;
}

static BOOL
emacs_windows_need_display_p (void)
{
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f))
	{
	  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

	  if ([window isVisible] && [window viewsNeedDisplay])
	    return YES;
	}
    }

  return NO;
}

- (void)processDeferredReadSocket:(NSTimer *)theTimer
{
  if (mac_persistent_loop_p)
    {
      /* Nothing polls the GUI; just let Lisp read its queue.  */
      mac_loop_wake_lisp ();
      return;
    }
  if (!handling_queued_nsevents_p)
    {
      if (mac_peek_next_event () || emacs_windows_need_display_p ())
	[NSApp postDummyEvent];
      else
	mac_flush_1 (NULL);
    }
}

- (void)cancelHelpEchoForEmacsFrame:(struct frame *)f
{
  /* Generate a nil HELP_EVENT to cancel a help-echo.
     Do it only if there's something to cancel.
     Otherwise, the startup message is cleared when the
     mouse leaves the frame.  */
  if (any_help_event_p
      /* But never if `mouse-drag-and-drop-region' is in progress,
	 since that results in the tooltip being dismissed when the
	 mouse moves on top.  */
      && !((EQ (track_mouse, Qdrag_source)
	    || EQ (track_mouse, Qdropping))
	   && gui_mouse_grabbed (FRAME_DISPLAY_INFO (f))))
    {
      Lisp_Object frame;

      XSETFRAME (frame, f);
      help_echo_string = Qnil;
      gen_help_event (Qnil, frame, Qnil, Qnil, 0);
    }
}

/* Work around conflicting Cocoa's text system key bindings.  */

- (BOOL)conflictingKeyBindingsDisabled
{
  return conflictingKeyBindingsDisabled;
}

- (void)setConflictingKeyBindingsDisabled:(BOOL)flag
{
  id keyBindingManager;

  if (flag == conflictingKeyBindingsDisabled)
    return;

  keyBindingManager = [(NSClassFromString (@"NSKeyBindingManager"))
			performSelector:@selector(sharedKeyBindingManager)];
  if (flag)
    {
      /* Disable the effect of NSQuotedKeystrokeBinding (C-q by
	 default) and NSRepeatCountBinding (none by default but user
	 may set it to C-u).  */
      [keyBindingManager performSelector:@selector(setQuoteBinding:)
			      withObject:nil];
      [keyBindingManager performSelector:@selector(setArgumentBinding:)
			      withObject:nil];
      if (keyBindingsWithConflicts == nil)
	{
	  NSArrayOf (NSString *) *writingDirectionCommands =
	    @[@"insertRightToLeftSlash:",
	      @"makeBaseWritingDirectionNatural:",
	      @"makeBaseWritingDirectionLeftToRight:",
	      @"makeBaseWritingDirectionRightToLeft:",
	      @"makeTextWritingDirectionNatural:",
	      @"makeTextWritingDirectionLeftToRight:",
	      @"makeTextWritingDirectionRightToLeft:"];
	  NSMutableDictionaryOf (NSString *, NSString *) *dictionary;

	  /* Replace entries for prefix keys and writing direction
	     commands with dummy ones.  */
	  keyBindingsWithConflicts =
	    MRC_RETAIN ([keyBindingManager dictionary]);
	  dictionary = [keyBindingsWithConflicts mutableCopy];
	  for (NSString *key in keyBindingsWithConflicts)
	    {
	      id object = keyBindingsWithConflicts[key];

	      if (![object isKindOfClass:NSString.class]
		  || [writingDirectionCommands containsObject:object])
		dictionary[key] = @"dummy:";
	    }
	  keyBindingsWithoutConflicts = dictionary;
	}
      [keyBindingManager setDictionary:keyBindingsWithoutConflicts];
    }
  else
    {
      NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

      [keyBindingManager
	performSelector:@selector(setQuoteBinding:)
	     withObject:[userDefaults
			  stringForKey:@"NSQuotedKeystrokeBinding"]];
      [keyBindingManager
	performSelector:@selector(setArgumentBinding:)
	     withObject:[userDefaults
			  stringForKey:@"NSRepeatCountBinding"]];
      if (keyBindingsWithConflicts)
	[keyBindingManager setDictionary:keyBindingsWithConflicts];
    }

  conflictingKeyBindingsDisabled = flag;
}

/* Some key bindings in mac_apple_event_map are regarded as methods in
   the application delegate.  */

/* Kinds of selectors bound dynamically in mac-apple-event-map.  */
enum { MAC_SELECTOR_NONE, MAC_SELECTOR_ACTION, MAC_SELECTOR_SERVICES };

/* Return the kind of SELECTOR.  Looking it up reads keymaps.  Under
   the persistent loop the GUI thread may do that only with Lisp
   access, so remember answers and reuse them while Lisp is busy.  */

static int
mac_selector_kind (SEL selector)
{
  static NSMutableDictionary *cache;
  NSString *key = NSStringFromSelector (selector);
  int token = mac_loop_begin_lisp_access ();

  if (token == MAC_LOOP_NO_ACCESS)
    return [cache[key] intValue];

  int kind = (is_action_selector (selector) ? MAC_SELECTOR_ACTION
	      : is_services_handler_selector (selector)
	      ? MAC_SELECTOR_SERVICES : MAC_SELECTOR_NONE);

  mac_loop_end_lisp_access (token);
  if (mac_persistent_loop_p && pthread_main_np ())
    {
      if (cache == nil)
	cache = [[NSMutableDictionary alloc] init];
      cache[key] = @(kind);
    }

  return kind;
}

- (BOOL)respondsToSelector:(SEL)aSelector
{
  return ([super respondsToSelector:aSelector]
	  || mac_selector_kind (aSelector) != MAC_SELECTOR_NONE);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
  NSMethodSignature *signature = [super methodSignatureForSelector:aSelector];

  if (signature)
    return signature;
  switch (mac_selector_kind (aSelector))
    {
    case MAC_SELECTOR_ACTION:
      return action_signature ();
    case MAC_SELECTOR_SERVICES:
      return services_handler_signature ();
    default:
      return nil;
    }
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
  if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())
    {
      /* The handlers build Lisp events; run them with access.  */
      [anInvocation retainArguments];
      MAC_LOOP_CALLBACK_NEEDS_LISP ([self forwardInvocation:anInvocation]);
    }

  SEL selector = [anInvocation selector];
  NSMethodSignature *signature = [anInvocation methodSignature];
  int kind = mac_selector_kind (selector);

  if (kind == MAC_SELECTOR_ACTION
      && [signature isEqual:(action_signature ())])
    handle_action_invocation (anInvocation);
  else if (kind == MAC_SELECTOR_SERVICES
	   && [signature isEqual:(services_handler_signature ())])
    handle_services_invocation (anInvocation);
  else
    [super forwardInvocation:anInvocation];
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem
{
  SEL action = [anItem action];

  return (action == @selector(activate:)
	  || mac_selector_kind (action) == MAC_SELECTOR_ACTION);
}

- (void)updatePresentationOptions
{
  NSWindow *window = [NSApp keyWindow].topLevelWindow;

  if (![NSApp isActive])
    {
      needsUpdatePresentationOptionsOnBecomingActive = YES;

      return;
    }

  if ([window isKindOfClass:EmacsWindow.class])
    {
      EmacsFrameController *frameController = ((EmacsFrameController *)
					       [window delegate]);
      WMState windowManagerState = [frameController windowManagerState];
      NSApplicationPresentationOptions options = [NSApp presentationOptions];

      if ((options & NSApplicationPresentationFullScreen)
	  || (windowManagerState & WM_STATE_DEDICATED_DESKTOP))
	{
	  if ((options & (NSApplicationPresentationFullScreen
			  | NSApplicationPresentationAutoHideMenuBar))
	      == NSApplicationPresentationFullScreen
	      /* Application can be in full screen mode without hiding
		 the dock on OS X 10.9.  OS X prior to 10.11 cannot
		 auto-hide the menu bar without hiding the dock.  */
	      && (can_auto_hide_menu_bar_without_hiding_dock_p ()
		  || (options & (NSApplicationPresentationHideDock
				 | NSApplicationPresentationAutoHideDock))))
	    {
	      options |= NSApplicationPresentationAutoHideMenuBar;
	      [NSApp setPresentationOptions:options];
	    }
	}
      else if (windowManagerState & WM_STATE_FULLSCREEN)
	{
	  NSScreen *screen = [window screen];

	  if ([screen canShowMenuBar])
	    {
	      options = NSApplicationPresentationAutoHideMenuBar;
	      if (!can_auto_hide_menu_bar_without_hiding_dock_p ()
		  || [screen containsDock])
		options |= NSApplicationPresentationAutoHideDock;
	    }
	  else if ([screen containsDock])
	    options = NSApplicationPresentationAutoHideDock;
	  else
	    options = NSApplicationPresentationDefault;
	  [NSApp setPresentationOptions:options];
	}
      else if (windowManagerState & WM_STATE_NO_MENUBAR)
	{
	  NSArrayOf (NSNumber *) *windowNumbers =
	    [NSWindow windowNumbersWithOptions:0];

	  options = NSApplicationPresentationDefault;
	  for (NSWindow *window in [NSApp windows])
	    if ([window isKindOfClass:EmacsWindow.class]
		&& window.isVisible && window.parentWindow == nil)
	      {
		if (windowNumbers
		    && ![windowNumbers containsObject:@(window.windowNumber)])
		  continue;

		frameController = (EmacsFrameController *) [window delegate];
		windowManagerState = [frameController windowManagerState];
		if (windowManagerState & WM_STATE_DEDICATED_DESKTOP)
		  ;
		else if (windowManagerState & WM_STATE_FULLSCREEN)
		  {
		    NSScreen *screen = [window screen];

		    if ([screen canShowMenuBar])
		      {
			options |= NSApplicationPresentationAutoHideMenuBar;
			if (!can_auto_hide_menu_bar_without_hiding_dock_p ()
			    || [screen containsDock])
			  options |= NSApplicationPresentationAutoHideDock;
		      }
		    else if ([screen containsDock])
		      options |= NSApplicationPresentationAutoHideDock;
		  }
	      }
	  [NSApp setPresentationOptions:options];
	}
      else
	[NSApp setPresentationOptions:NSApplicationPresentationDefault];
    }
}

- (void)showMenuBar
{
  NSWindow *window = [NSApp keyWindow].topLevelWindow;;

  if ([window isKindOfClass:EmacsWindow.class])
    {
      EmacsFrameController *frameController = ((EmacsFrameController *)
					       [window delegate]);
      WMState windowManagerState = [frameController windowManagerState];
      NSApplicationPresentationOptions options = [NSApp presentationOptions];

      if ((options & NSApplicationPresentationFullScreen)
	  || (windowManagerState & WM_STATE_DEDICATED_DESKTOP))
	{
	  if ((options & (NSApplicationPresentationFullScreen
			  | NSApplicationPresentationAutoHideMenuBar))
	      == (NSApplicationPresentationFullScreen
		  | NSApplicationPresentationAutoHideMenuBar)
	      && !has_notch_support_p ())
	    {
	      options &= ~NSApplicationPresentationAutoHideMenuBar;
	      [NSApp setPresentationOptions:options];
	    }
	}
      else if (windowManagerState & WM_STATE_FULLSCREEN)
	{
	  NSScreen *screen = [window screen];

	  if ([screen canShowMenuBar])
	    {
	      options = NSApplicationPresentationDisableMenuBarTransparency;
	      if (!can_auto_hide_menu_bar_without_hiding_dock_p ()
		  || [screen containsDock])
		options |= NSApplicationPresentationAutoHideDock;
	      [NSApp setPresentationOptions:options];
	    }
	}
    }
}

- (BOOL)doesHoldQuit
{
  return hold_quit != NULL;
}

@end				// EmacsController

/* The persistent loop registers none of the old loop's undocumented
   event-loop preferences.  For validation, EMACS_MAC_LOOP_PREFS may
   name some of them (comma-separated, or "all") to register anyway on
   the OS versions where the old loop would.  */

static void
mac_loop_register_event_loop_preferences (void)
{
  static const struct
  {
    NSString *key;
    id value;
    int min_major;
  } prefs[] =
    {
      {@"NSEventConcurrentProcessingEnabled", @"NO", 26},
      {@"NSApplicationUpdateCycleEnabled", @"NO", 26},
      {@"NSWindowResizeNeedsTrackingLoop", @YES, 27},
      {@"NSControlPrefersGestureRecognizerTracking", @NO, 27},
    };
  const char *spec = getenv ("EMACS_MAC_LOOP_PREFS");
  NSArray *names = (spec
		    ? [@(spec) componentsSeparatedByString:@","] : @[]);
  bool all_p = [names containsObject:@"all"];
  NSMutableDictionary *defaults = [NSMutableDictionary dictionary];

  for (int i = 0; i < countof (prefs); i++)
    if ((all_p || [names containsObject:prefs[i].key])
	&& mac_operating_system_version.major >= prefs[i].min_major)
      {
	defaults[prefs[i].key] = prefs[i].value;
	MAC_TRACE_LOOP ("registering preference %s\n",
			prefs[i].key.UTF8String);
      }
  if (defaults.count)
    [NSUserDefaults.standardUserDefaults registerDefaults:defaults];
}

OSStatus
install_application_handler (void)
{
  mac_within_gui (^{
      if (mac_persistent_loop_p)
	mac_loop_register_event_loop_preferences ();
      else if (mac_operating_system_version.major >= 26)
	/* Disable some event-related macOS 26 features so as to avoid
	   the following problems:
	   1. Can't get events from the Carbon main event queue.
	   2. Rerouting a C-g event to the GUI queue from -[EmacsMenu
	      performKeyEquivalent:] causes hang.
	   3. Deferring a menu bar click event may fail and report
	      "Canceling unexpected menu tracking:".  */
	[NSUserDefaults.standardUserDefaults
	    registerDefaults:@{@"NSEventConcurrentProcessingEnabled" : @"NO",
	      @"NSApplicationUpdateCycleEnabled" : @"NO"}];

      if (!mac_persistent_loop_p
	  && mac_operating_system_version.major >= 27)
	/* Native resize and titlebar control gestures fail with the
	   application update cycle disabled.  Preserve the existing
	   event-loop settings and select traditional tracking before
	   AppKit caches these settings.  */
	[NSUserDefaults.standardUserDefaults
	    registerDefaults:@{@"NSWindowResizeNeedsTrackingLoop" : @YES,
	      @"NSControlPrefersGestureRecognizerTracking" : @NO}];

      [EmacsApplication sharedApplication];
      emacsController = [[EmacsController alloc] init];
      [NSApp setDelegate:emacsController];

      if (mac_persistent_loop_p)
	/* `main' runs the application after this request, which
	   completes at applicationDidFinishLaunching:.  */
	mac_loop_begin_launch ();
      else
	/* Will be stopped at applicationDidFinishLaunching: in the
	   delegate.  */
	[NSApp run];
    });

  return noErr;
}

Lisp_Object
mac_application_state (void)
{
  Lisp_Object result = Qnil;

  if (NSApp == nil)
    return result;

  result = Fcons (QChidden_p, Fcons ([NSApp isHidden] ? Qt : Qnil, result));
  result = Fcons (QCactive_p, Fcons ([NSApp isActive] ? Qt : Qnil, result));
  if ([NSApp respondsToSelector:@selector(effectiveAppearance)])
    result = Fcons (QCappearance,
		    Fcons ([NSApp effectiveAppearance].name.lispString,
			   result));

  return result;
}


/************************************************************************
			       Windows
 ************************************************************************/

#ifndef USE_METAL_RENDERING
static void set_global_focus_view_frame (struct frame *);
static void unset_global_focus_view_frame (void);
#endif
static void mac_move_frame_window_structure_1 (struct frame *, int, int);
static void
mac_with_suppressed_transparent_titlebar( NSWindow* window, BOOL assumeTransparent, void (CF_NOESCAPE ^block) (void))
{
  BOOL isTransparent = assumeTransparent ||
    ([window respondsToSelector:@selector(titlebarAppearsTransparent)] &&
     [window titlebarAppearsTransparent]);
  if (isTransparent)
    [window setTitlebarAppearsTransparent:NO];
  @try
    {
      block ();
    }
  @finally
    {
      if (isTransparent)
	[window setTitlebarAppearsTransparent:YES];
    }
}

#define DEFAULT_NUM_COLS (80)
#define RESIZE_CONTROL_WIDTH (15)
#define RESIZE_CONTROL_HEIGHT (15)

@implementation EmacsWindow

- (instancetype)initWithContentRect:(NSRect)contentRect
			  styleMask:(NSWindowStyleMask)windowStyle
			    backing:(NSBackingStoreType)bufferingType
			      defer:(BOOL)deferCreation
{
  self = [super initWithContentRect:contentRect styleMask:windowStyle
			    backing:bufferingType defer:deferCreation];
  if (self == nil)
    return nil;

  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(applicationDidUnhide:)
    name:NSApplicationDidUnhideNotification
    object:NSApp];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [observedTabGroup removeObserver:self forKeyPath:@"overviewVisible"];
#if !USE_ARC
  [observedTabGroup release];
  [mouseUpEvent release];
  [super dealloc];
#endif
}

- (BOOL)canBecomeKeyWindow
{
  return ((EmacsFrameController *) self.delegate).acceptsFocus;
}

- (BOOL)canBecomeMainWindow
{
  return self.isVisible && self.parentWindow == nil;
}

- (void)setFrame:(NSRect)windowFrame display:(BOOL)displayViews
{
  if (self.hasTitleBar)
    [super setFrame:windowFrame display:displayViews];
  else
    [super setFrame:[self constrainFrameRect:windowFrame toScreen:nil]
	    display:displayViews];
}

- (void)setFrameOrigin:(NSPoint)point
{
  if (self.hasTitleBar)
    [super setFrameOrigin:point];
  else
    {
      NSRect frameRect = [self frame];

      frameRect.origin = point;
      frameRect = [self constrainFrameRect:frameRect toScreen:nil];

      [super setFrameOrigin:frameRect.origin];
    }
}

- (Lisp_Object)lispFrame
{
  Lisp_Object result;

  XSETFRAME (result, [((EmacsFrameController *) [self delegate]) emacsFrame]);

  return result;
}

- (void)setupResizeTracking:(NSEvent *)event
{
  resizeTrackingStartWindowSize = [self frame].size;
  resizeTrackingStartLocation = [event locationInWindow];
}

- (void)suspendResizeTracking:(NSEvent *)event
	   positionAdjustment:(NSPoint)adjustment
{
  mouseUpEvent =
    MRC_RETAIN ([event mouseEventByChangingType:NSEventTypeLeftMouseUp
				    andLocation:event.locationInWindow]);
  [NSApp postEvent:mouseUpEvent atStart:YES];
  MOUSE_TRACKING_SET_RESUMPTION (emacsController, self, resumeResizeTracking);
}

- (void)resumeResizeTracking
{
  NSPoint location;
  NSEvent *mouseDownEvent;
  NSRect frame = [self frame];
  NSPoint hysteresisCancelLocation;
  NSEvent *hysteresisCancelDragEvent;

  if (resizeTrackingStartLocation.x * 2
      < resizeTrackingStartWindowSize.width)
    {
      location.x = resizeTrackingStartLocation.x;
      if (resizeTrackingStartLocation.x < RESIZE_CONTROL_WIDTH)
	hysteresisCancelLocation.x = location.x + RESIZE_CONTROL_WIDTH;
      else
	hysteresisCancelLocation.x = location.x;
    }
  else
    {
      location.x = (NSWidth (frame) + resizeTrackingStartLocation.x
		    - resizeTrackingStartWindowSize.width);
      if (resizeTrackingStartLocation.x
	  >= resizeTrackingStartWindowSize.width - RESIZE_CONTROL_WIDTH)
	hysteresisCancelLocation.x = location.x - RESIZE_CONTROL_WIDTH;
      else
	hysteresisCancelLocation.x = location.x;
    }
  if (resizeTrackingStartLocation.y * 2
      <= resizeTrackingStartWindowSize.height)
    {
      location.y = resizeTrackingStartLocation.y;
      if (resizeTrackingStartLocation.y <= RESIZE_CONTROL_HEIGHT)
	hysteresisCancelLocation.y = location.y + RESIZE_CONTROL_HEIGHT;
      else
	hysteresisCancelLocation.y = location.y;
    }
  else
    {
      location.y = (NSHeight (frame) + resizeTrackingStartLocation.y
		    - resizeTrackingStartWindowSize.height);
      if (resizeTrackingStartLocation.y
	  > resizeTrackingStartWindowSize.height - RESIZE_CONTROL_HEIGHT)
	hysteresisCancelLocation.y = location.y - RESIZE_CONTROL_HEIGHT;
      else
	hysteresisCancelLocation.y = location.y;
    }

  hysteresisCancelDragEvent =
    [mouseUpEvent mouseEventByChangingType:NSEventTypeLeftMouseDragged
			       andLocation:hysteresisCancelLocation];
  [NSApp postEvent:hysteresisCancelDragEvent atStart:YES];

  mouseDownEvent = [mouseUpEvent
		     mouseEventByChangingType:NSEventTypeLeftMouseDown
				  andLocation:location];
  MRC_RELEASE (mouseUpEvent);
  mouseUpEvent = nil;
  [NSApp postEvent:mouseDownEvent atStart:YES];
  setupResizeTrackingSuspended = YES;
}

- (void)sendEvent:(NSEvent *)event
{
  if ([event type] == NSEventTypeLeftMouseDown)
    {
      if (setupResizeTrackingSuspended)
	setupResizeTrackingSuspended = NO;
      else
	[self setupResizeTracking:event];
    }

  [super sendEvent:event];
}

- (BOOL)needsOrderFrontOnUnhide
{
  return needsOrderFrontOnUnhide;
}

- (void)setNeedsOrderFrontOnUnhide:(BOOL)flag
{
  needsOrderFrontOnUnhide = flag;
}

- (void)applicationDidUnhide:(NSNotification *)notification
{
  if (needsOrderFrontOnUnhide)
    {
      [self orderFront:nil];
      needsOrderFrontOnUnhide = NO;
    }

  /* This is a workaround: when the application is unhidden, a
     top-level window may become a (bogus) key window when one of its
     descendants is a (real) key window.  This is problematic because
     a single mouse movement event may be sent to both of the
     top-level and descendant windows.  */
  if (self.isKeyWindow && ![self isEqual:[NSApp keyWindow]])
    [self resignKeyWindow];
}

- (void)suspendConstrainingToScreen:(BOOL)flag
{
  if (flag)
    constrainingToScreenSuspensionCount++;
  else
    {
      if (constrainingToScreenSuspensionCount > 0)
	constrainingToScreenSuspensionCount--;
      else
	eassert (false);
    }
}

- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen
{
  if (constrainingToScreenSuspensionCount == 0)
    {
      id delegate = [self delegate];

      frameRect = [super constrainFrameRect:frameRect toScreen:screen];
      if ([delegate
	    respondsToSelector:@selector(window:willConstrainFrame:toScreen:)])
	frameRect = [delegate window:self willConstrainFrame:frameRect
			    toScreen:screen];
    }

  return frameRect;
}

- (void)zoom:(id)sender
{
  id delegate = [self delegate];
  id target = emacsController;

  if ([delegate respondsToSelector:@selector(window:shouldForwardAction:to:)]
      && [delegate window:self shouldForwardAction:_cmd to:target])
    [NSApp sendAction:_cmd to:target from:sender];
  else
    {
      EmacsFrameController *frameController = (EmacsFrameController *) delegate;
      [frameController setShouldLiveResizeTriggerTransition:YES];
      [super zoom:sender];
      [frameController setShouldLiveResizeTriggerTransition:NO];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
  SEL action = [menuItem action];

  if (action == @selector(runToolbarCustomizationPalette:))
    return NO;

  return [super validateMenuItem:menuItem];
}

- (void)toggleToolbarShown:(id)sender
{
  Lisp_Object alist =
    list1 (Fcons (Qtool_bar_lines,
		  make_fixnum ([(NSMenuItem *)sender state]
			       != NSControlStateValueOff)));
  EmacsFrameController *frameController = ((EmacsFrameController *)
					   [self delegate]);

  [frameController storeModifyFrameParametersEvent:alist];
}

- (void)changeToolbarDisplayMode:(id)sender
{
  [NSApp sendAction:(NSSelectorFromString (@"change-toolbar-display-mode:"))
		 to:nil from:sender];
}

- (NSWindow *)tabPickerWindow
{
  /* The tab group overview is displayed in NSTabPickerWindow on macOS
     10.15, and -[NSWindowTabGroup isOverviewVisible] returns NO while
     exiting from the overview.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_14))
    {
      NSWindowTabGroup *tabGroup = self.tabGroup;

      if (tabGroup)
	{
	  NSArrayOf (NSWindow *) *windowsInTabGroup = tabGroup.windows;

	  for (NSWindow *window in [NSApp windows])
	    if (window.isVisible
		&& [window.tabGroup isEqual:tabGroup]
		&& ![windowsInTabGroup containsObject:window])
	      return window;
	}
    }

  return nil;
}

- (void)exitTabGroupOverview
{
  if ([self respondsToSelector:@selector(tabGroup)])
    {
      NSWindowTabGroup *tabGroup = self.tabGroup;

      if (tabGroup.isOverviewVisible || self.tabPickerWindow)
	{
	  tabGroup.overviewVisible = NO;
	  while (tabGroup.isOverviewVisible || self.tabPickerWindow)
	    mac_run_loop_run_once (kEventDurationForever);
	}
    }
}

- (void)toggleTabOverview:(id)sender
{
  NSWindowTabGroup *tabGroup = self.tabGroup;

  if (!tabGroup.isOverviewVisible)
    {
      id delegate = self.delegate;

      [tabGroup addObserver:self forKeyPath:@"overviewVisible"
		    options:NSKeyValueObservingOptionNew context:nil];
      observedTabGroup = MRC_RETAIN (tabGroup);

      if ([delegate respondsToSelector:@selector(windowWillEnterTabOverview)])
	[delegate windowWillEnterTabOverview];
    }

  [super toggleTabOverview:sender];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionaryOf (NSKeyValueChangeKey, id) *)change
                       context:(void *)context
{
  if ([keyPath isEqualToString:@"overviewVisible"])
    {
      if (!((NSNumber *) change[NSKeyValueChangeNewKey]).charValue)
	{
	  id delegate = self.delegate;

	  if ([delegate respondsToSelector:@selector(windowDidExitTabOverview)])
	    [delegate windowDidExitTabOverview];
	  [object removeObserver:self forKeyPath:keyPath];
	  MRC_RELEASE (observedTabGroup);
	  observedTabGroup = nil;
	}
    }
  else
    [super observeValueForKeyPath:keyPath ofObject:object change:change
			  context:context];
}

- (id <NSAppearanceCustomization>)appearanceCustomization
{
  if (has_system_appearance_p ())
    return self.contentView;
  else
    return self;
}

- (NSWindowTabGroup *)tabGroup
{
  __block NSWindowTabGroup *tg = [super tabGroup];
  if (tg)
    return tg;
  /* On a newly created Emacs window, that has a transparent title bar
     (e.g., as a result of (mac-transparent-titlebar . t) being present
     in default-frame-alist, or when the transparency has been turned on
     for a window before tabGroup has been called for the window) the
     call to super class' -[NSWindow tabGroup] yields NULL.  The
     workaround is to disable the transparency temporarily then call the
     super class again.  Strangely enough, subsequent calls to
     -[NSWindow tabGroup] (made from such a window with transparent
     title bar) yield a proper NSWindowTabGroup object.  */
  else if ([self respondsToSelector:@selector(titlebarAppearsTransparent)] &&
	   [self titlebarAppearsTransparent])
    {
      mac_with_suppressed_transparent_titlebar (self, YES, ^{
	  tg = [super tabGroup];
	});
      return tg;
    }
  else
    return NULL;
}

@end				// EmacsWindow

@implementation EmacsFrameController

- (instancetype)initWithEmacsFrame:(struct frame *)f
{
  self = [self init];
  if (self == nil)
    return nil;

  emacsFrame = f;

  [self setupEmacsView];
  [self setupWindow];

  return self;
}

- (void)setupEmacsView
{
  struct frame *f = emacsFrame;

  if (!FRAME_TOOLTIP_P (f))
    {
      NSRect frameRect = NSMakeRect (0, 0, FRAME_PIXEL_WIDTH (f),
				     FRAME_PIXEL_HEIGHT (f));
      EmacsMainView *mainView = [[EmacsMainView alloc] initWithFrame:frameRect];

      [mainView setAction:@selector(storeInputEvent:)];
      emacsView = mainView;
    }
  else
    {
      NSRect frameRect = NSMakeRect (0, 0, 100, 100);

      emacsView = [[EmacsView alloc] initWithFrame:frameRect];
    }
  [emacsView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin
				  | NSViewWidthSizable | NSViewHeightSizable)];
  emacsView.layerContentsRedrawPolicy =
    NSViewLayerContentsRedrawOnSetNeedsDisplay;
  emacsView.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
#ifdef HAVE_XWIDGETS
  FRAME_MAC_VIEW (f) = (__bridge void *) emacsView;
#endif

#ifdef USE_METAL_RENDERING
  /* Make the view layer-backed so makeBackingLayer creates the
     CAMetalLayer, then create the Metal context.  */
  [emacsView setWantsLayer:YES];
  {
    NSRect bounds = [emacsView bounds];
    /* Try to get scale from the window; falls back to 2 on Retina if
       the window isn't visible yet (updateBackingScaleFactor will
       correct this once the window appears on screen).  */
    int scale = (int)(emacsWindow ? [emacsWindow backingScaleFactor] : 2);
    if (scale < 1) scale = 1;
    FRAME_METAL_CTX (f) = emacs_metal_context_create (
      (__bridge void *)emacsView,
      (int)NSWidth (bounds), (int)NSHeight (bounds), scale);
  }
#endif
}

- (void)setupOverlayView
{
  NSRect contentRect = NSMakeRect (0, 0, 64, 64);

  if (overlayView)
    return;

  overlayView = [[EmacsOverlayView alloc] initWithFrame:contentRect];
  [overlayView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [overlayView setLayer:[CALayer layer]];
  [overlayView setWantsLayer:YES];
  /* OS X 10.9 needs this.  */
  [overlayView setLayerUsesCoreImageFilters:YES];

  [self setupAnimationLayer];

  /* We add overlayView to the view hierarchy only when it is
     necessary.  Otherwise the CVDisplayLink thread would take much
     CPU time especially with application-side double buffering.  */
  [overlayView.layer addObserver:self forKeyPath:@"sublayers"
			 options:NSKeyValueObservingOptionPrior context:nil];
  [animationLayer addObserver:self forKeyPath:@"sublayers"
		      options:NSKeyValueObservingOptionPrior context:nil];
  [overlayView.layer setValue:((id) kCFBooleanFalse) forKey:@"showingBorder"];
  [overlayView.layer addObserver:self forKeyPath:@"showingBorder"
			 options:0 context:nil];
}

- (void)synchronizeOverlayViewFrame
{
  overlayView.frame = [emacsWindow.contentView bounds];
}

- (void)updateOverlayViewParticipation
{
  BOOL shouldShowOverlayView =
    (overlayView.layer.sublayers.count > 1
     || animationLayer.sublayers.count != 0
     || ([overlayView.layer valueForKey:@"showingBorder"]
	 == (id) kCFBooleanTrue));

  if (overlayView.superview && !shouldShowOverlayView)
    [overlayView removeFromSuperview];
  else if (!overlayView.superview && shouldShowOverlayView)
    {
      /* We place overlayView below emacsView so events are not
	 intercepted by the former.  Still the former (layer-hosting)
	 is displayed in front of the latter (neither layer-backed nor
	 layer-hosting).  */
      /* Unfortunately, this trick does not work on macOS 10.14.
	 Placing overlayView above emacsView (with returning nil in
	 hitTest:) works if the executable is linked against the macOS
	 10.14 SDK, but not for the one linked on the older versions
	 then run on macOS 10.14.  Making overlayView a subview of
	 emacsView works for both cases.  Note that we need to
	 temporarily hide overlayView when taking screenshot in
	 -[EmacsFrameController bitmapImageRepInEmacsViewRect:].  */
      /* If emacsView is layer-backed, which is the case when the
	 executable is linked against the macOS 10.14 SDK, then the
	 live resize transition layer used in full screen transition
	 looks translucent if we make overlayView a subview of
	 emacsView.  */
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
      if (emacsView.wantsUpdateLayer)
#endif
	[emacsWindow.contentView addSubview:overlayView];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
      else if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_13))
	[emacsView addSubview:overlayView];
      else
	[emacsWindow.contentView addSubview:overlayView positioned:NSWindowBelow
				 relativeTo:emacsView];
#endif
      [self synchronizeOverlayViewFrame];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
			change:(NSDictionaryOf (NSKeyValueChangeKey, id) *)change
		       context:(void *)context
{
  BOOL updateOverlayViewParticipation = NO;

  if ([keyPath isEqualToString:@"sublayers"])
    {
      if (change[NSKeyValueChangeNotificationIsPriorKey])
	[self synchronizeOverlayViewFrame];
      else
	updateOverlayViewParticipation = YES;
    }
  else if ([keyPath isEqualToString:@"showingBorder"])
    updateOverlayViewParticipation = YES;

  if (updateOverlayViewParticipation)
    {
      if (!popup_activated ())
	[self updateOverlayViewParticipation];
      else
	[self performSelector:@selector(updateOverlayViewParticipation)
		   withObject:nil afterDelay:0];
    }
}

- (void)setupWindow
{
  struct frame *f = emacsFrame;
  EmacsWindow *oldWindow = emacsWindow;
  NSRect contentRect;
  NSWindowStyleMask windowStyle;
  EmacsWindow *window;

  if (!FRAME_TOOLTIP_P (f))
    {
      if (!self.shouldBeTitled)
	windowStyle = (NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable);
      else
	windowStyle = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
		       | NSWindowStyleMaskMiniaturizable
		       | NSWindowStyleMaskResizable);
    }
  else
    windowStyle = NSWindowStyleMaskBorderless;

  if (oldWindow == nil)
    {
      NSScreen *screen = nil;

      if (f->size_hint_flags & (USPosition | PPosition))
	screen = [NSScreen screenContainingPoint:(NSMakePoint (f->left_pos,
							       f->top_pos))];
      if (screen == nil)
	screen = [NSScreen mainScreen];
      contentRect.origin = [screen frame].origin;
      contentRect.size = [emacsView frame].size;
    }
  else
    {
      NSView *contentView = [oldWindow contentView];

      contentRect = [contentView frame];
      contentRect.origin = [[contentView superview]
			     convertPoint:contentRect.origin toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
      contentRect.origin = [oldWindow convertPointToScreen:contentRect.origin];
#else
      contentRect.origin = [oldWindow convertRectToScreen:contentRect].origin;
#endif
    }

  window = [[EmacsWindow alloc] initWithContentRect:contentRect
					  styleMask:windowStyle
					    backing:NSBackingStoreBuffered
					      defer:YES];
#if USE_ARC
  /* Increase retain count to accommodate itself to
     released-when-closed on ARC.  Just setting released-when-closed
     to NO leads to crash in some situations.  */
  CFBridgingRetain (window);
#endif
  NSVisualEffectView *visualEffectView =
    [[NSVisualEffectView alloc] initWithFrame:[window.contentView frame]];

  window.contentView = visualEffectView;
  MRC_RELEASE (visualEffectView);

  FRAME_BACKGROUND_ALPHA_ENABLED_P (f) = true;
  if (FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f) = true;
      if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_13)
	[window.contentView setWantsLayer:YES];
    }
  if (oldWindow)
    {
      [window setTitle:[oldWindow title]];
      [window setDocumentEdited:[oldWindow isDocumentEdited]];
      [window setAlphaValue:[oldWindow alphaValue]];
      [window setBackgroundColor:[oldWindow backgroundColor]];
      [window setRepresentedFilename:[oldWindow representedFilename]];
      [window setCollectionBehavior:[oldWindow collectionBehavior]];
      window.level = oldWindow.level;
      [window setExcludedFromWindowsMenu:oldWindow.isExcludedFromWindowsMenu];
      for (NSWindow *childWindow in oldWindow.childWindows)
	if ([childWindow isKindOfClass:EmacsWindow.class])
	  {
	    [(EmacsWindow *)childWindow suspendConstrainingToScreen:YES];
	    [oldWindow removeChildWindow:childWindow];
	    [(EmacsWindow *)childWindow suspendConstrainingToScreen:NO];
	    [window addChildWindow:childWindow ordered:NSWindowAbove];
	  }
      window.appearanceCustomization.appearance =
	oldWindow.appearanceCustomization.appearance;
      window.appearance =
	oldWindow.appearance;

      [oldWindow setDelegate:nil];
      [self hideHourglass:nil];
      hourglassWindow = nil;
    }

  emacsWindow = window;
  [window setDelegate:self];
  [[window contentView] addSubview:emacsView];
  [self updateBackingScaleFactor];
  [self updateEmacsViewIsHiddenOrHasHiddenAncestor];
#if HAVE_MAC_METAL
  [self updateEmacsViewMTLObjects];
#endif

  if (oldWindow)
    {
      BOOL isKeyWindow = [oldWindow isKeyWindow];
      NSWindow *parentWindow = oldWindow.parentWindow;

      if (parentWindow == nil)
	[window orderWindow:NSWindowBelow relativeTo:[oldWindow windowNumber]];
      else
	{
	  [parentWindow addChildWindow:window ordered:NSWindowAbove];
	  /* Mac OS X 10.6 needs this.  */
	  [parentWindow removeChildWindow:oldWindow];
	}
      window.animationBehavior = oldWindow.animationBehavior;
      [oldWindow close];
      /* This is necessary on OS X 10.11.  */
      if (isKeyWindow)
	[window makeKeyWindow];
    }

  if (!FRAME_TOOLTIP_P (f))
    {
      window.hasShadow = self.shouldHaveShadow;
      [window setAcceptsMouseMovedEvents:YES];
      if (window.hasTitleBar)
	[self setupToolBarWithVisibility:(FRAME_EXTERNAL_TOOL_BAR (f))];
      [self setupOverlayView];
      [self updateOverlayViewParticipation];
      if (!(windowManagerState & WM_STATE_FULLSCREEN)
	  && !FRAME_PARENT_FRAME (f))
	window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
      window.animationBehavior = NSWindowAnimationBehaviorDocumentWindow;
      if ([window respondsToSelector:@selector(titlebarAppearsTransparent)])
	{
	  BOOL transparent = FRAME_MAC_TRANSPARENT_TITLEBAR(f) ? YES : NO;
	  [window setTitlebarAppearsTransparent:transparent];
	}
    }
  else
    {
      [window setHasShadow:YES];
      [window setLevel:NSScreenSaverWindowLevel];
      [window setIgnoresMouseEvents:YES];
      [window setExcludedFromWindowsMenu:YES];
      window.animationBehavior = NSWindowAnimationBehaviorNone;
    }
}

- (void)closeWindow
{
  /* W7: the frame is actually being deleted, which resolves any
     pending close request for it immediately (rather than waiting for
     the generic mac_loop_select-driven clear).  */
  if (mac_persistent_loop_p)
    [self macLoopClearClosePending];

  /* We temporarily run application when closing a window.  That
     causes emacsView to receive drawRect: before closing a tabbed
     window on macOS 10.12.  It is too late to remove the view in the
     windowWillClose: delegate method, so we remove it here.  */
  [emacsView removeFromSuperview];
  [emacsWindow close];
}

- (struct frame *)emacsFrame
{
  return emacsFrame;
}

- (EmacsWindow *)emacsWindow
{
  return emacsWindow;
}

- (void)dealloc
{
  [overlayView.layer removeObserver:self forKeyPath:@"sublayers"];
  [animationLayer removeObserver:self forKeyPath:@"sublayers"];
  [overlayView.layer removeObserver:self forKeyPath:@"showingBorder"];
  MRC_RELEASE (macLoopSavedSubtitle);
#if !USE_ARC
  [savedChildWindowAlphaMap release];
  [emacsView release];
  /* emacsWindow and hourglassWindow are released via
     released-when-closed.  */
  [overlayView release];
  [super dealloc];
#endif
}

/* Persistent loop only (W7/W8): "Waiting for Emacs…" window subtitle,
   shown when Lisp has not resolved a close or Quit request within
   100 ms.  macLoopIndicatorPendingCount tracks how many of the two
   reasons currently apply to this window, so one being resolved does
   not clobber the saved subtitle while the other is still pending.  */

- (void)macLoopShowIndicatorIfNeeded
{
  if (macLoopIndicatorPendingCount == 0 || macLoopSavedSubtitle != nil)
    return;
  if (![emacsWindow respondsToSelector:@selector(setSubtitle:)])
    return;
  macLoopSavedSubtitle = [(emacsWindow.subtitle ?: @"") copy];
  emacsWindow.subtitle = @"Waiting for Emacs…";
}

- (void)macLoopRestoreIndicatorIfDone
{
  if (macLoopIndicatorPendingCount > 0 || macLoopSavedSubtitle == nil)
    return;
  if ([emacsWindow respondsToSelector:@selector(setSubtitle:)])
    emacsWindow.subtitle = macLoopSavedSubtitle;
  MRC_RELEASE (macLoopSavedSubtitle);
  macLoopSavedSubtitle = nil;
}

/* W7: begin a close-pending request for this frame's window.  Return
   YES if this is the first pending close (the caller should store
   DELETE_WINDOW_EVENT), or NO if a close is already pending (the
   caller should drop this click).  */

- (BOOL)macLoopBeginClosePending
{
  if (macLoopClosePending)
    return NO;

  macLoopClosePending = YES;
  macLoopIndicatorPendingCount++;
  __atomic_add_fetch (&mac_loop_pending_indicator_count, 1, __ATOMIC_RELEASE);

  unsigned long generation = ++macLoopCloseGeneration;

  dispatch_after (dispatch_time (DISPATCH_TIME_NOW,
				 (int64_t) (0.1 * NSEC_PER_SEC)),
		  dispatch_get_main_queue (), ^{
      if (macLoopClosePending && macLoopCloseGeneration == generation)
	[self macLoopShowIndicatorIfNeeded];
    });

  return YES;
}

/* W7: clear close-pending state for this frame's window.  Called once
   Lisp has resolved the request (the frame was deleted -- see
   -closeWindow -- a prompt appeared, or the close was refused).  */

- (void)macLoopClearClosePending
{
  if (!macLoopClosePending)
    return;

  macLoopClosePending = NO;
  macLoopCloseGeneration++;
  macLoopIndicatorPendingCount--;
  __atomic_sub_fetch (&mac_loop_pending_indicator_count, 1, __ATOMIC_RELEASE);
  [self macLoopRestoreIndicatorIfDone];
}

/* W8: apply/clear the Quit indicator on this window; the delay and
   dedupe live in mac_loop_quit_begin/mac_loop_quit_clear since Quit is
   process-wide rather than per-window.  */

- (void)macLoopShowQuitIndicator
{
  macLoopIndicatorPendingCount++;
  [self macLoopShowIndicatorIfNeeded];
}

#ifdef USE_METAL_RENDERING
/* W3: AppKit makes the view's CAMetalLayer opaque, and a layer that
   grows before Lisp presents a drawable of the new size shows the old
   drawable anchored top-left (NSViewLayerContentsPlacementTopLeft).
   Without a background colour the area outside that drawable is
   undefined.  Fill it with the published frame background.  */

- (void)setEmacsViewLayerBackgroundColor:(NSColor *)color
{
  [CATransaction setDisableActions:YES];
  emacsView.layer.backgroundColor = color.CGColor;
  [CATransaction commit];
}
#endif

- (void)macLoopClearQuitIndicator
{
  macLoopIndicatorPendingCount--;
  [self macLoopRestoreIndicatorIfDone];
}

- (BOOL)acceptsFocus
{
  struct frame *f = emacsFrame;

  return !FRAME_TOOLTIP_P (f) && !FRAME_NO_ACCEPT_FOCUS (f);
}

- (NSSize)hintedWindowFrameSize:(NSSize)frameSize allowsLarger:(BOOL)flag
{
  struct frame *f = emacsFrame;
  XSizeHints *size_hints = FRAME_SIZE_HINTS (f);
  NSRect windowFrame, emacsViewBounds;
  NSSize emacsViewSizeInPixels, emacsViewSize;
  CGFloat dw, dh, min_width, min_height;

  windowFrame = [emacsWindow frame];
  if (size_hints == NULL)
    return windowFrame.size;

  emacsViewBounds = [emacsView bounds];
  emacsViewSizeInPixels = [emacsView convertSize:emacsViewBounds.size
				     toView:nil];
  dw = NSWidth (windowFrame) - emacsViewSizeInPixels.width;
  dh = NSHeight (windowFrame) - emacsViewSizeInPixels.height;
  emacsViewSize = [emacsView convertSize:(NSMakeSize (frameSize.width - dw,
						      frameSize.height - dh))
				fromView:nil];

  min_width = (size_hints->min_width ? size_hints->min_width
	       : size_hints->width_inc);
  if (emacsViewSize.width < min_width)
    emacsViewSize.width = min_width;
  else
    emacsViewSize.width = size_hints->base_width
      + (int) ((emacsViewSize.width - size_hints->base_width)
	       / size_hints->width_inc + (flag ? .5f : 0))
      * size_hints->width_inc;

  min_height = (size_hints->min_height ? size_hints->min_height
	       : size_hints->height_inc);
  if (emacsViewSize.height < min_height)
    emacsViewSize.height = min_height;
  else
    emacsViewSize.height = size_hints->base_height
      + (int) ((emacsViewSize.height - size_hints->base_height)
	       / size_hints->height_inc + (flag ? .5f : 0))
      * size_hints->height_inc;

  emacsViewSizeInPixels = [emacsView convertSize:emacsViewSize toView:nil];

  return NSMakeSize (emacsViewSizeInPixels.width + dw,
		     emacsViewSizeInPixels.height + dh);
}

- (NSRect)window:(NSWindow *)sender willConstrainFrame:(NSRect)frameRect
	toScreen:(NSScreen *)screen
{
  if (windowManagerState & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT
			    | WM_STATE_FULLSCREEN))
    {
      NSWindow *parentWindow = sender.parentWindow;

      if (parentWindow == nil)
	{
	  if (screen == nil)
	    {
	      NSEvent *currentEvent = [NSApp currentEvent];

	      if (currentEvent.type == NSEventTypeLeftMouseUp)
		{
		  /* Probably end of title bar dragging.  */
		  NSWindow *eventWindow = [currentEvent window];
		  NSPoint location = [currentEvent locationInWindow];

		  if (eventWindow)
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
		    location = [eventWindow convertPointToScreen:location];
#else
		    location =
		      [eventWindow
			convertRectToScreen:(NSMakeRect (location.x, location.y,
							 0, 0))].origin;
#endif
		  screen = [NSScreen screenContainingPoint:location];
		}

	      if (screen == nil)
		screen = [NSScreen closestScreenForRect:frameRect];
	    }

	  if (windowManagerState & WM_STATE_FULLSCREEN)
	    frameRect = screen.frame;
	  else
	    {
	      NSRect screenVisibleFrame = screen.visibleFrame;

	      if (windowManagerState & WM_STATE_MAXIMIZED_HORZ)
		{
		  frameRect.origin.x = screenVisibleFrame.origin.x;
		  frameRect.size.width = screenVisibleFrame.size.width;
		}
	      if (windowManagerState & WM_STATE_MAXIMIZED_VERT)
		{
		  frameRect.origin.y = screenVisibleFrame.origin.y;
		  frameRect.size.height = screenVisibleFrame.size.height;
		}
	    }
	}
      else			/* parentWindow != nil */
	{
	  NSView *parentContentView = parentWindow.contentView;
	  NSRect parentContentRect = parentContentView.bounds;

	  parentContentRect = [parentContentView convertRect:parentContentRect
						      toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
	  parentContentRect.origin =
	    [parentWindow convertPointToScreen:parentContentRect.origin];
#else
	  parentContentRect.origin =
	    [parentWindow convertRectToScreen:parentContentRect].origin;
#endif

	  if (windowManagerState & WM_STATE_FULLSCREEN)
	    frameRect = parentContentRect;
	  else
	    {
	      if (windowManagerState & WM_STATE_MAXIMIZED_HORZ)
		{
		  frameRect.origin.x = parentContentRect.origin.x;
		  frameRect.size.width = parentContentRect.size.width;
		}
	      if (windowManagerState & WM_STATE_MAXIMIZED_VERT)
		{
		  frameRect.origin.y = parentContentRect.origin.y;
		  frameRect.size.height = parentContentRect.size.height;
		}
	    }
	}
    }

  return frameRect;
}

- (WMState)windowManagerState
{
  return windowManagerState;
}

- (void)updateCollectionBehavior
{
  NSWindowCollectionBehavior behavior;

  if ((windowManagerState & WM_STATE_NO_MENUBAR)
      && !(windowManagerState & WM_STATE_FULLSCREEN))
    {
      behavior = ((windowManagerState & WM_STATE_STICKY)
		  ? NSWindowCollectionBehaviorCanJoinAllSpaces
		  : NSWindowCollectionBehaviorMoveToActiveSpace);
      behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    }
  else
    {
      behavior = ((windowManagerState & WM_STATE_STICKY)
		  ? NSWindowCollectionBehaviorCanJoinAllSpaces
		  : NSWindowCollectionBehaviorDefault);
      if (!(windowManagerState & WM_STATE_FULLSCREEN)
	  || (windowManagerState & WM_STATE_DEDICATED_DESKTOP))
	behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    }
  behavior |= ((windowManagerState & WM_STATE_SKIP_TASKBAR)
	       ? NSWindowCollectionBehaviorIgnoresCycle
	       : NSWindowCollectionBehaviorParticipatesInCycle);
  behavior |= ((windowManagerState & WM_STATE_OVERRIDE_REDIRECT)
	       ? NSWindowCollectionBehaviorTransient
	       : NSWindowCollectionBehaviorManaged);
  [emacsWindow setCollectionBehavior:behavior];

  [emacsWindow setExcludedFromWindowsMenu:((windowManagerState
					    & WM_STATE_SKIP_TASKBAR) != 0)];
}

- (void)updateWindowLevel
{
  NSWindowLevel level = NSNormalWindowLevel;

  if (windowManagerState & WM_STATE_ABOVE)
    level++;
  else if (windowManagerState & WM_STATE_BELOW)
    level--;
  emacsWindow.level = level;
}

- (NSRect)preprocessWindowManagerStateChange:(WMState)newState
{
  NSRect frameRect = [emacsWindow frame];
  NSRect screenRect = [[emacsWindow screen] frame];
  WMState oldState, diff;

  oldState = windowManagerState;
  diff = (oldState ^ newState);

  if (diff & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_FULLSCREEN))
    {
      if (!(oldState & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_FULLSCREEN)))
	{
	  savedFrame.origin.x = NSMinX (frameRect) - NSMinX (screenRect);
	  savedFrame.size.width = NSWidth (frameRect);
	}
      else
	{
	  frameRect.origin.x = NSMinX (savedFrame) + NSMinX (screenRect);
	  frameRect.size.width = NSWidth (savedFrame);
	}
    }

  if (diff & (WM_STATE_MAXIMIZED_VERT | WM_STATE_FULLSCREEN))
    {
      if (!(oldState & (WM_STATE_MAXIMIZED_VERT | WM_STATE_FULLSCREEN)))
	{
	  savedFrame.origin.y = NSMinY (frameRect) - NSMaxY (screenRect);
	  savedFrame.size.height = NSHeight (frameRect);
	}
      else
	{
	  frameRect.origin.y = NSMinY (savedFrame) + NSMaxY (screenRect);
	  frameRect.size.height = NSHeight (savedFrame);
	}
    }

  windowManagerState ^=
    (diff & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT
	     | WM_STATE_FULLSCREEN | WM_STATE_DEDICATED_DESKTOP));
  [self updateCollectionBehavior];

  return frameRect;
}

- (NSRect)postprocessWindowManagerStateChange:(NSRect)frameRect
{
  frameRect = [emacsWindow constrainFrameRect:frameRect toScreen:nil];
  if (!(windowManagerState & WM_STATE_FULLSCREEN))
    {
      NSSize hintedFrameSize = [self hintedWindowFrameSize:frameRect.size
					      allowsLarger:NO];

      if (!(windowManagerState & WM_STATE_MAXIMIZED_HORZ))
	frameRect.size.width = hintedFrameSize.width;
      if (!(windowManagerState & WM_STATE_MAXIMIZED_VERT))
	frameRect.size.height = hintedFrameSize.height;
    }

  return frameRect;
}

- (void)changeFullScreenState:(WMState)fullScreenState
{
  eassert (emacsWindow.parentWindow == nil
	   && (!(emacsWindow.styleMask & NSWindowStyleMaskFullScreen)
	       != !(fullScreenState & WM_STATE_DEDICATED_DESKTOP)));

  fullScreenTargetState = fullScreenState;
  [emacsWindow toggleFullScreen:nil];
}

- (void)setWindowManagerState:(WMState)newState
{
  struct frame *f = emacsFrame;
  WMState oldState, diff, fullScreenState;
  const WMState collectionBehaviorStates =
    (WM_STATE_STICKY | WM_STATE_NO_MENUBAR
     | WM_STATE_SKIP_TASKBAR | WM_STATE_OVERRIDE_REDIRECT);
  const WMState windowLevelStates = WM_STATE_ABOVE | WM_STATE_BELOW;
  enum {
    SET_FRAME_UNNECESSARY,
    SET_FRAME_NECESSARY,
    SET_FRAME_TOGGLE_FULL_SCREEN_LATER
  } setFrameType = SET_FRAME_UNNECESSARY;

  oldState = windowManagerState;
  diff = (oldState ^ newState);

  if (diff == 0)
    return;

  if (diff & collectionBehaviorStates)
    {
      windowManagerState ^= (diff & collectionBehaviorStates);
      [self updateCollectionBehavior];
    }

  if (diff & windowLevelStates)
    {
      windowManagerState ^= (diff & windowLevelStates);
      [self updateWindowLevel];
    }

  if ((diff & WM_STATE_DEDICATED_DESKTOP)
      && emacsWindow.parentWindow == nil)
    {
      emacsWindow.collectionBehavior |=
	NSWindowCollectionBehaviorFullScreenPrimary;

      if (diff & WM_STATE_FULLSCREEN)
	[self changeFullScreenState:newState];
      else if (newState & WM_STATE_DEDICATED_DESKTOP)
	{
#if 1
	  /* We once used windows with NSWindowStyleMaskFullScreen for
	     fullboth frames instead of window class replacement, but
	     the use of such windows on non-dedicated Space seems to
	     lead to several glitches.  So we have to replace the
	     window class, and then enter full screen mode, i.e.,
	     fullboth -> maximized -> fullscreen.  */
	  fullScreenState = newState;
	  newState = ((newState & ~WM_STATE_FULLSCREEN)
		      | WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT);
	  diff = (oldState ^ newState);
#endif
	  setFrameType = SET_FRAME_TOGGLE_FULL_SCREEN_LATER;
	}
      else
	{
	  /* Direct transition fullscreen -> fullboth is not trivial
	     even if we use -[NSWindow setStyleMask:], which is
	     available from 10.6, instead of window class replacement,
	     because AppKit strips off NSWindowStyleMaskFullScreen
	     after exiting from the full screen mode.  We make such a
	     transition via maximized state, i.e, fullscreen ->
	     maximized -> fullboth.  */
	  mac_within_lisp (^{
	      store_frame_param (f, Qfullscreen, Qmaximized);
	    });
	  [self changeFullScreenState:((newState & ~WM_STATE_FULLSCREEN)
				       | WM_STATE_MAXIMIZED_HORZ
				       | WM_STATE_MAXIMIZED_VERT)];
	  fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_FULLBOTH;
	}
    }
  else if (diff & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT
		| WM_STATE_FULLSCREEN))
      setFrameType = SET_FRAME_NECESSARY;

  if (setFrameType != SET_FRAME_UNNECESSARY)
    {
      NSRect frameRect = [self preprocessWindowManagerStateChange:newState];

      if ((diff & WM_STATE_FULLSCREEN)
	  || setFrameType == SET_FRAME_TOGGLE_FULL_SCREEN_LATER)
	[self updateWindowStyle];

      frameRect = [self postprocessWindowManagerStateChange:frameRect];
      [emacsWindow setFrame:frameRect display:YES];

      if (setFrameType == SET_FRAME_TOGGLE_FULL_SCREEN_LATER)
	[self changeFullScreenState:fullScreenState];
    }

  [emacsController updatePresentationOptions];
}

- (void)updateBackingScaleFactor
{
  struct frame *f = emacsFrame;

  FRAME_BACKING_SCALE_FACTOR (f) = emacsWindow.backingScaleFactor;

#ifdef USE_METAL_RENDERING
  if (FRAME_METAL_CTX (f))
    {
      [emacsView syncMetalDrawableSize];
      emacsView.needsDisplay = YES;
    }
#endif
}

- (BOOL)emacsViewIsHiddenOrHasHiddenAncestor
{
  return emacsViewIsHiddenOrHasHiddenAncestor;
}

- (void)updateEmacsViewIsHiddenOrHasHiddenAncestor
{
  emacsViewIsHiddenOrHasHiddenAncestor =
    [emacsView isHiddenOrHasHiddenAncestor];
}

- (void)displayEmacsViewIfNeeded
{
  [emacsView displayIfNeeded];
}

- (void)lockFocusOnEmacsView
{
  [emacsView lockFocusOnBacking];
}

- (void)unlockFocusOnEmacsView
{
  [emacsView unlockFocusOnBacking];
}

#ifndef USE_METAL_RENDERING
- (void)scrollEmacsViewRect:(NSRect)rect by:(NSSize)delta
{
  [emacsView scrollBackingRect:rect by:delta];
}

- (void)invalidateEmacsViewBackingRect:(CGRect)invalidRect
			     clipRects:(const CGRect *)clipRects
				 count:(CFIndex)count
			  forCGContext:(CGContextRef)context
{
  [emacsView invalidateBackingRect:invalidRect
			 clipRects:clipRects count:count forCGContext:context];
}

#if HAVE_MAC_METAL
- (void)updateEmacsViewMTLObjects
{
  [emacsView updateMTLObjects];
}
#endif
#endif /* !USE_METAL_RENDERING */

- (NSPoint)convertEmacsViewPointToScreen:(NSPoint)point
{
  point = [emacsView convertPoint:point toView:nil];

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
  return [emacsWindow convertPointToScreen:point];
#else
  return [emacsWindow
	   convertRectToScreen:(NSMakeRect (point.x, point.y, 0, 0))].origin;
#endif
}

- (NSPoint)convertEmacsViewPointFromScreen:(NSPoint)point
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
  point = [emacsWindow convertPointFromScreen:point];
#else
  point = [emacsWindow
	    convertRectFromScreen:(NSMakeRect (point.x, point.y, 0, 0))].origin;
#endif

  return [emacsView convertPoint:point fromView:nil];
}

- (NSRect)convertEmacsViewRectToScreen:(NSRect)rect
{
  rect = [emacsView convertRect:rect toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
  rect.origin = [emacsWindow convertPointToScreen:rect.origin];
#else
  rect.origin = [emacsWindow convertRectToScreen:rect].origin;
#endif

  return rect;
}

- (NSRect)convertEmacsViewRectFromScreen:(NSRect)rect
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
  rect.origin = [emacsWindow convertPointFromScreen:rect.origin];
#else
  rect.origin = [emacsWindow convertRectFromScreen:rect].origin;
#endif
  rect = [emacsView convertRect:rect fromView:nil];

  return rect;
}

- (NSRect)centerScanEmacsViewRect:(NSRect)rect
{
  return [emacsView centerScanRect:rect];
}

- (void)invalidateCursorRectsForEmacsView
{
  [emacsWindow invalidateCursorRectsForView:emacsView];
}

- (void)setEmacsViewNeedsDisplayInRects:(const NSRect *)rects
				  count:(NSUInteger)count
{
  NSUInteger i;

  for (i = 0; i < count; i++)
    [emacsView setNeedsDisplayInRect:rects[i]];
}

- (void)setEmacsViewNeedsDisplay:(BOOL)flag
{
  emacsView.needsDisplay = flag;
}

/* Delegete Methods.  */

- (void)windowDidBecomeKey:(NSNotification *)notification
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self windowDidBecomeKey:notification]);

  struct frame *f = emacsFrame;

  mac_within_lisp_deferred_unless_popup (^{
      struct input_event inev;

      EVENT_INIT (inev);
      inev.arg = Qnil;
      mac_focus_changed (activeFlag, FRAME_DISPLAY_INFO (f), f, &inev);
      if (inev.kind != NO_EVENT)
	[emacsController storeEvent:&inev];
    });

  [self noteEnterEmacsView];

  [emacsController setConflictingKeyBindingsDisabled:YES];

  [emacsController updatePresentationOptions];

  [emacsWindow.topLevelWindow makeMainWindow];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self windowDidResignKey:notification]);

  struct frame *f = emacsFrame;

  mac_within_lisp_deferred_unless_popup (^{
      struct input_event inev;

      EVENT_INIT (inev);
      inev.arg = Qnil;
      mac_focus_changed (0, FRAME_DISPLAY_INFO (f), f, &inev);
      if (inev.kind != NO_EVENT)
	[emacsController storeEvent:&inev];
    });

  [self noteLeaveEmacsView];

  [emacsController setConflictingKeyBindingsDisabled:NO];
}

- (void)windowDidMove:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("move", [self windowDidMove:notification]);

  struct frame *f = emacsFrame;

  mac_handle_origin_change (f);
}

- (void)windowDidResize:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("resize", [self windowDidResize:notification]);

  struct frame *f = emacsFrame;

  /* `windowDidMove:' above is not called when both size and location
     are changed.  */
  mac_handle_origin_change (f);
  if (hourglassWindow)
    [self updateHourglassWindowOrigin];
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("visibility", [self windowDidMiniaturize:notification]);

  struct frame *f = emacsFrame;

  mac_handle_visibility_change (f);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("visibility", [self windowDidDeminiaturize:notification]);

  struct frame *f = emacsFrame;

  mac_handle_visibility_change (f);
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("screen", [self windowDidChangeScreen:notification]);

  /* We used to update the presentation options for the key window
     here.  But it makes application switching impossible in Split
     View on macOS 10.14 and later.  */
#ifdef USE_METAL_RENDERING
  [self updateBackingScaleFactor];
#else
#if HAVE_MAC_METAL
  [self updateEmacsViewMTLObjects];
#endif
#endif
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("backing", [self windowDidChangeBackingProperties:notification]);

  [self updateBackingScaleFactor];
}

- (BOOL)windowShouldClose:(id)sender
{
  struct frame *f = emacsFrame;
  struct input_event inev;

  /* W7: dedupe repeated close clicks while Lisp has not resolved a
     previous DELETE_WINDOW_EVENT for this frame.  */
  if (mac_persistent_loop_p && ![self macLoopBeginClosePending])
    return NO;

  EVENT_INIT (inev);
  inev.arg = Qnil;
  inev.kind = DELETE_WINDOW_EVENT;
  XSETFRAME (inev.frame_or_window, f);
  [emacsController storeEvent:&inev];

  return NO;
}

- (BOOL)window:(NSWindow *)sender shouldForwardAction:(SEL)action to:(id)target
{
  if (action == @selector(zoom:))
    if ((windowManagerState
	 & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT))
	&& [target respondsToSelector:action])
      return YES;

  return NO;
}

- (void)windowWillClose:(NSNotification *)notification
{
  [self hideHourglass:nil];
  [emacsWindow setDelegate:nil];
}

- (void)windowWillMove:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  f->output_data.mac->toolbar_win_gravity = 0;
}

- (NSSize)windowWillResize:(NSWindow *)sender
		    toSize:(NSSize)proposedFrameSize
{
  EmacsWindow *window = (EmacsWindow *) sender;
  NSEvent *currentEvent = [NSApp currentEvent];
  BOOL leftMouseDragged = ([currentEvent type] == NSEventTypeLeftMouseDragged);
  NSSize result;

  if (windowManagerState & WM_STATE_FULLSCREEN)
    {
      NSScreen *screen = window.screen;

      /* On macOS 12, window.screen might become nil when waking up
	 from sleep and window was on a non-primary screen.  */
      if (screen)
	result = screen.frame.size;
      else
	result = proposedFrameSize;
    }
  else
    {
      if (leftMouseDragged || [emacsController isMouseTrackingSuspended])
	result = [self hintedWindowFrameSize:proposedFrameSize
				allowsLarger:YES];
      else
	result = proposedFrameSize;
      if (windowManagerState
	  & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT))
	{
	  NSRect screenVisibleFrame = [[window screen] visibleFrame];

	  if (windowManagerState & WM_STATE_MAXIMIZED_HORZ)
	    result.width = NSWidth (screenVisibleFrame);
	  if (windowManagerState & WM_STATE_MAXIMIZED_VERT)
	    result.height = NSHeight (screenVisibleFrame);
	}
    }

  if (leftMouseDragged
      /* On macOS 27, keep a drag in one live-resize session instead of
	 repeatedly ending and restarting tracking with synthetic events.
	 Use the resize transition below, as for an Option-drag.  */
      && mac_operating_system_version.major < 27
      /* The persistent loop lets Lisp draw during one live-resize
	 session on every OS.  */
      && !mac_persistent_loop_p
      /* Updating screen during resize by mouse dragging is
	 implemented by generating fake release and press events.
	 This seems to be too intrusive for "window snapping"
	 introduced in macOS 10.12, so we suppress it when pixelwise
	 frame resizing is in effect.  */
      && (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_11
	  || (FRAME_SIZE_HINTS (emacsFrame)->width_inc != 1
	      && FRAME_SIZE_HINTS (emacsFrame)->height_inc != 1))
      && (!([currentEvent modifierFlags]
	    & (NSEventModifierFlagShift | NSEventModifierFlagOption))))
    {
      NSRect frameRect = [window frame];
      NSPoint adjustment = NSMakePoint (result.width - NSWidth (frameRect),
					result.height - NSHeight (frameRect));

      [window suspendResizeTracking:currentEvent positionAdjustment:adjustment];
    }
  else if ([window inLiveResize]
	   && [currentEvent type] != NSEventTypeLeftMouseUp)
    [self setupLiveResizeTransition];

  return result;
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)sender
			defaultFrame:(NSRect)defaultFrame
{
  struct frame *f = emacsFrame;
  NSRect windowFrame, emacsViewBounds;
  NSSize emacsViewSizeInPixels, emacsViewSize;
  CGFloat dw, dh, dx, dy;
  int columns, rows;

  windowFrame = [sender frame];
  emacsViewBounds = [emacsView bounds];
  emacsViewSizeInPixels = [emacsView convertSize:emacsViewBounds.size
					  toView:nil];
  dw = NSWidth (windowFrame) - emacsViewSizeInPixels.width;
  dh = NSHeight (windowFrame) - emacsViewSizeInPixels.height;
  emacsViewSize =
    [emacsView convertSize:(NSMakeSize (NSWidth (defaultFrame) - dw,
					NSHeight (defaultFrame) - dh))
	       fromView:nil];

  columns = FRAME_PIXEL_WIDTH_TO_TEXT_COLS (f, emacsViewSize.width);
  rows = FRAME_PIXEL_HEIGHT_TO_TEXT_LINES (f, emacsViewSize.height);
  if (columns > DEFAULT_NUM_COLS)
    columns = DEFAULT_NUM_COLS;
  emacsViewSize.width = FRAME_TEXT_COLS_TO_PIXEL_WIDTH (f, columns);
  emacsViewSize.height = FRAME_TEXT_LINES_TO_PIXEL_HEIGHT (f, rows);
  emacsViewSizeInPixels = [emacsView convertSize:emacsViewSize toView:nil];
  windowFrame.size.width = emacsViewSizeInPixels.width + dw;
  windowFrame.size.height = emacsViewSizeInPixels.height + dh;

  dx = NSMaxX (defaultFrame) - NSMaxX (windowFrame);
  if (dx < 0)
    windowFrame.origin.x += dx;
  dx = NSMinX (defaultFrame) - NSMinX (windowFrame);
  if (dx > 0)
    windowFrame.origin.x += dx;
  dy = NSMaxY (defaultFrame) - NSMaxY (windowFrame);
  if (dy > 0)
    windowFrame.origin.y += dy;

  return windowFrame;
}

/* On macOS 10.12 and earlier, cacheDisplayInRect:toBitmapImageRep: is
   buggy for flipped views unless the given rect is of full height.
   Use only for full height rectangles on such versions.  */

- (NSBitmapImageRep *)bitmapImageRepInEmacsViewRect:(NSRect)rect
{
  struct frame *f = emacsFrame;
  NSBitmapImageRep *bitmap =
    [emacsView bitmapImageRepForCachingDisplayInRect:rect];
  bool saved_synthetic_bold_workaround_disabled_p =
    FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f);
  bool saved_background_alpha_enabled_p = FRAME_BACKGROUND_ALPHA_ENABLED_P (f);

  eassert (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_12)
	   || (NSMinY (rect) == NSMinY ([emacsView bounds])
	       && NSHeight (rect) == NSHeight ([emacsView bounds])));

  FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f) = true;
  FRAME_BACKGROUND_ALPHA_ENABLED_P (f) = false;
  if ([overlayView.superview isEqual:emacsView])
    [overlayView setHidden:YES];
  [EmacsView globallyDisableUpdateLayer:YES];
  [emacsView cacheDisplayInRect:rect toBitmapImageRep:bitmap];
  [EmacsView globallyDisableUpdateLayer:NO];
  if (overlayView.isHidden)
    [overlayView setHidden:NO];
  FRAME_BACKGROUND_ALPHA_ENABLED_P (f) = saved_background_alpha_enabled_p;
  FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f) =
    saved_synthetic_bold_workaround_disabled_p;

  return bitmap;
}

- (NSBitmapImageRep *)bitmapImageRep
{
  return [self bitmapImageRepInEmacsViewRect:[emacsView bounds]];
}

- (void)storeModifyFrameParametersEvent:(Lisp_Object)alist
{
  struct frame *f = emacsFrame;
  struct input_event inev;
  Lisp_Object tag_Lisp = build_string ("Lisp");
  Lisp_Object arg;

  EVENT_INIT (inev);
  inev.kind = MAC_APPLE_EVENT;
  inev.x = Qframe;
  inev.y = intern ("modify-frame-parameters");
  XSETFRAME (inev.frame_or_window, f);
  arg = list2 (Fcons (Qframe, Fcons (tag_Lisp, inev.frame_or_window)),
	       Fcons (intern ("alist"), Fcons (tag_Lisp, alist)));
  inev.arg = Fcons (build_string ("aevt"), arg);
  [emacsController storeEvent:&inev];
}

- (CALayer *)liveResizeTransitionLayerWithDefaultBackground:(BOOL)flag
{
  struct frame *f = emacsFrame;
  CALayer *rootLayer, *contentLayer;
  CGSize contentLayerSize;
  NSView *contentView = [emacsWindow contentView];
  /* Use `bounds' rather than `visibleRect' because the latter
     contains the area below the title bar on macOS 14 where NSView's
     `clipsToBounds' property is defaulted to NO.  */
  NSRect contentViewRect = contentView.bounds;
  NSBitmapImageRep *bitmap = [self bitmapImageRep];
  id image = (id) [bitmap CGImage];
  CGFloat internalBorderWidth = FRAME_INTERNAL_BORDER_WIDTH (f);

  rootLayer = [CALayer layer];
  contentViewRect.origin = NSZeroPoint;
  rootLayer.bounds = NSRectToCGRect (contentViewRect);
  rootLayer.anchorPoint = CGPointZero;
  rootLayer.contentsScale = [emacsWindow backingScaleFactor];
  rootLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  rootLayer.geometryFlipped = YES;

  if (FRAME_INTERNAL_BORDER_WIDTH (f) == 0)
    contentLayer = rootLayer;
  else
    {
      int face_id = (!NILP (Vface_remapping_alist)
		     ? lookup_basic_face (NULL, f, INTERNAL_BORDER_FACE_ID)
		     : INTERNAL_BORDER_FACE_ID);
      GC gc = mac_gc_for_face_id (f, face_id, f->output_data.mac->normal_gc);
      CGColorRef borderColor = CGColorCreateCopyWithAlpha (gc->cg_back_color,
							   1.0f);
      CALayer *borderLayer = [CALayer layer];
      NSRect frameRect = contentViewRect;
      frameRect.origin.y -= internalBorderWidth;
      frameRect.size.height += internalBorderWidth;
      borderLayer.frame = NSRectToCGRect (frameRect);
      borderLayer.autoresizingMask = (kCALayerWidthSizable
				       | kCALayerHeightSizable);
      borderLayer.borderColor = borderColor;
      CGColorRelease (borderColor);
      borderLayer.borderWidth = internalBorderWidth;

      contentLayer = [CALayer layer];
      frameRect = NSInsetRect (contentViewRect, internalBorderWidth, 0);
      frameRect.size.height -= internalBorderWidth;
      contentLayer.frame = NSRectToCGRect (frameRect);
      contentLayer.autoresizingMask = (kCALayerWidthSizable
				       | kCALayerHeightSizable);
      contentLayer.masksToBounds = YES;
      [rootLayer addSublayer:contentLayer];
      [rootLayer addSublayer:borderLayer];
    }
  contentLayer.layoutManager = [CAConstraintLayoutManager layoutManager];
  if (flag)
    contentLayer.backgroundColor = f->output_data.mac->normal_gc->cg_back_color;
  contentLayerSize = contentLayer.bounds.size;

  struct window *root_window = XWINDOW (FRAME_ROOT_WINDOW (f));
  CGFloat rootWindowMinY = WINDOW_TOP_EDGE_Y (root_window);
  CGFloat rootWindowMaxY = WINDOW_BOTTOM_EDGE_Y (root_window);

  mac_foreach_window (f, ^(struct window *w) {
      enum {MIN_X_SCALE = 1 << 0, MAX_X_SCALE = 1 << 1,
	    MIN_Y_SCALE = 1 << 2, MAX_Y_SCALE = 1 << 3,
	    MIN_Y_OFFSET = 1 << 4, MAX_Y_OFFSET = 1 << 5,
	    MIN_X_NEXT_MIN = 1 << 6};
      NSString *nextLayerName = nil;
      NSRect rects[4];
      int constraints[4];
      int i, nrects = 1;

      rects[0] = NSMakeRect (WINDOW_LEFT_EDGE_X (w), WINDOW_TOP_EDGE_Y (w),
			     WINDOW_PIXEL_WIDTH (w), WINDOW_PIXEL_HEIGHT (w));
      if (NSMinY (rects[0]) <= rootWindowMinY)
	/* Tool/tab bar or topmost window.  */
	constraints[0] = MIN_X_SCALE | MIN_Y_OFFSET;
      else if (NSMinY (rects[0]) >= rootWindowMaxY)
	/* Bottommost (minibuffer) window.  */
	constraints[0] = MIN_X_SCALE | MAX_Y_OFFSET;
      else
	constraints[0] = MIN_X_SCALE | MIN_Y_SCALE;
      if (!w->pseudo_window_p)
	{
	  int x, y, width, height;
	  int bottom_idx = 0, right_idx = 0;
	  int bottom_fill_idx;
	  CGFloat right_width, bottom_height;

	  window_box (w, TEXT_AREA, &x, &y, &width, &height);
	  right_width = NSMaxX (rects[0]) - (x + width);
	  bottom_height = NSMaxY (rects[0]) - (y + height);
	  /* Make right_idx come earlier than bottom_idx for priority,
	     though we divide the right part later than the bottom
	     part.  */
	  if (right_width > 0)
	    right_idx = nrects++;
	  if (bottom_height > 0)
	    {
	      bottom_fill_idx = nrects++;
	      bottom_idx = nrects++;
	    }

	  if (bottom_idx)
	    {
	      NSDivideRect (rects[0], &rects[bottom_idx], &rects[0],
			    bottom_height, NSMaxYEdge);
	      NSDivideRect (rects[bottom_idx], &rects[bottom_fill_idx],
			    &rects[bottom_idx], 1, NSMaxXEdge);
	      if (NSMaxY (rects[bottom_idx]) == rootWindowMaxY)
		/* Bottommost mode-line.  */
		constraints[bottom_idx] = MIN_X_SCALE | MAX_Y_OFFSET;
	      else
		constraints[bottom_idx] = MIN_X_SCALE | MAX_Y_SCALE;
	      constraints[bottom_fill_idx] =
		(constraints[bottom_idx] ^ (MIN_X_SCALE
					    | MAX_X_SCALE | MIN_X_NEXT_MIN));
	    }
	  if (right_idx)
	    {
	      NSDivideRect (rects[0], &rects[right_idx], &rects[0],
			    right_width, NSMaxXEdge);
	      constraints[right_idx] =
		(MAX_X_SCALE | (constraints[0]
				& (MIN_Y_SCALE | MAX_Y_SCALE
				   | MIN_Y_OFFSET | MAX_Y_OFFSET)));
	    }
	}
      else if (!NSIsEmptyRect (rects[0])) /* Tool/tab bar.  */
	{
	  int bar_fill_idx = 0, bar_idx = nrects++;

	  rects[bar_idx] = rects[0];
	  constraints[bar_idx] = constraints[0];
	  NSDivideRect (rects[bar_idx], &rects[bar_fill_idx],
			&rects[bar_idx], 1, NSMaxXEdge);
	  constraints[bar_fill_idx] =
	    (constraints[bar_idx] ^ (MIN_X_SCALE
				     | MAX_X_SCALE | MIN_X_NEXT_MIN));
	}
      for (i = 0; i < nrects; i++)
	{
	  CALayer *layer = [CALayer layer];
	  NSMutableDictionaryOf (NSString *, id <CAAction>) *actions;
	  CAConstraintAttribute attribute;
	  CGFloat scale;

	  if (nextLayerName)
	    {
	      layer.name = nextLayerName;
	      nextLayerName = nil;
	    }
	  layer.frame = NSRectToCGRect (rects[i]);
	  layer.contents = image;
	  layer.contentsRect =
	    CGRectMake (NSMinX (rects[i]) / NSWidth (contentViewRect),
			NSMinY (rects[i]) / NSHeight (contentViewRect),
			NSWidth (rects[i]) / NSWidth (contentViewRect),
			NSHeight (rects[i]) / NSHeight (contentViewRect));

	  /* Suppress animations triggered by a size change in the
	     superlayer.  Actually not needed on OS X 10.9.  */
	  actions = [NSMutableDictionary
		      dictionaryWithDictionary:layer.actions];
	  actions[@"position"] = NSNull.null;
	  actions[@"bounds"] = NSNull.null;
	  layer.actions = actions;

	  if (constraints[i] & (MIN_X_SCALE | MAX_X_SCALE))
	    {
	      if (constraints[i] & MIN_X_SCALE)
		{
		  attribute = kCAConstraintMinX;
		  scale = ((NSMinX (rects[i]) - internalBorderWidth)
			   / contentLayerSize.width);
		}
	      else
		{
		  attribute = kCAConstraintMaxX;
		  scale = ((NSMaxX (rects[i]) - internalBorderWidth)
			   / contentLayerSize.width);
		}
	      [layer addConstraint:[CAConstraint
				     constraintWithAttribute:attribute
						  relativeTo:@"superlayer"
						   attribute:kCAConstraintWidth
						       scale:scale
						      offset:0]];
	    }
	  if (constraints[i] & MIN_X_NEXT_MIN)
	    {
	      CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];

	      [filter setDefaults];
	      layer.filters = @[filter];
	      layer.masksToBounds = YES;
	      attribute = kCAConstraintMinX;
	      nextLayerName = [NSString stringWithFormat:@"layer-%p-%d",
					w, i + 1];
	      [layer addConstraint:[CAConstraint
				     constraintWithAttribute:attribute
						  relativeTo:nextLayerName
						   attribute:attribute]];

	    }
	  if (constraints[i] & (MIN_Y_SCALE | MAX_Y_SCALE
				| MIN_Y_OFFSET | MAX_Y_OFFSET))
	    {
	      CAConstraintAttribute srcAttr;
	      CGFloat offset;

	      if (constraints[i] & MIN_Y_OFFSET)
		{
		  srcAttr = attribute = kCAConstraintMinY;
		  offset = NSMinY (rects[i]);
		  scale = 1;
		}
	      else if (constraints[i] & MAX_Y_OFFSET)
		{
		  srcAttr = attribute = kCAConstraintMaxY;
		  offset = NSMaxY (rects[i]) - contentLayerSize.height;
		  scale = 1;
		}
	      else
		{
		  srcAttr = kCAConstraintHeight;
		  offset = 0;
		  if (constraints[i] & MIN_Y_SCALE)
		    {
		      attribute = kCAConstraintMinY;
		      scale = NSMinY (rects[i]) / contentLayerSize.height;
		    }
		  else
		    {
		      attribute = kCAConstraintMaxY;
		      scale = NSMaxY (rects[i]) / contentLayerSize.height;
		    }
		}
	      [layer addConstraint:[CAConstraint
				     constraintWithAttribute:attribute
						  relativeTo:@"superlayer"
						   attribute:srcAttr
						       scale:scale
						      offset:offset]];
	    }
	  [contentLayer addSublayer:layer];
	}

      return (bool) true;
    });

  return rootLayer;
}

- (void)setShouldLiveResizeTriggerTransition:(BOOL)flag
{
  shouldLiveResizeTriggerTransition = flag;
}

- (void)setLiveResizeCompletionHandler:(void (^)(void))block
{
  MRC_RELEASE (liveResizeCompletionHandler);
  liveResizeCompletionHandler = [block copy];
}

- (void)setupLiveResizeTransition
{
  /* W2/W3: the persistent loop lets Lisp redraw live while it is
     idle, and otherwise keeps the last presentation anchored top-left
     over the published background colour.  The snapshot layer would
     hide the live redraw, and building it reads the window tree and
     faces, which the GUI thread may not do while Lisp is busy.  */
  if (mac_persistent_loop_p)
    return;

  if (liveResizeCompletionHandler == nil
      /* Resizing in Split View on macOS 10.15 no longer
	 scale-and-blurs non-main window.  */
      && (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_14)
	  || emacsWindow.isMainWindow))
    {
      EmacsFrameController * __unsafe_unretained weakSelf = self;
      CALayer *layer =
	[self liveResizeTransitionLayerWithDefaultBackground:YES];

      [CATransaction setDisableActions:YES];
      [[overlayView layer] addSublayer:layer];
      [CATransaction commit];
      [self setVibrantScrollersHidden:YES];
      [self setLiveResizeCompletionHandler:^{
	  [NSAnimationContext
	    runAnimationGroup:^(NSAnimationContext *context) {
	      [context setDuration:(10 / 60.0)];
	      layer.beginTime = [layer convertTime:(CACurrentMediaTime ())
					 fromLayer:nil] + 10 / 60.0;
	      layer.fillMode = kCAFillModeBackwards;
	      layer.opacity = 0;
	    } completionHandler:^{
	      [layer removeFromSuperlayer];
	      [weakSelf setVibrantScrollersHidden:NO];
	    }];
	}];
    }
}

- (void)windowWillStartLiveResize:(NSNotification *)notification
{
  if (shouldLiveResizeTriggerTransition)
    [self setupLiveResizeTransition];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
  if (liveResizeCompletionHandler)
    {
      liveResizeCompletionHandler ();
      [self setLiveResizeCompletionHandler:nil];
    }
}

- (NSSize)window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize
{
  return proposedSize;
}

- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions
{
  return proposedOptions | NSApplicationPresentationAutoHideToolbar;
}

- (void)storeFullScreenFrameParameter
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self storeFullScreenFrameParameter]);

  Lisp_Object value;

  switch (fullscreenFrameParameterAfterTransition)
    {
    case FULLSCREEN_PARAM_NIL:
      value = Qnil;
      break;
    case FULLSCREEN_PARAM_FULLBOTH:
      value = Qfullboth;
      break;
    case FULLSCREEN_PARAM_FULLSCREEN:
      value = Qfullscreen;
      break;
    default:
      return;
    }

  if (mac_persistent_loop_p)
    /* The event may be handled after later transitions; tag it so
       that only the latest one takes effect.  */
    [self storeModifyFrameParametersEvent:
	    (list2 (Fcons (Qfullscreen, value),
		    Fcons (intern ("mac-fullscreen-serial"),
			   make_fixnum (++fullscreenParameterSerial))))];
  else
    [self storeModifyFrameParametersEvent:(list1 (Fcons (Qfullscreen,
							 value)))];
  fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_NONE;
}

- (EMACS_INT)fullscreenParameterSerial
{
  return fullscreenParameterSerial;
}

- (void)storeParentFrameFrameParameter
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self storeParentFrameFrameParameter]);

  struct frame *f = emacsFrame;

  if (!NILP (f->parent_frame))
    {
      [self storeModifyFrameParametersEvent:(list1 (Fcons (Qparent_frame,
							   f->parent_frame)))];
      store_frame_param (f, Qparent_frame, Qnil);
      fset_parent_frame (f, Qnil);
    }
}

- (void)addFullScreenTransitionCompletionHandler:(void (^)(EmacsWindow *,
							   BOOL))block
{
  if (fullScreenTransitionCompletionHandlers == nil)
    fullScreenTransitionCompletionHandlers =
      [[NSMutableArray alloc] initWithCapacity:0];
  [fullScreenTransitionCompletionHandlers
    addObject:(MRC_AUTORELEASE ([block copy]))];
}

- (void)handleFullScreenTransitionCompletionForWindow:(EmacsWindow *)window
					      success:(BOOL)flag
{
  for (void (^handler) (EmacsWindow *, BOOL)
	 in fullScreenTransitionCompletionHandlers)
    handler (window, flag);
  MRC_RELEASE (fullScreenTransitionCompletionHandlers);
  fullScreenTransitionCompletionHandlers = nil;
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
  EmacsFrameController * __unsafe_unretained weakSelf = self;
  BOOL savedToolbarVisibility;

  if (!(fullScreenTargetState & WM_STATE_DEDICATED_DESKTOP))
    {
      /* Entering full screen is triggered by external events rather
	 than explicit frame parameter changes from Lisp.  */
      fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_FULLSCREEN;
      fullScreenTargetState = WM_STATE_FULLSCREEN | WM_STATE_DEDICATED_DESKTOP;
    }
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[weakSelf storeFullScreenFrameParameter];
    }];
  /* This part is executed in -[EmacsFrameController
     window:startCustomAnimationToEnterFullScreenWithDuration:] on OS
     X 10.10 and earlier.  Unfortunately this is a bit kludgy.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    [self preprocessWindowManagerStateChange:fullScreenTargetState];

  /* This is a workaround for the problem of not preserving toolbar
     visibility value.  */
  savedToolbarVisibility = [[emacsWindow toolbar] isVisible];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[[NSOperationQueue mainQueue] addOperationWithBlock:^{
	    [[window toolbar] setVisible:savedToolbarVisibility];
	  }];
    }];

  /* Child windows seem to be temporarily removed during full screen
     transition.  */
  for (NSWindow *childWindow in self.emacsWindow.childWindows)
    if ([childWindow isKindOfClass:EmacsWindow.class])
      [(EmacsWindow *)childWindow suspendConstrainingToScreen:YES];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      for (NSWindow *childWindow in window.childWindows)
	if ([childWindow isKindOfClass:EmacsWindow.class])
	  [(EmacsWindow *)childWindow suspendConstrainingToScreen:NO];
    }];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:YES];
  /* For resize in a split-view space on OS X 10.11.  */
  [self setShouldLiveResizeTriggerTransition:YES];
  /* This is necessary for executables compiled on OS X 10.10 or
     earlier and run on OS X 10.11.  Without this, Emacs placed on the
     left side of a split-view space tries to occupy maximum area.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    [emacsWindow suspendConstrainingToScreen:YES];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:NO];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
  EmacsFrameController * __unsafe_unretained weakSelf = self;
  BOOL savedToolbarVisibility;

  if (fullScreenTargetState & WM_STATE_DEDICATED_DESKTOP)
    {
      /* Exiting full screen is triggered by external events rather
	 than explicit frame parameter changes from Lisp.  */
      fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_NIL;
      fullScreenTargetState = 0;
    }
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[weakSelf storeFullScreenFrameParameter];
    }];
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    [self preprocessWindowManagerStateChange:fullScreenTargetState];

  /* This is a workaround for the problem of not preserving toolbar
     visibility value.  */
  savedToolbarVisibility = [[emacsWindow toolbar] isVisible];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[[NSOperationQueue mainQueue] addOperationWithBlock:^{
	    [[window toolbar] setVisible:savedToolbarVisibility];
	  }];
    }];

  [self setShouldLiveResizeTriggerTransition:NO];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (!success)
	[weakSelf setShouldLiveResizeTriggerTransition:YES];
    }];

  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    {
      [emacsWindow suspendConstrainingToScreen:NO];
      [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						       BOOL success) {
	  if (!success)
	    [window suspendConstrainingToScreen:YES];
	}];
    }

  for (NSWindow *childWindow in self.emacsWindow.childWindows)
    if ([childWindow isKindOfClass:EmacsWindow.class])
      [(EmacsWindow *)childWindow suspendConstrainingToScreen:YES];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      for (NSWindow *childWindow in window.childWindows)
	if ([childWindow isKindOfClass:EmacsWindow.class])
	  [(EmacsWindow *)childWindow suspendConstrainingToScreen:NO];
    }];

  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[weakSelf storeParentFrameFrameParameter];
    }];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:YES];
  [emacsController updatePresentationOptions];
}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:NO];
}

- (NSArrayOf (NSWindow *) *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window
{
  /* Custom transition animation is disabled on OS X 10.11 because (1)
     it doesn't look as intended and (2) C-x 5 2 on a full screen
     frame causes crash due to assertion failure in
     -[NSToolbarFullScreenWindowManager getToolbarLayout]:
     getToolbarLayout called with a nil content view.  */
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max)
    return @[window];
  else
    {
      EmacsFrameController * __unsafe_unretained weakSelf = self;
      /* The snapshot layer reads the window tree and faces.  Without
	 Lisp access, use AppKit's default animation instead (W3).  */
      int token = mac_loop_begin_lisp_access ();

      if (token == MAC_LOOP_NO_ACCESS)
	{
	  MAC_TRACE_LOOP ("full screen transition without snapshot\n");
	  return nil;
	}

      CALayer *layer =
	[self liveResizeTransitionLayerWithDefaultBackground:YES];

      mac_loop_end_lisp_access (token);

      [CATransaction setDisableActions:YES];
      [[overlayView layer] addSublayer:layer];
      [CATransaction commit];
      [self setVibrantScrollersHidden:YES];
      [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						       BOOL success) {
	  if (!success)
	    [layer removeFromSuperlayer];
	  else
	    [NSAnimationContext
	      runAnimationGroup:^(NSAnimationContext *context) {
		[context setDuration:(10 / 60.0)];
		layer.opacity = 0;
	      } completionHandler:^{
		[layer removeFromSuperlayer];
		[weakSelf setVibrantScrollersHidden:NO];
	      }];
	}];

      return nil;
    }
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
- (void)window:(NSWindow *)window
  startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration
{
  CGFloat previousAlphaValue = [window alphaValue];
  NSAutoresizingMaskOptions previousAutoresizingMask = [emacsView
							 autoresizingMask];
  NSRect srcRect = [window frame], destRect;
  NSView *contentView = [window contentView];
  CALayer *layer;
  CGFloat titleBarHeight;

  layer = [self liveResizeTransitionLayerWithDefaultBackground:NO];

  titleBarHeight = NSHeight (srcRect) - NSMaxY ([contentView frame]);

  destRect = [self preprocessWindowManagerStateChange:fullScreenTargetState];

  NSDisableScreenUpdates ();

  [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullScreen)];

  destRect = [self postprocessWindowManagerStateChange:destRect];
  /* The line below used to be [window setFrame:destRect display:NO],
     but this does not set content view's frame correctly on OS X
     10.10.  */
  [contentView setFrameSize:destRect.size];

  [emacsView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin)];
  [(EmacsWindow *)window suspendConstrainingToScreen:YES];
  /* We no longer set NSWindowStyleMaskFullScreen until the transition
     animation completes because OS X 10.10 places such a window at
     the center of screen and also makes calls to
     -window:willUseFullScreenContentSize: or
     -windowWillUseStandardFrame:defaultFrame:.  For the same reason,
     we shorten the given animation duration below a bit so as to
     avoid adding NSWindowStyleMaskFullScreen before the completion of
     the transition animation.  */
  [window setStyleMask:([window styleMask] & ~NSWindowStyleMaskFullScreen)];
  [window setFrame:srcRect display:NO];

  [CATransaction setDisableActions:YES];
  [[overlayView layer] addSublayer:layer];
  [CATransaction commit];
  [self setVibrantScrollersHidden:YES];
  [window display];

  [window setAlphaValue:1];

  NSEnableScreenUpdates ();

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      NSRect destRectWithTitleBar =
	NSMakeRect (NSMinX (destRect), NSMinY (destRect),
		    NSWidth (destRect), NSHeight (destRect) + titleBarHeight);

      [context setDuration:(duration * .9)];
      [context
	setTimingFunction:[CAMediaTimingFunction
			    functionWithName:kCAMediaTimingFunctionDefault]];
      [[window animator] setFrame:destRectWithTitleBar display:YES];
      layer.beginTime = [layer convertTime:(CACurrentMediaTime ())
				 fromLayer:nil] + duration * .9 * (1 - 1.0 / 5);
      layer.speed = 5;
      layer.fillMode = kCAFillModeBackwards;
      layer.opacity = 0;
    } completionHandler:^{
      [layer removeFromSuperlayer];
      [self setVibrantScrollersHidden:NO];
      [window setAlphaValue:previousAlphaValue];
      [(EmacsWindow *)window suspendConstrainingToScreen:NO];
      [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullScreen)];
      [window setFrame:destRect display:NO];
      [emacsView setAutoresizingMask:previousAutoresizingMask];
      /* Mac OS X 10.7 needs this.  */
      [emacsView setFrame:[[emacsView superview] bounds]];
      /* OS X 10.9 - 10.10 need this.  */
      [(EmacsMainView *)emacsView synchronizeChildFrameOrigins];
    }];
}
#endif

- (NSArrayOf (NSWindow *) *)customWindowsToExitFullScreenForWindow:(NSWindow *)window
{
  return [self customWindowsToEnterFullScreenForWindow:window];
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
- (void)window:(NSWindow *)window
  startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration
{
  CGFloat previousAlphaValue = [window alphaValue];
  NSWindowLevel previousWindowLevel = [window level];
  NSAutoresizingMaskOptions previousAutoresizingMask = [emacsView
							 autoresizingMask];
  NSRect srcRect = [window frame], destRect;
  NSView *contentView = [window contentView];
  CALayer *layer;
  CGFloat titleBarHeight;

  layer = [self liveResizeTransitionLayerWithDefaultBackground:NO];

  destRect = [self preprocessWindowManagerStateChange:fullScreenTargetState];

  NSDisableScreenUpdates ();

  [window setStyleMask:([window styleMask] & ~NSWindowStyleMaskFullScreen)];

  destRect = [self postprocessWindowManagerStateChange:destRect];
  [window setFrame:destRect display:NO];

  titleBarHeight = NSHeight (destRect) - NSMaxY ([contentView frame]);

  [emacsView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin)];
  srcRect.size.height += titleBarHeight;
  [(EmacsWindow *)window suspendConstrainingToScreen:YES];
  [window setFrame:srcRect display:NO];

  [CATransaction setDisableActions:YES];
  [[overlayView layer] addSublayer:layer];
  [CATransaction commit];
  [self setVibrantScrollersHidden:YES];
  [window display];

  [window setAlphaValue:1];
  [window setLevel:(NSMainMenuWindowLevel + 1)];

  NSEnableScreenUpdates ();

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      [context setDuration:duration];
      [context
	setTimingFunction:[CAMediaTimingFunction
			    functionWithName:kCAMediaTimingFunctionDefault]];
      [[window animator] setFrame:destRect display:YES];
      layer.beginTime = [layer convertTime:(CACurrentMediaTime ())
				 fromLayer:nil] + duration * (1 - 1.0 / 5);
      layer.speed = 5;
      layer.fillMode = kCAFillModeBackwards;
      layer.opacity = 0;
    } completionHandler:^{
      [layer removeFromSuperlayer];
      [self setVibrantScrollersHidden:NO];
      [window setAlphaValue:previousAlphaValue];
      [window setLevel:previousWindowLevel];
      [(EmacsWindow *)window suspendConstrainingToScreen:NO];
      [emacsView setAutoresizingMask:previousAutoresizingMask];
      /* Mac OS X 10.7 needs this.  */
      [emacsView setFrame:[[emacsView superview] bounds]];
      /* OS X 10.9 - 10.10 need this.  */
      [(EmacsMainView *)emacsView synchronizeChildFrameOrigins];
    }];
}
#endif

- (BOOL)isWindowFrontmost
{
  NSArrayOf (NSWindow *) *orderedWindows = [NSApp orderedWindows];

  if (orderedWindows.count > 0)
    {
      NSWindow *frontWindow = orderedWindows[0];

      return ([frontWindow isEqual:hourglassWindow]
	      || [frontWindow isEqual:emacsWindow]);
    }

  return NO;
}

- (BOOL)shouldBeTitled
{
  struct frame *f = emacsFrame;

  if (FRAME_PARENT_FRAME (f))
    return NO;
  else if (windowManagerState & WM_STATE_FULLSCREEN)
    return (windowManagerState & WM_STATE_DEDICATED_DESKTOP);
  else
    return !FRAME_UNDECORATED (f);
}

- (BOOL)shouldHaveShadow
{
  struct frame *f = emacsFrame;

  if (FRAME_PARENT_FRAME (f))
    return NO;
  else if (windowManagerState & WM_STATE_FULLSCREEN)
    return (windowManagerState & WM_STATE_DEDICATED_DESKTOP);
  else
    return YES;
}

- (void)updateWindowStyle
{
  BOOL shouldBeTitled = self.shouldBeTitled;

  if (emacsWindow.hasTitleBar != shouldBeTitled)
    {
      struct frame *f = emacsFrame;
      Lisp_Object tool_bar_lines = get_frame_param (f, Qtool_bar_lines);

      if (FIXNUMP (tool_bar_lines) && XFIXNUM (tool_bar_lines) > 0)
	mac_within_lisp (^{
	    gui_set_frame_parameters (f, list1 (Fcons (Qtool_bar_lines,
						       make_fixnum (0))));
	  });
      FRAME_INTERNAL_TOOL_BAR_P (f) = !shouldBeTitled;
      if (FIXNUMP (tool_bar_lines) && XFIXNUM (tool_bar_lines) > 0)
	mac_within_lisp (^{
	    gui_set_frame_parameters (f, list1 (Fcons (Qtool_bar_lines,
						       tool_bar_lines)));
	  });
      [self setupWindow];
    }

  emacsWindow.hasShadow = self.shouldHaveShadow;
}

- (void)windowWillEnterTabOverview
{
  [emacsWindow enumerateChildWindowsUsingBlock:^(NSWindow *child, BOOL *stop) {
      if (savedChildWindowAlphaMap == nil)
	savedChildWindowAlphaMap =
	  [[NSMapTable alloc]
	    initWithKeyOptions:NSMapTableObjectPointerPersonality
		  valueOptions:NSMapTableStrongMemory capacity:0];
      [savedChildWindowAlphaMap setObject:@(child.alphaValue) forKey:child];
      child.alphaValue = 0;
    }];
}

- (void)windowDidExitTabOverview
{
  [emacsWindow enumerateChildWindowsUsingBlock:^(NSWindow *child, BOOL *stop) {
      NSNumber *number = [savedChildWindowAlphaMap objectForKey:child];

      child.alphaValue = (number ? number.doubleValue : 1.0);
    }];
  MRC_RELEASE (savedChildWindowAlphaMap);
  savedChildWindowAlphaMap = nil;
}

@end				// EmacsFrameController

/* Window Manager function replacements.  */

void
mac_set_frame_window_title (struct frame *f, CFStringRef string)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setTitle:((__bridge NSString *) string)];});
}

void
mac_set_frame_window_modified (struct frame *f, bool modified)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setDocumentEdited:modified];});
}

void
mac_set_frame_window_transparent_titlebar (struct frame *f, bool transparent)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      if ([window respondsToSelector: @selector(titlebarAppearsTransparent)])
	[window setTitlebarAppearsTransparent:transparent ? YES : NO];});
}

void
mac_set_frame_window_proxy (struct frame *f, CFURLRef url)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setRepresentedURL:((__bridge NSURL *) url)];});
}

bool
mac_is_frame_window_visible (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  return [window isVisible] || [window isMiniaturized];
}

bool
mac_is_frame_window_collapsed (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  return [window isMiniaturized];
}

bool
mac_is_frame_window_drawable (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  return ![frameController emacsViewIsHiddenOrHasHiddenAncestor];
}

static void
mac_bring_frame_window_to_front_and_activate (struct frame *f, bool activate_p)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  if ([NSApp isHidden])
    window.needsOrderFrontOnUnhide = YES;
  else
    mac_within_app (^{
	struct frame *p = FRAME_PARENT_FRAME (f);

	if (p)
	  {
	    NSWindow *parentWindow = FRAME_MAC_WINDOW_OBJECT (p);

	    if (!window.isVisible)
	      {
		[parentWindow addChildWindow:window ordered:NSWindowAbove];
		mac_move_frame_window_structure_1 (f, f->left_pos, f->top_pos);
	      }
	    else if (![window isEqual:parentWindow.childWindows.lastObject])
	      {
		[parentWindow removeChildWindow:window];
		[parentWindow addChildWindow:window ordered:NSWindowAbove];
	      }
	    if (activate_p)
	      [window makeKeyWindow];
	  }
	else
	  {
	    NSWindowTabbingMode tabbingMode = NSWindowTabbingModeAutomatic;
	    NSWindow *mainWindow = [NSApp mainWindow];
	    if ([mainWindow respondsToSelector:@selector(tabGroup)]
		&& mainWindow.tabGroup
		&& ![mainWindow.tabGroup.windows containsObject:mainWindow])
	      mainWindow = mainWindow.tabGroup.selectedWindow;

	    if (!FRAME_TOOLTIP_P (f)
		&& [window respondsToSelector:@selector(setTabbingMode:)]
		&& !window.isVisible)
	      {
		if (!mainWindow.hasTitleBar || NILP (Vmac_frame_tabbing))
		  tabbingMode = NSWindowTabbingModeDisallowed;
		else if (EQ (Vmac_frame_tabbing, Qt))
		  tabbingMode = NSWindowTabbingModePreferred;
		else if (EQ (Vmac_frame_tabbing, Qinverted))
		  switch ([NSWindow userTabbingPreference])
		    {
		    case NSWindowUserTabbingPreferenceManual:
		      tabbingMode = NSWindowTabbingModePreferred;
		      break;
		    case NSWindowUserTabbingPreferenceAlways:
		      tabbingMode = NSWindowTabbingModeDisallowed;
		      break;
		    case NSWindowUserTabbingPreferenceInFullScreen:
		      if (mainWindow.styleMask & NSWindowStyleMaskFullScreen)
			tabbingMode = NSWindowTabbingModeDisallowed;
		      else
			tabbingMode = NSWindowTabbingModePreferred;
		      break;
		    }

		window.tabbingMode = tabbingMode;
		if ([mainWindow isKindOfClass:EmacsWindow.class])
		  {
		    mainWindow.tabbingMode = tabbingMode;
		    /* If the Tab Overview UI is visible and the window
		       is to join its tab group, then make the Overview
		       UI invisible and wait until it finishes.  */
		    if (tabbingMode == NSWindowTabbingModePreferred)
		      [(EmacsWindow *)mainWindow exitTabGroupOverview];
		  }
	      }

	    if (activate_p)
	      [window makeKeyAndOrderFront:nil];
	    else
	      [window orderFront:nil];

	    if (tabbingMode != NSWindowTabbingModeAutomatic)
	      {
		window.tabbingMode = NSWindowTabbingModeAutomatic;
		if ([mainWindow isKindOfClass:EmacsWindow.class])
		  mainWindow.tabbingMode = NSWindowTabbingModeAutomatic;
	      }
	  }
      });
}

void
mac_bring_frame_window_to_front (struct frame *f)
{
  mac_bring_frame_window_to_front_and_activate (f, false);
}

void
mac_send_frame_window_behind (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      struct frame *p = FRAME_PARENT_FRAME (f);

      if (p == NULL)
	[window orderWindow:NSWindowBelow relativeTo:0];
      else
	{
	  NSWindow *parentWindow = FRAME_MAC_WINDOW_OBJECT (p);
	  NSArrayOf (__kindof NSWindow *) *childWindows =
	    parentWindow.childWindows;

	  if (![window isEqual:childWindows[0]])
	    for (NSWindow *childWindow in childWindows)
	      if (![childWindow isEqual:window])
		{
		  [parentWindow removeChildWindow:childWindow];
		  [parentWindow addChildWindow:childWindow
				       ordered:NSWindowAbove];
		}
	}
    });
}

void
mac_hide_frame_window (struct frame *f)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      if ([window isMiniaturized])
	[window deminiaturize:nil];

      /* Mac OS X 10.6 needs this.  */
      [window.parentWindow removeChildWindow:window];
      [window orderOut:nil];
      [window setNeedsOrderFrontOnUnhide:NO];
    });
}

void
mac_show_frame_window (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  if (![window isVisible])
    mac_bring_frame_window_to_front_and_activate (f,
						  !FRAME_NO_FOCUS_ON_MAP (f));
}

OSStatus
mac_collapse_frame_window (struct frame *f, bool collapse)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      if (collapse && ![window isMiniaturized])
	[window miniaturize:nil];
      else if (!collapse && [window isMiniaturized])
	[window deminiaturize:nil];
    });

  return noErr;
}

bool
mac_is_frame_window_frontmost (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  return [frameController isWindowFrontmost];
}

void
mac_activate_frame_window (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window makeKeyWindow];});
}

static NSRect
mac_get_base_screen_frame (void)
{
  NSArrayOf (NSScreen *) *screens = NSScreen.screens;

  if (screens.count > 0)
    return [screens[0] frame];
  else
    return NSScreen.mainScreen.frame;
}

static void
mac_move_frame_window_structure_1 (struct frame *f, int x, int y)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  struct frame *p = FRAME_PARENT_FRAME (f);
  NSPoint topLeft;

  if (p == NULL)
    {
      NSRect baseScreenFrame = mac_get_base_screen_frame ();

      topLeft = NSMakePoint (x + NSMinX (baseScreenFrame),
			     -y + NSMaxY (baseScreenFrame));
    }
  else
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (p);

      topLeft = [frameController
		  convertEmacsViewPointToScreen:(NSMakePoint (x, y))];
    }

  [window setFrameTopLeftPoint:topLeft];
}

OSStatus
mac_move_frame_window_structure (struct frame *f, int x, int y)
{
  mac_within_app (^{mac_move_frame_window_structure_1 (f, x, y);});

  return noErr;
}

void
mac_size_frame_window (struct frame *f, int w, int h, bool update)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      NSView *contentView;
      NSRect contentViewBounds, windowFrame;
      NSSize oldSizeInPixels, newSizeInPixels;
      CGFloat dw, dh;

      /* W and H are dimensions in user space coordinates; they are
	 not the same as those in device space coordinates if scaling
	 is in effect.  */
      contentView = [window contentView];
      contentViewBounds = [contentView bounds];
      oldSizeInPixels = [contentView convertSize:contentViewBounds.size
					  toView:nil];
      newSizeInPixels = [contentView convertSize:(NSMakeSize (w, h))
					  toView:nil];
      dw = newSizeInPixels.width - oldSizeInPixels.width;
      dh = newSizeInPixels.height - oldSizeInPixels.height;

      windowFrame = [window frame];
      windowFrame.origin.y -= dh;
      windowFrame.size.width += dw;
      windowFrame.size.height += dh;

      [window setFrame:windowFrame display:update];
    });

  if (window.isVisible)
    extendReadSocketIntervalOnce = YES;
}

OSStatus
mac_set_frame_window_alpha (struct frame *f, CGFloat alpha)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setAlphaValue:alpha];});

  return noErr;
}

OSStatus
mac_get_frame_window_alpha (struct frame *f, CGFloat *out_alpha)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  *out_alpha = [window alphaValue];

  return noErr;
}

Lisp_Object
mac_set_tab_group_overview_visible_p (struct frame *f, Lisp_Object value)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  if (![window respondsToSelector:@selector(tabGroup)])
    {
      if (NILP (value))
	return Qnil;
      else
	return build_string ("Tab group overview is not supported on this macOS version");
    }

  Lisp_Object __block result = Qnil;
  mac_within_app (^{
      if (window.tabGroup.isOverviewVisible != !NILP (value))
	{
	  /* Sending toggleTabOverview to window doesn't work when the
	     window has a transparent title bar.  Suppress the
	     transparency temporarily for the call.  */
	  mac_with_suppressed_transparent_titlebar (window, NO, ^{
	      /* Just setting the property window.tabGroup.overviewVisible
		 does not show the search field on macOS 10.13 Beta.  */
	      [NSApp sendAction:@selector(toggleTabOverview:) to:window from:nil];
	    });
	  result = Qt;
	}
    });

  return result;
}

Lisp_Object
mac_set_tab_group_tab_bar_visible_p (struct frame *f, Lisp_Object value)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  mac_within_app (^{
      NSInteger count = window.tabbedWindows.count;

      if ((count != 0) == !NILP (value))
	result = Qnil;
      else if (count > 1)
	result = build_string ("Tab bar cannot be made invisible because of multiple tabs");
      else
	{
	      [window exitTabGroupOverview];
	      /* Sending toggleTabBar doesn't work when the window has a
		 transparent title bar.  Suppress the transparency
		 temporarily for the call.  */
	      mac_with_suppressed_transparent_titlebar (window, NO, ^{
		  [NSApp sendAction:@selector(toggleTabBar:) to:window from:nil];
		});
	      [[NSUserDefaults standardUserDefaults]
		removeObjectForKey:[@"NSWindowTabbingShoudShowTabBarKey-"
				       stringByAppendingString:window.tabbingIdentifier]];
	      result = Qt;
	}
    });

  return result;
}

Lisp_Object
mac_set_tab_group_selected_frame (struct frame *f, Lisp_Object value)
{
  Lisp_Object selected = mac_get_tab_group_selected_frame (f);
  Lisp_Object frames;
  EmacsWindow *newSelectedWindow;

  if (EQ (selected, value))
    return Qnil;

  frames = mac_get_tab_group_frames (f);
  if (NILP (Fmemq (value, frames)))
    {
      Lisp_Object frame;
      AUTO_STRING (fmt, "Frame %S is not in the tab group for frame %S");

      XSETFRAME (frame, f);

      return CALLN (Fformat, fmt, value, frame);
    }

  newSelectedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (value));
  if ([newSelectedWindow respondsToSelector:@selector(tabGroup)])
    mac_within_app (^{
	[newSelectedWindow exitTabGroupOverview];
	newSelectedWindow.tabGroup.selectedWindow = newSelectedWindow;
      });
  else
    mac_within_app (^{
	NSWindow *selectedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (selected));
	NSInteger __block aboveWindowNumber = 0;

	[newSelectedWindow exitTabGroupOverview];
	[NSApp enumerateWindowsWithOptions:NSWindowListOrderedFrontToBack
				usingBlock:^(NSWindow *window, BOOL *stop) {
	    if ([window isEqual:selectedWindow])
	      *stop = YES;
	    else if ([window isKindOfClass:EmacsWindow.class])
	      aboveWindowNumber = window.windowNumber;
	  }];
	if (aboveWindowNumber)
	  {
	    [newSelectedWindow orderFront:nil];
	    [newSelectedWindow orderWindow:NSWindowBelow
				relativeTo:aboveWindowNumber];
	  }
	else
	  [newSelectedWindow makeKeyAndOrderFront:nil];
      });

  return Qt;
}

Lisp_Object
mac_set_tab_group_frames (struct frame *f, Lisp_Object value)
{
  Lisp_Object frames = mac_get_tab_group_frames (f), rest, selected;
  NSWindowTabbingIdentifier identifier;

  if (!NILP (Fequal (frames, value)))
    return Qnil;

  if (NILP (frames))
    return build_string ("Frames must be non-nil");

  for (rest = value; CONSP (rest); rest = XCDR (rest))
    {
      Lisp_Object frame = XCAR (rest);

      if (!FRAME_MAC_P (XFRAME (frame)) || !FRAME_LIVE_P (XFRAME (frame)))
	{
	  AUTO_STRING (fmt, "Not a live Mac frame: %S");

	  return CALLN (Fformat, fmt, frame);
	}
    }
  if (!NILP (rest))
    {
      AUTO_STRING (fmt, "Frames do not end with nil: %S");

      return CALLN (Fformat, fmt, rest);
    }

  identifier = FRAME_MAC_WINDOW_OBJECT (f).tabbingIdentifier;
  for (rest = value; !NILP (rest); rest = XCDR (rest))
    if (!NILP (Fmemq (XCAR (rest), XCDR (rest))))
      {
	AUTO_STRING (fmt, "Duplicate frames: %S");

	return CALLN (Fformat, fmt, XCAR (rest));
      }
    else
      {
	NSWindow *window = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (rest)));

	if (!window.hasTitleBar)
	  {
	    AUTO_STRING (fmt, "Not a frame with the title bar: %S");

	    return CALLN (Fformat, fmt, XCAR (rest));
	  }
	if (!window.isVisible)
	  {
	    AUTO_STRING (fmt, "Can't rearrange tabs for invisible/iconified frame: %S");

	    return CALLN (Fformat, fmt, XCAR (rest));
	  }
	if (![identifier isEqualToString:window.tabbingIdentifier])
	  {
	    AUTO_STRING (fmt, "Not a frame with the same identifier: %S");

	    return CALLN (Fformat, fmt, XCAR (rest));
	  }
      }

  selected = mac_get_tab_group_selected_frame (f);
  mac_within_app (^{
      Lisp_Object cur_rest, toinclude, last = Qnil, toexclude = Qnil;
      EmacsWindow *window, *addedWindow;

      window = FRAME_MAC_WINDOW_OBJECT (f);
      [window exitTabGroupOverview];
      for (Lisp_Object rest = value; !NILP (rest); rest = XCDR (rest))
	{
	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (rest)));
	  [window exitTabGroupOverview];
	}

      toinclude = value;
      for (cur_rest = frames; !NILP (cur_rest); cur_rest = XCDR (cur_rest))
	{
	  Lisp_Object frame = XCAR (cur_rest), rest;

	  for (rest = value; !NILP (rest); rest = XCDR (rest))
	    {
	      if (EQ (rest, toinclude))
		last = frame;
	      if (EQ (XCAR (rest), frame))
		break;
	    }

	  if (NILP (rest))
	    {
	      /* `frame' was not found in `value'; to be excluded.  */
	      toexclude = Fcons (frame, toexclude);
	      continue;
	    }
	  else if (!EQ (last, frame))
	    /* `frame' was found between `value' (inclusive) to
	       `toinclude' (not inclusive); already included.  */
	    continue;

	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (frame));
	  while (!EQ (XCAR (toinclude), frame))
	    {
	      addedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (toinclude)));
	      [window addTabbedWindow:addedWindow ordered:NSWindowBelow];
	      toinclude = XCDR (toinclude);
	    }
	  toinclude = XCDR (toinclude);
	}
      if (!NILP (toinclude))
	{
	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (last));
	  do
	    {
	      addedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (toinclude)));
	      [window addTabbedWindow:addedWindow ordered:NSWindowAbove];
	      window = addedWindow;
	      last = XCAR (toinclude);

	      toinclude = XCDR (toinclude);
	    }
	  while (!NILP (toinclude));
	}

      if (!NILP (toexclude))
	{
	  Lisp_Object last_cell = toexclude;

	  /* `toexclude' is in reverse order.  First we create a new
	     frame for the last element.  */
	  while (!NILP (XCDR (last_cell)))
	    last_cell = XCDR (last_cell);
	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (last_cell)));
	  [NSApp sendAction:@selector(moveTabToNewWindow:) to:window from:nil];
	  for (; !EQ (toexclude, last_cell); toexclude = XCDR (toexclude))
	    {
	      addedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (toexclude)));
	      [window addTabbedWindow:addedWindow ordered:NSWindowAbove];
	    }
	}
    });
  mac_set_tab_group_selected_frame (XFRAME (selected), selected);

  return Qt;
}

Lisp_Object
mac_get_tab_group_overview_visible_p (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{if (window.tabGroup.isOverviewVisible) result = Qt;});

  return result;
}

Lisp_Object
mac_get_tab_group_tab_bar_visible_p (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{if (window.tabGroup.isTabBarVisible) result = Qt;});
  else if ([window respondsToSelector:@selector(tabbedWindows)])
    mac_within_gui (^{if (window.tabbedWindows != nil) result = Qt;});

  return result;
}

Lisp_Object
mac_get_tab_group_selected_frame (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{result = window.tabGroup.selectedWindow.lispFrame;});
  else if (!window.hasTitleBar)
    ;
#if 1
  else if ([window respondsToSelector:@selector(_windowStackController)])
    mac_within_gui (^{
	NSWindowStackController *stackController =
	  window._windowStackController;

	if (stackController == nil)
	  XSETFRAME (result, f);
	else
	  result = stackController.selectedWindow.lispFrame;
      });
#else  /* This only works for visible frames.  */
  else if ([window respondsToSelector:@selector(tabbedWindows)])
    mac_within_gui (^{
	NSArrayOf (NSWindow *) *tabbedWindows = window.tabbedWindows;

	if (tabbedWindows == nil)
	  XSETFRAME (result, f);
	else
	  {
	    NSWindow * __block selectedWindow = nil;

	    [NSApp enumerateWindowsWithOptions:NSWindowListOrderedFrontToBack
				    usingBlock:^(NSWindow *window, BOOL *stop) {
		if ([tabbedWindows containsObject:window])
		  {
		    selectedWindow = window;
		    *stop = YES;
		  }
	      }];

	    if (selectedWindow)
	      result = selectedWindow.lispFrame;
	  }
      });
#endif

  return result;
}

Lisp_Object
mac_get_tab_group_frames (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{
	for (NSWindow *tabbedWindow in window.tabGroup.windows)
	  {
	    Lisp_Object frame = tabbedWindow.lispFrame;

	    if (!NILP (frame))
	      result = Fcons (frame, result);
	  }
	result = Fnreverse (result);
      });
  else if (!window.hasTitleBar)
    ;
  else if ([window respondsToSelector:@selector(tabbedWindows)])
    mac_within_gui (^{
	NSArrayOf (NSWindow *) *tabbedWindows = window.tabbedWindows;
	Lisp_Object frame;

	if (tabbedWindows == nil)
	  {
	    XSETFRAME (frame, f);
	    result = Fcons (frame, result);
	  }
	else
	  {
	    for (NSWindow *tabbedWindow in tabbedWindows)
	      {
		frame = tabbedWindow.lispFrame;
		if (!NILP (frame))
		  result = Fcons (frame, result);
	      }
	    result = Fnreverse (result);
	  }
      });

  return result;
}

void
mac_set_frame_window_structure_bounds (struct frame *f, NativeRectangle bounds)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      struct frame *p = FRAME_PARENT_FRAME (f);
      NSRect rect = NSMakeRect (bounds.x, bounds.y,
				bounds.width, bounds.height);

      if (p == NULL)
	{
	  NSRect baseScreenFrame = mac_get_base_screen_frame ();

	  rect.origin =
	    NSMakePoint (NSMinX (rect) + NSMinX (baseScreenFrame),
			 - NSMaxY (rect) + NSMaxY (baseScreenFrame));
	}
      else
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (p);

	  rect = [frameController convertEmacsViewRectToScreen:rect];
	}

      [window setFrame:rect display:NO];
    });
}

static void
mac_get_frame_window_structure_bounds_1 (struct frame *f,
					 NativeRectangle *bounds)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  NSRect rect = [window frame];
  struct frame *p = FRAME_PARENT_FRAME (f);

  if (p == NULL)
    {
      NSRect baseScreenFrame = mac_get_base_screen_frame ();

      rect.origin = NSMakePoint (NSMinX (rect) - NSMinX (baseScreenFrame),
				 - NSMaxY (rect) + NSMaxY (baseScreenFrame));
    }
  else
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (p);

      rect = NSIntegralRect ([frameController
			       convertEmacsViewRectFromScreen:rect]);
    }

  STORE_NATIVE_RECT (*bounds, NSMinX (rect), NSMinY (rect),
		     NSWidth (rect), NSHeight (rect));
}

void
mac_get_frame_window_structure_bounds (struct frame *f, NativeRectangle *bounds)
{
  mac_within_gui (^{mac_get_frame_window_structure_bounds_1 (f, bounds);});
}

CGFloat
mac_get_frame_window_title_bar_height (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  CGFloat __block result;

  mac_within_gui (^{
      NSRect windowFrame = [window frame];
      NSRect rect = [NSWindow contentRectForFrameRect:windowFrame
					    styleMask:[window styleMask]];

      rect.origin = NSZeroPoint;
      rect = [[window contentView] convertRect:rect toView:nil];
      result = NSHeight (windowFrame) - NSHeight (rect);
    });

  return result;
}

CGSize
mac_get_frame_window_menu_bar_size (struct frame *f)
{
  NSSize menuBarSize = NSZeroSize;

  if (NSMenu.menuBarVisible)
    {
      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
      NSScreen *screen = window.screen;

      if (!screen.canShowMenuBar)
	screen = NSScreen.screens[0];
      if (screen)
	menuBarSize.width = NSWidth (screen.frame);
      menuBarSize.height = [NSApp mainMenu].menuBarHeight;
    }

  return NSSizeToCGSize (menuBarSize);
}

CGRect
mac_get_frame_window_tool_bar_rect (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  CGRect __block result;

  mac_within_gui (^{
      NSView *contentView = [window contentView];
      NSRect rect;
      CGFloat toolBarHeight;

      if (FRAME_INTERNAL_TOOL_BAR_P (f))
	{
	  if (FRAME_TOOL_BAR_HEIGHT (f))
	    {
	      rect = [contentView frame];
	      toolBarHeight = FRAME_TOOL_BAR_HEIGHT (f);
	      rect.origin.y += NSHeight (rect) - toolBarHeight;
	      if (NILP (Vtab_bar_position))
		rect.origin.y -= FRAME_TAB_BAR_HEIGHT (f);
	      rect.size.height = toolBarHeight;
	    }
	  else
	    rect = NSZeroRect;
	}
      else
	{
	  NSToolbar *toolbar = [window toolbar];

	  if (toolbar && [toolbar isVisible])
	    {
	      rect = [contentView frame];
	      toolBarHeight =
		(NSHeight ([NSWindow contentRectForFrameRect:[window frame]
						   styleMask:[window styleMask]])
		 - NSHeight (rect));
	      rect.origin.y += NSHeight (rect);
	      rect.size.height = toolBarHeight;
	    }
	  else
	    rect = NSZeroRect;
	}
      result = NSRectToCGRect ([contentView convertRect:rect toView:nil]);
    });

  return result;
}

CGRect
mac_get_frame_window_content_rect (struct frame *f, bool inner_p)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  NSRect __block rect;

  mac_within_gui (^{
      NSView *contentView = [window contentView];

      rect = [contentView bounds];
      if (inner_p)
	{
	  rect = NSInsetRect (rect, FRAME_INTERNAL_BORDER_WIDTH (f),
			      FRAME_INTERNAL_BORDER_WIDTH (f));
	  if (FRAME_INTERNAL_TOOL_BAR_P (f))
	    rect.size.height -= FRAME_TOOL_BAR_HEIGHT (f);
	  rect.size.height -= FRAME_TAB_BAR_HEIGHT (f);
	}
      rect = [contentView convertRect:rect toView:nil];
    });

  return NSRectToCGRect (rect);
}

CGPoint
mac_get_frame_mouse (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSPoint __block mouseLocation = [NSEvent mouseLocation];

  mac_within_gui (^{
      mouseLocation = [frameController
			convertEmacsViewPointFromScreen:mouseLocation];
    });

  return NSPointToCGPoint (mouseLocation);
}

struct frame *
mac_get_frame_at_mouse (bool ignore_tooltip_p)
{
  NSPoint mouseLocation = NSEvent.mouseLocation;
  NSInteger windowNumber = 0;

  while (true)
    {
      windowNumber = [NSWindow windowNumberAtPoint:mouseLocation
		       belowWindowWithWindowNumber:windowNumber];

      NSWindow *window = [NSApp windowWithWindowNumber:windowNumber];

      if (![window isKindOfClass:EmacsWindow.class])
	return NULL;

      EmacsFrameController *frameController = ((EmacsFrameController *)
					       window.delegate);
      struct frame *f = frameController.emacsFrame;

      if (!(ignore_tooltip_p && FRAME_TOOLTIP_P (f)))
	return f;
    }
}

CGPoint
mac_get_global_mouse (void)
{
  NSPoint mouseLocation = [NSEvent mouseLocation];
  NSRect baseScreenFrame = mac_get_base_screen_frame ();

  return CGPointMake (mouseLocation.x - NSMinX (baseScreenFrame),
		      - mouseLocation.y + NSMaxY (baseScreenFrame));
}

void
mac_convert_frame_point_to_global (struct frame *f, int *x, int *y)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSPoint __block point = NSMakePoint (*x, *y);
  NSRect baseScreenFrame = mac_get_base_screen_frame ();

  mac_within_gui (^{
      point = [frameController convertEmacsViewPointToScreen:point];
    });

  *x = point.x - NSMinX (baseScreenFrame);
  *y = - point.y + NSMaxY (baseScreenFrame);
}

void
mac_set_frame_window_background (struct frame *f, unsigned long color)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  EmacsWindow *window = [frameController emacsWindow];

  mac_within_gui (^{
      NSColor *backgroundColor = [NSColor colorWithEmacsColorPixel:color];

      [window setBackgroundColor:backgroundColor];
#ifdef USE_METAL_RENDERING
      if (mac_persistent_loop_p)
	[frameController setEmacsViewLayerBackgroundColor:backgroundColor];
#endif
      /* This formula comes from frame-set-background-mode in
	 frame.el.  */
      NSAppearanceName name =
	((RED_FROM_ULONG (color) + GREEN_FROM_ULONG (color)
	  + BLUE_FROM_ULONG (color)) >= (int) (0xff * 3 * .6)
	 ? NSAppearanceNameVibrantLight : NSAppearanceNameVibrantDark);

      window.appearanceCustomization.appearance =
	[NSAppearance appearanceNamed:name];
      window.appearance =
	[NSAppearance appearanceNamed:name];
    });
}

/* Store the screen positions of frame F into XPTR and YPTR.
   These are the positions of the containing window manager window,
   not Emacs's own window.  */

void
mac_real_positions (struct frame *f, int *xptr, int *yptr)
{
  eassert (pthread_main_np ());
  NativeRectangle bounds;

  mac_get_frame_window_structure_bounds_1 (f, &bounds);

  *xptr = bounds.x;
  *yptr = bounds.y;
}

/* Flush display of frame F.  */

void
mac_force_flush (struct frame *f)
{
  eassert (f && FRAME_MAC_P (f));
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      EmacsWindow *window;

      block_input ();
      window = FRAME_MAC_WINDOW_OBJECT (f);
      if (window.isVisible)
	mac_within_gui (^{[window flushWindow];});
      unblock_input ();

      return;
    }
#endif
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  block_input ();
  mac_within_gui (^{[frameController displayEmacsViewIfNeeded];});
  unblock_input ();
}

static void
mac_flush_1 (struct frame *f)
{
  if (f == NULL)
    {
      Lisp_Object rest, frame;
      FOR_EACH_FRAME (rest, frame)
	if (FRAME_MAC_P (XFRAME (frame)))
	  mac_flush_1 (XFRAME (frame));
    }
  else
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
      if (!FRAME_MAC_DOUBLE_BUFFERED_P (f))
	{
	  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

	  if (window.isVisible)
	    [window flushWindow];

	  return;
	}
#endif
#if 0 /* XXX: is this "flush" necessary for layer-backed views?  */
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      [frameController displayEmacsViewIfNeeded];
#endif
    }
}

void
mac_flush (struct frame *f)
{
  block_input ();
#ifdef USE_METAL_RENDERING
  /* Drawing that happened outside update_begin/update_end sits in an
     implicit frame; a flush is a request to make it visible.  */
  if (f && FRAME_MAC_P (f))
    emacs_metal_end_implicit_frame (FRAME_METAL_CTX (f));
#endif
  mac_within_gui (^{mac_flush_1 (NULL);});
  unblock_input ();
}

void
mac_update_frame_begin (struct frame *f)
{
#ifndef USE_METAL_RENDERING
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      [frameController lockFocusOnEmacsView];
      set_global_focus_view_frame (f);
    });
#endif
}

void
mac_update_frame_end (struct frame *f)
{
#ifndef USE_METAL_RENDERING
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      unset_global_focus_view_frame ();
      [frameController unlockFocusOnEmacsView];
    });
#endif
}

/* Create a new Mac window for the frame F and store its delegate in
   FRAME_MAC_WINDOW (f).  */

void
mac_create_frame_window (struct frame *f)
{
  EmacsFrameController * __block frameController;
  int left_pos, top_pos;

  /* Save possibly negative position values because they might be
     changed by `setToolbar' -> `windowDidResize:' if the toolbar is
     visible.  */
  if (f->size_hint_flags & (USPosition | PPosition)
      || FRAME_PARENT_FRAME (f))
    {
      left_pos = f->left_pos;
      top_pos = f->top_pos;
    }

  mac_within_gui (^{
      frameController = [[EmacsFrameController alloc] initWithEmacsFrame:f];
    });
  FRAME_MAC_WINDOW (f) = (void *) CF_ESCAPING_BRIDGE (frameController);

  if (f->size_hint_flags & (USPosition | PPosition)
      || FRAME_PARENT_FRAME (f))
    {
      f->left_pos = left_pos;
      f->top_pos = top_pos;
      mac_move_frame_window_structure (f, f->left_pos, f->top_pos);
    }
  else if (!FRAME_TOOLTIP_P (f))
    {
      mac_within_gui (^{
	  NSWindow *window = [frameController emacsWindow];
	  NSWindow *mainWindow = [NSApp mainWindow];

	  if (mainWindow == nil)
	    [window center];
	  else
	    {
	      NSRect windowFrame = [mainWindow frame];
	      NSPoint topLeft = NSMakePoint (NSMinX (windowFrame),
					     NSMaxY (windowFrame));

	      topLeft = [window cascadeTopLeftFromPoint:topLeft];
	      [window cascadeTopLeftFromPoint:topLeft];
	    }
	});
    }
}

/* Dispose of the Mac window of the frame F.  */

void
mac_dispose_frame_window (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      EmacsWindow *window = frameController.emacsWindow;

      /* Mac OS X 10.6 needs this.  */
      [window.parentWindow removeChildWindow:window];
      [frameController closeWindow];
      /* [overlayView.layer removeObserver:self forKeyPath:...] in
	 -[EmacsFrameController dealloc] must be called from the GUI
	 thread.  */
      CFRelease (FRAME_MAC_WINDOW (f));
    });
}

void
mac_change_frame_window_wm_state (struct frame *f, WMState flags_to_set,
				  WMState flags_to_clear)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  WMState oldState, newState;

  oldState = [frameController windowManagerState];
  newState = (oldState & ~flags_to_clear) | flags_to_set;
  mac_within_gui_allowing_inner_lisp (^{
      [frameController setWindowManagerState:newState];
    });
}

Emacs_Cursor
mac_cursor_create (ThemeCursor shape, const Emacs_Color *fore_color,
		   const Emacs_Color *back_color)
{
  NSCursor *cursor = nil;
  NSImage *image;
  NSSize imageSize;
  NSArrayOf (NSImageRep *) *reps;
  enum {RED, GREEN, BLUE, ALPHA, NCOMPONENTS = ALPHA} c;
  int fg[NCOMPONENTS], delta[NCOMPONENTS];

  if ((fore_color && fore_color->pixel != 0)
      || (back_color && back_color->pixel != 0xffffff))
    cursor = [NSCursor cursorWithThemeCursor:shape];
  if (cursor == nil)
    return CFNumberCreate (NULL, kCFNumberSInt32Type, &shape);

  if (fore_color == NULL)
    fg[RED] = fg[GREEN] = fg[BLUE] = 0;
  else
    {
      fg[RED] = fore_color->red;
      fg[GREEN] = fore_color->green;
      fg[BLUE] = fore_color->blue;
    }
  if (back_color == NULL)
    for (c = 0; c < NCOMPONENTS; c++)
      delta[c] = 0xffff - fg[c];
  else
    {
      delta[RED] = back_color->red - fg[RED];
      delta[GREEN] = back_color->green - fg[GREEN];
      delta[BLUE] = back_color->blue - fg[BLUE];
    }

  image = [cursor image];
  reps = [image representations];

  imageSize = [image size];
  image = [[NSImage alloc] initWithSize:imageSize];
  for (NSImageRep * __strong rep in reps)
    {
      NSInteger width = [rep pixelsWide], height = [rep pixelsHigh];
      unsigned char *data = xmalloc (width * height * 4);
      CGContextRef context =
	CGBitmapContextCreate (data, width, height, 8, width * 4,
			       mac_cg_color_space_rgb,
			       (kCGImageAlphaPremultipliedLast
				| kCGBitmapByteOrder32Big));

      if (context)
	{
	  NSGraphicsContext *gcontext;
	  CGImageRef cgImage;
	  NSInteger i;

	  CGContextClearRect (context, CGRectMake (0, 0, width, height));
	  [NSGraphicsContext saveGraphicsState];
	  gcontext = [NSGraphicsContext graphicsContextWithCGContext:context
							     flipped:NO];
	  NSGraphicsContext.currentContext = gcontext;
	  [rep draw];
	  [NSGraphicsContext restoreGraphicsState];
	  for (i = 0; i < width * height; i++)
	    if (data[i*4+ALPHA] > 0x7f)
	      if ((max (data[i*4+RED], max (data[i*4+GREEN], data[i*4+BLUE]))
		   - min (data[i*4+RED], min (data[i*4+GREEN], data[i*4+BLUE])))
		  <= 5)
		for (c = 0; c < NCOMPONENTS; c++)
		  data[i*4+c] = (fg[c] * data[i*4+ALPHA]
				 + delta[c] * data[i*4+c]) / 0xffff;
	  cgImage = CGBitmapContextCreateImage (context);
	  CGContextRelease (context);
	  if (cgImage)
	    {
	      rep = [NSImage imageWithCGImage:cgImage
				    exclusive:NO].representations[0];
	      CGImageRelease (cgImage);
	    }
	}
      xfree (data);
      [rep setSize:imageSize];
      [image addRepresentation:rep];
    }
  cursor = [[NSCursor alloc] initWithImage:image hotSpot:[cursor hotSpot]];
  MRC_RELEASE (image);

  return CF_ESCAPING_BRIDGE (cursor);
}

void
mac_cursor_set (Emacs_Cursor cursor)
{
  if (CFGetTypeID (cursor) == CFNumberGetTypeID ())
    {
#if __LP64__
      extern OSStatus SetThemeCursor (ThemeCursor);
#endif
      ThemeCursor cursor_value;

      if (CFNumberGetValue (cursor, kCFNumberSInt32Type, &cursor_value))
	SetThemeCursor (cursor_value);
    }
  else
    [(__bridge NSCursor *)cursor set];
}

void
mac_cursor_release (Emacs_Cursor cursor)
{
  if (cursor)
    CFRelease (cursor);
}

void
mac_invalidate_frame_cursor_rects (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController invalidateCursorRectsForEmacsView];
}

void
mac_invalidate_rectangles (struct frame *f, NativeRectangle *rectangles, int n)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSRect *rects = alloca (sizeof (NSRect) * n);
  int i;

  for (i = 0; i < n; i++)
    rects[i] = NSMakeRect (rectangles[i].x, rectangles[i].y,
			   rectangles[i].width, rectangles[i].height);
  mac_within_gui (^{
      [frameController setEmacsViewNeedsDisplayInRects:rects count:n];
    });
}

void
mac_update_frame_window_style (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui_allowing_inner_lisp (^{[frameController updateWindowStyle];});
}

void
mac_update_frame_window_parent (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  WMState windowManagerState = frameController.windowManagerState;
  struct frame *p = FRAME_PARENT_FRAME (f);
  int x = f->left_pos, y = f->top_pos;

  if ((windowManagerState & WM_STATE_DEDICATED_DESKTOP)
      && p)
    {
      /* Exit from full screen and try setting the `parent-frame'
	 frame parameter again via storeParentFrameFrameParameter. */
      mac_within_app (^{
	  [frameController changeFullScreenState:WM_STATE_FULLSCREEN];
	});

      return;
    }

  mac_within_gui (^{
      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

      window.animationBehavior = (p == NULL
				  ? NSWindowAnimationBehaviorDocumentWindow
				  : NSWindowAnimationBehaviorNone);
      if (window.isVisible)
	{
	  [window.parentWindow removeChildWindow:window];
	  if (p)
	    {
	      NSWindow *newParentWindow = FRAME_MAC_WINDOW_OBJECT (p);

	      window.collectionBehavior &=
		~NSWindowCollectionBehaviorFullScreenPrimary;
	      [newParentWindow addChildWindow:window ordered:NSWindowAbove];
	    }
	  else
	    [frameController updateCollectionBehavior];

	  [emacsController updatePresentationOptions];
	}
      mac_move_frame_window_structure_1 (f, x, y);
    });
  mac_update_frame_window_style (f);
  if (((windowManagerState & (WM_STATE_FULLSCREEN
			      | WM_STATE_DEDICATED_DESKTOP))
       == WM_STATE_FULLSCREEN)
      && EQ (get_frame_param (f, Qfullscreen), Qfullscreen)
      && p == NULL)
    mac_within_gui_allowing_inner_lisp (^{
	[frameController setWindowManagerState:(WM_STATE_DEDICATED_DESKTOP
						| windowManagerState)];
      });
}

Lisp_Object
mac_frame_list_z_order (struct frame *f)
{
  Lisp_Object result = Qnil;
  NSWindow *root = nil;

  block_input ();
  if (f)
    root = FRAME_MAC_WINDOW_OBJECT (f);
  for (NSWindow *window in [NSApp orderedWindows])
    if ([window isKindOfClass:EmacsWindow.class])
      {
	Lisp_Object frame = ((EmacsWindow *) window).lispFrame;

	if (FRAME_TOOLTIP_P (XFRAME (frame)))
	  continue;

	if (root)
	  {
	    NSWindow *ancestor = window;

	    do
	      {
		if ([ancestor isEqual:root])
		  break;
		ancestor = ancestor.parentWindow;
	      }
	    while (ancestor);
	    if (ancestor == nil)
	      continue;
	  }

	result = Fcons (frame, result);
      }
  unblock_input ();

  return Fnreverse (result);
}

void
mac_frame_restack (struct frame *f1, struct frame *f2, bool above_flag)
{
  NSWindow *window1, *window2;

  block_input ();
  window1 = FRAME_MAC_WINDOW_OBJECT (f1);
  window2 = FRAME_MAC_WINDOW_OBJECT (f2);
  mac_within_gui (^{
      [window1 orderWindow:(above_flag ? NSWindowAbove : NSWindowBelow)
		relativeTo:window2.windowNumber];
    });
  unblock_input ();
}


/************************************************************************
			   View and Drawing
 ************************************************************************/

/* Array of Carbon key events that are deferred during the execution
   of AppleScript.  NULL if not executing AppleScript.  */
static CFMutableArrayRef deferred_key_events;

static int mac_event_to_emacs_modifiers (NSEvent *);
static bool mac_try_buffer_and_glyph_matrix_access (void);
static void mac_end_buffer_and_glyph_matrix_access (void);

#ifndef USE_METAL_RENDERING
@implementation EmacsBacking

static vImage_Error
mac_vimage_buffer_init_8888 (vImage_Buffer *buf, vImagePixelCount height,
			     vImagePixelCount width)
{
  return vImageBuffer_Init (buf, height, width, 8 * sizeof (Pixel_8888),
			    kvImageNoFlags);
}

static vImage_Error
mac_vimage_copy_8888 (const vImage_Buffer *src, const vImage_Buffer *dest,
		      vImage_Flags flags)
{
  return vImageCopyBuffer (src, dest, sizeof (Pixel_8888), flags);
}

static IOSurfaceRef
mac_iosurface_create (size_t width, size_t height)
{
  NSDictionary *properties =
    @{(__bridge NSString *) kIOSurfaceWidth : @(width),
      (__bridge NSString *) kIOSurfaceHeight : @(height),
      (__bridge NSString *) kIOSurfaceBytesPerElement : @4,
      (__bridge NSString *) kIOSurfacePixelFormat : @((uint32_t) 'BGRA')};

  return IOSurfaceCreate ((__bridge CFDictionaryRef) properties);
}

- (instancetype)initWithView:(NSView *)view
{
  self = [super init];
  if (self == nil)
    return nil;

  scaleFactor = view.window.backingScaleFactor;

  NSSize size = view.bounds.size;
  size_t width = size.width * scaleFactor;
  size_t height = size.height * scaleFactor;
  NSColorSpace *colorSpace = view.window.colorSpace;
  CGColorSpaceRef color_space = (colorSpace ? colorSpace.CGColorSpace
				 /* The window does not have a backing
				    store, and is off-screen.  */
				 : mac_cg_color_space_rgb);
  CGContextRef bitmaps[2] = {NULL, NULL};
  IOSurfaceRef surfaces[2] = {NULL, NULL};

  for (int i = 0; i < 2; i++)
    {
      void *data = NULL;
      size_t bytes_per_row = 0;

      surfaces[i] = mac_iosurface_create (width, height);
      if (surfaces[i])
	{
	  IOSurfaceLock (surfaces[i], 0, NULL);
	  data = IOSurfaceGetBaseAddress (surfaces[i]);
	  bytes_per_row = IOSurfaceGetBytesPerRow (surfaces[i]);
	}
      bitmaps[i] = CGBitmapContextCreate (data, width, height, 8, bytes_per_row,
					  color_space,
					  /* This combination enables
					     us to use LCD Font
					     smoothing.  */
					  (kCGImageAlphaPremultipliedFirst
					   | kCGBitmapByteOrder32Host));
      CGContextTranslateCTM (bitmaps[i], 0, height);
      CGContextScaleCTM (bitmaps[i], scaleFactor, - scaleFactor);
      if (!surfaces[i])
	break;
    }
  backBitmap = bitmaps[0];
  backSurface = surfaces[0];
  frontBitmap = bitmaps[1];
  frontSurface = surfaces[1];
  if (frontSurface)
    {
      IOSurfaceUnlock (frontSurface, 0, NULL);
      invalidRectValues = [[NSMutableArray alloc] initWithCapacity:0];
    }
#if HAVE_MAC_METAL
  [self updateMTLObjectsForView:view];
#endif

  return self;
}

- (void)swapResourcesAndStartCopy
{
  CGContextRef bitmap = backBitmap;
  backBitmap = frontBitmap;
  frontBitmap = bitmap;

  IOSurfaceUnlock (backSurface, 0, NULL);

  IOSurfaceRef surface = backSurface;
  backSurface = frontSurface;
  frontSurface = surface;

#if HAVE_MAC_METAL
  id <MTLTexture> texture = backTexture;
  backTexture = frontTexture;
  frontTexture = texture;
#endif

  NSArrayOf (NSValue *) *rectValues = invalidRectValues;
  invalidRectValues = [[NSMutableArray alloc] initWithCapacity:0];

  dispatch_queue_t queue =
    dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  copyFromFrontToBackSemaphore = dispatch_semaphore_create (0);

  dispatch_async (queue, ^{
#if HAVE_MAC_METAL
      if (backTexture)
	{
	  id <MTLCommandBuffer> commandBuffer = [mtlCommandQueue commandBuffer];
	  id <MTLBlitCommandEncoder> blitCommandEncoder =
	    [commandBuffer blitCommandEncoder];

	  for (NSValue *value in rectValues)
	    {
	      NSRect rect = value.rectValue;
	      MTLOrigin origin = MTLOriginMake (NSMinX (rect) * scaleFactor,
						NSMinY (rect) * scaleFactor, 0);
	      MTLSize size = MTLSizeMake (NSWidth (rect) * scaleFactor,
					  NSHeight (rect) * scaleFactor, 1);

	      [blitCommandEncoder copyFromTexture:frontTexture
				      sourceSlice:0 sourceLevel:0
				     sourceOrigin:origin sourceSize:size
					toTexture:backTexture
				 destinationSlice:0 destinationLevel:0
				destinationOrigin:origin];
	    }
	  [blitCommandEncoder endEncoding];
	  [commandBuffer commit];
	  [commandBuffer waitUntilCompleted];
	  IOSurfaceLock (backSurface, 0, NULL);
	}
      else
#endif
	{
	  IOSurfaceLock (frontSurface, kIOSurfaceLockReadOnly, NULL);
	  IOSurfaceLock (backSurface, 0, NULL);
	  unsigned char *backBase = IOSurfaceGetBaseAddress (backSurface);
	  unsigned char *frontBase = IOSurfaceGetBaseAddress (frontSurface);
	  size_t bytesPerRow = IOSurfaceGetBytesPerRow (backSurface);
	  size_t surfaceWidth = IOSurfaceGetWidth (backSurface);
	  vImage_Buffer src, dest;
	  src.rowBytes = dest.rowBytes = bytesPerRow;
	  for (NSValue *value in rectValues)
	    {
	      NSRect rect = value.rectValue;
	      size_t x = NSMinX (rect) * scaleFactor;
	      size_t y = NSMinY (rect) * scaleFactor;
	      size_t offset = y * bytesPerRow + x * sizeof (Pixel_8888);
	      src.width = NSWidth (rect) * scaleFactor;
	      src.height = NSHeight (rect) * scaleFactor;

	      if (surfaceWidth - src.width < surfaceWidth / 16)
		memcpy (backBase + offset, frontBase + offset,
			((src.height - 1) * bytesPerRow
			 + src.width * sizeof (Pixel_8888)));
	      else
		{
		  src.data = frontBase + offset;
		  dest.width = src.width;
		  dest.height = src.height;
		  dest.data = backBase + offset;
		  mac_vimage_copy_8888 (&src, &dest, kvImageDoNotTile);
		}
	    }
	  IOSurfaceUnlock (frontSurface, kIOSurfaceLockReadOnly, NULL);
	}

      MRC_RELEASE (rectValues);
      dispatch_semaphore_signal (copyFromFrontToBackSemaphore);
    });
}

- (void)waitCopyFromFrontToBack
{
  if (copyFromFrontToBackSemaphore)
    {
      dispatch_semaphore_wait (copyFromFrontToBackSemaphore,
			       DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
      dispatch_release (copyFromFrontToBackSemaphore);
#endif
      copyFromFrontToBackSemaphore = NULL;
    }
}

- (void)dealloc
{
  [self waitCopyFromFrontToBack];
  CGContextRelease (backBitmap);
  CGContextRelease (frontBitmap);
  if (backSurface)
    CFRelease (backSurface);
  if (frontSurface)
    CFRelease (frontSurface);
#if !USE_ARC
  [invalidRectValues release];
#if HAVE_MAC_METAL
  [backTexture release];
  [frontTexture release];
  [mtlCommandQueue release];
#endif
  [super dealloc];
#endif
}

- (char)lockCount
{
  return lockCount;
}

- (NSSize)size
{
  return NSMakeSize (CGBitmapContextGetWidth (backBitmap) / scaleFactor,
		     CGBitmapContextGetHeight (backBitmap) / scaleFactor);
}

- (BOOL)wantsInvalidRectForCGContext:(CGContextRef)context
{
  return invalidRectValues && context == backBitmap;
}

- (void)invalidateRect:(NSRect)rect
{
  if (!invalidRectValues)
    return;

  NSUInteger i, count = invalidRectValues.count;
  NSRect r, boundsRect = {NSZeroPoint, self.size};

  rect = NSIntersectionRect (rect, boundsRect);
  if (NSIsEmptyRect (rect))
    return;

#if 1
  /* Usually count is not so large, and the simple linear search would
     be enough.  */
  for (i = 0; i < count; i++)
    {
      r = [invalidRectValues[i] rectValue];
      if (NSMinY (rect) <= NSMaxY (r))
	break;
    }
  if (i == count || NSMaxY (rect) < NSMinY (r))
    [invalidRectValues insertObject:[NSValue valueWithRect:rect] atIndex:i];
  else if (!NSContainsRect (r, rect))
    {
      NSUInteger j = i++;

      rect = NSUnionRect (rect, r);
      for (; i < count; i++)
	{
	  r = [invalidRectValues[i] rectValue];
	  if (NSMaxY (rect) < NSMinY (r))
	    break;
	  rect = NSUnionRect (rect, r);
	}
      [invalidRectValues replaceObjectAtIndex:j++
				   withObject:[NSValue valueWithRect:rect]];
      [invalidRectValues removeObjectsInRange:(NSMakeRange (j, i - j))];
    }
#else
  i = [invalidRectValues
	indexOfObject:[NSValue
			valueWithRect:(NSMakeRect (0, NSMinY (rect), 0, 0))]
	inSortedRange:NSMakeRange (0, count)
	      options:NSBinarySearchingInsertionIndex
	usingComparator:^(id obj1, id obj2) {
      CGFloat y1 = NSMaxY (((NSValue *) obj1).rectValue);
      CGFloat y2 = NSMaxY (((NSValue *) obj2).rectValue);
      return (NSComparisonResult) (y1 > y2 ? NSOrderedDescending
				   : y1 < y2 ? NSOrderedAscending
				   : NSOrderedSame);
    }];
  NSUInteger j;
  for (j = i; j < count; j++)
    {
      r = invalidRectValues[j].rectValue;
      if (NSMaxY (rect) < NSMinY (r))
	break;
      rect = NSUnionRect (rect, r);
    }
  if (i == j)
    [invalidRectValues insertObject:[NSValue valueWithRect:rect] atIndex:i];
  else
    {
      [invalidRectValues replaceObjectAtIndex:i++
				   withObject:[NSValue valueWithRect:rect]];
      [invalidRectValues removeObjectsInRange:(NSMakeRange (i, j - i))];
    }
#endif
}

#if HAVE_MAC_METAL
static id <MTLTexture>
mac_texture_create_with_surface (id <MTLDevice> device, IOSurfaceRef surface)
{
  if (!device || !surface)
    return nil;

  MTLTextureDescriptor *textureDescriptor =
    [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				   width:(IOSurfaceGetWidth (surface))
				  height:(IOSurfaceGetHeight (surface))
			       mipmapped:NO];

  return [device newTextureWithDescriptor:textureDescriptor
				iosurface:surface plane:0];
}

- (void)updateMTLObjectsForView:(NSView *)view
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
  if (CGDirectDisplayCopyCurrentMetalDevice == NULL)
    return;
#endif
  CGDirectDisplayID displayID =
    (CGDirectDisplayID) [view.window.screen.deviceDescription[@"NSScreenNumber"]
			     unsignedIntValue];
  id <MTLDevice> newDevice = CGDirectDisplayCopyCurrentMetalDevice (displayID);

  if (newDevice != mtlCommandQueue.device)
    {
      MRC_RELEASE (backTexture);
      backTexture = mac_texture_create_with_surface (newDevice, backSurface);
      MRC_RELEASE (frontTexture);
      if (backTexture == nil)
	frontTexture = nil;
      else
	{
	  frontTexture = mac_texture_create_with_surface (newDevice,
							  frontSurface);
	  if (frontTexture == nil)
	    {
	      MRC_RELEASE (backTexture);
	      backTexture = nil;
	    }
	}
      MRC_RELEASE (mtlCommandQueue);
      mtlCommandQueue = newDevice.newCommandQueue;
    }
  MRC_RELEASE (newDevice);
}
#endif

- (void)setContentsForLayer:(CALayer *)layer
{
  eassert (lockCount == 0);

  [self waitCopyFromFrontToBack];
  if (frontSurface)
    {
      [self swapResourcesAndStartCopy];
      layer.contents = (__bridge id) frontSurface;
    }
  else
    layer.contents =
      CFBridgingRelease (CGBitmapContextCreateImage (backBitmap));
  layer.contentsScale = scaleFactor;
}

- (void)lockFocus
{
  lockCount++;
  [self waitCopyFromFrontToBack];

  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext =
    [NSGraphicsContext graphicsContextWithCGContext:backBitmap flipped:NO];
}

- (void)unlockFocus
{
  eassert (lockCount);
  eassert (backBitmap);

  lockCount--;
  [NSGraphicsContext restoreGraphicsState];
}

- (void)scrollRect:(NSRect)rect by:(NSSize)delta
{
  NSInteger deltaX, deltaY, srcX, srcY, width, height;

  if ((delta.width == 0 && delta.height == 0) || NSIsEmptyRect (rect))
    return;

  [self invalidateRect:(NSOffsetRect (rect, delta.width, delta.height))];

  if (scaleFactor != 1.0)
    {
      rect.origin.x *= scaleFactor, rect.origin.y *= scaleFactor;
      rect.size.width *= scaleFactor, rect.size.height *= scaleFactor;
      delta.width *= scaleFactor, delta.height *= scaleFactor;
    }

  deltaX = delta.width, deltaY = delta.height;
  srcX = NSMinX (rect), srcY = NSMinY (rect);
  width = NSWidth (rect), height = NSHeight (rect);

  eassert (CGBitmapContextGetBitsPerPixel (backBitmap)
	   == 8 * sizeof (Pixel_8888));
  NSInteger bytesPerRow = CGBitmapContextGetBytesPerRow (backBitmap);
  const NSInteger bytesPerPixel = sizeof (Pixel_8888);
  unsigned char *srcData = CGBitmapContextGetData (backBitmap);
  vImage_Buffer src, dest;

  src.data = srcData + srcY * bytesPerRow + srcX * bytesPerPixel;
  src.height = height;
  src.width = width;
  src.rowBytes = bytesPerRow;
  if (deltaY != 0)
    {
      if (deltaY > 0)
	{
	  src.data = ((unsigned char *) src.data
		      + (src.height - 1) * bytesPerRow);
	  src.rowBytes = - bytesPerRow;
	}
      dest = src;
      dest.data = ((unsigned char *) dest.data
		   + deltaY * bytesPerRow + deltaX * bytesPerPixel);
      /* As of macOS 10.13, vImageCopyBuffer no longer does
	 multi-threading even if we give it kvImageNoFlags.  We rather
	 pass kvImageDoNotTile so it works with overlapping areas on
	 older versions.  */
      mac_vimage_copy_8888 (&src, &dest, kvImageDoNotTile);
    }
  else /* deltaY == 0, which does not happen on the current version of
	  Emacs. */
    {
      dest = src;
      dest.data = ((unsigned char *) dest.data
		   + /* deltaY * bytesPerRow + */ deltaX * bytesPerPixel);
      if (labs (deltaX) >= src.width)
	mac_vimage_copy_8888 (&src, &dest, kvImageNoFlags);
      else if (deltaX == 0)
	return;
      else
	{
	  vImage_Buffer buf;

	  mac_vimage_buffer_init_8888 (&buf, src.height, src.width);
	  mac_vimage_copy_8888 (&src, &buf, kvImageNoFlags);
	  mac_vimage_copy_8888 (&buf, &dest, kvImageNoFlags);
	  free (buf.data);
	}
    }
}

- (NSData *)imageBuffersDataForRectanglesData:(NSData *)rectanglesData
{
  NSInteger i, count = rectanglesData.length / sizeof (NativeRectangle);
  const NativeRectangle *rectangles = rectanglesData.bytes;
  NSMutableData *imageBuffersData =
    [NSMutableData dataWithCapacity:(count * sizeof (vImage_Buffer))];
  vImage_Buffer *imageBuffers = imageBuffersData.mutableBytes;
  [self waitCopyFromFrontToBack];
  unsigned char *srcData = CGBitmapContextGetData (backBitmap);
  NSInteger scale = scaleFactor;
  NativeRectangle backing_rectangle = {0, 0,
    CGBitmapContextGetWidth (backBitmap) / scale,
    CGBitmapContextGetHeight (backBitmap) / scale};
  vImage_Buffer src;

  src.rowBytes = CGBitmapContextGetBytesPerRow (backBitmap);
  for (i = 0; i < count; i++)
    {
      vImage_Buffer *dest = imageBuffers + i;
      NativeRectangle rectangle;

      gui_intersect_rectangles (rectangles + i, &backing_rectangle, &rectangle);
      mac_vimage_buffer_init_8888 (dest, rectangle.height * scale,
				   rectangle.width * scale);
      src.height = dest->height, src.width = dest->width;
      src.data = srcData + (rectangle.y * src.rowBytes
			    + rectangle.x * sizeof (Pixel_8888)) * scale;
      mac_vimage_copy_8888 (&src, dest, kvImageNoFlags);
    }

  return imageBuffersData;
}

- (void)restoreImageBuffersData:(NSData *)imageBuffersData
	      forRectanglesData:(NSData *)rectanglesData
{
  NSInteger i, count = rectanglesData.length / sizeof (NativeRectangle);
  const NativeRectangle *rectangles = rectanglesData.bytes;
  const vImage_Buffer *imageBuffers = imageBuffersData.bytes;
  [self waitCopyFromFrontToBack];
  unsigned char *destData = CGBitmapContextGetData (backBitmap);
  NSInteger scale = scaleFactor;
  NativeRectangle backing_rectangle = {0, 0,
    CGBitmapContextGetWidth (backBitmap) / scale,
    CGBitmapContextGetHeight (backBitmap) / scale};
  vImage_Buffer dest;

  dest.rowBytes = CGBitmapContextGetBytesPerRow (backBitmap);
  for (i = 0; i < count; i++)
    {
      const vImage_Buffer *src = imageBuffers + i;
      NativeRectangle rectangle;

      gui_intersect_rectangles (rectangles + i, &backing_rectangle, &rectangle);
      dest.height = src->height, dest.width = src->width;
      dest.data = destData + (rectangle.y * dest.rowBytes
			      + rectangle.x * sizeof (Pixel_8888)) * scale;
      mac_vimage_copy_8888 (src, &dest, kvImageNoFlags);
      free (src->data);
      [self invalidateRect:(NSMakeRect (rectangle.x, rectangle.y,
					rectangle.width, rectangle.height))];
    }
}

@end				// EmacsBacking
#endif /* !USE_METAL_RENDERING */

/* View for Emacs frame.  */

@implementation EmacsView

static BOOL emacsViewUpdateLayerDisabled;

- (instancetype)initWithFrame:(NSRect)frameRect
{
  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  [self setPostsFrameChangedNotifications:YES];

  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(viewFrameDidChange:)
	   name:@"NSViewFrameDidChangeNotification"
	 object:self];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !USE_ARC
#ifndef USE_METAL_RENDERING
  [backing release];
#endif
  [super dealloc];
#endif
}

+ (void)globallyDisableUpdateLayer:(BOOL)flag
{
  emacsViewUpdateLayerDisabled = flag;
}

- (struct frame *)emacsFrame
{
  EmacsFrameController *frameController =
    (EmacsFrameController *) self.window.delegate;

  return frameController.emacsFrame;
}

- (void)drawRect:(NSRect)aRect
{
#ifdef USE_METAL_RENDERING
  /* Under Metal, drawing is handled by the Metal rendering pipeline.
     Expose events trigger redisplay through the normal
     expose_frame path.  */
  struct frame *f = self.emacsFrame;
  int x = NSMinX (aRect), y = NSMinY (aRect);
  int width = NSWidth (aRect), height = NSHeight (aRect);

  if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())
    /* Keep the last presentation; Lisp redraws when it can.  */
    return;
  if (FRAME_METAL_CTX (f))
    {
      emacs_metal_frame_begin (FRAME_METAL_CTX (f));
      mac_clear_area (f, x, y, width, height);
      expose_frame (f, x, y, width, height);
      mac_clear_under_internal_border (f);
      emacs_metal_frame_end (FRAME_METAL_CTX (f));
    }
#else
  struct frame *f = self.emacsFrame;
  int x = NSMinX (aRect), y = NSMinY (aRect);
  int width = NSWidth (aRect), height = NSHeight (aRect);

  if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())
    /* Keep the last presentation; Lisp redraws when it can.  */
    return;
  set_global_focus_view_frame (f);
  mac_clear_area (f, x, y, width, height);
  mac_begin_scale_mismatch_detection (f);
  expose_frame (f, x, y, width, height);
  mac_clear_under_internal_border (f);
  if (mac_end_scale_mismatch_detection (f))
    SET_FRAME_GARBAGED (f);
  if (!backing)
    mac_invert_flash_rectangles (f);
  unset_global_focus_view_frame ();
#endif
}

- (BOOL)isFlipped
{
  return YES;
}

- (BOOL)isOpaque
{
#ifdef USE_METAL_RENDERING
  return YES;
#else
  return !self.wantsUpdateLayer;
#endif
}

#ifdef USE_METAL_RENDERING
- (CALayer *)makeBackingLayer
{
  CAMetalLayer *layer = [CAMetalLayer layer];
  layer.device = MTLCreateSystemDefaultDevice ();
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  return layer;
}

- (BOOL)wantsLayer
{
  return YES;
}

- (BOOL)wantsUpdateLayer
{
  return YES;
}

- (void)updateLayer
{
  /* Under Metal, presentation is handled by emacs_metal_frame_end.
     Nothing to do here.  */
}

- (void)syncMetalDrawableSize
{
  struct frame *f = self.emacsFrame;

  if (!f || !FRAME_METAL_CTX (f))
    return;

  CALayer *layer = self.layer;
  if (![layer isKindOfClass:[CAMetalLayer class]])
    return;

  int scale = (int) self.window.backingScaleFactor;
  if (scale < 1)
    scale = 1;

  NSRect bounds = [self bounds];
  int width = max (0, (int) NSWidth (bounds));
  int height = max (0, (int) NSHeight (bounds));
  CAMetalLayer *metalLayer = (CAMetalLayer *) layer;

  metalLayer.contentsScale = scale;
  metalLayer.drawableSize = CGSizeMake (width * scale, height * scale);
  emacs_metal_context_resize (FRAME_METAL_CTX (f), width, height, scale);
}
#else  /* !USE_METAL_RENDERING */

#if HAVE_MAC_METAL
- (void)updateMTLObjects
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.wantsUpdateLayer)
    return;
#endif
  [backing updateMTLObjectsForView:self];
}
#endif

- (BOOL)wantsUpdateLayer
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (self.layer == nil
      /* This method may be called when creating the layer tree, where
	 the view layer is not ready.  */
      && !FRAME_MAC_DOUBLE_BUFFERED_P (self.emacsFrame))
    return NO;
#endif
  return !emacsViewUpdateLayerDisabled;
}
#endif /* !USE_METAL_RENDERING */

#ifndef USE_METAL_RENDERING
- (void)updateLayer
{
  struct frame *f = self.emacsFrame;
  NSData *rectanglesData = ((__bridge NSData *)
			    (FRAME_FLASH_RECTANGLES_DATA (f)));
  NSData *savedImageBuffersData;

  if (backing.lockCount)
    return;

  if (!backing)
    {
      if (mac_try_buffer_and_glyph_matrix_access ())
	{
	  [self lockFocusOnBacking];
	  [self drawRect:self.bounds];
	  [self unlockFocusOnBacking];
	  self.needsDisplay = NO;
	  mac_end_buffer_and_glyph_matrix_access ();
	}
      else
	return;
    }

  if (rectanglesData)
    {
      savedImageBuffersData =
	[backing imageBuffersDataForRectanglesData:rectanglesData];
      [self lockFocusOnBacking];
      set_global_focus_view_frame (f);
      mac_invert_flash_rectangles (f);
      unset_global_focus_view_frame ();
      [self unlockFocusOnBacking];
      self.needsDisplay = NO;
    }

  [backing setContentsForLayer:self.layer];

  if (rectanglesData)
    [backing restoreImageBuffersData:savedImageBuffersData
		   forRectanglesData:rectanglesData];
}
#endif /* !USE_METAL_RENDERING */

- (void)lockFocusOnBacking
{
#ifdef USE_METAL_RENDERING
  /* No-op under Metal — no backing store to lock.  */
#else
  eassert (pthread_main_np ());

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.wantsUpdateLayer)
    {
      [self lockFocus];

      return;
    }
#endif
  if (backingSizeOutOfSync)
    {
      if (backing && !NSEqualSizes (backing.size, self.bounds.size))
	{
	  MRC_RELEASE (backing);
	  backing = nil;
	}
      backingSizeOutOfSync = NO;
    }
  if (!backing)
    backing = [[EmacsBacking alloc] initWithView:self];
  [backing lockFocus];
#endif /* !USE_METAL_RENDERING */
}

- (void)unlockFocusOnBacking
{
#ifdef USE_METAL_RENDERING
  /* No-op under Metal — no backing store to unlock.  */
#else
  eassert (pthread_main_np ());

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.wantsUpdateLayer)
    {
      [self unlockFocus];

      return;
    }
#endif
  [backing unlockFocus];
#endif /* !USE_METAL_RENDERING */
}

#ifndef USE_METAL_RENDERING
- (void)scrollBackingRect:(NSRect)rect by:(NSSize)delta
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.wantsUpdateLayer)
    {
      [self scrollRect:rect by:delta];

      return;
    }
#endif
  [backing scrollRect:rect by:delta];
}

- (void)invalidateBackingRect:(CGRect)invalidRect
		    clipRects:(const CGRect *)clipRects count:(CFIndex)count
		 forCGContext:(CGContextRef)context
{
  if (![backing wantsInvalidRectForCGContext:context])
    return;

  if (count == 0)
    [backing invalidateRect:(NSRectFromCGRect (invalidRect))];
  else
    for (CFIndex i = 0; i < count; i++)
      [backing
	invalidateRect:(NSIntersectionRect (NSRectFromCGRect (invalidRect),
					    NSRectFromCGRect (clipRects[i])))];
}
#endif /* !USE_METAL_RENDERING */

- (void)viewDidChangeBackingProperties
{
#ifdef USE_METAL_RENDERING
  /* W10: resizing the Metal context races with Lisp drawing into it.
     Without Lisp access, keep the old drawable, which the layer
     scales; -windowDidChangeBackingProperties: resizes it once Lisp
     can redraw.  */
  int token = mac_loop_begin_lisp_access ();

  if (token == MAC_LOOP_NO_ACCESS)
    return;
  [self syncMetalDrawableSize];
  mac_loop_end_lisp_access (token);
#else
  MRC_RELEASE (backing);
  backing = nil;
#endif
  self.needsDisplay = YES;
}

- (void)viewFrameDidChange:(NSNotification *)notification
{
#ifdef USE_METAL_RENDERING
  [self syncMetalDrawableSize];
#else
  backingSizeOutOfSync = YES;
#endif
}

@end				// EmacsView

@implementation EmacsMainView

+ (void)initialize
{
  if (self == EmacsMainView.class)
    {
      NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

      if ([defaults objectForKey:@"NSAutoFillHeuristicControllerEnabled"] == nil)
	[defaults registerDefaults:@{@"NSAutoFillHeuristicControllerEnabled" : @false}];
      if ([defaults objectForKey:@"ApplePressAndHoldEnabled"] == nil)
	[defaults registerDefaults:@{@"ApplePressAndHoldEnabled" : @"NO"}];
      [defaults setBool:NO forKey:@"NSAutomaticPeriodSubstitutionEnabled"];
    }
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
  NSTrackingArea *trackingAreaForCursor;

  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  trackingAreaForCursor = [[NSTrackingArea alloc]
			    initWithRect:NSZeroRect
				 options:(NSTrackingCursorUpdate
					  | NSTrackingActiveInKeyWindow
					  | NSTrackingInVisibleRect)
				   owner:self userInfo:nil];
  [self addTrackingArea:trackingAreaForCursor];
  MRC_RELEASE (trackingAreaForCursor);

  return self;
}

#if !USE_ARC
- (void)dealloc
{
  [candidateListTouchBarItem release];
  [rawKeyEvent release];
  [markedText release];
  [super dealloc];
}
#endif

- (void)setMarkedText:(id)aString
{
  if (markedText == aString)
    return;

  (void) MRC_AUTORELEASE (markedText);
  markedText = [aString copy];
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (id)target
{
  return target;
}

- (SEL)action
{
  return action;
}

- (void)setTarget:(id)anObject
{
  target = anObject;		/* Targets should not be retained. */
}

- (void)setAction:(SEL)aSelector
{
  action = aSelector;
}

- (BOOL)sendAction:(SEL)theAction to:(id)theTarget
{
  return [NSApp sendAction:theAction to:theTarget from:self];
}

- (struct input_event *)inputEvent
{
  return &inputEvent;
}

- (void)mouseDown:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
  bool tab_bar_p = false;
  bool tool_bar_p = false;
  NSUInteger down_p;

  down_p = (NSEventMaskFromType ([theEvent type]) & ANY_MOUSE_DOWN_EVENT_MASK);

  if (!down_p && !(dpyinfo->grabbed & (1 << [theEvent buttonNumber])))
    return;

  dpyinfo->last_mouse_glyph_frame = NULL;

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  mac_cgevent_to_input_event ([theEvent coreGraphicsEvent], &inputEvent);

  {
    Lisp_Object window;
    EMACS_INT x = point.x;
    EMACS_INT y = point.y;

    XSETINT (inputEvent.x, x);
    XSETINT (inputEvent.y, y);

    window = window_from_coordinates (f, x, y, 0, false, true, true);
    if (EQ (window, f->tab_bar_window))
      tab_bar_p = true;
    else if (EQ (window, f->tool_bar_window))
      tool_bar_p = true;
    if (tab_bar_p || tool_bar_p)
      {
	[self lockFocusOnBacking];
#ifndef USE_METAL_RENDERING
	set_global_focus_view_frame (f);
#endif
	if (tab_bar_p)
	  {
	    Lisp_Object tab_bar_arg;

	    if (down_p)
	      tab_bar_arg = handle_tab_bar_click (f, x, y, 1, 0);
	    else
	      tab_bar_arg = handle_tab_bar_click (f, x, y, 0,
						  inputEvent.modifiers);
	    if (!NILP (tab_bar_arg))
	      {
		XSETFRAME (inputEvent.frame_or_window, f);
		inputEvent.kind = MOUSE_CLICK_EVENT;
		inputEvent.arg = tab_bar_arg;
	      }
	  }
	else
	  {
	    if (down_p)
	      handle_tool_bar_click (f, x, y, 1, 0);
	    else
	      handle_tool_bar_click (f, x, y, 0, inputEvent.modifiers);
	  }
#ifndef USE_METAL_RENDERING
	unset_global_focus_view_frame ();
#endif
	[self unlockFocusOnBacking];
      }
    else
      {
	XSETFRAME (inputEvent.frame_or_window, f);
	inputEvent.kind = MOUSE_CLICK_EVENT;
      }
  }

  if (down_p)
    {
      dpyinfo->grabbed |= (1 << [theEvent buttonNumber]);
      dpyinfo->last_mouse_frame = f;

      if (!tab_bar_p)
	f->last_tab_bar_item = -1;
      if (!tool_bar_p)
	f->last_tool_bar_item = -1;
    }
  else
    dpyinfo->grabbed &= ~(1 << [theEvent buttonNumber]);

  /* Ignore any mouse motion that happened before this event; any
     subsequent mouse-movement Emacs events should reflect only motion
     after the ButtonPress.  */
  if (f != 0)
    f->mouse_moved = false;

  inputEvent.modifiers |= (down_p ? down_modifier : up_modifier);
  if (inputEvent.kind == MOUSE_CLICK_EVENT)
    [self sendAction:action to:target];
}

- (void)mouseUp:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

static Lisp_Object
event_phase_to_symbol (NSEventPhase phase)
{
  switch (phase)
    {
    case NSEventPhaseNone:		return Qnone;
    case NSEventPhaseBegan:		return Qbegan;
    case NSEventPhaseStationary:	return Qstationary;
    case NSEventPhaseChanged:		return Qchanged;
    case NSEventPhaseEnded:		return Qended;
    case NSEventPhaseCancelled:		return Qcancelled;
    case NSEventPhaseMayBegin:		return Qmay_begin;
    default:				return make_fixnum (phase);
    }
}

- (void)scrollWheel:(NSEvent *)theEvent
{
  struct frame *f = self.emacsFrame;
  NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
  int modifiers = mac_event_to_emacs_modifiers (theEvent);
  NSEventType type = theEvent.type;
  BOOL isDirectionInvertedFromDevice = NO;
  BOOL isSwipeTrackingFromScrollEventsEnabled = NO;
  CGFloat deltaX = 0, deltaY = 0, deltaZ = 0;
  CGFloat scrollingDeltaX = 0, scrollingDeltaY = 0;
  Lisp_Object phase = Qnil, momentumPhase = Qnil, arg = Qnil;

  switch (type)
    {
    case NSEventTypeScrollWheel:
      if (theEvent.hasPreciseScrollingDeltas)
	{
	  scrollingDeltaX = theEvent.scrollingDeltaX;
	  scrollingDeltaY = theEvent.scrollingDeltaY;
	}
      phase = event_phase_to_symbol (theEvent.phase);
      momentumPhase = event_phase_to_symbol (theEvent.momentumPhase);
      if (!NILP (momentumPhase))
	{
	  if (EQ (momentumPhase, Qnone))
	    {
	      savedWheelPoint = point;
	      savedWheelModifiers = modifiers;
	    }
	  else
	    {
	      point = savedWheelPoint;
	      modifiers = savedWheelModifiers;
	    }
	}
      isSwipeTrackingFromScrollEventsEnabled =
	NSEvent.isSwipeTrackingFromScrollEventsEnabled;
      FALLTHROUGH;

    case NSEventTypeSwipe:
      deltaX = theEvent.deltaX;
      deltaY = theEvent.deltaY;
      deltaZ = theEvent.deltaZ;
      isDirectionInvertedFromDevice = theEvent.isDirectionInvertedFromDevice;
      break;

    case NSEventTypeMagnify:
      phase = event_phase_to_symbol (theEvent.phase);
      FALLTHROUGH;
    case NSEventTypeGesture:
      deltaY = theEvent.magnification;
      break;

    case NSEventTypeRotate:
      deltaX = theEvent.rotation;
      phase = event_phase_to_symbol (theEvent.phase);
      break;

#if __LP64__
    case NSEventTypeSmartMagnify:
      type = NSEventTypeGesture;
      break;
#endif

    default:
      emacs_abort ();
    }

  if (
#if 0 /* We let the framework decide whether events to non-focus frame
	 get accepted.  */
      !(FRAMEP (mac_get_focus_frame (f))
	&& XFRAME (mac_get_focus_frame (f)) == f) ||
#endif
      deltaX == 0 && (deltaY == 0 && type != NSEventTypeGesture) && deltaZ == 0
      && scrollingDeltaX == 0 && scrollingDeltaY == 0
      && NILP (phase) && NILP (momentumPhase))
    return;

  /* Two-finger touch (and subsequent release or gesture events other
     than scrolling) on trackpads produces NSEventPhaseMayBegin (and
     NSEventPhaseCancelled, resp.) on OS X 10.8.  We ignore them for
     now because they interfere with `mouse--strip-first-event'.  */
  if (type == NSEventTypeScrollWheel
      && (EQ (phase, Qmay_begin) || EQ (phase, Qcancelled)))
    return;

  if (point.x < 0 || point.y < 0)
    return;

  Lisp_Object window = window_from_coordinates (f, point.x, point.y, 0,
						false, true, true);
  if (EQ (window, f->tab_bar_window) || EQ (window, f->tool_bar_window))
    return;

  EVENT_INIT (inputEvent);
  if (type == NSEventTypeScrollWheel || type == NSEventTypeSwipe)
    {
      if (isDirectionInvertedFromDevice)
	arg = list2 (QCdirection_inverted_from_device_p, Qt);
      if (type == NSEventTypeScrollWheel)
	{
	  arg = nconc2 (arg, list (QCdelta_x, make_float (deltaX),
				   QCdelta_y, make_float (deltaY),
				   QCdelta_z, make_float (deltaZ)));
	  if (scrollingDeltaX != 0 || scrollingDeltaY != 0)
	    arg = nconc2 (arg, list4 (QCscrolling_delta_x,
				      make_float (scrollingDeltaX),
				      QCscrolling_delta_y,
				      make_float (scrollingDeltaY)));
	  if (!NILP (phase))
	    arg = nconc2 (arg, list2 (QCphase, phase));
	  if (!NILP (momentumPhase))
	    arg = nconc2 (arg, list2 (QCmomentum_phase, momentumPhase));
	  if (isSwipeTrackingFromScrollEventsEnabled)
	    arg = nconc2 (arg,
			  list2 (QCswipe_tracking_from_scroll_events_enabled_p,
				 Qt));
	}
    }
  else if (type == NSEventTypeMagnify)
    arg = list4 (QCmagnification, make_float (deltaY), QCphase, phase);
  else if (type == NSEventTypeGesture)
    arg = list2 (QCmagnification, make_float (deltaY));
  else if (type == NSEventTypeRotate)
    arg = list4 (QCrotation, make_float (deltaX), QCphase, phase);
  else
    arg = Qnil;
  inputEvent.kind = (deltaY != 0 || scrollingDeltaY != 0
		     || type == NSEventTypeMagnify || type == NSEventTypeGesture
		     ? WHEEL_EVENT : HORIZ_WHEEL_EVENT);
  inputEvent.code = 0;
  inputEvent.modifiers =
    (modifiers
     | (deltaY < 0 || scrollingDeltaY < 0 ? down_modifier
	: (deltaY > 0 || scrollingDeltaY > 0 ? up_modifier
	   : (deltaX < 0 || scrollingDeltaX < 0 ? down_modifier
	      : up_modifier)))
     | (type == NSEventTypeScrollWheel ? 0
	: (type == NSEventTypeSwipe ? drag_modifier : click_modifier)));
  XSETINT (inputEvent.x, point.x);
  XSETINT (inputEvent.y, point.y);
  XSETFRAME (inputEvent.frame_or_window, f);
  inputEvent.arg = make_vector (1, arg);
  inputEvent.timestamp = theEvent.timestamp * 1000;
  [self sendAction:action to:target];
}

- (void)swipeWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)magnifyWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)rotateWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)smartMagnifyWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)changeModeWithEvent:(NSEvent *)event
{
  [NSApp sendAction:(NSSelectorFromString (@"change-mode:")) to:nil from:nil];
}

- (void)mouseMoved:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;
  NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];

  if (theEvent.type == NSEventTypeMouseMoved && !self.window.isKeyWindow)
    return;

  previous_help_echo_string = help_echo_string;
  help_echo_string = Qnil;

  if (hlinfo->mouse_face_hidden)
    {
      hlinfo->mouse_face_hidden = false;
      [frameController clearMouseFace:hlinfo];
    }

  /* Generate SELECT_WINDOW_EVENTs when needed.  */
  if (!NILP (Vmouse_autoselect_window)
      /* Don't switch if we're currently in the minibuffer.  This
	 tries to work around problems where the minibuffer gets
	 unselected unexpectedly, and where you then have to move your
	 mouse all the way down to the minibuffer to select it.  */
      && !MINI_WINDOW_P (XWINDOW (selected_window))
      /* With `focus-follows-mouse' non-nil create an event also when
	 the target window is on another frame.  */
      && (f == XFRAME (selected_frame)
	  || !NILP (focus_follows_mouse)))
    {
      static Lisp_Object last_mouse_window;
      Lisp_Object window = window_from_coordinates (f, point.x, point.y, 0,
						    false, false, false);

      /* A window will be autoselected only when it is not selected
	 now and the last mouse movement event was not in it.  The
	 remainder of the code is a bit vague wrt what a "window" is.
	 For immediate autoselection, the window is usually the entire
	 window but for GTK where the scroll bars don't count.  For
	 delayed autoselection the window is usually the window's text
	 area including the margins.  */
      if (WINDOWP (window)
	  && !EQ (window, last_mouse_window)
	  && !EQ (window, selected_window))
	{
	  EVENT_INIT (inputEvent);
	  inputEvent.arg = Qnil;
	  inputEvent.kind = SELECT_WINDOW_EVENT;
	  inputEvent.frame_or_window = window;
	  [self sendAction:action to:target];
	}
      /* Remember the last window where we saw the mouse.  */
      last_mouse_window = window;
    }

  if (![frameController noteMouseMovement:point])
    help_echo_string = previous_help_echo_string;
  else
    [frameController noteToolBarMouseMovement:theEvent];

  /* If the contents of the global variable help_echo_string has
     changed, generate a HELP_EVENT.  */
  if (!NILP (help_echo_string) || !NILP (previous_help_echo_string))
    {
      EVENT_INIT (inputEvent);
      inputEvent.arg = Qnil;
      inputEvent.kind = HELP_EVENT;
      XSETFRAME (inputEvent.frame_or_window, f);
      [self sendAction:action to:target];
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
  [self mouseMoved:theEvent];
}

- (void)rightMouseDragged:(NSEvent *)theEvent
{
  [self mouseMoved:theEvent];
}

- (void)otherMouseDragged:(NSEvent *)theEvent
{
  [self mouseMoved:theEvent];
}

- (void)pressureChangeWithEvent:(NSEvent *)event
{
  NSInteger stage = [event stage];

  if (pressureEventStage != stage)
    {
      if (stage == 2
	  && [[NSUserDefaults standardUserDefaults]
	       boolForKey:@"com.apple.trackpad.forceClick"])
	[NSApp sendAction:@selector(quickLookPreviewItems:) to:nil from:nil];
      pressureEventStage = stage;
    }
}

- (void)cursorUpdate:(NSEvent *)event
{
  struct frame *f = [self emacsFrame];

  mac_cursor_set (f->output_data.mac->current_cursor);
}

- (void)keyDown:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;
  CGEventRef cgevent = [theEvent coreGraphicsEvent];
  CGEventFlags mapped_flags;

  [NSCursor setHiddenUntilMouseMoves:YES];

  /* If mouse-highlight is an integer, input clears out mouse
     highlighting.  */
  if (!hlinfo->mouse_face_hidden && FIXNUMP (Vmouse_highlight)
      && !EQ (f->tool_bar_window, hlinfo->mouse_face_window)
      && !EQ (f->tab_bar_window, hlinfo->mouse_face_window))
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      [frameController clearMouseFace:hlinfo];
      hlinfo->mouse_face_hidden = true;
    }

  mapped_flags = mac_cgevent_to_input_event (cgevent, NULL);

  if (!(mapped_flags
	& ~(mac_pass_control_to_system ? kCGEventFlagMaskControl : 0))
      /* This is a workaround: some input methods on macOS 10.13 -
	 10.13.1 do not recognize Control+Space even if it is
	 unchecked in the system-wide short cut settings
	 (rdar://33842041).  */
      && !(1561 <= NSAppKitVersionNumber && NSAppKitVersionNumber < 1561.2
	   && (([theEvent modifierFlags]
		& NSEventModifierFlagDeviceIndependentFlagsMask)
	       == NSEventModifierFlagControl)
	   && [[theEvent charactersIgnoringModifiers] isEqualToString:@" "]))
    {
      keyEventsInterpreted = YES;
      rawKeyEvent = theEvent;
      rawKeyEventHasMappedFlags = (mapped_flags != 0);
      [self interpretKeyEvents:@[theEvent]];
      rawKeyEvent = nil;
      rawKeyEventHasMappedFlags = NO;
      if (keyEventsInterpreted)
	return;
    }

  if ([theEvent type] == NSEventTypeKeyUp)
    return;

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  XSETFRAME (inputEvent.frame_or_window, f);
  mac_cgevent_to_input_event (cgevent, &inputEvent);
  if (inputEvent.kind != NO_EVENT)
    [self sendAction:action to:target];
}

- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange
{
  /* Input methods may call this outside key event handling, for
     example from a candidate window.  */
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self insertText:aString
			       replacementRange:replacementRange]);

  struct frame *f = [self emacsFrame];
  NSString *charactersForASCIIKeystroke = nil;
  Lisp_Object arg = Qnil;

  /* While executing AppleScript, key events are directly delivered to
     the first responder's insertText:replacementRange: (not via
     keyDown:).  These are confusing, so we defer them.  */
  if (deferred_key_events)
    {
      EventRef event = GetCurrentEvent ();
      OSType class = GetEventClass (event);
      UInt32 kind = GetEventKind (event);

      if (class == kEventClassKeyboard
	  && (kind == kEventRawKeyDown || kind == kEventRawKeyRepeat))
	CFArrayAppendValue (deferred_key_events, event);

      return;
    }

  if (rawKeyEvent && ![self hasMarkedText])
    {
      unichar character;

      if (rawKeyEventHasMappedFlags
	  || [rawKeyEvent type] == NSEventTypeKeyUp
	  || ([aString isKindOfClass:NSString.class]
	      && [aString isEqualToString:[rawKeyEvent characters]]
	      && [(NSString *)aString length] == 1
	      && ((character = [aString characterAtIndex:0]) < 0x80
		  /* NSEvent reserves the following Unicode characters
		     for function keys on the keyboard.  */
		  || (character >= 0xf700 && character <= 0xf74f))))
	{
	  /* Process it in keyDown:.  */
	  keyEventsInterpreted = NO;

	  return;
	}
    }

  [self setMarkedText:nil];

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  inputEvent.timestamp = [[NSApp currentEvent] timestamp] * 1000;
  XSETFRAME (inputEvent.frame_or_window, f);

  if ([aString isKindOfClass:NSString.class])
    {
      NSUInteger i, length = [(NSString *)aString length];
      unichar character;

      for (i = 0; i < length; i++)
	{
	  character = [aString characterAtIndex:i];
	  if (!(character >= 0x20 && character <= 0x7f))
	    break;
	}

      if (i == length)
	{
	  /* ASCII only.  Store a text-input/insert-text event to
	     clear the marked text, and store ASCII keystroke events.  */
	  charactersForASCIIKeystroke = aString;
	  aString = @"";
	}
    }

  if (!NSEqualRanges (replacementRange, NSMakeRange (NSNotFound, 0)))
    arg = Fcons (Fcons (build_string ("replacementRange"),
			Fcons (build_string ("Lisp"),
			       Fcons (make_fixnum (replacementRange.location),
				      make_fixnum (replacementRange.length)))),
		 arg);

  inputEvent.kind = MAC_APPLE_EVENT;
  inputEvent.x = Qtext_input;
  inputEvent.y = Qinsert_text;
  inputEvent.arg =
    Fcons (build_string ("aevt"),
	   Fcons (Fcons (build_string ("----"),
			 Fcons (build_string ("Lisp"),
				[aString UTF16LispString])), arg));
  [self sendAction:action to:target];

  if (charactersForASCIIKeystroke)
    {
      NSUInteger i, length = [charactersForASCIIKeystroke length];

      inputEvent.kind = ASCII_KEYSTROKE_EVENT;
      for (i = 0; i < length; i++)
	{
	  inputEvent.code = [charactersForASCIIKeystroke characterAtIndex:i];
	  [self sendAction:action to:target];
	}
    }
  /* This is necessary for insertions by press-and-hold to be
     responsive.  */
  if (rawKeyEvent == nil)
    [NSApp postDummyEvent];
}

- (void)doCommandBySelector:(SEL)aSelector
{
  keyEventsInterpreted = NO;
}

- (void)setMarkedText:(id)aString selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self setMarkedText:aString
				      selectedRange:selectedRange
				   replacementRange:replacementRange]);

  struct frame *f = [self emacsFrame];
  Lisp_Object arg = Qnil;

  [self setMarkedText:aString];

  if (!NSEqualRanges (replacementRange, NSMakeRange (NSNotFound, 0)))
    arg = Fcons (Fcons (build_string ("replacementRange"),
			Fcons (build_string ("Lisp"),
			       Fcons (make_fixnum (replacementRange.location),
				      make_fixnum (replacementRange.length)))),
		 arg);

  arg = Fcons (Fcons (build_string ("selectedRange"),
		      Fcons (build_string ("Lisp"),
			     Fcons (make_fixnum (selectedRange.location),
				    make_fixnum (selectedRange.length)))),
	       arg);

  EVENT_INIT (inputEvent);
  inputEvent.kind = MAC_APPLE_EVENT;
  inputEvent.x = Qtext_input;
  inputEvent.y = Qset_marked_text;
  inputEvent.arg = Fcons (build_string ("aevt"),
			  Fcons (Fcons (build_string ("----"),
					Fcons (build_string ("Lisp"),
					       [aString UTF16LispString])),
				 arg));
  inputEvent.timestamp = [[NSApp currentEvent] timestamp] * 1000;
  XSETFRAME (inputEvent.frame_or_window, f);
  [self sendAction:action to:target];
  /* This is necessary for candidate selection from touch bar to be
     responsive.  */
  if (rawKeyEvent == nil)
    [NSApp postDummyEvent];
}

- (void)unmarkText
{
  if ([self hasMarkedText])
    [self insertText:markedText replacementRange:(NSMakeRange (NSNotFound, 0))];
}

- (BOOL)hasMarkedText
{
  /* The cast below is just for determining the return type.  The
     object `markedText' might be of class NSAttributedString.

     Strictly speaking, `markedText != nil &&' is not necessary
     because message to nil is defined to return 0 as NSUInteger, but
     we keep this as markedText is likely to be nil in most cases.  */
  return markedText != nil && [(NSString *)markedText length] != 0;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)aRange
						actualRange:(NSRangePointer)actualRange
{
  MAC_LOOP_QUERY_NEEDS_LISP (NSAttributedString *, nil,
			     [self attributedSubstringForProposedRange:aRange
							  actualRange:actualRange]);

  NSRange markedRange = [self markedRange];
  NSAttributedString *result = nil;

  if ([self hasMarkedText]
      && NSEqualRanges (NSUnionRange (markedRange, aRange), markedRange))
    {
      NSRange range = NSMakeRange (aRange.location - markedRange.location,
				   aRange.length);

      if ([markedText isKindOfClass:NSAttributedString.class])
	result = [markedText attributedSubstringFromRange:range];
      else
	{
	  NSString *string = [markedText substringWithRange:range];

	  result = MRC_AUTORELEASE ([[NSAttributedString alloc]
				      initWithString:string]);
	}

      if (actualRange)
	*actualRange = aRange;
    }
  else if ((poll_suppress_count != 0 || NILP (Vinhibit_quit))
	   /* Might be called during the select emulation.  */
	   && mac_try_buffer_and_glyph_matrix_access ())
    {
      struct frame *f = [self emacsFrame];
      struct window *w = XWINDOW (f->selected_window);
      struct buffer *b = XBUFFER (w->contents);

      /* Are we in a window whose display is up to date?
	 And verify the buffer's text has not changed.  */
      if (w->window_end_valid && !window_outdated (w))
	{
	  NSRange range;
	  CFStringRef string =
	    mac_ax_create_string_for_range (f, (CFRange *) &aRange,
					    (CFRange *) &range);

	  if (string)
	    {
	      NSMutableAttributedString *attributedString =
		MRC_AUTORELEASE ([[NSMutableAttributedString alloc]
				   initWithString:((__bridge NSString *)
						   string)]);
	      int last_face_id = DEFAULT_FACE_ID;
	      NSFont *lastFont =
		[NSFont fontWithFace:(FACE_FROM_ID (f, last_face_id))];
	      EMACS_INT start_charpos, end_charpos;
	      struct glyph_row *r1, *r2;

	      start_charpos = BUF_BEGV (b) + range.location;
	      end_charpos = start_charpos + range.length;
	      [attributedString beginEditing];
	      [attributedString addAttribute:NSFontAttributeName
				       value:lastFont
				       range:(NSMakeRange (0, range.length))];
	      rows_from_pos_range (w, start_charpos, end_charpos, Qnil,
				   &r1, &r2);
	      if (r1 == NULL || r2 == NULL)
		{
		  struct glyph_row *first, *last;

		  first = MATRIX_FIRST_TEXT_ROW (w->current_matrix);
		  last = MATRIX_ROW (w->current_matrix, w->window_end_vpos);
		  if (start_charpos <= MATRIX_ROW_END_CHARPOS (last)
		      && end_charpos > MATRIX_ROW_START_CHARPOS (first))
		    {
		      if (r1 == NULL)
			r1 = first;
		      if (r2 == NULL)
			r2 = last;
		    }
		}
	      if (r1 && r2)
		for (; r1 <= r2; r1++)
		  {
		    struct glyph *glyph;

		    for (glyph = r1->glyphs[TEXT_AREA];
			 glyph < r1->glyphs[TEXT_AREA] + r1->used[TEXT_AREA];
			 glyph++)
		      if (BUFFERP (glyph->object)
			  && glyph->charpos >= start_charpos
			  && glyph->charpos < end_charpos
			  && (glyph->type == CHAR_GLYPH
			      || glyph->type == COMPOSITE_GLYPH)
			  && !glyph->glyph_not_available_p)
			{
			  NSRange attributeRange =
			    (glyph->type == CHAR_GLYPH
			     ? NSMakeRange (glyph->charpos - start_charpos, 1)
			     : [[attributedString string]
				 rangeOfComposedCharacterSequenceAtIndex:(glyph->charpos - start_charpos)]);

			  if (last_face_id != glyph->face_id)
			    {
			      last_face_id = glyph->face_id;
			      lastFont =
				[NSFont fontWithFace:(FACE_FROM_ID
						      (f, last_face_id))];
			    }
			  [attributedString addAttribute:NSFontAttributeName
						   value:lastFont
						   range:attributeRange];
			}
		  }
	      [attributedString endEditing];
	      result = attributedString;

	      if (actualRange)
		*actualRange = range;

	      CFRelease (string);
	    }
	}
      mac_end_buffer_and_glyph_matrix_access ();
    }

  return result;
}

- (NSRange)markedRange
{
  MAC_LOOP_QUERY_NEEDS_LISP (NSRange, NSMakeRange (NSNotFound, 0),
			     [self markedRange]);

  NSUInteger location = NSNotFound;

  if (![self hasMarkedText])
    return NSMakeRange (NSNotFound, 0);

  if (OVERLAYP (Vmac_ts_active_input_overlay)
      && !NILP (Foverlay_get (Vmac_ts_active_input_overlay, Qbefore_string))
      && !NILP (Foverlay_buffer (Vmac_ts_active_input_overlay)))
    location = OVERLAY_START (Vmac_ts_active_input_overlay) - BEGV;

  /* The cast below is just for determining the return type.  The
     object `markedText' might be of class NSAttributedString.  */
  return NSMakeRange (location, [(NSString *)markedText length]);
}

- (NSRange)selectedRange
{
  MAC_LOOP_QUERY_NEEDS_LISP (NSRange, NSMakeRange (NSNotFound, 0),
			     [self selectedRange]);

  struct frame *f = [self emacsFrame];
  NSRange result;

  /* Might be called when deactivating TSM document inside [emacsView
     removeFromSuperview] in -[EmacsFrameController closeWindow] on
     macOS 10.13.  */
  if (!WINDOWP (f->root_window)
      /* Also might be called during the select emulation.  */
      || !mac_try_buffer_and_glyph_matrix_access ())
    return NSMakeRange (NSNotFound, 0);

  mac_ax_selected_text_range (f, (CFRange *) &result);
  mac_end_buffer_and_glyph_matrix_access ();

  return result;
}

static bool
mac_ts_active_input_string_in_echo_area_p (struct frame *f)
{
  Lisp_Object val = buffer_local_value (intern ("isearch-mode"),
					XWINDOW (f->selected_window)->contents);

  if (!(NILP (val) || BASE_EQ (val, Qunbound)))
    return true;

  if (OVERLAYP (Vmac_ts_active_input_overlay)
      && !NILP (Foverlay_get (Vmac_ts_active_input_overlay, Qbefore_string)))
    return false;

  for (Lisp_Object msg = current_message (); STRINGP (msg);
       msg = Fget_text_property (make_fixnum (0), Qdisplay, msg))
    if (!NILP (Fget_text_property (make_fixnum (0), Qmac_ts_active_input_string,
				   msg))
	|| !NILP (Fnext_single_property_change (make_fixnum (0),
						Qmac_ts_active_input_string,
						msg, Qnil)))
      return true;

  return false;
}

- (NSRect)firstRectForCharacterRange:(NSRange)aRange
			 actualRange:(NSRangePointer)actualRange
{
  MAC_LOOP_QUERY_NEEDS_LISP (NSRect, NSZeroRect,
			     [self firstRectForCharacterRange:aRange
						  actualRange:actualRange]);

  NSRect rect = NSZeroRect;
  struct frame *f = NULL;

  if (mac_try_buffer_and_glyph_matrix_access ())
    {
      struct window *w;
      NSRange markedRange = self.markedRange;

      if (aRange.location >= NSNotFound
	  || (self.hasMarkedText
	      && NSEqualRanges (NSUnionRange (markedRange, aRange),
				markedRange)))
	{
	  /* Probably asking the location of the marked text.
	     Strictly speaking, it is impossible to get the correct
	     one in general because events pending in the Lisp queue
	     may change some states about display.  In particular,
	     this method might be called before displaying the marked
	     text.

	     We return the current cursor position either in the
	     selected window or in the echo area (during isearch, for
	     example) as an approximate value.  */
	  struct glyph *glyph = NULL;

	  if (WINDOWP (echo_area_window)
	      && mac_ts_active_input_string_in_echo_area_p (self.emacsFrame))
	    {
	      w = XWINDOW (echo_area_window);
	      f = WINDOW_XFRAME (w);
	      glyph = get_phys_cursor_glyph (w);
	    }
	  if (glyph == NULL)
	    {
	      f = self.emacsFrame;
	      w = XWINDOW (f->selected_window);
	      glyph = get_phys_cursor_glyph (w);
	    }
	  if (glyph)
	    {
	      int x, y, h;
	      struct glyph_row *row = MATRIX_ROW (w->current_matrix,
						  w->phys_cursor.vpos);

	      get_phys_cursor_geometry (w, row, glyph, &x, &y, &h);

	      rect = NSMakeRect (x, y, w->phys_cursor_width, h);
	      if (actualRange)
		*actualRange = aRange;
	    }
	}
      else
	{
	  f = self.emacsFrame;
	  w = XWINDOW (f->selected_window);

	  /* Are we in a window whose display is up to date?
	     And verify the buffer's text has not changed.  */
	  if (w->window_end_valid && !window_outdated (w))
	    rect =
	      NSRectFromCGRect (mac_get_first_rect_for_range (w, ((CFRange *)
								  &aRange),
							      ((CFRange *)
							       actualRange)));
	}
      mac_end_buffer_and_glyph_matrix_access ();
    }

  if (actualRange && NSEqualRects (rect, NSZeroRect))
    *actualRange = NSMakeRange (NSNotFound, 0);

  if (f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      rect = [frameController convertEmacsViewRectToScreen:rect];
    }

  return rect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)thePoint
{
  MAC_LOOP_QUERY_NEEDS_LISP (NSUInteger, NSNotFound,
			     [self characterIndexForPoint:thePoint]);

  NSUInteger result = NSNotFound;
  NSPoint point;
  Lisp_Object window;
  enum window_part part;
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  struct window *w;
  struct buffer *b;
  int x, y;

  point = [frameController convertEmacsViewPointFromScreen:thePoint];
  x = point.x;
  y = point.y;
  window = window_from_coordinates (f, x, y, &part, false, false, false);
  if (!WINDOWP (window) || !EQ (window, f->selected_window))
    return result;

  /* Convert to window-relative pixel coordinates.  */
  w = XWINDOW (window);
  frame_to_window_pixel_xy (w, &x, &y);

  /* Are we in a window whose display is up to date?
     And verify the buffer's text has not changed.  */
  b = XBUFFER (w->contents);
  if (part == ON_TEXT && w->window_end_valid && !window_outdated (w))
    {
      int hpos, vpos, area;
      struct glyph *glyph;

      /* Find the glyph under X/Y.  */
      glyph = x_y_to_hpos_vpos (w, x, y, &hpos, &vpos, 0, 0, &area);

      if (glyph != NULL && area == TEXT_AREA
	  && BUFFERP (glyph->object) && glyph->charpos <= BUF_Z (b))
	result = glyph->charpos - BUF_BEGV (b);
    }

  return result;
}

- (NSArrayOf (NSString *) *)validAttributesForMarkedText
{
  return nil;
}

- (NSString *)string
{
  struct frame *f = [self emacsFrame];
  CFRange range;
  CFStringRef string;

  /* Don't try to get buffer contents as the gap might be being
     altered. */
  if ((poll_suppress_count == 0 && !NILP (Vinhibit_quit))
      /* Might be called during the select emulation.  */
      || !mac_try_buffer_and_glyph_matrix_access ())
    return nil;

  range = CFRangeMake (0, mac_ax_number_of_characters (f));
  string = mac_ax_create_string_for_range (f, &range, NULL);
  mac_end_buffer_and_glyph_matrix_access ();

  return CFBridgingRelease (string);
}

- (void)synchronizeChildFrameOrigins
{
  struct frame *f = self.emacsFrame;
  Lisp_Object frame, tail;

  FOR_EACH_FRAME (tail, frame)
    if (FRAME_PARENT_FRAME (XFRAME (frame)) == f)
      {
	struct frame *c = XFRAME (frame);

	mac_move_frame_window_structure_1 (c, c->left_pos, c->top_pos);
      }
}

/* Persistent loop (W2/W3): pass the size of each live-resize step to
   Lisp while it is idle, so that it redraws at that size during the
   drag.  While Lisp is busy, skip the step rather than deferring it:
   -viewDidEndLiveResize delivers the final size, and the layer shows
   the last presentation over the frame background meanwhile.  */

- (void)macLoopLiveResizeFrameDidChange
{
  if (!([self autoresizingMask] & (NSViewWidthSizable | NSViewHeightSizable)))
    return;

  int token = mac_loop_begin_lisp_access ();
  NSRect frameRect = [self frame];

  MAC_TRACE_LOOP ("live resize step %.0fx%.0f %s\n", NSWidth (frameRect),
		  NSHeight (frameRect),
		  token == MAC_LOOP_NO_ACCESS ? "skipped" : "applied");
  if (token == MAC_LOOP_NO_ACCESS)
    return;

  struct frame *f = [self emacsFrame];

  [self synchronizeChildFrameOrigins];
#ifndef USE_METAL_RENDERING
  backingSizeOutOfSync = YES;
#else
  [self syncMetalDrawableSize];
#endif
  mac_handle_size_change (f, NSWidth (frameRect), NSHeight (frameRect));
  mac_loop_end_lisp_access (token);
  if (token == MAC_LOOP_LOCKED_ACCESS)
    mac_loop_wake_lisp ();
}

- (void)viewDidEndLiveResize
{
  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("end-live-resize", [self viewDidEndLiveResize]);

  struct frame *f = [self emacsFrame];
  NSRect frameRect = [self frame];

  [super viewDidEndLiveResize];
  [self synchronizeChildFrameOrigins];
#ifndef USE_METAL_RENDERING
  backingSizeOutOfSync = YES;
#else
  [self syncMetalDrawableSize];
#endif
  mac_handle_size_change (f, NSWidth (frameRect), NSHeight (frameRect));
  /* Exit from mac_select so as to react to the frame size change,
     especially in a full screen tile on OS X 10.11.  */
  [NSApp postDummyEvent];
}

- (void)viewFrameDidChange:(NSNotification *)notification
{
  if (mac_persistent_loop_p && [self inLiveResize])
    {
      [self macLoopLiveResizeFrameDidChange];
      return;
    }

  MAC_LOOP_STATE_CALLBACK_NEEDS_LISP ("frame", [self viewFrameDidChange:notification]);

  if (![self inLiveResize]
      && ([self autoresizingMask] & (NSViewWidthSizable | NSViewHeightSizable)))
    {
      struct frame *f = [self emacsFrame];
      NSRect frameRect = [self frame];

      [self synchronizeChildFrameOrigins];
      [super viewFrameDidChange:notification];
      mac_handle_size_change (f, NSWidth (frameRect), NSHeight (frameRect));
      /* Exit from mac_select so as to react to the frame size
	 change.  */
      [NSApp postDummyEvent];
    }
}

- (void)viewDidHide
{
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController updateEmacsViewIsHiddenOrHasHiddenAncestor];

  mac_handle_visibility_change (f);
}

- (void)viewDidUnhide
{
  [self viewDidHide];
}

- (NSTouchBar *)makeTouchBar
{
  NSTouchBar *mainBar = [[NS_TOUCH_BAR alloc] init];

  mainBar.delegate = self;
  mainBar.defaultItemIdentifiers =
    @[NS_TOUCH_BAR_ITEM_IDENTIFIER_CHARACTER_PICKER,
      NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST];

  return MRC_AUTORELEASE (mainBar);
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
  NSTouchBarItem *result = nil;

  if ([identifier isEqualToString:NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST])
    {
      if (candidateListTouchBarItem == nil)
	candidateListTouchBarItem =
	  [[NS_CANDIDATE_LIST_TOUCH_BAR_ITEM alloc]
	    initWithIdentifier:NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST];
      result = candidateListTouchBarItem;
    }

  return result;
}

- (NSCandidateListTouchBarItem *)candidateListTouchBarItem
{
  return candidateListTouchBarItem;
}

@end				// EmacsMainView

#ifdef USE_METAL_RENDERING
/* Under Metal rendering, the CG drawing pipeline is not used.
   mac_draw_queue_sync is kept as a no-op because it is called from
   event handling code that runs under both paths.  */

static void
mac_draw_queue_sync (void)
{
  /* No-op under Metal.  */
}

#else  /* !USE_METAL_RENDERING */

#define FRAME_CG_CONTEXT(f)	((f)->output_data.mac->cg_context)

/* Emacs frame containing the globally focused NSView.  */
static struct frame *global_focus_view_frame;
/* Whether view's core animation layer contents are out of sync with
   the backing bitmap and need to be updated.  */
static bool global_focus_view_modified_p;
/* -[EmacsView drawRect:] might be called during update_frame.  */
static struct frame *saved_focus_view_frame;
static CGContextRef saved_focus_view_context;
static bool saved_focus_view_modified_p;
#if DRAWING_USE_GCD
static dispatch_queue_t global_focus_drawing_queue;
static const void * kDrawingQueueKey = &kDrawingQueueKey;
#endif

static void
set_global_focus_view_frame (struct frame *f)
{
  saved_focus_view_frame = global_focus_view_frame;
  if (f != global_focus_view_frame)
    {
      if (saved_focus_view_frame)
	{
	  saved_focus_view_context = FRAME_CG_CONTEXT (saved_focus_view_frame);
	  saved_focus_view_modified_p = global_focus_view_modified_p;
	}
      global_focus_view_frame = f;
      global_focus_view_modified_p = false;
    }
  FRAME_CG_CONTEXT (f) = [[NSGraphicsContext currentContext] CGContext];
#if DRAWING_USE_GCD
  if (mac_drawing_use_gcd)
    {
      if (global_focus_drawing_queue == NULL)
        {
          global_focus_drawing_queue =
            dispatch_queue_create ("org.gnu.Emacs.drawing", NULL);
          dispatch_queue_set_specific(global_focus_drawing_queue, kDrawingQueueKey,
                                      (void *)kDrawingQueueKey, NULL);
        }
    }
  else
    {
      if (global_focus_drawing_queue)
	{
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
	  dispatch_release (global_focus_drawing_queue);
#endif
	  global_focus_drawing_queue = NULL;
	}
    }
#endif
}

static void
mac_draw_queue_sync (void)
{
#if DRAWING_USE_GCD
  if (global_focus_drawing_queue &&
      /* Avoid deadlock if already on the drawing queue */
      !dispatch_get_specific(kDrawingQueueKey))
      dispatch_sync (global_focus_drawing_queue, ^{});
#endif
}

static void
mac_draw_queue_dispatch_async (void (^block) (void))
{
#if DRAWING_USE_GCD
  if (global_focus_drawing_queue)
    dispatch_async (global_focus_drawing_queue, block);
  else
#endif
    block ();
}

static void
unset_global_focus_view_frame (void)
{
  mac_draw_queue_sync ();

  if (global_focus_view_frame != saved_focus_view_frame)
    {
      FRAME_CG_CONTEXT (global_focus_view_frame) = NULL;
      if (FRAME_MAC_DOUBLE_BUFFERED_P (global_focus_view_frame)
	  && global_focus_view_modified_p)
	{
	  EmacsFrameController *frameController =
	    FRAME_CONTROLLER (global_focus_view_frame);

	  [frameController setEmacsViewNeedsDisplay:YES];
	}
      global_focus_view_frame = saved_focus_view_frame;
      if (global_focus_view_frame)
	{
	  FRAME_CG_CONTEXT (global_focus_view_frame) = saved_focus_view_context;
	  global_focus_view_modified_p = saved_focus_view_modified_p;
	}
    }
  saved_focus_view_frame = NULL;
}

#if DRAWING_USE_GCD
static
#endif
CGContextRef
mac_begin_cg_clip (struct frame *f, GC gc, CGRect invalid_rect)
{
  CGContextRef context;
  const CGRect *clip_rects;
  CFIndex n_clip_rects;

  clip_rects = mac_gc_clip_rects (gc, &n_clip_rects);

  if (global_focus_view_frame != f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{
	  [frameController lockFocusOnEmacsView];
	  FRAME_CG_CONTEXT (f) = [[NSGraphicsContext currentContext] CGContext];
	});
    }

  context = FRAME_CG_CONTEXT (f);
  CGContextSaveGState (context);
  if (n_clip_rects)
    CGContextClipToRects (context, clip_rects, n_clip_rects);
  if (FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      [frameController invalidateEmacsViewBackingRect:invalid_rect
					    clipRects:clip_rects
						count:n_clip_rects
					 forCGContext:context];
    }

  return context;
}

#if DRAWING_USE_GCD
static
#endif
void
mac_end_cg_clip (struct frame *f)
{
  CGContextRestoreGState (FRAME_CG_CONTEXT (f));
  if (global_focus_view_frame != f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{
	  [frameController unlockFocusOnEmacsView];
	  FRAME_CG_CONTEXT (f) = NULL;
	  if (FRAME_MAC_DOUBLE_BUFFERED_P (f))
	    [frameController setEmacsViewNeedsDisplay:YES];
	});
    }
  else
    global_focus_view_modified_p = true;
}

#if DRAWING_USE_GCD
void
mac_draw_to_frame (struct frame *f, GC gc, CGRect invalid_rect,
		   void (^block) (CGContextRef, GC))
{
  CGContextRef context;

  if (global_focus_view_frame != f || global_focus_drawing_queue == NULL)
    {
      context = mac_begin_cg_clip (f, gc, invalid_rect);
      block (context, gc);
      mac_end_cg_clip (f);
    }
  else
    {
      const CGRect *clip_rects;
      CFIndex n_clip_rects;

      context = FRAME_CG_CONTEXT (f);
      gc = mac_duplicate_gc (gc);
      clip_rects = mac_gc_clip_rects (gc, &n_clip_rects);

      dispatch_async (global_focus_drawing_queue, ^{
	  CGContextSaveGState (context);
	  if (n_clip_rects)
	    CGContextClipToRects (context, clip_rects, n_clip_rects);
	  if (FRAME_MAC_DOUBLE_BUFFERED_P (f))
	    {
	      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

	      [frameController invalidateEmacsViewBackingRect:invalid_rect
						    clipRects:clip_rects
							count:n_clip_rects
						 forCGContext:context];
	    }
	  block (context, gc);
	  CGContextRestoreGState (context);
	  mac_free_gc (gc);
	});

      global_focus_view_modified_p = true;
    }
}
#endif

/* Mac replacement for XCopyArea: used only for scrolling.  */

void
mac_scroll_area (struct frame *f, GC gc, int src_x, int src_y,
		 int width, int height, int dest_x, int dest_y)
{
  eassert (global_focus_view_frame);
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSRect rect = NSMakeRect (src_x, src_y, width, height);
  NSSize offset = NSMakeSize (dest_x - src_x, dest_y - src_y);

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      mac_draw_queue_sync ();
      mac_within_gui (^{[frameController scrollEmacsViewRect:rect by:offset];});

      return;
    }
#endif
  mac_draw_queue_dispatch_async (^{
      [frameController scrollEmacsViewRect:rect by:offset];
    });
  global_focus_view_modified_p = true;
}

#endif /* !USE_METAL_RENDERING */

@implementation EmacsOverlayView

- (void)setHighlighted:(BOOL)flag
{
  CALayer *layer = [self layer];

  if (flag)
    {
      CGColorRef __block borderColor;

      mac_with_current_drawing_appearance (self.effectiveAppearance, ^{
	  borderColor = CGColorRetain (NSColor.selectedControlColor.CGColor);
	});

      [layer setValue:((id) kCFBooleanTrue) forKey:@"showingBorder"];

      [CATransaction setDisableActions:YES];
      layer.borderColor = borderColor;
      CGColorRelease (borderColor);
      [CATransaction commit];

      layer.borderWidth = 3.0;
    }
  else
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
	layer.borderWidth = 0;
      } completionHandler:^{
	[layer setValue:((id) kCFBooleanFalse) forKey:@"showingBorder"];
      }];
}

- (NSView *)hitTest:(NSPoint)point
{
  return nil;
}

@end				// EmacsOverlayView


/************************************************************************
				Color
 ************************************************************************/

Lisp_Object
mac_color_lookup (const char *color_name)
{
  Lisp_Object __block result = Qnil;
  char *colon;
  NSColorListName listName = @"System";
  NSColor *color = nil;

  /* color_name is of the form either "mac:COLOR_LIST_NAME:COLOR_NAME"
     or "mac:COLOR_NAME".  The latter form is for system colors.  */
  if (strncasecmp (color_name, "mac:", 4) != 0)
    return Qnil;

  color_name += sizeof ("mac:") - 1;
  colon = strchr (color_name, ':');
  if (colon)
    {
      listName = MRC_AUTORELEASE ([[NSString alloc]
				    initWithBytes:color_name
					   length:(colon - color_name)
					 encoding:NSUTF8StringEncoding]);
      color_name = colon + 1;
    }
  if (listName)
    {
      NSColorName colorName = @(color_name);
      NSColorList *colorList = [NSColorList colorListNamed:listName];

      if (!colorList)
	for (NSColorList *list in NSColorList.availableColorLists)
	  if ([list.name localizedCaseInsensitiveCompare:listName]
	      == NSOrderedSame)
	    {
	      colorList = list;
	      break;
	    }

      color = [colorList colorWithKey:colorName];
      if (!color && colorList)
	for (NSColorName key in colorList.allKeys)
	  if ([key localizedCaseInsensitiveCompare:colorName] == NSOrderedSame)
	    {
	      color = [colorList colorWithKey:key];
	      break;
	    }
    }

  if (!color)
    return Qnil;

  NSAppearance *appearance =
    ([NSApp respondsToSelector:@selector(effectiveAppearance)]
     ? [NSApp effectiveAppearance]
     : [NSAppearance appearanceNamed:NSAppearanceNameAqua]);

  mac_with_current_drawing_appearance (appearance, ^{
      CGFloat components[4];

      if ([color getSRGBComponents:components])
	result = make_fixnum (RGB_TO_ULONG ((int) (components[0] * 255 + .5),
					    (int) (components[1] * 255 + .5),
					    (int) (components[2] * 255 + .5)));
    });

  return result;
}

Lisp_Object
mac_color_list_alist (void)
{
  Lisp_Object result = Qnil;

  for (NSColorList *colorList in NSColorList.availableColorLists)
    {
      Lisp_Object color_list = Qnil;

      for (NSColorName key in colorList.allKeys)
	color_list = Fcons (key.lispString, color_list);

      result = Fcons (Fcons (colorList.name.lispString, Fnreverse (color_list)),
		      result);
    }

  return Fnreverse (result);
}


/************************************************************************
			Multi-monitor support
 ************************************************************************/

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101500
static NSArrayOf (NSDictionary *) *
mac_display_get_info_dictionaries (IOOptionBits options)
{
  NSMutableArrayOf (NSDictionary *) *result =
    [NSMutableArray arrayWithCapacity:0];
  CFDictionaryRef matching = IOServiceMatching ("IODisplayConnect");

  if (matching)
    {
      io_iterator_t existing;
      kern_return_t kr = IOServiceGetMatchingServices (kIOMasterPortDefault,
						       matching, &existing);

      if (kr == KERN_SUCCESS)
	{
	  io_object_t service;

	  while ((service = IOIteratorNext (existing)) != 0)
	    {
	      CFDictionaryRef dictionary =
		IODisplayCreateInfoDictionary (service, options);

	      if (dictionary)
		[result addObject:(CFBridgingRelease (dictionary))];
	    }
	  IOObjectRelease (existing);
	}
    }

  return result;
}

static CFDictionaryRef
mac_display_copy_info_dictionary_for_cgdisplay (CGDirectDisplayID displayID,
						NSArrayOf (NSDictionary *)
						*infoDictionaries)
{
  CFDictionaryRef __block result = NULL;
  NSMutableDictionaryOf (NSString *, NSNumber *) *info =
    [NSMutableDictionary dictionaryWithCapacity:3];
  uint32_t val;

  val = CGDisplayVendorNumber (displayID);
  if (val != kDisplayVendorIDUnknown && val != 0xFFFFFFFF)
    /* According to IODisplayLib.c in IOKitUser, a dictionary created
       with IODisplayCreateInfoDictionary maps the kDisplayVendorID
       (or kDisplayProductID, kDisplaySerialNumber) key to a SInt32
       value, whereas the return type of CGDisplayVendorNumber (or
       CGDisplayModelNumber, CGDisplaySerialNumber) is uint32_t.  */
    info[@kDisplayVendorID] = @(val);

  val = CGDisplayModelNumber (displayID);
  if (val != kDisplayProductIDGeneric && val != 0xFFFFFFFF)
    info[@kDisplayProductID] = @(val);

  val = CGDisplaySerialNumber (displayID);
  if (val != 0x00000000 && val != 0xFFFFFFFF)
    info[@kDisplaySerialNumber] = @(val);

  [infoDictionaries enumerateObjectsUsingBlock:
		      ^(NSDictionary *dictionary, NSUInteger idx, BOOL *stop) {
      if (IODisplayMatchDictionaries ((__bridge CFDictionaryRef) dictionary,
				      (__bridge CFDictionaryRef) info,
				      kNilOptions))
	{
	  result = CFBridgingRetain (dictionary);
	  *stop = YES;
	}
    }];

  return result;
}
#endif

Lisp_Object
mac_display_monitor_attributes_list (struct mac_display_info *dpyinfo)
{
  Lisp_Object attributes_list = Qnil, rest, frame;
  NSRect baseScreenFrame = mac_get_base_screen_frame ();
  CGFloat baseScreenFrameMinX = NSMinX (baseScreenFrame);
  CGFloat baseScreenFrameMaxY = NSMaxY (baseScreenFrame);
  NSArrayOf (NSScreen *) *screens = [NSScreen screens];
  NSUInteger i, count = [screens count];
  Lisp_Object monitor_frames = Fmake_vector (make_fixnum (count), Qnil);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101500
  NSArrayOf (NSDictionary *) *infoDictionaries =
    mac_display_get_info_dictionaries (kIODisplayOnlyPreferredName);
#endif

  FOR_EACH_FRAME (rest, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f) && FRAME_DISPLAY_INFO (f) == dpyinfo
	  && !FRAME_TOOLTIP_P (f))
	{
	  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
	  NSScreen *screen = [window screen];

	  if (screen == nil)
	    screen = [NSScreen closestScreenForRect:[window frame]];
	  i = [screens indexOfObject:screen];
	  if (i != NSNotFound)
	    ASET (monitor_frames, i, Fcons (frame, AREF (monitor_frames, i)));
	}
    }

  i = count;
  while (i-- > 0)
    {
      Lisp_Object geometry, workarea, attributes = Qnil;
      NSScreen *screen = screens[i];
      CGDirectDisplayID displayID;
      CGSize size;
      NSRect rect;

      attributes = Fcons (Fcons (Qbacking_scale_factor,
				 make_fixnum (screen.backingScaleFactor)),
			  attributes);

      displayID =
	((CGDirectDisplayID)
	 [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
#if HAVE_MAC_METAL
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      if (CGDirectDisplayCopyCurrentMetalDevice != NULL)
#endif
	{
	  id <MTLDevice> device =
	    CGDirectDisplayCopyCurrentMetalDevice (displayID);

	  attributes = Fcons (Fcons (Qmetal_device_name,
				     device ? device.name.lispString : Qnil),
			      attributes);
	  MRC_RELEASE (device);
	}
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101500
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101500
      if ([screen respondsToSelector:@selector(localizedName)])
#endif
	attributes = Fcons (Fcons (Qname, screen.localizedName.lispString),
			    attributes);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101500
      else
#endif
#endif
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101500 || MAC_OS_X_VERSION_MIN_REQUIRED < 101500
	{
	  CFDictionaryRef displayInfo;
	  displayInfo =
	    mac_display_copy_info_dictionary_for_cgdisplay (displayID,
							    infoDictionaries);
	  if (displayInfo)
	    {
	      CFDictionaryRef localizedNames =
		CFDictionaryGetValue (displayInfo, CFSTR (kDisplayProductName));

	      if (localizedNames)
		{
		  NSDictionary *names =
		    (__bridge NSDictionary *) localizedNames;
		  NSString *name = names.objectEnumerator.nextObject;

		  if (name)
		    attributes = Fcons (Fcons (Qname, name.lispString),
					attributes);
		}
	      CFRelease (displayInfo);
	    }
	}
#endif

      attributes = Fcons (Fcons (Qframes, AREF (monitor_frames, i)),
			  attributes);

      size = CGDisplayScreenSize (displayID);
      attributes = Fcons (Fcons (Qmm_size,
				 list2i (size.width + 0.5f,
					 size.height + 0.5f)),
			  attributes);

      rect = [screen visibleFrame];
      workarea = list4i (NSMinX (rect) - baseScreenFrameMinX,
			 - NSMaxY (rect) + baseScreenFrameMaxY,
			 NSWidth (rect), NSHeight (rect));
      attributes = Fcons (Fcons (Qworkarea, workarea), attributes);

      rect = [screen frame];
      geometry = list4i (NSMinX (rect) - baseScreenFrameMinX,
			 - NSMaxY (rect) + baseScreenFrameMaxY,
			 NSWidth (rect), NSHeight (rect));
      attributes = Fcons (Fcons (Qgeometry, geometry), attributes);

      attributes_list = Fcons (attributes, attributes_list);
    }

  return attributes_list;
}


/************************************************************************
			     Scroll bars
 ************************************************************************/

@implementation NonmodalScroller

static NSTimeInterval NonmodalScrollerButtonDelay = 0.5;
static NSTimeInterval NonmodalScrollerButtonPeriod = 1.0 / 20;
static BOOL NonmodalScrollerPagingBehavior;

+ (void)initialize
{
  if (self == NonmodalScroller.class)
    {
      [self updateBehavioralParameters];
      [[NSDistributedNotificationCenter defaultCenter]
	addObserver:self
	   selector:@selector(pagingBehaviorDidChange:)
	       name:@"AppleNoRedisplayAppearancePreferenceChanged"
	     object:nil
	suspensionBehavior:NSNotificationSuspensionBehaviorCoalesce];
    }
}

+ (void)updateBehavioralParameters
{
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

  [userDefaults synchronize];
  /* NSScrollerButtonDelay and NSScrollerButtonPeriod are not
     initialized on macOS 10.15.  */
  if ([userDefaults objectForKey:@"NSScrollerButtonDelay"])
    NonmodalScrollerButtonDelay =
      [userDefaults doubleForKey:@"NSScrollerButtonDelay"];
  if ([userDefaults objectForKey:@"NSScrollerButtonPeriod"])
    NonmodalScrollerButtonPeriod =
      [userDefaults doubleForKey:@"NSScrollerButtonPeriod"];
  NonmodalScrollerPagingBehavior =
    [userDefaults boolForKey:@"AppleScrollerPagingBehavior"];
}

+ (void)pagingBehaviorDidChange:(NSNotification *)notification
{
  [self updateBehavioralParameters];
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  isHorizontal = !(NSHeight (frameRect) >= NSWidth (frameRect));

  return self;
}

#if !USE_ARC
- (void)dealloc
{
  [timer release];
  [super dealloc];
}
#endif

/* Whether mouse drag on knob updates the float value.  Subclass may
   override the definition.  */

- (BOOL)dragUpdatesFloatValue
{
  return YES;
}

/* First delay in seconds for mouse tracking.  Subclass may override
   the definition.  */

- (NSTimeInterval)buttonDelay
{
  return NonmodalScrollerButtonDelay;
}

/* Continuous delay in seconds for mouse tracking.  Subclass may
   override the definition.  */

- (NSTimeInterval)buttonPeriod
{
  return NonmodalScrollerButtonPeriod;
}

/* Whether a click in the knob slot above/below the knob jumps to the
   spot that's clicked.  Subclass may override the definition.  */

- (BOOL)pagingBehavior
{
  return NonmodalScrollerPagingBehavior;
}

- (NSScrollerPart)hitPart
{
  return hitPart;
}

/* Post a dummy mouse dragged event to the main event queue to notify
   timer has expired.  */

- (void)postMouseDraggedEvent:(NSTimer *)theTimer
{
  NSEvent *event =
    [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
		       location:[[self window]
				  mouseLocationOutsideOfEventStream]
		  modifierFlags:[NSEvent modifierFlags] timestamp:0
		   windowNumber:[[self window] windowNumber]
			context:[NSGraphicsContext currentContext]
		    eventNumber:0 clickCount:1 pressure:0];

  [NSApp postEvent:event atStart:NO];
  MRC_RELEASE (timer);
  timer = nil;
}

/* Invalidate timer if any, and set new timer's interval to
   SECONDS.  */

- (void)rescheduleTimer:(NSTimeInterval)seconds
{
  [timer invalidate];

  if (seconds >= 0)
    {
      MRC_RELEASE (timer);
      timer = MRC_RETAIN ([NSTimer scheduledTimerWithTimeInterval:seconds
							   target:self
							 selector:@selector(postMouseDraggedEvent:)
							 userInfo:nil
							  repeats:NO]);
    }
}

- (void)mouseDown:(NSEvent *)theEvent
{
  BOOL jumpsToClickedSpot;

  hitPart = [self testPart:[theEvent locationInWindow]];

  if (hitPart == NSScrollerNoPart)
    return;

  if (hitPart != NSScrollerIncrementPage && hitPart != NSScrollerDecrementPage)
    jumpsToClickedSpot = NO;
  else
    {
      jumpsToClickedSpot = [self pagingBehavior];
      if ([theEvent modifierFlags] & NSEventModifierFlagOption)
	jumpsToClickedSpot = !jumpsToClickedSpot;
    }

  if (hitPart != NSScrollerKnob && !jumpsToClickedSpot)
    {
      [self rescheduleTimer:[self buttonDelay]];
      [self sendAction:[self action] to:[self target]];
    }
  else
    {
      NSPoint point = [self convertPoint:[theEvent locationInWindow]
			    fromView:nil];
      NSRect knobRect;

      knobRect = [self rectForPart:NSScrollerKnob];

      if (jumpsToClickedSpot)
	{
	  NSRect knobSlotRect = [self rectForPart:NSScrollerKnobSlot];

	  if (!isHorizontal)
	    {
	      knobRect.origin.y = point.y - round (NSHeight (knobRect) / 2);
	      if (NSMinY (knobRect) < NSMinY (knobSlotRect))
		knobRect.origin.y = knobSlotRect.origin.y;
#if 0		      /* This might be better if no overscrolling.  */
	      else if (NSMaxY (knobRect) > NSMaxY (knobSlotRect))
		knobRect.origin.y = NSMaxY (knobSlotRect) - NSHeight (knobRect);
#endif
	    }
	  else
	    {
	      knobRect.origin.x = point.x - round (NSWidth (knobRect) / 2);
	      if (NSMinX (knobRect) < NSMinX (knobSlotRect))
		knobRect.origin.x = knobSlotRect.origin.x;
#if 0
	      else if (NSMaxX (knobRect) > NSMaxX (knobSlotRect))
		knobRect.origin.x = NSMaxX (knobSlotRect) - NSWidth (knobRect);
#endif
	    }
	  hitPart = NSScrollerKnob;
	}

      if (!isHorizontal)
	knobGrabOffset = - (point.y - NSMinY (knobRect)) - 1;
      else
	knobGrabOffset = - (point.x - NSMinX (knobRect)) - 1;

      if (jumpsToClickedSpot)
	[self mouseDragged:theEvent];
    }
}

- (void)mouseUp:(NSEvent *)theEvent
{
  NSScrollerPart lastPart = hitPart;

  [self rescheduleTimer:-1];

  hitPart = NSScrollerNoPart;
  if (lastPart != NSScrollerKnob || knobGrabOffset >= 0)
    [self sendAction:[self action] to:[self target]];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
  [self mouseUp:theEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
  [self mouseUp:theEvent];
}

- (void)mouseDragged:(NSEvent *)theEvent
{
  if (hitPart == NSScrollerNoPart)
    return;

  if (hitPart == NSScrollerKnob)
    {
      NSPoint point = [self convertPoint:[theEvent locationInWindow]
			    fromView:nil];
      NSRect knobSlotRect;

      if (knobGrabOffset <= -1)
	knobGrabOffset = - (knobGrabOffset + 1);

      knobSlotRect = [self rectForPart:NSScrollerKnobSlot];
      if (!isHorizontal)
	knobMinEdgeInSlot = point.y - knobGrabOffset - NSMinY (knobSlotRect);
      else
	knobMinEdgeInSlot = point.x - knobGrabOffset - NSMinX (knobSlotRect);

      if ([self dragUpdatesFloatValue])
	{
	  CGFloat maximum, minEdge;
	  NSRect KnobRect = [self rectForPart:NSScrollerKnob];

	  if (!isHorizontal)
	    maximum = NSHeight (knobSlotRect) - NSHeight (KnobRect);
	  else
	    maximum = NSWidth (knobSlotRect) - NSWidth (KnobRect);

	  minEdge = knobMinEdgeInSlot;
	  if (minEdge < 0)
	    minEdge = 0;
	  if (minEdge > maximum)
	    minEdge = maximum;

	  [self setDoubleValue:minEdge/maximum];
	}

      [self sendAction:[self action] to:[self target]];
    }
  else
    {
      BOOL unhilite = NO;
      NSScrollerPart part = [self testPart:[theEvent locationInWindow]];

      if (part == NSScrollerKnob)
	unhilite = YES;
      else
	{
	  switch (hitPart)
	    {
	    case NSScrollerIncrementPage:
	    case NSScrollerDecrementPage:
	      if (part != NSScrollerIncrementPage
		  && part != NSScrollerDecrementPage)
		unhilite = YES;
	      break;
	    default:
	      break;
	    }
	}

      if (!unhilite && (part != hitPart || timer == nil))
	{
	  hitPart = part;
	  [self rescheduleTimer:[self buttonPeriod]];
	  [self sendAction:[self action] to:[self target]];
	}
    }
}

@end				// NonmodalScroller

@implementation EmacsScroller

- (void)viewFrameDidChange:(NSNotification *)notification
{
  BOOL enabled = [self isEnabled], tooSmall = NO;
  double floatValue = [self doubleValue];
  CGFloat knobProportion = [self knobProportion];
  const NSControlSize controlSizes[] =
    {NSControlSizeRegular, NSControlSizeSmall}; /* Descending */
  int i, count = countof (controlSizes);
  NSRect knobRect, bounds = [self bounds];
  CGFloat shorterDimension =
    !isHorizontal ? NSWidth (bounds) : NSHeight (bounds);

  for (i = 0; i < count; i++)
    {
      CGFloat width = [self.class
			  scrollerWidthForControlSize:controlSizes[i]
			  scrollerStyle:NSScrollerStyleLegacy];

      if (shorterDimension >= width)
	{
	  [self setControlSize:controlSizes[i]];
	  break;
	}
    }
  if (i == count)
    tooSmall = YES;

  [self setDoubleValue:0];
  [self setKnobProportion:0];
  [self setEnabled:YES];
  knobRect = [self rectForPart:NSScrollerKnob];
  /* Avoid "Invalid rect passed to CoreUI: {{nan,nan},{nan,nan}}".  */
  if (NSWidth (knobRect) > NSWidth (bounds)
      || NSHeight (knobRect) > NSHeight (bounds)
      || (NSWidth (knobRect) == NSWidth (bounds)
	  && NSHeight (knobRect) == NSHeight (bounds)))
    tooSmall = YES;
  if (!isHorizontal)
    minKnobSpan = NSHeight (knobRect);
  else
    minKnobSpan = NSWidth (knobRect);
  /* The value for knobSlotSpan used to be updated here.  But it seems
     to be too early on Mac OS X 10.7.  We just invalidate it here,
     and update it in the next -[EmacsScroller knobSlotSpan] call.  */
  knobSlotSpan = -1;

  if (!tooSmall)
    {
      [self setEnabled:enabled];
      [self setDoubleValue:floatValue];
      [self setKnobProportion:knobProportion];
    }
  else
    {
      [self setEnabled:NO];
      minKnobSpan = 0;
    }
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(viewFrameDidChange:)
    name:@"NSViewFrameDidChangeNotification"
    object:self];

  [self viewFrameDidChange:nil];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !USE_ARC
  [super dealloc];
#endif
}

- (void)drawRect:(NSRect)aRect
{
  [self.window.backgroundColor set];
  NSRectFill (aRect);
  [super drawRect:aRect];

  NSAppearance *currentDrawingAppearance;

  if (
#if __clang_major__ >= 9
      @available (macOS 10.16, *)
#else
      [NSAppearance respondsToSelector:@selector(currentDrawingAppearance)]
#endif
      )
    currentDrawingAppearance = NSAppearance.currentDrawingAppearance;
  else
    {
      /* Suppress warnings about deprecated declarations.  This #if
	 shouldn't be necessary if the compiler can handle @available
	 above properly.  */
#if MAC_OS_X_VERSION_MIN_REQUIRED < 110000
      currentDrawingAppearance = NSAppearance.currentAppearance;
#else
      emacs_abort ();
#endif
    }
  if (!currentDrawingAppearance.allowsVibrancy
      && !mac_accessibility_display_options.reduce_transparency_p)
    {
      [[self.window.backgroundColor colorWithAlphaComponent:0.25] set];
      NSRectFillUsingOperation ([self rectForPart:NSScrollerKnobSlot],
				NSCompositingOperationSourceOver);
    }
}

- (void)setEmacsScrollBar:(struct scroll_bar *)bar
{
  emacsScrollBar = bar;
}

- (struct scroll_bar *)emacsScrollBar
{
  return emacsScrollBar;
}

- (BOOL)dragUpdatesFloatValue
{
  return NO;
}

- (BOOL)isOpaque
{
  return YES;
}

- (NSAppearance *)effectiveAppearance
{
  NSAppearance *effectiveAppearance = super.effectiveAppearance;

  /* If a scroll bar is drawn with the vibrant light appearance, then
     the backgrounds of the scroll bar and containing Emacs window
     become the same color.  This makes it difficult to distinguish
     horizontally adjacent fringe-less Emacs windows with scroll bars.
     So we change EmacsScroller's appearance to NSAppearanceNameAqua
     if otherwise it becomes NSAppearanceNameVibrantLight.  */
  if ([effectiveAppearance.name
	  isEqualToString:NSAppearanceNameVibrantLight])
    return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  else
    return effectiveAppearance;
}

- (CGFloat)knobSlotSpan
{
  if (knobSlotSpan < 0)
    {
      BOOL enabled = [self isEnabled];
      double floatValue = [self doubleValue];
      CGFloat knobProportion = [self knobProportion];
      NSRect knobSlotRect;

      [self setDoubleValue:0];
      [self setKnobProportion:0];
      [self setEnabled:YES];
      knobSlotRect = [self rectForPart:NSScrollerKnobSlot];
      if (!isHorizontal)
	knobSlotSpan = NSHeight (knobSlotRect);
      else
	knobSlotSpan = NSWidth (knobSlotRect);
      [self setEnabled:enabled];
      [self setDoubleValue:floatValue];
      [self setKnobProportion:knobProportion];
    }

  return knobSlotSpan;
}

- (CGFloat)minKnobSpan
{
  return minKnobSpan;
}

- (CGFloat)knobMinEdgeInSlot
{
  return knobMinEdgeInSlot;
}

- (CGFloat)frameSpan
{
  return frameSpan;
}

- (CGFloat)clickPositionInFrame
{
  return clickPositionInFrame;
}

- (int)inputEventModifiers
{
  return inputEvent.modifiers;
}

- (ptrdiff_t)inputEventCode
{
  return inputEvent.code;
}

- (void)mouseClick:(NSEvent *)theEvent
{
  NSPoint point = [theEvent locationInWindow];
  NSRect bounds = [self bounds];

  hitPart = [self testPart:point];
  point = [self convertPoint:point fromView:nil];
  if (!isHorizontal)
    {
      frameSpan = NSHeight (bounds);
      clickPositionInFrame = point.y;
    }
  else
    {
      frameSpan = NSWidth (bounds);
      clickPositionInFrame = point.x;
    }
  [self sendAction:[self action] to:[self target]];
}

- (void)mouseDown:(NSEvent *)theEvent
{
  struct mac_display_info *dpyinfo = &one_mac_display_info;

  dpyinfo->last_mouse_glyph_frame = NULL;

  mac_cgevent_to_input_event ([theEvent coreGraphicsEvent], &inputEvent);
  /* Make the "Ctrl-Mouse-2 splits window" work for toolkit scroll bars.  */
  if (inputEvent.modifiers & ctrl_modifier)
    {
      inputEvent.modifiers |= down_modifier;
      [self mouseClick:theEvent];
    }
  else
    {
      inputEvent.modifiers = 0;
      [super mouseDown:theEvent];
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
  if (inputEvent.modifiers == 0)
    [super mouseDragged:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
  if (inputEvent.modifiers != 0)
    {
      mac_cgevent_to_input_event ([theEvent coreGraphicsEvent], &inputEvent);
      inputEvent.modifiers |= up_modifier;
      [self mouseClick:theEvent];
    }
  else
    [super mouseUp:theEvent];
}

- (int)whole
{
  return whole;
}

- (void)setWhole:(int)theWhole
{
  whole = theWhole;
}

- (int)portion
{
  return portion;
}

- (void)setPortion:(int)thePortion
{
  portion = thePortion;
}

@end				// EmacsScroller

@implementation EmacsMainView (ScrollBar)

static int
scroller_part_to_scroll_bar_part (NSScrollerPart part,
				  NSEventModifierFlags flags)
{
  switch (part)
    {
    case NSScrollerDecrementPage:	return scroll_bar_above_handle;
    case NSScrollerIncrementPage:	return scroll_bar_below_handle;
    case NSScrollerKnob:		return scroll_bar_handle;
    case NSScrollerNoPart:		return scroll_bar_end_scroll;
    default:				return -1;
    }
}

static int
scroller_part_to_horizontal_scroll_bar_part (NSScrollerPart part,
					     NSEventModifierFlags flags)
{
  switch (part)
    {
    case NSScrollerDecrementPage:	return scroll_bar_before_handle;
    case NSScrollerIncrementPage:	return scroll_bar_after_handle;
    case NSScrollerKnob:		return scroll_bar_horizontal_handle;
    case NSScrollerNoPart:		return scroll_bar_end_scroll;
    default:				return -1;
    }
}

/* Generate an Emacs input event in response to a scroller action sent
   from SENDER to the receiver Emacs view, and then send the action
   associated to the view to the target of the view.  */

- (void)convertScrollerAction:(id)sender
{
  struct scroll_bar *bar = [sender emacsScrollBar];
  NSScrollerPart hitPart = [sender hitPart];
  int modifiers = [sender inputEventModifiers];
  NSEvent *currentEvent = [NSApp currentEvent];
  NSEventModifierFlags modifierFlags = [currentEvent modifierFlags];

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  inputEvent.frame_or_window = bar->window;
  if (bar->horizontal)
    {
      inputEvent.kind = HORIZONTAL_SCROLL_BAR_CLICK_EVENT;
      inputEvent.part =
	scroller_part_to_horizontal_scroll_bar_part (hitPart, modifierFlags);
    }
  else
    {
      inputEvent.kind = SCROLL_BAR_CLICK_EVENT;
      inputEvent.part =
	scroller_part_to_scroll_bar_part (hitPart, modifierFlags);
    }
  inputEvent.timestamp = [currentEvent timestamp] * 1000;
  inputEvent.modifiers = modifiers;

  if (modifiers)
    {
      CGFloat clickPositionInFrame = [sender clickPositionInFrame];
      CGFloat frameSpan = [sender frameSpan];
      ptrdiff_t inputEventCode = [sender inputEventCode];

      if (clickPositionInFrame < 0)
	clickPositionInFrame = 0;
      if (clickPositionInFrame > frameSpan)
	clickPositionInFrame = frameSpan;

      XSETINT (inputEvent.x, clickPositionInFrame);
      XSETINT (inputEvent.y, frameSpan);
      if (inputEvent.part == scroll_bar_end_scroll)
	inputEvent.part = scroll_bar_handle;
      inputEvent.code = inputEventCode;
    }
  else if (hitPart == NSScrollerKnob)
    {
      CGFloat minEdge = [sender knobMinEdgeInSlot];
      CGFloat knobSlotSpan = [sender knobSlotSpan];
      CGFloat minKnobSpan = [sender minKnobSpan];
      CGFloat maximum = knobSlotSpan - minKnobSpan;
      int whole = [sender whole], portion = [sender portion];

      if (minEdge < 0)
	minEdge = 0;
      if (minEdge > maximum)
	minEdge = maximum;

      if (bar->horizontal && whole > 0)
	{
	  /* The default horizontal scroll bar drag handler assumes
	     previously-set `whole' value to be preserved and doesn't
	     want overscrolling.  */
	  int position = lround (whole * minEdge / maximum);

	  if (position > whole - portion)
	    position = whole - portion;
	  XSETINT (inputEvent.x, position);
	  XSETINT (inputEvent.y, whole);
	}
      else
	{
	  XSETINT (inputEvent.x, minEdge);
	  XSETINT (inputEvent.y, maximum);
	}
    }

  [self sendAction:action to:target];
}

@end				// EmacsMainView (ScrollBar)

@implementation EmacsFrameController (ScrollBar)

- (void)addScrollerWithScrollBar:(struct scroll_bar *)bar
{
  struct window *w = XWINDOW (bar->window);
  NSRect frame = NSMakeRect (bar->left, bar->top, bar->width, bar->height);
  BOOL frameAdjusted = NO;
  EmacsScroller *scroller;

  /* Avoid confusion between vertical and horizontal types when
     creating the scroller.  */
  if (!bar->horizontal)
    {
      if (bar->height < bar->width)
	frame.size.height = NSWidth (frame) + 1;
      frameAdjusted = YES;
    }
  else
    {
      if (bar->width < bar->height)
	frame.size.width = NSHeight (frame) + 1;
      frameAdjusted = YES;
    }

  scroller = [[EmacsScroller alloc] initWithFrame:frame];

  if (frameAdjusted)
    {
      if (!bar->horizontal)
	frame.size.height = bar->height;
      else
	frame.size.width = bar->width;
      scroller.frame = frame;
    }

  [scroller setEmacsScrollBar:bar];
  [scroller setAction:@selector(convertScrollerAction:)];
  if (!bar->horizontal
      && WINDOW_RIGHTMOST_P (w) && WINDOW_HAS_VERTICAL_SCROLL_BAR_ON_RIGHT (w))
    [scroller setAutoresizingMask:NSViewMinXMargin];
  else if (bar->horizontal && WINDOW_BOTTOMMOST_P (w))
    [scroller setAutoresizingMask:NSViewMinYMargin];
  [emacsView addSubview:scroller positioned:NSWindowBelow relativeTo:nil];
  MRC_RELEASE (scroller);
  SET_SCROLL_BAR_SCROLLER (bar, scroller);
}

- (void)setVibrantScrollersHidden:(BOOL)flag
{
  for (NSView *view in emacsView.subviews)
    if ([view isKindOfClass:EmacsScroller.class]
	&& view.effectiveAppearance.allowsVibrancy)
      [view setHidden:flag];
}

@end				// EmacsFrameController (ScrollBar)

/* Create a scroll bar control for BAR.  The created control is stored
   in some members of BAR.  */

void
mac_create_scroll_bar (struct scroll_bar *bar)
{
  struct frame *f = XFRAME (WINDOW_FRAME (XWINDOW (bar->window)));
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{[frameController addScrollerWithScrollBar:bar];});
}

/* Dispose of the scroll bar control stored in some members of
   BAR.  */

void
mac_dispose_scroll_bar (struct scroll_bar *bar)
{
  EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);

  mac_within_gui (^{[scroller removeFromSuperview];});
}

/* Update bounds of the scroll bar BAR.  */

void
mac_update_scroll_bar_bounds (struct scroll_bar *bar)
{
  mac_within_gui (^{
      struct window *w = XWINDOW (bar->window);
      EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);
      NSRect frame = NSMakeRect (bar->left, bar->top, bar->width, bar->height);

      [scroller setFrame:frame];
      [scroller setNeedsDisplay:YES];
      if (!bar->horizontal && WINDOW_RIGHTMOST_P (w)
	  && WINDOW_HAS_VERTICAL_SCROLL_BAR_ON_RIGHT (w))
	[scroller setAutoresizingMask:NSViewMinXMargin];
      else if (bar->horizontal && WINDOW_BOTTOMMOST_P (w))
	[scroller setAutoresizingMask:NSViewMinYMargin];
      else
	[scroller setAutoresizingMask:NSViewNotSizable];
    });
}

/* Draw the scroll bar BAR.  */

void
mac_redraw_scroll_bar (struct scroll_bar *bar)
{
  EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);

  mac_within_gui (^{[scroller setNeedsDisplay:YES];});
}

/* Set the thumb size and position of scroll bar BAR.  We are currently
   displaying PORTION out of a whole WHOLE, and our position POSITION.  */

void
mac_set_scroll_bar_thumb (struct scroll_bar *bar, int portion, int position,
			  int whole)
{
  EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);

  block_input ();

  mac_within_gui (^{
      /* Must be inside BLOCK_INPUT as objc_msgSend may call zone_free
	 via _class_lookupMethodAndLoadCache, for example.  */
      CGFloat minKnobSpan = [scroller minKnobSpan];

      if (minKnobSpan == 0)
	;
      else if (whole <= portion)
	[scroller setEnabled:NO];
      else
	{
	  CGFloat knobSlotSpan = [scroller knobSlotSpan];
	  CGFloat maximum, scale, top, size;
	  CGFloat floatValue, knobProportion;

	  maximum = knobSlotSpan - minKnobSpan;
	  scale = maximum / whole;
	  top = position * scale;
	  size = portion * scale + minKnobSpan;

	  floatValue = top / (knobSlotSpan - size);
	  knobProportion = size / knobSlotSpan;

	  [scroller setDoubleValue:floatValue];
	  [scroller setKnobProportion:knobProportion];
	  [scroller setWhole:whole];
	  [scroller setPortion:portion];
	  [scroller setEnabled:YES];
	}
    });

  unblock_input ();
}

int
mac_get_default_scroll_bar_width (struct frame *f)
{
  return [EmacsScroller scrollerWidthForControlSize:NSControlSizeRegular
				      scrollerStyle:NSScrollerStyleLegacy];
}

int
mac_get_default_scroll_bar_height (struct frame *f)
{
  return mac_get_default_scroll_bar_width (f);
}

/************************************************************************
			       Tool-bars
 ************************************************************************/

#define TOOLBAR_IDENTIFIER_FORMAT (@"org.gnu.Emacs.%p.toolbar")

/* In identifiers such as function/variable names, Emacs tool bar is
   referred to as `tool_bar', and Carbon HIToolbar as `toolbar'.  */

#define TOOLBAR_ICON_ITEM_IDENTIFIER (@"org.gnu.Emacs.toolbar.icon")

@implementation EmacsToolbarItem

- (BOOL)allowsDuplicatesInToolbar
{
  return YES;
}

#if !USE_ARC
- (void)dealloc
{
  [coreGraphicsImages release];
  [super dealloc];
}
#endif

/* Set the toolbar icon image to the CoreGraphics image CGIMAGE.  */

- (void)setCoreGraphicsImage:(CGImageRef)cgImage
{
  self.coreGraphicsImages = @[(__bridge id) cgImage];
}

- (void)setCoreGraphicsImages:(NSArrayOf (id) *)cgImages
{
  NSUInteger i, count;
  NSImage *image;

  if ([coreGraphicsImages isEqualToArray:cgImages])
    return;

  count = [cgImages count];
  image = [NSImage imageWithCGImage:((__bridge CGImageRef) cgImages[0])
			  exclusive:(count == 1)];
  for (i = 1; i < count; i++)
    {
      NSArrayOf (NSImageRep *) *reps =
	[[NSImage imageWithCGImage:((__bridge CGImageRef) cgImages[i])
			 exclusive:NO] representations];

      [image addRepresentation:reps[0]];
    }

  [self setImage:image];
  coreGraphicsImages = [cgImages copy];
}

- (void)setImage:(NSImage *)image
{
  [super setImage:image];
  MRC_RELEASE (coreGraphicsImages);
  coreGraphicsImages = nil;
}

@end				// EmacsToolbarItem

@implementation EmacsFrameController (Toolbar)

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
  NSToolbarItem *item = nil;

  if ([itemIdentifier isEqualToString:TOOLBAR_ICON_ITEM_IDENTIFIER])
    {
      item = MRC_AUTORELEASE ([[EmacsToolbarItem alloc]
				initWithItemIdentifier:itemIdentifier]);
      [item setTarget:self];
      [item setAction:@selector(storeToolBarEvent:)];
      [item setEnabled:NO];
    }

  return item;
}

- (NSArrayOf (NSToolbarItemIdentifier) *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
  return @[TOOLBAR_ICON_ITEM_IDENTIFIER];
}

- (NSArrayOf (NSToolbarItemIdentifier) *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
  return @[TOOLBAR_ICON_ITEM_IDENTIFIER];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
  return [theItem isEnabled];
}

/* Create a tool bar for the frame.  */

- (void)setupToolBarWithVisibility:(BOOL)visible
{
  NSToolbarIdentifier identifier =
    [NSString stringWithFormat:TOOLBAR_IDENTIFIER_FORMAT, self];
  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:identifier];
  NSButton *button;

  if (toolbar == nil)
    return;

#if MAC_OS_X_VERSION_MIN_REQUIRED < 110000
  toolbar.sizeMode = NSToolbarSizeModeSmall;
#endif
  toolbar.allowsUserCustomization = YES;
  toolbar.autosavesConfiguration = NO;
  toolbar.delegate = self;

  emacsWindow.toolbar = toolbar;
  /* If we set toolbar.visible to NO before setting window's toolbar,
     the title bar becomes taller on macOS 14.  */
  toolbar.visible = visible;
  MRC_RELEASE (toolbar);

  [self updateToolbarDisplayMode];

  button = [emacsWindow standardWindowButton:NSWindowToolbarButton];
  button.target = emacsController;
  button.action = NSSelectorFromString (@"toolbar-pill-button-clicked:");
}

/* Update display mode of the toolbar for the frame according to
   the value of Vtool_bar_style.  */

- (void)updateToolbarDisplayMode
{
  NSToolbar *toolbar = [emacsWindow toolbar];
  NSToolbarDisplayMode displayMode = NSToolbarDisplayModeDefault;

  if (EQ (Vtool_bar_style, Qimage))
    displayMode = NSToolbarDisplayModeIconOnly;
  else if (EQ (Vtool_bar_style, Qtext))
    displayMode = NSToolbarDisplayModeLabelOnly;
  else if (EQ (Vtool_bar_style, Qboth) || EQ (Vtool_bar_style, Qboth_horiz)
	   || EQ (Vtool_bar_style, Qtext_image_horiz))
    displayMode = NSToolbarDisplayModeIconAndLabel;

  [toolbar setDisplayMode:displayMode];
}

/* Store toolbar item click event from SENDER to kbd_buffer.  */

- (void)storeToolBarEvent:(id)sender
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self storeToolBarEvent:sender]);

  NSInteger i = [sender tag];
  struct frame *f = emacsFrame;

#define PROP(IDX) AREF (f->tool_bar_items, i * TOOL_BAR_ITEM_NSLOTS + (IDX))
  if (i < f->n_tool_bar_items && !NILP (PROP (TOOL_BAR_ITEM_ENABLED_P)))
    {
      Lisp_Object frame;
      struct input_event buf;

      EVENT_INIT (buf);

      XSETFRAME (frame, f);
      buf.kind = TOOL_BAR_EVENT;
      buf.frame_or_window = frame;
      buf.arg = PROP (TOOL_BAR_ITEM_KEY);
      buf.modifiers = mac_event_to_emacs_modifiers ([NSApp currentEvent]);
      kbd_buffer_store_event (&buf);
    }
#undef PROP
}

/* Report a mouse movement over toolbar to the mainstream Emacs
   code.  */

- (void)noteToolBarMouseMovement:(NSEvent *)event
{
  /* Help echo only; skip it while Lisp is busy.  */
  if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())
    return;

  struct frame *f = emacsFrame;
  NSView *hitView;

  /* Return if mouse dragged.  */
  if ([event type] != NSEventTypeMouseMoved)
    return;

  if (!VECTORP (f->tool_bar_items))
    return;

  hitView = [[[emacsWindow contentView] superview]
	      hitTest:[event locationInWindow]];
  if ([hitView respondsToSelector:@selector(item)])
    {
      NSToolbarItem *item = [(id <EmacsToolbarItemViewer>)hitView item];

      if ([item isKindOfClass:EmacsToolbarItem.class])
	{
#define PROP(IDX) AREF (f->tool_bar_items, i * TOOL_BAR_ITEM_NSLOTS + (IDX))
	  NSInteger i = [item tag];

	  if (i >= 0 && i < f->n_tool_bar_items)
	    {
	      struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
	      NSRect viewFrame;

	      viewFrame = [hitView convertRect:[hitView bounds] toView:nil];
	      viewFrame = [emacsView convertRect:viewFrame fromView:nil];
	      STORE_NATIVE_RECT (dpyinfo->last_mouse_glyph,
				 NSMinX (viewFrame), NSMinY (viewFrame),
				 NSWidth (viewFrame), NSHeight (viewFrame));

	      help_echo_object = help_echo_window = Qnil;
	      help_echo_pos = -1;
	      help_echo_string = PROP (TOOL_BAR_ITEM_HELP);
	      if (NILP (help_echo_string))
		help_echo_string = PROP (TOOL_BAR_ITEM_CAPTION);
	    }
	}
    }
#undef PROP
}

@end				// EmacsFrameController (Toolbar)

/* Whether the toolbar for the frame F is visible.  */

bool
mac_is_frame_window_toolbar_visible (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  return [[window toolbar] isVisible];
}

/* Copied from gtkutil.c.  */

static Lisp_Object
file_for_image (Lisp_Object image)
{
  Lisp_Object specified_file = Qnil;
  Lisp_Object tail;

  for (tail = XCDR (image);
       NILP (specified_file) && CONSP (tail) && CONSP (XCDR (tail));
       tail = XCDR (XCDR (tail)))
    if (EQ (XCAR (tail), QCfile))
      specified_file = XCAR (XCDR (tail));

  return specified_file;
}

static NSImage *
mac_cached_system_symbol (NSString *name)
{
  NSImage *systemSymbol = nil;

  if (
#if __clang_major__ >= 9
      @available (macOS 10.16, *)
#else
      [NSImage respondsToSelector:@selector(imageWithSystemSymbolName:accessibilityDescription:)]
#endif
      )
    {
      static NSMutableDictionaryOf (NSString *, id) *systemSymbolCache = nil;
      id obj = systemSymbolCache[name];

      if ([obj isKindOfClass:NSImage.class])
	systemSymbol = obj;
      else if (obj == nil)
	{
	  if (systemSymbolCache == nil)
	    systemSymbolCache = [[NSMutableDictionary alloc] init];
	  systemSymbol = [NSImage imageWithSystemSymbolName:name
				   accessibilityDescription:nil];
	  obj = systemSymbol ? systemSymbol : NSNull.null;
	  systemSymbolCache[name] = obj;
	}
    }

  return systemSymbol;
}

/* Update the tool bar for frame F.  Add new buttons and remove old.  */

void
update_frame_tool_bar (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  EmacsWindow *window;
  NativeRectangle r;
  NSToolbar *toolbar;
  int i, win_gravity = f->output_data.mac->toolbar_win_gravity;
  int pos;
  bool system_symbol_inhibited_p = false;

  block_input ();

  window = [frameController emacsWindow];
  mac_get_frame_window_gravity_reference_bounds (f, win_gravity, &r);
  /* Shrinking the toolbar height with preserving the whole window
     height (e.g., fullheight) seems to be problematic.  */
  [window suspendConstrainingToScreen:YES];

  /* Work around bogus view bounds/frame values on some versions of
     macOS 11.x (x >= 3?) when using system image tool bar icons in
     the `expanded' style., which is default for the executable
     compiled with macOS 10.* SDKs.  */
  /* NSWindowSupportsAutomaticInlineTitle has no effect on macOS 12.  */
  if (floor (NSAppKitVersionNumber) == NSAppKitVersionNumber11_0)
    {
      NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

      if ([userDefaults objectForKey:@"NSWindowSupportsAutomaticInlineTitle"]
	  && ![userDefaults boolForKey:@"NSWindowSupportsAutomaticInlineTitle"])
	system_symbol_inhibited_p = true;
    }
#if MAC_OS_X_VERSION_MAX_ALLOWED < 110000
  else
    system_symbol_inhibited_p = true;
#endif

  toolbar = [window toolbar];
  pos = 0;
  for (i = 0; i < f->n_tool_bar_items; ++i)
    {
#define PROP(IDX) AREF (f->tool_bar_items, i * TOOL_BAR_ITEM_NSLOTS + (IDX))
      bool enabled_p = !NILP (PROP (TOOL_BAR_ITEM_ENABLED_P));
      bool selected_p = !NILP (PROP (TOOL_BAR_ITEM_SELECTED_P));
      int idx = 0;
      Lisp_Object image;
      NSImage *systemSymbol = nil;
      NSString *label = nil;
      NSArrayOf (id) *cgImages = nil;
      NSToolbarItemIdentifier identifier = TOOLBAR_ICON_ITEM_IDENTIFIER;

      if (EQ (PROP (TOOL_BAR_ITEM_TYPE), Qt))
	identifier = nil;
      else
	{
	  /* If image is a vector, choose the image according to the
	     button state.  */
	  image = PROP (TOOL_BAR_ITEM_IMAGES);
	  if (VECTORP (image))
	    {
	      if (enabled_p)
		idx = (selected_p
		       ? TOOL_BAR_IMAGE_ENABLED_SELECTED
		       : TOOL_BAR_IMAGE_ENABLED_DESELECTED);
	      else
		idx = (selected_p
		       ? TOOL_BAR_IMAGE_DISABLED_SELECTED
		       : TOOL_BAR_IMAGE_DISABLED_DESELECTED);

	      eassert (ASIZE (image) >= idx);
	      image = AREF (image, idx);
	    }
	  else
	    idx = -1;

	  /* Ignore invalid image specifications.  */
	  if (!valid_image_p (image))
	    continue;

	  if (!system_symbol_inhibited_p)
	    if (
#if __clang_major__ >= 9
		@available (macOS 10.16, *)
#else
		[NSImage respondsToSelector:@selector(imageWithSystemSymbolName:accessibilityDescription:)]
#endif
		)
	      {
		Lisp_Object specified_file = file_for_image (image);
		Lisp_Object names = Qnil;
		if (!NILP (specified_file)
		    && !NILP (Ffboundp (Qmac_map_system_symbol)))
		  names = calln (Qmac_map_system_symbol, specified_file);

		if (CONSP (names))
		  {
		    Lisp_Object tem;
		    for (tem = names; CONSP (tem); tem = XCDR (tem))
		      if (! NILP (tem) && STRINGP (XCAR (tem)))
			{
			  NSString *str = [NSString
					    stringWithLispString:(XCAR (tem))];
			  systemSymbol = mac_cached_system_symbol (str);
			  if (systemSymbol) break;
			}
		  }
		else if (STRINGP (names))
		  {
		    NSString *str = [NSString stringWithLispString:names];
		    systemSymbol = mac_cached_system_symbol (str);
		  }
	      }

	  if (!systemSymbol)
	    {
	      ptrdiff_t img_id;
	      struct image *img;

	      FRAME_BACKING_SCALE_FACTOR (f) = 1;
	      img_id = lookup_image (f, image, -1);
	      [frameController updateBackingScaleFactor];
	      img = IMAGE_FROM_ID (f, img_id);
	      prepare_image_for_display (f, img);

	      if (img->cg_image == NULL)
		continue;

	      /* As displayed images of toolbar image items are scaled
		 to square shapes, narrow images such as separators
		 look weird.  So we use separator items for too narrow
		 disabled images.  */
	      if (CGImageGetWidth (img->cg_image) <= 2 && !enabled_p)
		identifier = nil;
	      else if (img->target_backing_scale == 0)
		cgImages = @[(__bridge id) img->cg_image];
	      else
		{
		  CGImageRef cg_image = img->cg_image;

		  FRAME_BACKING_SCALE_FACTOR (f) = 2;
		  img_id = lookup_image (f, image, -1);
		  [frameController updateBackingScaleFactor];
		  img = IMAGE_FROM_ID (f, img_id);
		  prepare_image_for_display (f, img);

		  /* The value of img->cg_image may be NULL, so we
		     don't use NSArray literals here.  */
		  cgImages = [NSArray arrayWithObjects:((__bridge id) cg_image),
				      ((__bridge id) img->cg_image), nil];
		}
	    }

	  if (STRINGP (PROP (TOOL_BAR_ITEM_LABEL)))
	    label = [NSString
		      stringWithLispString:(PROP (TOOL_BAR_ITEM_LABEL))];
	  else
	    label = @"";
	}

      if (!identifier)
	continue;

      mac_within_gui (^{
	  NSArrayOf (__kindof NSToolbarItem *) *items = [toolbar items];
	  NSUInteger count = [items count];

	  if (pos >= count
	      || ![identifier isEqualToString:[items[pos] itemIdentifier]])
	    {
	      [toolbar insertItemWithItemIdentifier:identifier atIndex:pos];
	      items = [toolbar items];
	      count = [items count];
	    }

	  EmacsToolbarItem *item = items[pos];

	  if (systemSymbol)
	    item.image = systemSymbol;
	  else
	    [item setCoreGraphicsImages:cgImages];
	  [item setLabel:label];
	  [item setEnabled:(enabled_p || idx >= 0)];
	  [item setTag:i];
	});
      pos++;
#undef PROP
    }

  mac_within_gui (^{
      NSUInteger count = [[toolbar items] count];
#if 0
      /* This leads to the problem that the toolbar space right to the
	 icons cannot be dragged if it becomes wider on Mac OS X
	 10.5. */
      while (pos < count)
	[toolbar removeItemAtIndex:--count];
#else
      while (pos < count)
	{
	  [toolbar removeItemAtIndex:pos];
	  count--;
	}
#endif
    });

  unblock_input ();

  /* Check if the window has moved during toolbar item setup.  As
     title bar dragging is processed asynchronously, we don't
     notice it without reading window events.  */
  if (input_polling_used ())
    {
      /* It could be confusing if a real alarm arrives while
	 processing the fake one.  Turn it off and let the handler
	 reset it.  */
      int old_poll_suppress_count = poll_suppress_count;
      poll_suppress_count = 1;
      poll_for_input_1 ();
      poll_suppress_count = old_poll_suppress_count;
    }

  block_input ();

  mac_within_gui (^{
      [frameController updateToolbarDisplayMode];
      /* If we change the visibility of a toolbar while its window is
	 being moved asynchronously, the window moves to the original
	 position.  How can we know we are in asynchronous dragging?
	 Note that sometimes we don't receive windowDidMove: messages
	 for preceding windowWillMove:.  */
      if (![toolbar isVisible])
	[toolbar setVisible:YES];
    });

  [window suspendConstrainingToScreen:NO];
  win_gravity = f->output_data.mac->toolbar_win_gravity;
  if (!(EQ (frame_inhibit_implied_resize, Qt)
	|| (CONSP (frame_inhibit_implied_resize)
	    && !NILP (Fmemq (Qtool_bar_lines, frame_inhibit_implied_resize)))))
    {
      r.width = 0;
      if (!([frameController windowManagerState] & WM_STATE_MAXIMIZED_VERT))
	r.height = 0;
    }
  mac_set_frame_window_gravity_reference_bounds (f, win_gravity, r);
  f->output_data.mac->toolbar_win_gravity = 0;

  unblock_input ();
}

/* Hide the tool bar on frame F.  Unlike the counterpart on GTK+, it
   doesn't deallocate the resources.  */

void
free_frame_tool_bar (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  EmacsWindow *window;
  NSToolbar *toolbar;

  block_input ();

  window = [frameController emacsWindow];
  toolbar = [window toolbar];
  if ([toolbar isVisible])
    {
      int win_gravity = f->output_data.mac->toolbar_win_gravity;
      NativeRectangle r;

      mac_get_frame_window_gravity_reference_bounds (f, win_gravity, &r);
      /* Shrinking the toolbar height with preserving the whole window
	 height (e.g., fullheight) seems to be problematic.  */
      [window suspendConstrainingToScreen:YES];

      mac_within_gui (^{[toolbar setVisible:NO];});

      [window suspendConstrainingToScreen:NO];
      if (!(EQ (frame_inhibit_implied_resize, Qt)
	    || (CONSP (frame_inhibit_implied_resize)
		&& !NILP (Fmemq (Qtool_bar_lines,
				 frame_inhibit_implied_resize)))))
	{
	  r.width = 0;
	  if (!([frameController windowManagerState] & WM_STATE_MAXIMIZED_VERT))
	    r.height = 0;
	}
      mac_set_frame_window_gravity_reference_bounds (f, win_gravity, r);
    }
  f->output_data.mac->toolbar_win_gravity = 0;

  unblock_input ();
}


/************************************************************************
			      Font Panel
 ************************************************************************/

@implementation EmacsFontPanel

#if !USE_ARC
- (void)dealloc
{
  [mouseUpEvent release];
  [super dealloc];
}
#endif

- (void)suspendSliderTracking:(NSEvent *)event
{
  mouseUpEvent =
    MRC_RETAIN ([event mouseEventByChangingType:NSEventTypeLeftMouseUp
				    andLocation:[event locationInWindow]]);
  [NSApp postEvent:mouseUpEvent atStart:YES];
  MOUSE_TRACKING_SET_RESUMPTION (emacsController, self, resumeSliderTracking);
}

- (void)resumeSliderTracking
{
  NSPoint location = [mouseUpEvent locationInWindow];
  NSRect trackRect;
  NSEvent *mouseDownEvent;

  trackRect = [trackedSlider convertRect:[[trackedSlider cell] trackRect]
			     toView:nil];
  if (location.x < NSMinX (trackRect))
    location.x = NSMinX (trackRect);
  else if (location.x >= NSMaxX (trackRect))
    location.x = NSMaxX (trackRect) - 1;
  if (location.y <= NSMinY (trackRect))
    location.y = NSMinY (trackRect) + 1;
  else if (location.y > NSMaxY (trackRect))
    location.y = NSMaxY (trackRect);

  mouseDownEvent = [mouseUpEvent
		     mouseEventByChangingType:NSEventTypeLeftMouseDown
				  andLocation:location];
  MRC_RELEASE (mouseUpEvent);
  mouseUpEvent = nil;
  [NSApp postEvent:mouseDownEvent atStart:YES];
}

- (void)sendEvent:(NSEvent *)event
{
  if ([event type] == NSEventTypeLeftMouseDown)
    {
      NSView *contentView = [self contentView], *hitView;

      hitView = [contentView hitTest:[[contentView superview]
				       convertPoint:[event locationInWindow]
				       fromView:nil]];
      if ([hitView isKindOfClass:NSSlider.class])
	trackedSlider = (NSSlider *) hitView;
    }

  [super sendEvent:event];
}

@end				// EmacsFontPanel

@implementation EmacsController (FontPanel)

/* Called when the font panel is about to close.  */

- (void)fontPanelWillClose:(NSNotification *)notification
{
  OSStatus err;
  EventRef event;

  err = CreateEvent (NULL, kEventClassFont, kEventFontPanelClosed, 0,
		     kEventAttributeNone, &event);
  if (err == noErr)
    {
      err = mac_store_event_ref_as_apple_event (0, 0, Qfont, Qpanel_closed,
						event, 0, NULL, NULL);
      ReleaseEvent (event);
    }
}

@end				// EmacsController (FontPanel)

@implementation EmacsFrameController (FontPanel)

/* Return the NSFont object for the face FACEID and the character C.  */

- (NSFont *)fontForFace:(int)faceId character:(int)c
	       position:(int)pos object:(Lisp_Object)object
{
  struct frame *f = emacsFrame;

  if (FRAME_FACE_CACHE (f) && CHAR_VALID_P (c))
    {
      struct face *face;

      faceId = FACE_FOR_CHAR (f, FACE_FROM_ID (f, faceId), c, pos, object);
      face = FACE_FROM_ID (f, faceId);

      return [NSFont fontWithFace:face];
    }
  else
    return nil;
}

/* Called when the user has chosen a font from the font panel.  */

- (void)changeFont:(NSFontManager *)sender
{
  EmacsFontPanel *fontPanel = (EmacsFontPanel *) [sender fontPanel:NO];
  NSEvent *currentEvent;
  NSFont *oldFont, *newFont;
  Lisp_Object arg = Qnil;
  struct input_event inev;

  /* This might look strange, but can happen on Mac OS X 10.5 and
     later inside [fontPanel makeFirstResponder:accessoryView] (in
     mac_font_dialog) if the panel is shown for the first time.  */
  if ([[fontPanel delegate] isMemberOfClass:EmacsFontDialogController.class])
    return;

  currentEvent = [NSApp currentEvent];
  if ([currentEvent type] == NSEventTypeLeftMouseDragged)
    [fontPanel suspendSliderTracking:currentEvent];

  oldFont = [self fontForFace:DEFAULT_FACE_ID character:0 position:-1
		       object:Qnil];
  newFont = [sender convertFont:oldFont];
  if (newFont)
    arg = Fcons (Fcons (Qfont_spec,
			Fcons (build_string ("Lisp"),
			       macfont_nsctfont_to_spec ((__bridge void *)
							 newFont))),
		 arg);

  EVENT_INIT (inev);
  inev.kind = MAC_APPLE_EVENT;
  inev.x = Qfont;
  inev.y = Qselection;
  inev.frame_or_window = mac_event_frame ();
  inev.arg = Fcons (build_string ("aevt"), arg);
  [emacsController storeEvent:&inev];
}

/* Hide unused features in font panels.  */

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel
{
  /* Underline, Strikethrough, TextColor, DocumentColor, and Shadow
     are not used in font panels.  */
  return (NSFontPanelModeMaskFace
	  | NSFontPanelModeMaskSize
	  | NSFontPanelModeMaskCollection);
}

@end				// EmacsFrameController (FontPanel)

/* Whether the font panel is currently visible.  */

bool
mac_font_panel_visible_p (void)
{
  NSFontPanel *fontPanel = [[NSFontManager sharedFontManager] fontPanel:NO];

  return [fontPanel isVisible];
}

/* Toggle visiblity of the font panel.  */

OSStatus
mac_show_hide_font_panel (void)
{
  static BOOL initialized;
  NSFontManager *fontManager = [NSFontManager sharedFontManager];
  NSFontPanel * __block fontPanel;

  mac_within_gui (^{fontPanel = MRC_RETAIN ([fontManager fontPanel:YES]);});

  if (!initialized)
    {
      [[NSNotificationCenter defaultCenter]
	addObserver:emacsController
	selector:@selector(fontPanelWillClose:)
	name:@"NSWindowWillCloseNotification"
	object:fontPanel];
      initialized = YES;
    }

  mac_within_gui (^{
      if ([fontPanel isVisible])
	[fontPanel orderOut:nil];
      else
	[fontManager orderFrontFontPanel:nil];
    });

  MRC_RELEASE (fontPanel);

  return noErr;
}

/* Set the font selected in the font panel to the one corresponding to
   the face FACE_ID and the charcacter C in the frame F.  */

OSStatus
mac_set_font_info_for_selection (struct frame *f, int face_id, int c, int pos,
				 Lisp_Object object)
{
  if (mac_font_panel_visible_p () && f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);
      NSFont *font = [frameController fontForFace:face_id character:c
					 position:pos object:object];

      mac_within_gui (^{
	  [[NSFontManager sharedFontManager] setSelectedFont:font
						  isMultiple:NO];
	});
    }

  return noErr;
}


/************************************************************************
			    Event Handling
 ************************************************************************/

extern Boolean _IsSymbolicHotKeyEvent (EventRef, UInt32 *, Boolean *) AVAILABLE_MAC_OS_X_VERSION_10_3_AND_LATER;

static void update_apple_event_handler (void);
static void update_dragged_types (void);

/* Specify how long dpyinfo->saved_menu_event remains valid in
   seconds.  This is to avoid infinitely ignoring mouse events when
   MENU_BAR_ACTIVATE_EVENT is not processed: e.g., "M-! sleep 30 RET
   -> try to activate menu bar -> C-g".  */
#define SAVE_MENU_EVENT_TIMEOUT	5

@implementation EmacsFrameController (EventHandling)

/* Called when an EnterNotify event would happen for an Emacs window
   if it were on X11.  */

- (void)noteEnterEmacsView
{
  NSPoint mouseLocation = [NSEvent mouseLocation];

  mouseLocation = [self convertEmacsViewPointFromScreen:mouseLocation];
  /* EnterNotify counts as mouse movement,
     so update things that depend on mouse position.  */
  [self noteMouseMovement:mouseLocation];
}

/* Called when a LeaveNotify event would happen for an Emacs window if
   it were on X11.  */

- (void)noteLeaveEmacsView
{
  struct frame *f = emacsFrame;
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;

  if (emacsViewIsHiddenOrHasHiddenAncestor)
    return;

  /* This corresponds to LeaveNotify for an X11 window for an Emacs
     frame.  */
  if (f == hlinfo->mouse_face_mouse_frame)
    {
      /* If we move outside the frame, then we're
	 certainly no longer on any text in the
	 frame.  */
      [self clearMouseFace:hlinfo];
      hlinfo->mouse_face_mouse_frame = 0;
      mac_flush_1 (f);
    }

  [emacsController cancelHelpEchoForEmacsFrame:f];

  /* This corresponds to EnterNotify for an X11 window for some
     popup (from note_mouse_movement in xterm.c).  */
  [self noteMouseHighlightAtX:-1 y:-1];
  dpyinfo->last_mouse_glyph_frame = NULL;
}

/* Function to report a mouse movement to the mainstream Emacs code.
   The input handler calls this.

   We have received a mouse movement event, whose position in the view
   coordinate is given in POINT.  If the mouse is over a different
   glyph than it was last time, tell the mainstream emacs code by
   setting mouse_moved.  If not, ask for another motion event, so we
   can check again the next time it moves.  */

- (BOOL)noteMouseMovement:(NSPoint)point
{
  struct frame *f = emacsFrame;
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;
  NSRect emacsViewBounds = [emacsView bounds];
  int x, y;
  NativeRectangle *r;

  /* While the Tab Overview UI is in action, the views previously
     shown before the invocation of the Overview UI are hidden and not
     drawable.  We avoid lazy creation of emacsWindow.tabGroup because
     it causes side effect of not creating a tabbed window.  */
  if (emacsViewIsHiddenOrHasHiddenAncestor)
    return true;

  dpyinfo->last_mouse_movement_time = mac_system_uptime () * 1000;

  if (f == hlinfo->mouse_face_mouse_frame
      && ! (point.x >= 0 && point.x < NSMaxX (emacsViewBounds)
	    && point.y >= 0 && point.y < NSMaxY (emacsViewBounds)))
    {
      /* This case corresponds to LeaveNotify in X11.  If we move
	 outside the frame, then we're certainly no longer on any text
	 in the frame.  */
      [self clearMouseFace:hlinfo];
      hlinfo->mouse_face_mouse_frame = 0;
    }

  x = point.x;
  y = point.y;
  r = &dpyinfo->last_mouse_glyph;
  /* Has the mouse moved off the glyph it was on at the last sighting?  */
  if (f != dpyinfo->last_mouse_glyph_frame
      || x < r->x || x - r->x >= r->width || y < r->y || y - r->y >= r->height)
    {
      [self noteMouseHighlightAtX:x y:y];
      /* Remember which glyph we're now on.  */
      remember_mouse_glyph (f, x, y, r);
      dpyinfo->last_mouse_glyph_frame = f;
      return true;
    }

  return false;
}

- (BOOL)clearMouseFace:(Mouse_HLInfo *)hlinfo
{
  BOOL result;

  [emacsView lockFocusOnBacking];
#ifndef USE_METAL_RENDERING
  set_global_focus_view_frame (emacsFrame);
#endif
  result = clear_mouse_face (hlinfo);
#ifndef USE_METAL_RENDERING
  unset_global_focus_view_frame ();
#endif
  [emacsView unlockFocusOnBacking];

  return result;
}

- (void)noteMouseHighlightAtX:(int)x y:(int)y
{
  struct frame *f = emacsFrame;

  f->mouse_moved = true;
  [emacsView lockFocusOnBacking];
#ifndef USE_METAL_RENDERING
  set_global_focus_view_frame (f);
#endif
  note_mouse_highlight (f, x, y);
#ifndef USE_METAL_RENDERING
  unset_global_focus_view_frame ();
#endif
  [emacsView unlockFocusOnBacking];
}

@end				// EmacsFrameController (EventHandling)

/* Obtains the emacs modifiers from the event EVENT.  */

static int
mac_event_to_emacs_modifiers (NSEvent *event)
{
  struct input_event buf;

  mac_cgevent_to_input_event ([event coreGraphicsEvent], &buf);

  return buf.modifiers;
}

void
mac_get_screen_info (struct mac_display_info *dpyinfo)
{
  NSArrayOf (NSScreen *) *screens = NSScreen.screens;
  NSWindowDepth depth = [screens[0] depth];
  NSRect frame;

  dpyinfo->n_planes = NSBitsPerPixelFromDepth (depth);
  dpyinfo->color_p = dpyinfo->n_planes > NSBitsPerSampleFromDepth (depth);

  frame = NSZeroRect;
  for (NSScreen *screen in screens)
    frame = NSUnionRect (frame, screen.frame);
  dpyinfo->width = NSWidth (frame);
  dpyinfo->height = NSHeight (frame);
}

/* Run the current run loop in the default mode until some input
   happens or TIMEOUT seconds passes unless it is negative.  Return 0
   if timeout occurs first.  Return the remaining timeout unless the
   original TIMEOUT value is negative.  */

EventTimeout
mac_run_loop_run_once (EventTimeout timeout)
{
  NSDate *expiration;

  if (timeout < 0)
    expiration = [NSDate distantFuture];
  else
    expiration = [NSDate dateWithTimeIntervalSinceNow:timeout];

  /* On macOS 10.12, the application sometimes becomes unresponsive to
     Dock icon clicks (though it reacts to Command-Tab) if we directly
     run a run loop and the application windows are covered by other
     applications for a while.  */
  mac_within_app (^{
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			       beforeDate:expiration];
    });

  if (timeout > 0)
    {
      timeout = [expiration timeIntervalSinceNow];
      if (timeout < 0)
	timeout = 0;
    }

  return timeout;
}

/* Return next event in the main queue if it exists.  Otherwise return
   NULL.  */

static EventRef
mac_peek_next_event (void)
{
  EventRef event;

  event = AcquireFirstMatchingEventInQueue (GetCurrentEventQueue (), 0,
					    NULL, kEventQueueOptionsNone);
  if (event)
    ReleaseEvent (event);

  return event;
}

/* Return next event in the main queue if it exists and is a mouse
   down on the menu bar.  Otherwise return NULL.  */

static EventRef
peek_if_next_event_activates_menu_bar (void)
{
  EventRef event = mac_peek_next_event ();
  OSType event_class;
  UInt32 event_kind;

  if (event == NULL)
    return NULL;

  event_class = GetEventClass (event);
  event_kind = GetEventKind (event);
  if (event_class == kEventClassKeyboard
      && event_kind == kEventRawKeyDown)
    {
      UInt32 code;
      Boolean isEnabled;

      if (_IsSymbolicHotKeyEvent (event, &code, &isEnabled)
	  && isEnabled && code == 7) /* Move focus to the menu bar */
	{
	  OSStatus err;
	  UInt32 modifiers;

	  err = GetEventParameter (event, kEventParamKeyModifiers, typeUInt32,
				   NULL, sizeof (UInt32), NULL, &modifiers);
	  if (err == noErr
	      && !(modifiers
		   & ((mac_pass_command_to_system ? 0 : cmdKey)
		      | (mac_pass_control_to_system ? 0 : controlKey))))
	    return event;
	}
    }
  else if (event_class == kEventClassMouse
	   && event_kind == kEventMouseDown)
    {
      OSStatus err;
      HIPoint point;

      err = GetEventParameter (event, kEventParamMouseLocation,
			       typeHIPoint, NULL, sizeof (HIPoint), NULL,
			       &point);
      if (err == noErr)
	{
	  NSRect baseScreenFrame = mac_get_base_screen_frame ();
	  NSPoint mouseLocation =
	    NSMakePoint (point.x + NSMinX (baseScreenFrame),
			 - point.y + NSMaxY (baseScreenFrame));
	  NSScreen *screen = [NSScreen screenContainingPoint:mouseLocation];

	  if ([screen canShowMenuBar])
	    {
	      NSRect frame = [screen frame];
	      CGFloat menuBarHeight = [[NSApp mainMenu] menuBarHeight];

	      frame.origin.y = NSMaxY (frame) - menuBarHeight;
	      frame.size.height = menuBarHeight;
	      if (NSMouseInRect (mouseLocation, frame, NO))
		return event;
	    }
	}
    }

  return NULL;
}

/* Emacs calls this whenever it wants to read an input event from the
   user. */

int
mac_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  int count;
  struct mac_display_info *dpyinfo = &one_mac_display_info;
#if __clang_major__ < 3
  NSAutoreleasePool *pool;
#endif
  static NSDate *lastCallDate;
  static NSTimer *timer;
  NSTimeInterval timeInterval, minimumInterval;

  block_input ();

  BEGIN_AUTORELEASE_POOL;

  minimumInterval = [emacsController minimumIntervalForReadSocket];
  if (lastCallDate
      && (timeInterval = - [lastCallDate timeIntervalSinceNow],
	  timeInterval < minimumInterval))
    {
      if (![timer isValid])
	{
	  MRC_RELEASE (timer);
	  timeInterval = minimumInterval - timeInterval;
	  mac_within_gui (^{
	      timer =
		MRC_RETAIN ([NSTimer
			      scheduledTimerWithTimeInterval:timeInterval
						      target:emacsController
						    selector:@selector(processDeferredReadSocket:)
						    userInfo:nil
						     repeats:NO]);
	    });
	}
      count = 0;
    }
  else
    {
      Lisp_Object tail, frame;

      MRC_RELEASE (lastCallDate);
      lastCallDate = [[NSDate alloc] init];
      [timer invalidate];
      MRC_RELEASE (timer);
      timer = nil;
      extendReadSocketIntervalOnce = NO;

      /* Maybe these should be done at some redisplay timing.  */
      update_apple_event_handler ();
      update_dragged_types ();
      [emacsController updateObservedKeyPaths];

      if (dpyinfo->saved_menu_event
	  && (GetEventTime (dpyinfo->saved_menu_event) + SAVE_MENU_EVENT_TIMEOUT
	      <= GetCurrentEventTime ()))
	{
	  ReleaseEvent (dpyinfo->saved_menu_event);
	  dpyinfo->saved_menu_event = NULL;
	}

      mac_draw_queue_sync ();
      handling_queued_nsevents_p = true;
      if (mac_persistent_loop_p)
	count = mac_loop_read_socket_events (hold_quit);
      else
	count = [emacsController handleQueuedNSEventsWithHoldingQuitIn:hold_quit];
      handling_queued_nsevents_p = false;

      /* If the focus was just given to an autoraising frame,
	 raise it now.  */
      /* ??? This ought to be able to handle more than one such frame.  */
      if (dpyinfo->mac_pending_autoraise_frame)
	{
	  terminal->frame_raise_lower_hook (dpyinfo->mac_pending_autoraise_frame,
					    true);
	  dpyinfo->mac_pending_autoraise_frame = NULL;
	}

      if (mac_screen_config_changed)
	{
	  mac_get_screen_info (dpyinfo);
	  mac_screen_config_changed = 0;
	}

      FOR_EACH_FRAME (tail, frame)
	{
	  struct frame *f = XFRAME (frame);

	  if (FRAME_MAC_P (f))
	    {
	      mac_force_flush (f);
	      /* Check which frames are still visible.  We do this
		 here because there doesn't seem to be any direct
		 notification that the visibility of a window has
		 changed (at least, not in all cases.  Or are there
		 any counterparts of kEventWindowShown/Hidden?).  */
	      mac_handle_visibility_change (f);
	    }
	}
    }

  END_AUTORELEASE_POOL;

  unblock_input ();

  return count;
}


/************************************************************************
				Busy cursor
 ************************************************************************/

@implementation EmacsFrameController (Hourglass)

- (void)showHourglass:(id)sender
{
  if (hourglassWindow == nil
      /* Adding a child window to an invisible one makes it
	 appear.  */
      && emacsWindow.isVisible
      /* Adding a child window to a window on an inactive space would
	 cause space switching.  */
      && emacsWindow.isOnActiveSpace)
    {
      NSRect rect = NSMakeRect (0, 0, HOURGLASS_WIDTH, HOURGLASS_HEIGHT);
      NSProgressIndicator *indicator =
	[[NSProgressIndicator alloc] initWithFrame:rect];

      [indicator setStyle:NSProgressIndicatorStyleSpinning];
      hourglassWindow =
	[[NSWindow alloc] initWithContentRect:rect
				    styleMask:NSWindowStyleMaskBorderless
				      backing:NSBackingStoreBuffered
					defer:YES];
#if USE_ARC
      /* Increase retain count to accommodate itself to
	 released-when-closed on ARC.  Just setting
	 released-when-closed to NO leads to crash in some
	 situations.  */
      CFBridgingRetain (hourglassWindow);
#endif
      [hourglassWindow setBackgroundColor:[NSColor clearColor]];
      [hourglassWindow setOpaque:NO];
      [hourglassWindow setIgnoresMouseEvents:YES];
      [hourglassWindow setContentView:indicator];
      [indicator startAnimation:sender];
      MRC_RELEASE (indicator);
      [self updateHourglassWindowOrigin];
      hourglassWindow.appearance =
	((windowManagerState & WM_STATE_FULLSCREEN)
	 ? emacsWindow.appearanceCustomization.appearance
	 : emacsWindow.appearance);
      [emacsWindow addChildWindow:hourglassWindow ordered:NSWindowAbove];
      [hourglassWindow orderWindow:NSWindowAbove
			relativeTo:[emacsWindow windowNumber]];
    }
}

- (void)hideHourglass:(id)sender
{
  if (hourglassWindow)
    {
      [emacsWindow removeChildWindow:hourglassWindow];
      [hourglassWindow close];
      hourglassWindow = nil;
    }
}

- (void)updateHourglassWindowOrigin
{
  NSRect emacsWindowFrame = [emacsWindow frame];
  NSPoint origin;

  origin.x = (NSMaxX (emacsWindowFrame)
	      - (HOURGLASS_WIDTH
		 + (emacsWindow.hasTitleBar
		    ? HOURGLASS_RIGHT_MARGIN : HOURGLASS_TOP_MARGIN)));
  origin.y = (NSMaxY (emacsWindowFrame)
	      - (HOURGLASS_HEIGHT + HOURGLASS_TOP_MARGIN));
  [hourglassWindow setFrameOrigin:origin];
}

@end				// EmacsFrameController (Hourglass)

/* Show the spinning progress indicator for the frame F.  Create it if
   it doesn't exist yet. */

void
mac_show_hourglass (struct frame *f)
{
  if (!FRAME_TOOLTIP_P (f) && FRAME_PARENT_FRAME (f) == NULL)
    {
      /* If we try to add a child window to a window that is currently
	 hidden by window tabbing, then its parent window would
	 suddenly appear at the position where it was previously
	 hidden.  */
      Lisp_Object tab_selected_frame = mac_get_tab_group_selected_frame (f);
      if (NILP (tab_selected_frame) || XFRAME (tab_selected_frame) == f)
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

	  mac_within_gui (^{[frameController showHourglass:nil];});
	}
    }
}

/* Hide the spinning progress indicator for the frame F.  Do nothing
   it doesn't exist yet. */

void
mac_hide_hourglass (struct frame *f)
{
  if (!FRAME_TOOLTIP_P (f) && FRAME_PARENT_FRAME (f) == NULL)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{[frameController hideHourglass:nil];});
    }
}


/************************************************************************
			File selection dialog
 ************************************************************************/

@implementation EmacsSavePanel

/* Simulate kNavDontConfirmReplacement.  */

- (BOOL)_overwriteExistingFileCheck:(id)fp8
{
  return YES;
}

@end				// EmacsSavePanel

/* The actual implementation of Fx_file_dialog.  */

Lisp_Object
mac_file_dialog (Lisp_Object prompt, Lisp_Object dir,
		 Lisp_Object default_filename, Lisp_Object mustmatch,
		 Lisp_Object only_dir_p)
{
  struct frame *f = SELECTED_FRAME ();
  NSURL * __block url = nil;
  Lisp_Object file = Qnil;
  specpdl_ref count = SPECPDL_INDEX ();
  NSString *title, *directory, *nondirectory = nil;

  check_window_system (f);

  CHECK_STRING (prompt);
  CHECK_STRING (dir);

  block_input ();

  title = [NSString stringWithLispString:prompt];
  dir = Fexpand_file_name (dir, Qnil);
  directory = [NSString stringWithLispString:dir];

  if (STRINGP (default_filename))
    {
      Lisp_Object tem = Ffile_name_nondirectory (default_filename);

      nondirectory = [NSString stringWithLispString:tem];
    }

  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{
      if (NILP (only_dir_p) && NILP (mustmatch))
	{
	  /* This is a save dialog */
	  NSSavePanel *savePanel = EmacsSavePanel.savePanel;
	  NSModalResponse __block response;

	  savePanel.title = title;
	  savePanel.prompt = @"OK";
	  savePanel.nameFieldLabel = @"Enter Name:";
	  savePanel.showsTagField = NO;

	  savePanel.directoryURL = [NSURL fileURLWithPath:directory
					      isDirectory:YES];
	  if (nondirectory)
	    savePanel.nameFieldStringValue = nondirectory;
	  mac_within_app (^{response = [savePanel runModal];});
	  if (response == NSModalResponseOK)
	    url = MRC_RETAIN (savePanel.URL);
	}
      else
	{
	  /* This is an open dialog */
	  NSOpenPanel *openPanel = NSOpenPanel.openPanel;
	  NSModalResponse __block response;

	  openPanel.title = title;
	  openPanel.prompt = @"OK";
	  openPanel.allowsMultipleSelection = NO;
	  openPanel.canChooseDirectories = YES;
	  openPanel.canChooseFiles = NILP (only_dir_p);

	  openPanel.directoryURL = [NSURL fileURLWithPath:directory
					      isDirectory:YES];
	  if (nondirectory)
	    openPanel.nameFieldStringValue = nondirectory;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 110000
	  openPanel.allowedContentTypes = @[];
#else
	  openPanel.allowedFileTypes = nil;
#endif
	  mac_within_app (^{response = [openPanel runModal];});
	  if (response == NSModalResponseOK)
	    url = MRC_RETAIN (openPanel.URLs[0]);
	}
    });
  mac_menu_set_in_use (false);

  if (url.isFileURL)
    file = url.path.lispString;
  MRC_RELEASE (url);

  unblock_input ();

  /* Make "Cancel" equivalent to C-g.  */
  if (NILP (file))
    quit ();

  return unbind_to (count, file);
}


/************************************************************************
			Font selection dialog
 ************************************************************************/

@implementation EmacsFontDialogController

- (void)windowWillClose:(NSNotification *)notification
{
  [NSApp abortModal];
}

- (void)cancel:(id)sender
{
  [NSApp abortModal];
}

- (void)ok:(id)sender
{
  [NSApp stopModal];
}

- (void)changeFont:(NSFontManager *)sender
{
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel
{
  /* Underline, Strikethrough, TextColor, DocumentColor, and Shadow
     are not used in font panels.  */
  return (NSFontPanelModeMaskFace
	  | NSFontPanelModeMaskSize
	  | NSFontPanelModeMaskCollection);
}

@end				// EmacsFontDialogController

static NSView *
create_ok_cancel_buttons_view (void)
{
  NSView *view;
  NSButton *cancelButton, *okButton;
  NSDictionaryOf (NSString *, id) *viewsDictionary;

  cancelButton = [[NSButton alloc] init];
  [cancelButton setBezelStyle:NSBezelStylePush];
  [cancelButton setTitle:@"Cancel"];
  [cancelButton setAction:@selector(cancel:)];
  [cancelButton setKeyEquivalent:@"\e"];
  [cancelButton setTranslatesAutoresizingMaskIntoConstraints:NO];

  okButton = [[NSButton alloc] init];
  [okButton setBezelStyle:NSBezelStylePush];
  [okButton setTitle:@"OK"];
  [okButton setAction:@selector(ok:)];
  [okButton setKeyEquivalent:@"\r"];
  [okButton setTranslatesAutoresizingMaskIntoConstraints:NO];

  view = [[NSView alloc] initWithFrame:NSZeroRect];
  [view addSubview:cancelButton];
  [view addSubview:okButton];

  viewsDictionary = NSDictionaryOfVariableBindings (cancelButton, okButton);
  for (NSString *format in @[@"V:|-5-[cancelButton]-5-|",
			     @"[cancelButton]-[okButton(==cancelButton)]-|"])
    {
      NSArrayOf (NSLayoutConstraint *) *constraints =
	[NSLayoutConstraint
	  constraintsWithVisualFormat:format
			      options:NSLayoutFormatAlignAllCenterY
			      metrics:nil views:viewsDictionary];

      [NSLayoutConstraint activateConstraints:constraints];
    }
  [view setFrameSize:[view fittingSize]];

  MRC_RELEASE (cancelButton);
  MRC_RELEASE (okButton);

  return view;
}

Lisp_Object
mac_font_dialog (struct frame *f)
{
  Lisp_Object __block result = Qnil;

  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{
      NSFontManager *fontManager = [NSFontManager sharedFontManager];
      NSFontPanel *fontPanel = [fontManager fontPanel:YES];
      NSFont *savedSelectedFont, *selectedFont;
      BOOL savedIsMultiple;
      NSView *savedAccessoryView, *accessoryView;
      id savedDelegate, delegate;
      NSModalResponse __block response;

      savedSelectedFont = MRC_RETAIN ([fontManager selectedFont]);
      savedIsMultiple = [fontManager isMultiple];
      selectedFont = (__bridge NSFont *) macfont_get_nsctfont (FRAME_FONT (f));
      [fontManager setSelectedFont:selectedFont isMultiple:NO];

      savedAccessoryView = [fontPanel accessoryView];
      accessoryView = create_ok_cancel_buttons_view ();
      [fontPanel setAccessoryView:accessoryView];
      MRC_RELEASE (accessoryView);

      savedDelegate = [fontPanel delegate];
      delegate = [[EmacsFontDialogController alloc] init];
      [fontPanel setDelegate:delegate];

      [fontManager orderFrontFontPanel:nil];
      /* This avoids bogus font selection by -[NSTextView
	 resignFirstResponder] inside the modal loop.  */
      [fontPanel makeFirstResponder:accessoryView];

      mac_within_app (^{response = [NSApp runModalForWindow:fontPanel];});
      if (response != NSModalResponseAbort)
	{
	  selectedFont = [fontManager convertFont:[fontManager selectedFont]];
	  if (selectedFont == nil) {
	    NSLog(@"Font conversion failed");
	  } else {
	    result = macfont_nsctfont_to_spec ((__bridge void *) selectedFont);
	  }
	}

      [fontPanel setAccessoryView:savedAccessoryView];
      [fontPanel setDelegate:savedDelegate];
      MRC_RELEASE (delegate);
      if (savedSelectedFont != nil) {
	[fontManager setSelectedFont:savedSelectedFont
			  isMultiple:savedIsMultiple];
      } else {
	NSLog(@"No saved font selection, skipping");
      }
      MRC_RELEASE (savedSelectedFont);
      [fontPanel close];
    });
  mac_menu_set_in_use (false);

  return result;
}


/************************************************************************
				 Menu
 ************************************************************************/

static void update_services_menu_types (void);
static void mac_fake_menu_bar_click (EventPriority);
static void mac_press_native_menubar (struct frame *, NSInteger, NSString *,
				     EmacsMenu *, NSWindow *);

static NSString *localizedMenuTitleForEdit, *localizedMenuTitleForHelp, *localizedMenuTitleForWindow;

/* Maximum interval time in seconds between key down and modifier key
   release events when they are recognized part of a synthetic
   modified key (e.g., three-finger editing gestures in Sidecar)
   rather than that of a physical key stroke.  */
#define SYNTHETIC_MODIFIED_KEY_MAX_INTERVAL (1 / 600.0)

@implementation NSMenu (Emacs)

/* Create a new menu item using the information in *WV (except
   submenus) and add it to the end of the receiver.  */

- (NSMenuItem *)addItemWithWidgetValue:(widget_value *)wv
{
  NSMenuItem *item;

  if (name_is_separator (wv->name))
    {
      item = (NSMenuItem *) [NSMenuItem separatorItem];
      [self addItem:item];
    }
  else
    {
      NSString *itemName = [NSString stringWithUTF8String:wv->name
				     fallback:YES];
      if (wv->key != NULL)
	itemName = [NSString stringWithFormat:@"%@\t%@", itemName,
			     [NSString stringWithUTF8String:wv->key
				       fallback:YES]];

      item = [self addItemWithTitle:itemName
			     action:(wv->contents ? nil
				     : @selector(setMenuItemSelectionToTag:))
		      keyEquivalent:@""];

      [item setEnabled:wv->enabled];

      /* We can't use [NSValue valueWithBytes:&wv->help
	 objCType:@encode(Lisp_Object)] when USE_LISP_UNION_TYPE
	 defined, because NSGetSizeAndAlignment does not support bit
	 fields (at least as of Mac OS X 10.5).  */
      EmacsWeakLispObject *weakLispObject =
	[[EmacsWeakLispObject alloc] initWithLispObject:wv->help];
      item.representedObject = weakLispObject;
      MRC_RELEASE (weakLispObject);

      /* Draw radio buttons and tickboxes. */
      if (wv->selected && (wv->button_type == BUTTON_TYPE_TOGGLE
			   || wv->button_type == BUTTON_TYPE_RADIO))
	[item setState:NSControlStateValueOn];
      else
	[item setState:NSControlStateValueOff];

      [item setTag:((NSInteger) (intptr_t) wv->call_data)];
    }

  return item;
}

/* Create menu trees defined by WV and add them to the end of the
   receiver.  */

- (void)fillWithWidgetValue:(widget_value *)first_wv
{
  widget_value *wv;
  NSFont *menuFont = [NSFont menuFontOfSize:0];
  NSDictionaryOf (NSString *, id) *attributes =
    @{NSFontAttributeName : menuFont};
  NSSize spaceSize = [@" " sizeWithAttributes:attributes];
  CGFloat maxTabStop = 0;

  for (wv = first_wv; wv != NULL; wv = wv->next)
    if (!name_is_separator (wv->name) && wv->key)
      {
	NSString *itemName =
	  [NSString stringWithUTF8String:wv->name fallback:YES];
	NSSize size = [[itemName stringByAppendingString:@"\t"]
			sizeWithAttributes:attributes];

	if (maxTabStop < size.width)
	  maxTabStop = size.width;
      }

  for (wv = first_wv; wv != NULL; wv = wv->next)
    if (!name_is_separator (wv->name) && wv->key)
      {
	NSString *itemName =
	  [NSString stringWithUTF8String:wv->name fallback:YES];
	NSSize nameSize = [itemName sizeWithAttributes:attributes];
	int name_len = strlen (wv->name);
	int pad_len = ceil ((maxTabStop - nameSize.width) / spaceSize.width);
	Lisp_Object name;

	name = make_uninit_string (name_len + pad_len);
	strcpy (SSDATA (name), wv->name);
	memset (SDATA (name) + name_len, ' ', pad_len);
	wv->name = SSDATA (name);
      }

  for (wv = first_wv; wv != NULL; wv = wv->next)
    {
      NSMenuItem *item = [self addItemWithWidgetValue:wv];

      if (wv->contents)
	{
	  NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Submenu"];

	  [submenu setAutoenablesItems:NO];
	  [self setSubmenu:submenu forItem:item];
	  [submenu fillWithWidgetValue:wv->contents];
	  MRC_RELEASE (submenu);
	}
    }

  [self setDelegate:emacsController];
}

@end				// NSMenu (Emacs)

@implementation EmacsMenu

- (BOOL)nativeTracking { return nativeTracking; }
- (BOOL)nativePreparing { return nativePreparing; }
- (unsigned long)nativeGeneration { return nativeGeneration; }
- (BOOL)nativeNeedsPreparation { return nativeNeedsPreparation; }
- (void)setNativeActivationPrepared { nativeActivationPrepared = YES; }
- (unsigned long)persistentMenuGeneration { return persistentMenuGeneration; }
- (void)setPersistentMenuGeneration:(unsigned long)generation
{
  persistentMenuGeneration = generation;
}

- (BOOL)cancelNativeTrackingForQuitEvent:(NSEvent *)event
{
  /* D15: under the persistent loop, the first quit key during
     menu-bar tracking cancels it and is consumed; it sets no quit
     request and runs no Lisp.  */
  if (mac_persistent_loop_p)
    {
      if (self != NSApp.mainMenu || !persistentTracking || popup_activated ()
	  || event.type != NSEventTypeKeyDown
	  || !mac_keydown_cgevent_quit_p (event.coreGraphicsEvent))
	return NO;

      MAC_TRACE_LOOP ("quit key cancels menu-bar tracking\n");
      for (NSMenuItem *item in self.itemArray)
	[item.submenu cancelTrackingWithoutAnimation];
      [self cancelTrackingWithoutAnimation];
      [NSApp postDummyEvent];
      return YES;
    }

  if (self != NSApp.mainMenu || !nativeTracking || popup_activated ()
      || mac_operating_system_version.major < 27
      || !mac_native_menus_enabled_p ()
      || event.type != NSEventTypeKeyDown
      || !mac_keydown_cgevent_quit_p (event.coreGraphicsEvent))
    return NO;

  mac_trace_menu_lifecycle ("native-keyboard-quit", self, 0);
  if (nativeRetryMenu)
    [NSObject cancelPreviousPerformRequestsWithTarget:self
		selector:@selector(cancelAndRetryNativeMenu:)
		object:nativeRetryMenu];
  nativeRetryMenu = nil;
  nativeRetryPending = NO;
  nativeActivationPrepared = NO;
  /* Cancel the attached submenus as well as the root: cancelling only
     the root has not reliably ended AppKit's native tracking loop.  */
  for (NSMenuItem *item in self.itemArray)
    [item.submenu cancelTrackingWithoutAnimation];
  [self cancelTrackingWithoutAnimation];
  [NSApp postDummyEvent];
  return YES;
}

- (void)restoreNativeHelpMenu
{
  if (!nativeHelpPlaceholder)
    return;
  /* A newer root may already have installed its own Help menu.  */
  if (NSApp.helpMenu == nativeHelpPlaceholder)
    NSApp.helpMenu = nativeSavedHelpMenu;
  MRC_RELEASE (nativeSavedHelpMenu);
  nativeSavedHelpMenu = nil;
  MRC_RELEASE (nativeHelpPlaceholder);
  nativeHelpPlaceholder = nil;
  mac_trace_menu_lifecycle ("restore-help-search", self, 0);
}

- (void)scheduleNativeRetry:(NSMenu *)menu
{
  if (!nativeNeedsPreparation || nativeRetryPending
      || self != NSApp.mainMenu || menu.supermenu != self)
    return;
  nativeRetryPending = YES;
  nativeRetryMenu = menu; /* Retained by the delayed perform request.  */
  /* menuNeedsUpdate: permits changing items before AppKit displays them.
     Do not flash the previous Lisp snapshot while waiting for the safe
     preparation context.  Keep the submenu itself attached so that the
     tracking-mode callback can still cancel the actual tracking session.
     The retry performs a deep rebuild before pressing this heading.  */
  mac_trace_menu_lifecycle ("hide-worker-submenu", menu, menu.numberOfItems);
  [menu removeAllItems];
  [self performSelector:@selector(cancelAndRetryNativeMenu:)
	     withObject:menu afterDelay:0
		inModes:@[NSEventTrackingRunLoopMode]];
}

- (void)cancelAndRetryNativeMenu:(NSMenu *)menu
{
  nativeRetryMenu = nil;
  NSInteger index = [self indexOfItemWithSubmenu:menu];
  if (self != NSApp.mainMenu || !nativeTracking
      || !nativeNeedsPreparation || index < 0)
    {
      nativeRetryPending = NO;
      return;
    }
  NSString *title = [self itemAtIndex:index].title;
  /* Help's search field can make its popup the key window by this point.
     Capture the owning document window, then require it to regain key
     status and still match the selected frame before retrying.  */
  NSWindow *window = NSApp.mainWindow;
  if (getenv ("EMACS_MAC_TRACE_MENUS"))
    NSLog (@"Emacs worker menu: capture index=%ld owner=%p (%@) key=%p (%@)",
	   (long) index, window, NSStringFromClass (window.class),
	   NSApp.keyWindow, NSStringFromClass (NSApp.keyWindow.class));
  nativeRetryCancelling = YES;
  mac_trace_menu_lifecycle ("cancel-worker-submenu", menu, index);
  [menu cancelTrackingWithoutAnimation];
  [NSApp postDummyEvent];
  /* This runs only after native tracking has returned.  The copied
     block retains native request objects, not an unrooted Lisp frame.  */
  mac_within_lisp_deferred_if_gui_thread (^{
      if (getenv ("EMACS_MAC_TRACE_MENUS"))
	NSLog (@"Emacs worker menu: Lisp resumed gui=%d", pthread_main_np ());
      @try
	{
	  BOOL __block retry;
	  mac_within_gui (^{ retry = nativeRetryPending; });
	  if (retry)
	    mac_press_native_menubar (SELECTED_FRAME (), index, title, self, window);
	}
      @finally
	{
	  mac_within_gui (^{
	      nativeRetryPending = NO;
	      nativeRetryCancelling = NO;
	    });
	}
    });
}

- (void)dealloc
{
  [self restoreNativeHelpMenu];
  /* Queue cleanup behind any selection already captured from this root.
     The block must not retain SELF while it is being deallocated.  */
  unsigned long generation = nativeGeneration;
  mac_trace_menu_lifecycle ("dealloc-root", self, generation);
  if (generation)
    mac_within_lisp_deferred_if_gui_thread (^{
        mac_release_native_menubar (generation);
      });
#if !USE_ARC
  [super dealloc];
#endif
}

/* Forward unprocessed shortcut key events to the first responder of
   the key window.  */

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
  NSWindow *window;
  NSResponder *firstResponder;

  if ([self cancelNativeTrackingForQuitEvent:theEvent])
    return YES;

  if ([super performKeyEquivalent:theEvent])
    return YES;

  window = [NSApp keyWindow];
  if (window == nil)
    window = FRAME_MAC_WINDOW_OBJECT (SELECTED_FRAME ());
  firstResponder = [window firstResponder];
  if ([firstResponder isMemberOfClass:EmacsMainView.class])
    {
      UInt32 code;
      Boolean isEnabled;

      if (!(_IsSymbolicHotKeyEvent ((EventRef) [theEvent eventRef], &code,
				    &isEnabled)
	    && isEnabled))
	{
	  if ([theEvent type] == NSEventTypeKeyDown
	      && (([theEvent modifierFlags]
		   & NSEventModifierFlagDeviceIndependentFlagsMask)
		  == ((1UL << 31) | NSEventModifierFlagCommand))
	      && [[theEvent charactersIgnoringModifiers] isEqualToString:@"c"])
	    {
	      /* Probably Command-C from "Speak selected text."  */
	      [NSApp sendAction:@selector(copy:) to:nil from:nil];

	      return YES;
	    }

	  if (theEvent.type == NSEventTypeKeyDown)
	    {
	      SEL action = NULL;
	      NSEventModifierFlags modifierFlags =
		(theEvent.modifierFlags
		 & NSEventModifierFlagDeviceIndependentFlagsMask);

	      switch (theEvent.keyCode)
		{
		case kVK_ANSI_Z:
		  if (modifierFlags == NSEventModifierFlagCommand)
		    action = NSSelectorFromString (@"synthetic-undo:");
		  else if (modifierFlags == (NSEventModifierFlagCommand
					     | NSEventModifierFlagShift))
		    action = NSSelectorFromString (@"synthetic-redo:");
		  break;

		case kVK_ANSI_X:
		  if (modifierFlags == NSEventModifierFlagCommand)
		    action = NSSelectorFromString (@"synthetic-cut:");
		  break;

		case kVK_ANSI_C:
		  if (modifierFlags == NSEventModifierFlagCommand)
		    action = NSSelectorFromString (@"synthetic-copy:");
		  break;

		case kVK_ANSI_V:
		  if (modifierFlags == NSEventModifierFlagCommand)
		    action = NSSelectorFromString (@"synthetic-paste:");
		  break;
		}
	      if (action)
		{
		  EventRef event = mac_peek_next_event ();

		  if (event)
		    {
		      OSType event_class = GetEventClass (event);
		      UInt32 event_kind = GetEventKind (event);
		      EventTime event_time = GetEventTime (event);

		      if (event_class == kEventClassKeyboard
			  && event_kind == kEventRawKeyModifiersChanged
			  && (event_time - theEvent.timestamp
			      <= SYNTHETIC_MODIFIED_KEY_MAX_INTERVAL))
			{
			  [NSApp sendAction:action to:nil from:nil];

			  return YES;
			}
		    }
		}
	    }

	  /* Note: this is not necessary for binaries built on Mac OS
	     X 10.5 because -[NSWindow sendEvent:] now sends keyDown:
	     to the first responder even if the command-key modifier
	     is set when it is not a key equivalent.  But we keep this
	     for binary compatibility.
	     Update: this is necessary for passing Control-Tab to
	     Emacs on Mac OS X 10.5 and later.  */
	  /* With the xwidget support, -[NSMenu performKeyEquivalent:]
	     might be called outside read_socket_hook.  This means
	     keyboard quit is not held in hold_quit and causes longjmp
	     within the GUI thread.  We reroute the event to the GUI
	     queue to avoid this.  */
	  if (!emacsController.doesHoldQuit
	      && mac_keydown_cgevent_quit_p (theEvent.coreGraphicsEvent))
	    [NSApp postEvent:theEvent atStart:YES];
	  else
	    [firstResponder keyDown:theEvent];

	  return YES;
	}
    }
  else if ([theEvent type] == NSEventTypeKeyDown)
    {
      NSEventModifierFlags flags = [theEvent modifierFlags];

      flags &= ANY_KEY_MODIFIER_FLAGS_MASK;

      if (flags == NSEventModifierFlagCommand)
	{
	  NSString *characters = [theEvent charactersIgnoringModifiers];
	  SEL action = NULL;

	  if ([characters isEqualToString:@"x"])
	    action = @selector(cut:);
	  else if ([characters isEqualToString:@"c"])
	    action = @selector(copy:);
	  else if ([characters isEqualToString:@"v"])
	    action = @selector(paste:);

	  if (action)
	    return [NSApp sendAction:action to:nil from:nil];
	}

      if ([[theEvent charactersIgnoringModifiers] length] == 1
	  && mac_keydown_cgevent_quit_p ([theEvent coreGraphicsEvent]))
	{
	  /* This is necessary for avoiding hang when canceling
	     pop-up dictionary with C-g on OS X 10.11.  */
	  BOOL __block sent;

	  mac_within_app (^{
	      sent = [NSApp sendAction:@selector(cancel:) to:nil from:nil];
	    });

	  return sent;
	}
    }

  return NO;
}

- (void)menuDidBeginTracking:(NSNotification *)notification
{
  mac_trace_menu_lifecycle ("begin", self, 0);
  if (mac_persistent_loop_p)
    {
      persistentTracking = !popup_activated ();
      return;
    }
  if (nativeTracking)
    return;
  if ((nativeGeneration || nativeNeedsPreparation) && !popup_activated ())
    {
      nativeTracking = YES;
      nativeActivationPrepared = NO;
      return;
    }
  if (!popup_activated () && !mac_persistent_loop_p)
    {
      NSLog (@"Canceling unexpected menu tracking: %@", [NSApp currentEvent]);
      [self cancelTracking];
    }
}

- (void)menuDidEndTracking:(NSNotification *)notification
{
  mac_trace_menu_lifecycle ("end", self, 0);
  persistentTracking = NO;
  nativeTracking = NO;
  [self restoreNativeHelpMenu];
  if (nativeRetryPending && !nativeRetryCancelling)
    {
      [NSObject cancelPreviousPerformRequestsWithTarget:self
		    selector:@selector(cancelAndRetryNativeMenu:)
		    object:nativeRetryMenu];
      nativeRetryMenu = nil;
      nativeRetryPending = NO;
    }
}

- (void)update
{
  mac_trace_menu_lifecycle ("update", self, 0);
  if (mac_worker_menus_enabled_p () && mac_native_menus_enabled_p ()
      && mac_operating_system_version.major >= 27
      && self == NSApp.mainMenu && !nativePreparing && !nativeTracking
      && !popup_activated () && !mac_select_allow_lisp_evaluation)
    {
      nativeNeedsPreparation = !(nativeActivationPrepared && nativeGeneration);
      if (nativeNeedsPreparation && !nativeHelpPlaceholder
	  && NSApp.helpMenu.supermenu == self)
	{
	  /* AppKit adds Help search independently of our submenu items.
	     An off-bar Help menu suppresses that UI during the unprepared
	     tracking attempt; nil would let AppKit choose a menu itself.  */
	  nativeSavedHelpMenu = MRC_RETAIN (NSApp.helpMenu);
	  nativeHelpPlaceholder = [[NSMenu alloc] initWithTitle:@""];
	  NSApp.helpMenu = nativeHelpPlaceholder;
	  mac_trace_menu_lifecycle ("suppress-help-search", self, 0);
	}
    }
  if (mac_native_menus_enabled_p ()
      && mac_operating_system_version.major >= 27
      && self == [NSApp mainMenu] && !nativePreparing && !nativeTracking
      && !popup_activated () && mac_select_allow_lisp_evaluation)
    {
      unsigned long previousGeneration = nativeGeneration;
      [self restoreNativeHelpMenu];
      nativeNeedsPreparation = NO;
      nativeActivationPrepared = NO;
      nativePreparing = YES;
      @try
        {
          mac_within_lisp (^{
              nativeGeneration = mac_prepare_native_menubar ();
            });
        }
      @finally
        {
          nativePreparing = NO;
        }
      /* A selection may already be queued when this update prepares a
         newer command table.  Retire the old table on the same FIFO,
         rather than replacing its Lisp roots during preparation.  */
      if (previousGeneration)
        mac_within_lisp_deferred_if_gui_thread (^{
            mac_release_native_menubar (previousGeneration);
          });
      mac_trace_menu_lifecycle ("prepared", self, nativeGeneration);
    }
  [super update];
}

@end				// EmacsMenu

@implementation EmacsWeakLispObject

- (instancetype)initWithLispObject:(Lisp_Object)anObject
{
  self = [self init];
  if (self == nil)
    return nil;

  object = anObject;

  return self;
}

- (Lisp_Object)lispObject
{
  return object;
}

@end				// EmacsWeakLispObject

@implementation EmacsController (Menu)

- (void)menuNeedsUpdate:(NSMenu *)menu
{
  if ([NSApp.mainMenu isKindOfClass:EmacsMenu.class])
    [(EmacsMenu *) NSApp.mainMenu scheduleNativeRetry:menu];
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
  id object = item.representedObject;
  EmacsWeakLispObject *helpObject =
    ([object isKindOfClass:EmacsWeakLispObject.class] ? object : nil);

  if (popup_activated ())
    {
      /* The Lisp thread is parked on the popup's Lisp-to-GUI request
	 (mac_loop_request_depth > 0), so mac_within_lisp's synchronous
	 round trip is safe and immediate; unchanged from before the
	 persistent loop (D13's "keep the current behaviour" case).  */
      mac_within_lisp (^{
	  show_help_echo (helpObject ? helpObject.lispObject : Qnil,
			  Qnil, Qnil, Qnil);
	});
      return;
    }

  if (!mac_persistent_loop_p)
    return;

  /* D13: outside a parked popup (menu-bar highlighting), help-echo is
     advisory and must never block the GUI thread waiting for Lisp.
     Queue it fire-and-forget and coalesce so that only the latest of
     a burst of highlight notifications actually runs.  The help object
     is not protected from GC by itself; it stays reachable only while
     the snapshot published with this root menu exists, so check that
     on the Lisp thread before dereferencing it.  */
  static unsigned long mac_loop_menu_help_echo_generation;
  unsigned long my_generation
    = __atomic_add_fetch (&mac_loop_menu_help_echo_generation, 1,
			  __ATOMIC_RELAXED);
  NSMenu *root = menu;

  while (root.supermenu)
    root = root.supermenu;

  unsigned long snapshot
    = ([root isKindOfClass:EmacsMenu.class]
       ? [(EmacsMenu *) root persistentMenuGeneration] : 0);

  mac_loop_queue_lisp_block (^{
      if (my_generation != __atomic_load_n (&mac_loop_menu_help_echo_generation,
					    __ATOMIC_RELAXED))
	return;
      show_help_echo ((helpObject && mac_menu_bar_snapshot_live_p (snapshot)
		       ? helpObject.lispObject : Qnil),
		      Qnil, Qnil, Qnil);
    });
}

/* Start menu bar tracking and return when it is completed.

   The tracking is done inside the application loop because otherwise
   we can't pop down an error dialog caused by a Service invocation,
   for example.  */

- (void)trackMenuBar
{
  mac_within_app (^{
      mac_trace_menu_lifecycle ("pump-enter", [NSApp mainMenu], 0);
      /* Mac OS X 10.2 doesn't regard untilDate:nil as polling.  */
      NSDate *expiration = [NSDate distantPast];

      while (1)
	{
	  NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
				  untilDate:expiration
				  inMode:NSDefaultRunLoopMode dequeue:YES];
	  NSDate *limitDate;

	  if (event == nil)
	    {
	      /* There can be a pending mouse down event on the menu
		 bar at least on Mac OS X 10.5 with Command-Shift-/ ->
		 search with keyword -> select.  Also, some
		 kEventClassMenu event is still pending on Mac OS X
		 10.6 when selecting menu item via search field on the
		 Help menu.  */
	      if (mac_peek_next_event ())
		continue;
	    }
	  else
	    {
	      [NSApp sendEvent:event];
	      continue;
	    }

	  /* This seems to be necessary for selecting menu item via
	     search field in the Help menu on Mac OS X 10.6.  */
	  limitDate = [[NSRunLoop currentRunLoop]
			limitDateForMode:NSDefaultRunLoopMode];
	  if (limitDate == nil
	      || [limitDate timeIntervalSinceNow] > 0)
	    break;
	}

      mac_trace_menu_lifecycle ("pump-exit", [NSApp mainMenu], 0);
      [emacsController updatePresentationOptions];
    });
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
  NSMenu *menu = [[NSMenu alloc] init];

  for (NSWindow *window in [NSApp windows])
    if (!window.hasTitleBar && window.parentWindow == nil
	&& !window.isExcludedFromWindowsMenu
	&& ([window isVisible] || [window isMiniaturized]))
      {
	NSMenuItem *item =
	  [[NSMenuItem alloc] initWithTitle:[window title]
				     action:@selector(makeKeyAndOrderFront:)
			      keyEquivalent:@""];

	[item setTarget:window];
	if ([window isKeyWindow])
	  [item setState:NSControlStateValueOn];
	else if ([window isMiniaturized])
	  {
	    NSImage *image = [NSImage imageNamed:@"NSMenuItemDiamond"];

	    if (image)
	      {
		[item setOnStateImage:image];
		[item setState:NSControlStateValueOn];
	      }
	  }
	[menu addItem:item];
	MRC_RELEASE (item);
      }
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *newFrameItem = [[NSMenuItem alloc]
                                 initWithTitle:@"New Frame"
					action:@selector(newFrame:)
                                 keyEquivalent:@""];
  [newFrameItem setTarget:self];
  [menu addItem:newFrameItem];
  MRC_RELEASE (newFrameItem);

  return MRC_AUTORELEASE (menu);
}

/* Methods for the NSUserInterfaceItemSearching protocol.  */

/* This might be called from a non-main thread.  */
- (void)searchForItemsWithSearchString:(NSString *)searchString
			   resultLimit:(NSInteger)resultLimit
		    matchedItemHandler:(void (^)(NSArray *items))handleMatchedItems
{
  if (mac_persistent_loop_p && !pthread_main_np ())
    {
      /* AppKit may search on a background queue; read the topics on
	 the GUI thread under the access rules.  */
      dispatch_async (dispatch_get_main_queue (), ^{
	  [self searchForItemsWithSearchString:searchString
				   resultLimit:resultLimit
			    matchedItemHandler:handleMatchedItems];
	});
      return;
    }

  int token = mac_loop_begin_lisp_access ();

  if (token == MAC_LOOP_NO_ACCESS)
    {
      /* Lisp is busy: no topics rather than a stall.  */
      handleMatchedItems (@[]);
      return;
    }

  NSMutableArrayOf (NSString *) *items =
    [NSMutableArray arrayWithCapacity:resultLimit];
  Lisp_Object rest;

  for (rest = Vmac_help_topics; CONSP (rest); rest = XCDR (rest))
    if (STRINGP (XCAR (rest)))
      {
	NSString *string = [NSString stringWithUTF8LispString:(XCAR (rest))];
	NSRange searchRange = NSMakeRange (0, [string length]);
	NSRange foundRange;

	if ([NSApp searchString:searchString inUserInterfaceItemString:string
		    searchRange:searchRange foundRange:&foundRange])
	  {
	    [items addObject:string];
	    if ([items count] == resultLimit)
	      break;
	  }
      }
  mac_loop_end_lisp_access (token);

  handleMatchedItems (items);
}

- (NSArrayOf (NSString *) *)localizedTitlesForItem:(id)item
{
  return @[item];
}

- (void)performActionForItem:(id)item
{
  /* The action reads selectedHelpTopic synchronously.  */
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self performActionForItem:item]);

  selectedHelpTopic = item;
  [NSApp sendAction:(NSSelectorFromString (@"select-help-topic:"))
		 to:nil from:self];
  selectedHelpTopic = nil;
}

- (void)showAllHelpTopicsForSearchString:(NSString *)searchString
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self showAllHelpTopicsForSearchString:
					searchString]);

  searchStringForAllHelpTopics = searchString;
  [NSApp sendAction:(NSSelectorFromString (@"show-all-help-topics:"))
		 to:nil from:self];
  searchStringForAllHelpTopics = nil;
}

@end				// EmacsController (Menu)

@implementation EmacsFrameController (Menu)

- (void)popUpMenu:(NSMenu *)menu atLocationInEmacsView:(NSPoint)location
{
  if (!mac_popup_menu_add_contextual_menu)
    [menu popUpMenuPositioningItem:nil atLocation:location inView:emacsView];
  else
    {
      NSEvent *event =
	[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
			   location:[emacsView convertPoint:location toView:nil]
		      modifierFlags:0 timestamp:0
		       windowNumber:[emacsWindow windowNumber]
			    context:[NSGraphicsContext currentContext]
			eventNumber:0 clickCount:1 pressure:0];

      [NSMenu popUpContextMenu:menu withEvent:event forView:emacsView];
    }
}

@end				// EmacsFrameController (Menu)

static void
mac_track_menu_with_block (void (^block) (void))
{
  eassert (!pthread_main_np ());
  Lisp_Object mini_window, old_show_help_function = Vshow_help_function;

  /* Temporarily bind Vshow_help_function to
     tooltip-show-help-non-mode (or nil if the minibuffer frame is not
     visible) because we don't want tooltips during menu tracking.  */
  Vshow_help_function = Qnil;
  mini_window = FRAME_MINIBUF_WINDOW (SELECTED_FRAME ());
  if (WINDOWP (mini_window))
    {
      struct frame *mini_frame = XFRAME (WINDOW_FRAME (XWINDOW (mini_window)));

      if (FRAME_MAC_P (mini_frame)
	  && FRAME_VISIBLE_P (mini_frame))
	Vshow_help_function = intern ("tooltip-show-help-non-mode");
    }
  mac_within_gui_allowing_inner_lisp (block);
  Vshow_help_function = old_show_help_function;
}

/* Activate the menu bar of frame F.

   To activate the menu bar, we use the button-press event that was
   saved in dpyinfo->saved_menu_event.

   Return the selection.  */

static int
mac_activate_menubar_1 (struct frame *f)
{
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  EventRef menu_event;

  update_services_menu_types ();
  menu_event = dpyinfo->saved_menu_event;
  if (menu_event)
    {
      dpyinfo->saved_menu_event = NULL;
      PostEventToQueue (GetMainEventQueue (), menu_event, kEventPriorityHigh);
      ReleaseEvent (menu_event);
    }
  else
    mac_fake_menu_bar_click (kEventPriorityHigh);
  mac_menu_set_in_use (true);
  mac_track_menu_with_block (^{[emacsController trackMenuBar];});
  mac_menu_set_in_use (false);

  return [emacsController getAndClearMenuItemSelection];
}

/* Activate the menu bar of frame F.
   This is called from keyboard.c when it gets the
   MENU_BAR_ACTIVATE_EVENT out of the Emacs event queue.

   To activate the menu bar, we call mac_activate_menubar_1.

   But first we recompute the menu bar contents (the whole tree).

   The reason for saving the button event until here, instead of
   passing it to the toolkit right away, is that we can safely
   execute Lisp code.  */

void
mac_activate_menubar (struct frame *f)
{
  int selection;

  eassert (FRAME_MAC_P (f));

  set_frame_menubar (f, true);
  block_input ();
  selection = mac_activate_menubar_1 (f);
  unblock_input ();

  if (selection)
    find_and_call_menu_selection (f, f->menu_bar_items_used, f->menu_bar_vector,
				  (void *) (intptr_t) selection);
}

/* Press a native menu item using a bridge that permits menu preparation.
   A deferred retry must still belong to the same root, heading and window.  */

static void
mac_press_native_menubar (struct frame *f, NSInteger index, NSString *title,
			 EmacsMenu *expectedMenu, NSWindow *expectedWindow)
{
  if (expectedMenu)
    {
      bool __block current;
      mac_within_gui (^{
	  current = expectedMenu == NSApp.mainMenu
	    && expectedWindow == NSApp.keyWindow
	    && FRAME_LIVE_P (f) && FRAME_MAC_P (f)
	    && FRAME_MAC_WINDOW_OBJECT (f) == expectedWindow;
	  if (getenv ("EMACS_MAC_TRACE_MENUS"))
	    NSLog (@"Emacs worker menu: ownership current=%d root=%d key=%d frame=%d expected=%p key-now=%p main-now=%p",
		   current, expectedMenu == NSApp.mainMenu,
		   expectedWindow == NSApp.keyWindow,
		   FRAME_LIVE_P (f) && FRAME_MAC_P (f)
		   && FRAME_MAC_WINDOW_OBJECT (f) == expectedWindow,
		   expectedWindow, NSApp.keyWindow, NSApp.mainWindow);
	});
      if (!current)
	return;
    }

  set_frame_menubar (f, true);
  mac_within_gui_allowing_inner_lisp (^{
      /* Menu preparation can synchronously call Lisp during the press.
         This bridge permits it even outside the select event loop.  */
      bool saved_allow_lisp = mac_select_allow_lisp_evaluation;
      mac_select_allow_lisp_evaluation = true;
      @try
	{
	  mac_within_app (^{
	      [emacsController showMenuBar];
	      [[NSApp mainMenu] update];
	      NSMenu *menu = [NSApp mainMenu];
	      NSMenuItem *item = index >= 0 && index < menu.numberOfItems
		? MRC_RETAIN ([menu itemAtIndex:index]) : nil;
	      @try
		{
		  BOOL pressed = NO;
		  if (item && item.enabled && !item.hidden
		      && (!title || [item.title isEqualToString:title])
		      && (!expectedWindow || NSApp.keyWindow == expectedWindow)
		      && (!expectedMenu
			  || ([menu isKindOfClass:EmacsMenu.class]
			      && [(EmacsMenu *) menu nativeGeneration]
			      && ![(EmacsMenu *) menu nativeNeedsPreparation])))
		    {
		      if (mac_worker_menus_enabled_p ()
			  && [menu isKindOfClass:EmacsMenu.class])
			[(EmacsMenu *) menu setNativeActivationPrepared];
		      pressed = [item accessibilityPerformPress];
		    }
		  mac_trace_menu_lifecycle ("keyboard-press", [NSApp mainMenu],
				    pressed);
		}
	      @finally
		{
		  MRC_RELEASE (item);
		}
	    });
	}
      @finally
	{
	  mac_select_allow_lisp_evaluation = saved_allow_lisp;
	}
    });
}

/* Return false only outside the native opt-in: a failed native press
   may already have changed menu tracking state.  */
bool
mac_focus_native_menubar (struct frame *f)
{
  if (mac_operating_system_version.major < 27
      || !mac_native_menus_enabled_p ())
    return false;
  mac_press_native_menubar (f, 0, nil, nil, nil);
  return true;
}

/* Set up the initial menu bar.  */

static void
init_menu_bar (void)
{
  NSMenu *servicesMenu = [[NSMenu alloc] init];
  NSMenu *windowsMenu = [[NSMenu alloc] init];
  NSMenu *appleMenu = [[NSMenu alloc] init];
  EmacsMenu *mainMenu = [[EmacsMenu alloc] init];
  NSBundle *appKitBundle = [NSBundle bundleWithIdentifier:@"com.apple.AppKit"];
  NSString *localizedTitleForServices = /* Mac OS X 10.6 and later.  */
    NSLocalizedStringFromTableInBundle (@"Services", @"Services",
					appKitBundle, NULL);

  [NSApp setServicesMenu:servicesMenu];

  [NSApp setWindowsMenu:windowsMenu];

  [appleMenu addItemWithTitle:@"About Emacs"
	     action:@selector(about:)
	     keyEquivalent:@""];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu addItemWithTitle:(mac_operating_system_version.major >= 13
			       ? @"Settings..." : @"Preferences...")
	     action:@selector(preferences:) keyEquivalent:@""];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu setSubmenu:servicesMenu
		forItem:[appleMenu addItemWithTitle:localizedTitleForServices
					     action:nil keyEquivalent:@""]];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu addItemWithTitle:@"Hide Emacs"
	     action:@selector(hide:) keyEquivalent:@"h"];
  [[appleMenu addItemWithTitle:@"Hide Others"
	      action:@selector(hideOtherApplications:) keyEquivalent:@"h"]
    setKeyEquivalentModifierMask:(NSEventModifierFlagOption
				  | NSEventModifierFlagCommand)];
  [appleMenu addItemWithTitle:@"Show All"
	     action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu addItemWithTitle:@"Quit Emacs"
	     action:@selector(terminate:) keyEquivalent:@""];
  /* -[NSApplication setAppleMenu:] is hidden on Mac OS X 10.4.  */
  [NSApp performSelector:@selector(setAppleMenu:) withObject:appleMenu];

  [mainMenu setAutoenablesItems:NO];
  [mainMenu setSubmenu:appleMenu
	    forItem:[mainMenu addItemWithTitle:@""
			      action:nil keyEquivalent:@""]];
  [NSApp setMainMenu:mainMenu];

  // Tell appkit to manage the Window menu named "Window"
  [mainMenu setSubmenu:windowsMenu
	       forItem:[mainMenu addItemWithTitle:@"Window"
					   action:nil keyEquivalent:@""]];


  MRC_RELEASE (mainMenu);
  MRC_RELEASE (appleMenu);
  MRC_RELEASE (windowsMenu);
  MRC_RELEASE (servicesMenu);

  localizedMenuTitleForEdit =
    MRC_RETAIN (NSLocalizedStringFromTableInBundle (@"Edit", @"InputManager",
						    appKitBundle, NULL));
  localizedMenuTitleForHelp =
    MRC_RETAIN (NSLocalizedStringFromTableInBundle (@"Help", @"HelpManager",
						    appKitBundle, NULL));

  localizedMenuTitleForWindow =
    MRC_RETAIN (NSLocalizedStringFromTableInBundle (@"Window", @"MenuCommands",
						    appKitBundle, NULL));
}

/* Fill menu bar with the items defined by FIRST_WV.  If DEEP_P,
   consider the entire menu trees we supply, rather than just the menu
   bar item names.  Return false if native tracking prevented the update,
   so the caller can invalidate its display cache and retry.

   Under the persistent loop, GENERATION is the snapshot generation
   the caller (set_frame_menubar) already published for the command
   table these widget values were built from (0 if not applicable, or
   under the old loop where it is unused).  When this fill installs a
   new root menu, that root is stamped with GENERATION so that
   -[EmacsMenu setMenuItemSelectionToTag:] can bind a later selection
   back to the matching snapshot (D4/D5).  */

bool
mac_fill_menubar (widget_value *first_wv, bool deep_p,
		  unsigned long generation)
{
  bool __block applied = false;
  mac_within_gui (^{
      NSMenu *newMenu, *mainMenu = [NSApp mainMenu];
      NSMenu *helpMenu = nil, *windowMenu = nil;
      NSInteger index = 1, nitems = [mainMenu numberOfItems];
      bool needs_update_p = deep_p;

      /* Redisplay must not replace a menu currently owned by AppKit.  */
      if ([mainMenu isKindOfClass:EmacsMenu.class]
          && [(EmacsMenu *) mainMenu nativeTracking])
        return;

      newMenu = [[EmacsMenu alloc] init];
      [newMenu setAutoenablesItems:NO];
      if (generation)
	[(EmacsMenu *) newMenu setPersistentMenuGeneration:generation];

      for (widget_value *wv = first_wv; wv != NULL; wv = wv->next, index++)
	{
	  NSString *title = CFBridgingRelease (CFStringCreateWithCString
					       (NULL, wv->name,
						kCFStringEncodingMacRoman));
	  NSMenu *submenu;

	  /* The title of the Help menu needs to be localized in order
	     for Spotlight for Help to be installed on Mac OS X
	     10.5.  */
	  if ([title isEqualToString:@"Help"])
	    title = localizedMenuTitleForHelp;

          /* To make Input Manager add "Special Characters..." to the
             "Edit" menu, we have to localize the menu title. */
	  else if ([title isEqualToString:@"Edit"])
	    title = localizedMenuTitleForEdit;

          /* Localize Window Menu for consistency with AppKit provided
             menu items. */
	  else if ([title isEqualToString:@"Window"])
	    title = localizedMenuTitleForWindow;


	  if (!needs_update_p)
	    {
	      if (index >= nitems)
		needs_update_p = true;
	      else
		{
		  submenu = [mainMenu itemAtIndex:index].submenu;
		  if (!(submenu && [title isEqualToString:submenu.title]))
		    needs_update_p = true;
		}
	    }

	  submenu = [[NSMenu alloc] initWithTitle:title];
	  [submenu setAutoenablesItems:NO];
	  if (mac_worker_menus_enabled_p ())
	    [submenu setDelegate:emacsController];

	  if (title == localizedMenuTitleForHelp)
	    helpMenu = submenu;
	  else if (title == localizedMenuTitleForWindow)
	    windowMenu = submenu;

	  [newMenu setSubmenu:submenu
		      forItem:[newMenu addItemWithTitle:title action:nil
					  keyEquivalent:@""]];

	  if (wv->contents)
	    [submenu fillWithWidgetValue:wv->contents];

	  MRC_RELEASE (submenu);
	}

      if (!needs_update_p && index != nitems)
	needs_update_p = true;

      if (needs_update_p)
	{

          if ([mainMenu isKindOfClass:EmacsMenu.class]
              && [(EmacsMenu *) mainMenu nativePreparing])
            {
              /* Keep the root, and matching top-level items/submenus,
                 alive across AppKit's update-to-tracking transition.  */
              NSInteger count = [newMenu numberOfItems];
              for (NSInteger i = 0; i < count; i++)
                {
                  NSMenuItem *item = MRC_RETAIN ([newMenu itemAtIndex:0]);
                  [newMenu removeItem:item];
                  NSMenuItem *old = i + 1 < [mainMenu numberOfItems]
                    ? [mainMenu itemAtIndex:i + 1] : nil;
                  if (old && [old.title isEqualToString:item.title]
                      && old.submenu && item.submenu)
                    {
                      NSMenu *source = item.submenu, *target = old.submenu;
                      [target removeAllItems];
                      while ([source numberOfItems])
                        {
                          NSMenuItem *child = MRC_RETAIN ([source itemAtIndex:0]);
                          [source removeItem:child];
                          [target addItem:child];
                          MRC_RELEASE (child);
                        }
                      [target setDelegate:emacsController];
                      if (source == helpMenu) helpMenu = target;
                      if (source == windowMenu) windowMenu = target;
                    }
                  else
                    {
                      if (old) [mainMenu removeItemAtIndex:i + 1];
                      [mainMenu insertItem:item atIndex:i + 1];
                    }
                  MRC_RELEASE (item);
                }
              while ([mainMenu numberOfItems] > count + 1)
                [mainMenu removeItemAtIndex:[mainMenu numberOfItems] - 1];
            }
          else
            {
	  /* Tracking-end can precede visual dismissal on macOS 27.
	     Cancel before detaching any part of the old tree, while its
	     observers are still registered, to avoid a stranded popup.  */
	  if (mac_operating_system_version.major >= 27
	      && mac_native_menus_enabled_p ())
	    {
	      mac_trace_menu_lifecycle ("cancel-before-replace", mainMenu, 0);
	      [mainMenu cancelTracking];
	      mac_trace_menu_lifecycle ("cancel-before-replace-done", mainMenu, 0);
	    }
	  NSMenuItem *appleMenuItem = MRC_RETAIN ([mainMenu itemAtIndex:0]);

	  mac_trace_menu_lifecycle ("detach-apple-item", mainMenu, 0);
	  [mainMenu removeItem:appleMenuItem];
	  [newMenu insertItem:appleMenuItem atIndex:0];
	  MRC_RELEASE (appleMenuItem);

	  [NSApp setMainMenu:newMenu];
            }

	  if (windowMenu && [windowMenu numberOfItems])
	    [NSApp setWindowsMenu:windowMenu];

	  if (helpMenu)
	    [NSApp setHelpMenu:helpMenu];
	}

      MRC_RELEASE (newMenu);
      applied = true;
    });
  return applied;
}

static void
mac_fake_menu_bar_click (EventPriority priority)
{
  OSStatus err = noErr;
  const EventKind kinds[] = {kEventMouseDown, kEventMouseUp};
  Point point = {0, 10};	/* vertical, horizontal */
  NSScreen *mainScreen = [NSScreen mainScreen];
  int i;

  if ([mainScreen canShowMenuBar])
    {
      NSRect baseScreenFrame, mainScreenFrame;

      baseScreenFrame = mac_get_base_screen_frame ();
      mainScreenFrame = [mainScreen frame];
      point.h += NSMinX (mainScreenFrame) - NSMinX (baseScreenFrame);
      point.v += - NSMaxY (mainScreenFrame) + NSMaxY (baseScreenFrame);
    }

  mac_within_gui (^{[emacsController showMenuBar];});

  /* CopyEventAs is not available on Mac OS X 10.2.  */
  for (i = 0; i < 2; i++)
    {
      EventRef event;

      if (err == noErr)
	err = CreateEvent (NULL, kEventClassMouse, kinds[i], 0,
			   kEventAttributeNone, &event);
      if (err == noErr)
	{
	  const UInt32 modifiers = 0, count = 1;
	  const EventMouseButton button = kEventMouseButtonPrimary;
	  const struct {
	    EventParamName name;
	    EventParamType type;
	    ByteCount size;
	    const void *data;
	  } params[] = {
	    {kEventParamMouseLocation, typeQDPoint, sizeof (Point), &point},
	    {kEventParamKeyModifiers, typeUInt32, sizeof (UInt32), &modifiers},
	    {kEventParamMouseButton, typeMouseButton,
	     sizeof (EventMouseButton), &button},
	    {kEventParamClickCount, typeUInt32, sizeof (UInt32), &count}};
	  int j;

	  for (j = 0; j < countof (params); j++)
	    if (err == noErr)
	      err = SetEventParameter (event, params[j].name, params[j].type,
				       params[j].size, params[j].data);
	  if (err == noErr)
	    err = PostEventToQueue (GetMainEventQueue (), event, priority);
	  ReleaseEvent (event);
	}
    }
}

/* Pop up the menu for frame F defined by FIRST_WV at X/Y and loop until the
   menu pops down.  Return the selection.  */

int
create_and_show_popup_menu (struct frame *f, widget_value *first_wv, int x, int y,
			    bool for_click)
{
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Popup"];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  EmacsFrameController *focusFrameController =
    dpyinfo->mac_focus_frame ? FRAME_CONTROLLER (dpyinfo->mac_focus_frame) : nil;

  /* Inserting a menu item in a non-main thread causes hang on macOS
     Big Sur beta 8.  */
  mac_within_gui (^{
      [menu setAutoenablesItems:NO];
      [menu fillWithWidgetValue:first_wv->contents];
    });

  mac_menu_set_in_use (true);
  mac_track_menu_with_block (^{
      [focusFrameController noteLeaveEmacsView];
      [frameController popUpMenu:menu
	   atLocationInEmacsView:(NSMakePoint (x, y))];
      [focusFrameController noteEnterEmacsView];
    });
  mac_menu_set_in_use (false);

  /* Must reset this manually because the button release event is not
     passed to Emacs event loop. */
  FRAME_DISPLAY_INFO (f)->grabbed = 0;
  MRC_RELEASE (menu);

  return [emacsController getAndClearMenuItemSelection];
}


/************************************************************************
			     Popup Dialog
 ************************************************************************/

@implementation EmacsDialogView

#define DIALOG_BUTTON_BORDER (6)
#define DIALOG_TEXT_BORDER (1)

#define EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG \
  (@"EmacsTouchBarItemIdentifierDialog")

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (BOOL)isFlipped
{
  return YES;
}

- (instancetype)initWithWidgetValue:(widget_value *)wv
{
  const char *dialog_name;
  int nb_buttons, first_group_count, i;
  CGFloat buttons_height, text_height, inner_width, inner_height;
  NSString *message;
  NSRect frameRect;
  NSButton * __unsafe_unretained *buttons;
  NSButton *defaultButton = nil;
  NSTextField *text;
  NSImageView *icon;

  self = [self init];

  if (self == nil)
    return nil;

  dialog_name = wv->name;
  nb_buttons = dialog_name[1] - '0';
  first_group_count = nb_buttons - (dialog_name[4] - '0');

  wv = wv->contents;
  message = [NSString stringWithUTF8String:wv->value fallback:YES];

  wv = wv->next;

  buttons = ((NSButton * __unsafe_unretained *)
	     alloca (sizeof (NSButton *) * nb_buttons));

  for (i = 0; i < nb_buttons; i++)
    {
      NSButton *button = [[NSButton alloc] init];
      NSString *label = [NSString stringWithUTF8String:wv->value fallback:YES];

      [self addSubview:button];
      MRC_RELEASE (button);

      [button setBezelStyle:NSBezelStylePush];
      [button setFont:[NSFont systemFontOfSize:0]];
      [button setTitle:label];

      [button setEnabled:wv->enabled];
      if (defaultButton == nil)
	defaultButton = button;

      [button sizeToFit];
      frameRect = [button frame];
      if (frameRect.size.width < (DIALOG_BUTTON_MIN_WIDTH
				  + DIALOG_BUTTON_BORDER * 2))
	frameRect.size.width = (DIALOG_BUTTON_MIN_WIDTH
				+ DIALOG_BUTTON_BORDER * 2);
      else if (frameRect.size.width > (DIALOG_MAX_INNER_WIDTH
				       + DIALOG_BUTTON_BORDER * 2))
	frameRect.size.width = (DIALOG_MAX_INNER_WIDTH
				+ DIALOG_BUTTON_BORDER * 2);
      [button setFrameSize:frameRect.size];

      [button setTag:((NSInteger) (intptr_t) wv->call_data)];
      [button setTarget:self];
      [button setAction:@selector(stopModalWithTagAsCode:)];

      buttons[i] = button;
      wv = wv->next;
    }

  /* Layout buttons.  [buttons[i] frame] is set relative to the
     bottom-right corner of the inner box.  */
  {
    CGFloat bottom, right, max_height, left_align_shift;
    CGFloat button_cell_width, button_cell_height;
    NSButton *button;

    inner_width = DIALOG_MIN_INNER_WIDTH;
    bottom = right = max_height = 0;

    for (i = 0; i < nb_buttons; i++)
      {
	button = buttons[i];
	frameRect = [button frame];
	button_cell_width = NSWidth (frameRect) - DIALOG_BUTTON_BORDER * 2;
	button_cell_height = NSHeight (frameRect) - DIALOG_BUTTON_BORDER * 2;
	if (right - button_cell_width < - inner_width)
	  {
	    if (i != first_group_count
		&& right - button_cell_width >= - DIALOG_MAX_INNER_WIDTH)
	      inner_width = - (right - button_cell_width);
	    else
	      {
		bottom -= max_height + DIALOG_BUTTON_BUTTON_VERTICAL_SPACE;
		right = max_height = 0;
	      }
	  }
	if (max_height < button_cell_height)
	  max_height = button_cell_height;
	frameRect.origin = NSMakePoint ((right - button_cell_width
					 - DIALOG_BUTTON_BORDER),
					(bottom - button_cell_height
					 - DIALOG_BUTTON_BORDER));
	[button setFrameOrigin:frameRect.origin];
	right = (NSMinX (frameRect) + DIALOG_BUTTON_BORDER
		 - DIALOG_BUTTON_BUTTON_HORIZONTAL_SPACE);
	if (i == first_group_count - 1)
	  right -= DIALOG_BUTTON_BUTTON_HORIZONTAL_SPACE;
      }
    buttons_height = - (bottom - max_height);

    left_align_shift = - (inner_width + NSMinX (frameRect)
			  + DIALOG_BUTTON_BORDER);
    for (i = nb_buttons - 1; i >= first_group_count; i--)
      {
	button = buttons[i];
	frameRect = [button frame];

	if (bottom != NSMaxY (frameRect) - DIALOG_BUTTON_BORDER)
	  {
	    left_align_shift = - (inner_width + NSMinX (frameRect)
				  + DIALOG_BUTTON_BORDER);
	    bottom = NSMaxY (frameRect) - DIALOG_BUTTON_BORDER;
	  }
	frameRect.origin.x += left_align_shift;
	[button setFrameOrigin:frameRect.origin];
      }
  }

  /* Create a static text control and measure its bounds.  */
  frameRect = NSMakeRect (0, 0, inner_width + DIALOG_TEXT_BORDER * 2, 0);
  text = [[NSTextField alloc] initWithFrame:frameRect];

  [self addSubview:text];
  MRC_RELEASE (text);

  [text setFont:[NSFont systemFontOfSize:0]];
  [text setStringValue:message];
  [text setDrawsBackground:NO];
  [text setSelectable:NO];
  [text setBezeled:NO];

  [text sizeToFit];
  frameRect = [text frame];
  text_height = NSHeight (frameRect) - DIALOG_TEXT_BORDER * 2;
  if (text_height < DIALOG_TEXT_MIN_HEIGHT)
    text_height = DIALOG_TEXT_MIN_HEIGHT;

  /* Place buttons. */
  inner_height = (text_height + DIALOG_TEXT_BUTTONS_VERTICAL_SPACE
		  + buttons_height);
  for (i = 0; i < nb_buttons; i++)
    {
      NSButton *button = buttons[i];

      frameRect = [button frame];
      frameRect.origin.x += DIALOG_LEFT_MARGIN + inner_width;
      frameRect.origin.y += DIALOG_TOP_MARGIN + inner_height;
      [button setFrameOrigin:frameRect.origin];
    }

  /* Place text.  */
  frameRect = NSMakeRect (DIALOG_LEFT_MARGIN - DIALOG_TEXT_BORDER,
			  DIALOG_TOP_MARGIN - DIALOG_TEXT_BORDER,
			  inner_width + DIALOG_TEXT_BORDER * 2,
			  text_height + DIALOG_TEXT_BORDER * 2);
  [text setFrame:frameRect];

  /* Create the application icon at the upper-left corner.  */
  frameRect = NSMakeRect (DIALOG_ICON_LEFT_MARGIN, DIALOG_ICON_TOP_MARGIN,
			  DIALOG_ICON_WIDTH, DIALOG_ICON_HEIGHT);
  icon = [[NSImageView alloc] initWithFrame:frameRect];
  [self addSubview:icon];
  MRC_RELEASE (icon);
  [icon setImage:[NSImage imageNamed:@"NSApplicationIcon"]];

  [defaultButton setKeyEquivalent:@"\r"];

  frameRect =
    NSMakeRect (0, 0,
		DIALOG_LEFT_MARGIN + inner_width + DIALOG_RIGHT_MARGIN,
		DIALOG_TOP_MARGIN + inner_height + DIALOG_BOTTOM_MARGIN);
  [self setFrame:frameRect];

  return self;
}

- (void)stopModalWithTagAsCode:(id)sender
{
  [NSApp stopModalWithCode:[sender tag]];
}

/* Pop down if escape or quit key is pressed.  */

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
  BOOL quit = NO;

  if ([theEvent type] == NSEventTypeKeyDown)
    {
      NSString *characters = [theEvent characters];

      if ([characters length] == 1
	  && ([characters characterAtIndex:0] == '\033'
	      || mac_keydown_cgevent_quit_p ([theEvent coreGraphicsEvent])))
	quit = YES;
    }

  if (quit)
    {
      [NSApp stopModal];

      return YES;
    }

  return [super performKeyEquivalent:theEvent];
}

- (NSTouchBar *)makeTouchBar
{
  NSTouchBar *touchBar = [[NS_TOUCH_BAR alloc] init];

  touchBar.delegate = self;
  touchBar.defaultItemIdentifiers = @[EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG];
  touchBar.principalItemIdentifier = EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG;

  return MRC_AUTORELEASE (touchBar);
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
  NSTouchBarItem *result = nil;

  if ([identifier isEqualToString:EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG])
    {
      NSMutableArrayOf (NSView *) *touchButtons;
      NSScrollView *scrollView;
      NSStackView *stackView;
      NSView *contentView;
      NSCustomTouchBarItem *item;

      touchButtons = [NSMutableArray arrayWithCapacity:self.subviews.count];
      for (NSButton *button in self.subviews)
	if ([button isKindOfClass:NSButton.class] && button.isEnabled)
	  {
	    NSButton *touchButton = [NSButton buttonWithTitle:button.title
						       target:button.target
						       action:button.action];

	    touchButton.tag = button.tag;
	    touchButton.keyEquivalent = button.keyEquivalent;
	    touchButton.translatesAutoresizingMaskIntoConstraints = NO;
	    [touchButton.widthAnchor
		constraintLessThanOrEqualToConstant:120].active = YES;
	    [touchButtons insertObject:touchButton atIndex:0];
	  }

      scrollView = [[NSScrollView alloc] init];
      stackView = [NSStackView stackViewWithViews:touchButtons];
      scrollView.documentView = stackView;
      contentView = scrollView.contentView;
      [stackView.trailingAnchor
	  constraintEqualToAnchor:contentView.trailingAnchor].active = YES;
      [stackView.widthAnchor
	  constraintGreaterThanOrEqualToAnchor:contentView.widthAnchor].active =
	YES;
      [stackView.topAnchor
	  constraintEqualToAnchor:contentView.topAnchor].active = YES;
      [stackView.bottomAnchor
	  constraintEqualToAnchor:contentView.bottomAnchor].active = YES;

      item = [[NS_CUSTOM_TOUCH_BAR_ITEM alloc] initWithIdentifier:identifier];
      item.view = scrollView;
      MRC_RELEASE (scrollView);
      result = MRC_AUTORELEASE (item);
    }

  return result;
}

@end				// EmacsDialogView

static void
pop_down_dialog (Lisp_Object arg)
{
  NSPanel *panel;
  NSModalSession session;

  memcpy (&session, SDATA (XCDR (arg)), sizeof (NSModalSession));

  block_input ();

  panel = CFBridgingRelease (xmint_pointer (XCAR (arg)));
  mac_within_gui_allowing_inner_lisp (^{
      [panel close];
      [NSApp endModalSession:session];
    });
  mac_menu_set_in_use (false);

  unblock_input ();
}

/* Pop up the dialog for frame F defined by FIRST_WV and loop until the
   dialog pops down.  Return the selection.  */

int
create_and_show_dialog (struct frame *f, widget_value *first_wv)
{
  int __block result = 0;
  CFTypeRef __block cfpanel;
  NSPanel * __unsafe_unretained __block panel;

  mac_within_gui (^{
      EmacsDialogView *dialogView =
	[[EmacsDialogView alloc] initWithWidgetValue:first_wv];

      cfpanel =
	CF_ESCAPING_BRIDGE ([[NSPanel alloc]
			      initWithContentRect:[dialogView frame]
					styleMask:NSWindowStyleMaskTitled
					  backing:NSBackingStoreBuffered
					    defer:YES]);
      panel = (__bridge NSPanel *) cfpanel;

      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
      NSRect panelFrame, windowFrame, visibleFrame;

      panelFrame = [panel frame];
      windowFrame = [window frame];
      panelFrame.origin.x = floor (windowFrame.origin.x
				   + (NSWidth (windowFrame)
				      - NSWidth (panelFrame)) * 0.5f);
      if (NSHeight (panelFrame) < NSHeight (windowFrame))
	panelFrame.origin.y = floor (windowFrame.origin.y
				     + (NSHeight (windowFrame)
					- NSHeight (panelFrame)) * 0.8f);
      else
	panelFrame.origin.y = NSMaxY (windowFrame) - NSHeight (panelFrame);

      visibleFrame = [[window screen] visibleFrame];
      if (NSMaxX (panelFrame) > NSMaxX (visibleFrame))
	panelFrame.origin.x -= NSMaxX (panelFrame) - NSMaxX (visibleFrame);
      if (NSMinX (panelFrame) < NSMinX (visibleFrame))
	panelFrame.origin.x += NSMinX (visibleFrame) - NSMinX (panelFrame);
      if (NSMinY (panelFrame) < NSMinY (visibleFrame))
	panelFrame.origin.y += NSMinY (visibleFrame) - NSMinY (panelFrame);
      if (NSMaxY (panelFrame) > NSMaxY (visibleFrame))
	panelFrame.origin.y -= NSMaxY (panelFrame) - NSMaxY (visibleFrame);

      [panel setFrameOrigin:panelFrame.origin];
      [panel setContentView:dialogView];
      MRC_RELEASE (dialogView);
#if USE_ARC
      dialogView = nil;
      window = nil;
#endif
      [panel setTitle:(first_wv->name[0] == 'Q'
		       ? @"Question" : @"Information")];
      panel.animationBehavior = NSWindowAnimationBehaviorAlertPanel;
      [panel makeKeyAndOrderFront:nil];
    });

  mac_menu_set_in_use (true);
  {
    NSModalSession __block session;
    mac_within_gui_allowing_inner_lisp (^{
	session = [NSApp beginModalSessionForWindow:panel];
      });
    Lisp_Object session_obj =
      make_unibyte_string ((char *) &session, sizeof (NSModalSession));
    specpdl_ref specpdl_count = SPECPDL_INDEX ();
    NSModalResponse __block response;

    record_unwind_protect (pop_down_dialog,
			   Fcons (make_mint_ptr ((void *) cfpanel),
				  session_obj));
    do
      {
	struct timespec next_time = timer_check ();

	mac_within_gui_allowing_inner_lisp (^{
	    NSDate *expiration;

	    if (timespec_valid_p (next_time))
	      expiration = [NSDate dateWithTimeIntervalSinceNow:(timespectod
								 (next_time))];
	    else
	      expiration = [NSDate distantFuture];

	    do
	      {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:expiration];

		/* This is necessary on 10.5 to make the dialog
		   visible when the user tries logout/shutdown.  */
		[panel makeKeyAndOrderFront:nil];
		response = [NSApp runModalSession:session];
		if (response >= 0)
		  result = response;
	      }
	    while (response == NSModalResponseContinue
		   && expiration.timeIntervalSinceNow > 0);
	  });
      }
    while (response == NSModalResponseContinue);

    unbind_to (specpdl_count, Qnil);
  }

  return result;
}


/************************************************************************
			       Printing
 ************************************************************************/

@implementation EmacsPrintProxyView

- (instancetype)initWithViews:(NSArrayOf (NSView *) *)theViews
{
  CGFloat width = 0, height = 0;

  for (NSView *view in theViews)
    {
      NSRect rect = view.bounds;

      if (width < NSWidth (rect))
	width = NSWidth (rect);
      height += NSHeight (rect);
    }

  self = [self initWithFrame:NSMakeRect (0, 0, width, height)];
  if (self == nil)
    return nil;

  views = [theViews copy];

  return self;
}

#if !USE_ARC
- (void)dealloc
{
  MRC_RELEASE (views);
  [super dealloc];
}
#endif

- (void)print:(id)sender
{
  mac_within_app (^{
      [[NSPrintOperation printOperationWithView:self] runOperation];
    });
}

- (BOOL)knowsPageRange:(NSRangePointer)range
{
  range->location = 1;
  range->length = [views count];

  return YES;
}

- (NSRect)rectForPage:(NSInteger)page
{
  NSRect rect = [views[page - 1] bounds];
  NSInteger i;

  rect.origin = NSZeroPoint;
  for (i = 0; i < page - 1; i++)
    rect.origin.y += NSHeight ([views[i] bounds]);

  return rect;
}

- (void)drawRect:(NSRect)aRect
{
  CGFloat y = 0;
  NSInteger i = 0, pageCount = views.count;

  while (y < NSMinY (aRect) && i < pageCount)
    {
      NSView *view = views[i++];

      y += NSHeight (view.bounds);
    }
  while (y < NSMaxY (aRect) && i < pageCount)
    {
      NSView *view = views[i++];
      NSRect rect = view.bounds;
      NSGraphicsContext *gcontext = NSGraphicsContext.currentContext;
      NSAffineTransform *transform = NSAffineTransform.transform;

      [gcontext saveGraphicsState];
      [transform translateXBy:(- NSMinX (rect)) yBy:(y - NSMinY (rect))];
      [transform concat];
      [EmacsView globallyDisableUpdateLayer:YES];
      [view displayRectIgnoringOpacity:rect inContext:gcontext];
      [EmacsView globallyDisableUpdateLayer:NO];
      [gcontext restoreGraphicsState];
      y += NSHeight (view.bounds);
    }
}

@end				// EmacsPrintProxyView

static void
mac_cgcontext_release (Lisp_Object arg)
{
  CGContextRef context = xmint_pointer (arg);

  block_input ();
  CGContextRelease (context);
  unblock_input ();
}

Lisp_Object
mac_export_frames (Lisp_Object frames, Lisp_Object type)
{
  Lisp_Object result = Qnil;
  struct frame *f;
  NSWindow *window;
  NSView *contentView;
  specpdl_ref count = SPECPDL_INDEX ();

  redisplay_preserve_echo_area (31);

  f = XFRAME (XCAR (frames));
  frames = XCDR (frames);

  block_input ();
  window = FRAME_MAC_WINDOW_OBJECT (f);
  contentView = [window contentView];
  if (EQ (type, Qpng))
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);
      Lisp_Object __block string = Qnil;

      mac_within_gui (^{
	  NSBitmapImageRep *bitmap = [frameController bitmapImageRep];
	  NSData *data =
	    [bitmap representationUsingType:NSBitmapImageFileTypePNG
				 properties:@{}];

	  if (data)
	    string = [data lispString];
	});
      result = string;
    }
  else if (EQ (type, Qpdf))
    {
      CGContextRef context = NULL;
      NSMutableData *data = [NSMutableData dataWithCapacity:0];
      CGDataConsumerRef consumer =
	CGDataConsumerCreateWithCFData ((__bridge CFMutableDataRef) data);
      CGRect __block mediaBox;

      mac_within_gui (^{
	  mediaBox = NSRectToCGRect (contentView.bounds);
	});
      if (consumer)
	{
	  context = CGPDFContextCreate (consumer, &mediaBox, NULL);
	  CGDataConsumerRelease (consumer);
	}
      if (context)
	{
	  record_unwind_protect (mac_cgcontext_release,
				 make_mint_ptr (context));
	  while (1)
	    {
	      mac_within_gui (^{
		  CGRect mediaBox = NSRectToCGRect (contentView.bounds);
		  NSData *mediaBoxData =
		    [NSData dataWithBytes:&mediaBox length:(sizeof (CGRect))];
		  NSDictionary *pageInfo =
		    @{((__bridge NSString *) kCGPDFContextMediaBox)
		      : mediaBoxData};
		  NSGraphicsContext *gcontext =
		    [NSGraphicsContext graphicsContextWithCGContext:context
							    flipped:NO];

		  CGPDFContextBeginPage (context,
					 (__bridge CFDictionaryRef) pageInfo);
		  [EmacsView globallyDisableUpdateLayer:YES];
		  [contentView
		    displayRectIgnoringOpacity:(NSRectFromCGRect (mediaBox))
				     inContext:gcontext];
		  [EmacsView globallyDisableUpdateLayer:NO];
		  CGPDFContextEndPage (context);
		});

	      if (NILP (frames))
		break;

	      f = XFRAME (XCAR (frames));
	      frames = XCDR (frames);
	      window = FRAME_MAC_WINDOW_OBJECT (f);
	      contentView = [window contentView];

	      unblock_input ();
	      maybe_quit ();
	      block_input ();
	    }

	  CGPDFContextClose (context);
	  result = [data lispString];
	}
    }
  unblock_input ();

  unbind_to (count, Qnil);

  return result;
}

void
mac_page_setup_dialog (void)
{
  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{
      mac_within_app (^{[[NSPageLayout pageLayout] runModal];});
    });
  mac_menu_set_in_use (false);
}

Lisp_Object
mac_get_page_setup (void)
{
  NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
  NSSize paperSize = [printInfo paperSize];
  NSPaperOrientation orientation = [printInfo orientation];
  CGFloat leftMargin, rightMargin, topMargin, bottomMargin;
  CGFloat pageWidth, pageHeight;
  Lisp_Object orientation_symbol;

  leftMargin = [printInfo leftMargin];
  rightMargin = [printInfo rightMargin];
  topMargin = [printInfo topMargin];
  bottomMargin = [printInfo bottomMargin];

  if (orientation == NSPaperOrientationPortrait)
    {
      orientation_symbol = Qportrait;
      pageWidth = paperSize.width - leftMargin - rightMargin;
      pageHeight = paperSize.height - topMargin - bottomMargin;
    }
  else
    {
      orientation_symbol = Qlandscape;
      pageWidth = paperSize.width - topMargin - bottomMargin;
      pageHeight = paperSize.height - leftMargin - rightMargin;
    }

  return list (Fcons (Qorientation, orientation_symbol),
	       Fcons (Qwidth, make_float (pageWidth)),
	       Fcons (Qheight, make_float (pageHeight)),
	       Fcons (Qleft_margin, make_float (leftMargin)),
	       Fcons (Qright_margin, make_float (rightMargin)),
	       Fcons (Qtop_margin, make_float (topMargin)),
	       Fcons (Qbottom_margin, make_float (bottomMargin)));
}

void
mac_print_frames_dialog (Lisp_Object frames)
{
  EmacsPrintProxyView * __block printProxyView;
  NSMutableArrayOf (NSView *) *views = [NSMutableArray arrayWithCapacity:0];

  while (!NILP (frames))
    {
      struct frame *f = XFRAME (XCAR (frames));
      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
      NSView *contentView = [window contentView];

      [views addObject:contentView];
      frames = XCDR (frames);
    }

  mac_within_gui (^{
      printProxyView = [[EmacsPrintProxyView alloc] initWithViews:views];
    });
  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{[printProxyView print:nil];});
  mac_menu_set_in_use (false);
  MRC_RELEASE (printProxyView);
}


/************************************************************************
			  Selection support
 ************************************************************************/

/* Get a reference to the selection corresponding to the symbol SYM.
   The reference is set to *SEL, and it becomes NULL if there's no
   corresponding selection.  Clear the selection if CLEAR_P is
   true.  */

OSStatus
mac_get_selection_from_symbol (Lisp_Object sym, bool clear_p, Selection *sel)
{
  Lisp_Object str = Fget (sym, Qmac_pasteboard_name);

  if (!STRINGP (str))
    *sel = NULL;
  else
    {
      NSPasteboardName name = [NSString stringWithUTF8LispString:str];

      *sel = (__bridge Selection) [NSPasteboard pasteboardWithName:name];
      if (clear_p)
	[(__bridge NSPasteboard *)*sel declareTypes:@[] owner:nil];
    }

  return noErr;
}

/* Get a pasteboard data type from the symbol SYM.  Return nil if no
   corresponding data type.  If SEL is non-zero, the return value is
   non-zero only when the SEL has the data type.  */

static NSPasteboardType
get_pasteboard_data_type_from_symbol (Lisp_Object sym, Selection sel)
{
  Lisp_Object str = Fget (sym, Qmac_pasteboard_data_type);
  NSPasteboardType dataType;

  if (STRINGP (str))
    dataType = [NSString stringWithUTF8LispString:str];
  else
    dataType =
      CFBridgingRelease (mac_uti_create_with_mime_type
			 ((__bridge CFStringRef)
			  [NSString stringWithLispString:(SYMBOL_NAME (sym))]));

  if (dataType && sel)
    {
      NSArrayOf (NSPasteboardType) *array = @[dataType];

      dataType = [(__bridge NSPasteboard *)sel availableTypeFromArray:array];
    }

  return dataType;
}

/* Check if the symbol SYM has a corresponding selection target type.  */

bool
mac_valid_selection_target_p (Lisp_Object sym)
{
  return STRINGP (Fget (sym, Qmac_pasteboard_data_type));
}

/* Clear the selection whose reference is *SEL.  */

OSStatus
mac_clear_selection (Selection *sel)
{
  [(__bridge NSPasteboard *)*sel declareTypes:@[] owner:nil];

  return noErr;
}

/* Get ownership information for SEL.  Emacs can detect a change of
   the ownership by comparing saved and current values of the
   ownership information.  */

Lisp_Object
mac_get_selection_ownership_info (Selection sel)
{
  return INT_TO_INTEGER ([(__bridge NSPasteboard *)sel changeCount]);
}

/* Return true if VALUE is a valid selection value for TARGET.  */

bool
mac_valid_selection_value_p (Lisp_Object value, Lisp_Object target)
{
  return STRINGP (value);
}

/* Put Lisp object VALUE to the selection SEL.  The target type is
   specified by TARGET. */

OSStatus
mac_put_selection_value (Selection sel, Lisp_Object target, Lisp_Object value)
{
  NSPasteboardType dataType =
    get_pasteboard_data_type_from_symbol (target, nil);
  NSPasteboard *pboard = (__bridge NSPasteboard *)sel;

  if (dataType == nil)
    return noTypeErr;

  [pboard addTypes:@[dataType] owner:nil];

  if (dataType == nil)
    return noTypeErr;
  else
    {
      NSData *data = [NSData dataWithBytes:(SDATA (value))
				    length:(SBYTES (value))];

      return [pboard setData:data forType:dataType] ? noErr : noTypeErr;
    }
}

/* Check if data for the target type TARGET is available in SEL.  */

bool
mac_selection_has_target_p (Selection sel, Lisp_Object target)
{
  return get_pasteboard_data_type_from_symbol (target, sel) != nil;
}

/* Get data for the target type TARGET from SEL and create a Lisp
   object.  Return nil if failed to get data.  */

Lisp_Object
mac_get_selection_value (Selection sel, Lisp_Object target)
{
  Lisp_Object result = Qnil;
  NSPasteboardType dataType =
    get_pasteboard_data_type_from_symbol (target, sel);

  if (dataType)
    {
      NSData *data = [(__bridge NSPasteboard *)sel dataForType:dataType];

      if (data)
	result = [data lispString];
    }

  return result;
}

/* Get the list of target types in SEL.  The return value is a list of
   target type symbols including MIME type ones.  */

Lisp_Object
mac_get_selection_target_list (Selection sel)
{
  Lisp_Object result = Qnil, rest, target;
  NSArrayOf (NSPasteboardType) *types = ((__bridge NSPasteboard *) sel).types;

  for (NSPasteboardType type in types)
    {
      NSString *mimeType = CFBridgingRelease (mac_uti_copy_mime_type
					      ((__bridge CFStringRef) type));
      if (mimeType)
	{
	  target = Fintern (mimeType.lispString, Qnil);
	  if (NILP (Fmemq (target, result)))
	    result = Fcons (target, result);
	}
    }

  for (rest = Vselection_converter_alist; CONSP (rest); rest = XCDR (rest))
    if (CONSP (XCAR (rest))
	&& (target = XCAR (XCAR (rest)),
	    SYMBOLP (target))
	&& mac_selection_has_target_p (sel, target)
	&& NILP (Fmemq (target, result)))
      result = Fcons (target, result);

  return result;
}


/************************************************************************
			 Apple event support
 ************************************************************************/

static NSMutableSetOf (NSNumber *) *registered_apple_event_specs;

@implementation NSAppleEventDescriptor (Emacs)

- (OSErr)copyDescTo:(AEDesc *)desc
{
  return AEDuplicateDesc ([self aeDesc], desc);
}

@end				// NSAppleEventDescriptor (Emacs)

@implementation EmacsController (AppleEvent)

static OSErr
mac_handle_apple_event_descriptors (NSAppleEventDescriptor *event,
				    NSAppleEventDescriptor *replyEvent)
{
  OSErr err;
  AEDesc reply;

  err = [replyEvent copyDescTo:&reply];
  if (err == noErr)
    {
      const AEDesc *event_ptr = [event aeDesc];

      if (event_ptr)
	err = mac_handle_apple_event (event_ptr, &reply, 0);
      AEDisposeDesc (&reply);
    }

  return err;
}

- (void)handleAppleEvent:(NSAppleEventDescriptor *)event
	  withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
  if (mac_persistent_loop_p && !mac_loop_gui_has_lisp_access ())
    {
      int token = mac_loop_begin_lisp_access ();

      if (token != MAC_LOOP_NO_ACCESS)
	{
	  mac_handle_apple_event_descriptors (event, replyEvent);
	  mac_loop_end_lisp_access (token);
	  mac_loop_wake_lisp ();
	  return;
	}

      /* Lisp is busy: suspend the event and handle it later with
	 access, as if it had just arrived.  */
      NSAppleEventManager *manager =
	[NSAppleEventManager sharedAppleEventManager];
      NSAppleEventManagerSuspensionID suspensionID =
	[manager suspendCurrentAppleEvent];

      if (suspensionID == NULL)
	return;
      MAC_TRACE_LOOP ("Apple event suspended until Lisp access\n");
      mac_loop_with_access_now_or_later (^{
	  [manager setCurrentAppleEventAndReplyEventWithSuspensionID:
		     suspensionID];
	  mac_apple_event_suspended_by_caller = true;
	  OSErr err = (mac_handle_apple_event_descriptors
		       (manager.currentAppleEvent,
			manager.currentReplyAppleEvent));
	  mac_apple_event_suspended_by_caller = false;
	  if (err != noErr)
	    [manager resumeWithSuspensionID:suspensionID];
	});
      return;
    }

  mac_handle_apple_event_descriptors (event, replyEvent);
}

@end				// EmacsController (AppleEvent)

/* Register pairs of Apple event class and ID in mac_apple_event_map
   if they have not registered yet.  Each registered pair is stored in
   registered_apple_event_specs as a unsigned long long value whose
   upper and lower half stand for class and ID, respectively.  */

static void
update_apple_event_handler (void)
{
  Lisp_Object keymap = get_keymap (Vmac_apple_event_map, 0, 0);

  if (NILP (keymap))
    return;

  mac_map_keymap (keymap, false, ^(Lisp_Object key, Lisp_Object binding) {
      if (!SYMBOLP (key))
	return;
      AEEventClass eventClass;
      if (!mac_string_to_four_char_code (Fget (key, Qmac_apple_event_class),
					 &eventClass))
	return;
      Lisp_Object keymap = get_keymap (binding, 0, 0);
      if (NILP (keymap))
	return;

      mac_map_keymap (keymap, false, ^(Lisp_Object key, Lisp_Object binding) {
	  if (NILP (binding) || EQ (binding, Qundefined) || !SYMBOLP (key))
	    return;
	  AEEventID eventID;
	  if (!mac_string_to_four_char_code (Fget (key, Qmac_apple_event_id),
					     &eventID))
	    return;

	  NSNumber *value = @(((unsigned long long) eventClass << 32)
			      + eventID);

	  if (![registered_apple_event_specs containsObject:value])
	    {
	      [[NSAppleEventManager sharedAppleEventManager]
		setEventHandler:emacsController
		    andSelector:@selector(handleAppleEvent:withReplyEvent:)
		  forEventClass:eventClass andEventID:eventID];
	      [registered_apple_event_specs addObject:value];
	    }
	});
    });
}

static void
init_apple_event_handler (void)
{
  /* Force NSScriptSuiteRegistry to initialize here so our custom
     handlers may not be overwritten by lazy initialization.  */
  [NSScriptSuiteRegistry sharedScriptSuiteRegistry];
  registered_apple_event_specs = [[NSMutableSet alloc] initWithCapacity:0];
  update_apple_event_handler ();
  atexit (cleanup_all_suspended_apple_events);
}


/************************************************************************
                      Drag and drop support
 ************************************************************************/

static NSMutableArrayOf (NSPasteboardType) *registered_dragged_types;

/* Global state maintained during a drag-and-drop operation.  */

/* Flag that indicates if a drag-and-drop operation is in progress.  */
static bool mac_dnd_in_progress;

/* Whether or not to move the tooltip along with the mouse pointer
   during drag-and-drop.  */
static bool mac_dnd_update_tooltip;

/* Whether or not to return a frame from
   `mac_dnd_begin_drag_and_drop'.  */
static enum mac_return_frame_mode mac_dnd_return_frame;

/* The frame that should be returned by
   `mac_dnd_begin_drag_and_drop'.  */
static struct frame *mac_dnd_return_frame_object;

/* The action the drop target actually chose to perform.  */
static NSDragOperation mac_dnd_action;

/* The action we want the drop target to perform.  The drop target may
   elect to perform some different action, which is guaranteed to be
   in `mac_dnd_action' upon completion of a drop.  */
static NSDragOperation mac_dnd_wanted_action;

@implementation EmacsMainView (DragAndDrop)

- (void)setDragHighlighted:(BOOL)flag
{
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController setOverlayViewHighlighted:flag];
}

- (BOOL)allowsLispEvaluationInDragging
{
  /* Lisp evaluation is safe in the `x-begin-drag' context, because no
     other Lisp threads are running unlike the `mac_select' one.  */
  return mac_dnd_in_progress
#if MAC_SELECT_ALLOW_LISP_EVALUATION
    || mac_select_allow_lisp_evaluation
#endif
    ;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
  [self setDragHighlighted:YES];

  return NSDragOperationGeneric;
}

- (BOOL)wantsPeriodicDraggingUpdates
{
  return self.allowsLispEvaluationInDragging;
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
  if (self.allowsLispEvaluationInDragging)
    {
      NSPoint location = [self convertPoint:sender.draggingLocation
				   fromView:nil];
      Lisp_Object frame, x, y;

      XSETFRAME (frame, self.emacsFrame);
      XSETINT (x, location.x);
      XSETINT (y, location.y);
      mac_within_lisp (^{
	  safe_calln (Vmac_drag_motion_function, frame, x, y);
	  redisplay ();
	});
    }

  return NSDragOperationGeneric;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
  [self setDragHighlighted:NO];
}

/* Convert the NSDragOperation value OPERATION to a list of symbols for
   the corresponding drag actions.  */

static Lisp_Object
drag_operation_to_actions (NSDragOperation operation)
{
  Lisp_Object result = Qnil;

  if (operation & NSDragOperationCopy)
    result = Fcons (Qcopy, result);
  if (operation & NSDragOperationLink)
    result = Fcons (Qlink, result);
  if (operation & NSDragOperationGeneric)
    result = Fcons (Qgeneric, result);
  if (operation & NSDragOperationPrivate)
    result = Fcons (Qprivate, result);
  if (operation & NSDragOperationMove)
    result = Fcons (Qmove, result);
  if (operation & NSDragOperationDelete)
    result = Fcons (Qdelete, result);

  return result;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
  /* The pasteboard is only valid during this call: reject the drop
     rather than wait if Lisp is busy.  */
  MAC_LOOP_QUERY_NEEDS_LISP (BOOL, NO, [self performDragOperation:sender]);

  struct frame *f = [self emacsFrame];
  NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
  NSDragOperation operation = [sender draggingSourceOperationMask];
  Lisp_Object items = Qnil, arg;
  BOOL hasItems = NO;

  [self setDragHighlighted:NO];

  for (NSPasteboardItem *pi in [[sender draggingPasteboard] pasteboardItems])
    {
      Lisp_Object item = Qnil;
      /* The elements in -[NSView registeredDraggedTypes] are in no
	 particular order.  */
      NSPasteboardType type =
	[pi availableTypeFromArray:registered_dragged_types];

      if (type)
	{
	  NSData *data = [pi dataForType:type];

	  if (data)
	    {
	      item = Fcons ([type UTF8LispString], [data lispString]);
	      hasItems = YES;
	    }
	}
      items = Fcons (item, items);
    }

  if (!hasItems)
    return NO;

  arg = list2 (QCitems, Fnreverse (items));
  arg = Fcons (QCactions, Fcons (drag_operation_to_actions (operation), arg));

  EVENT_INIT (inputEvent);
  inputEvent.kind = DRAG_N_DROP_EVENT;
  inputEvent.modifiers = 0;
  inputEvent.timestamp = [[NSApp currentEvent] timestamp] * 1000;
  XSETINT (inputEvent.x, point.x);
  XSETINT (inputEvent.y, point.y);
  XSETFRAME (inputEvent.frame_or_window, f);
  inputEvent.arg = arg;
  [self sendAction:action to:target];

  return YES;
}

@end				// EmacsMainView (DragAndDrop)

@implementation EmacsFrameController (DragAndDrop)

- (void)registerEmacsViewForDraggedTypes:(NSArrayOf (NSPasteboardType) *)pboardTypes
{
  [emacsView registerForDraggedTypes:pboardTypes];
}

- (void)setOverlayViewHighlighted:(BOOL)flag
{
  [overlayView setHighlighted:flag];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
  return mac_dnd_wanted_action;
}

- (void)draggingSession:(NSDraggingSession *)session
           movedToPoint:(NSPoint)screenPoint
{
  if (mac_dnd_return_frame != RETURN_FRAME_NEVER)
    {
      NSInteger windowNumber = [NSWindow windowNumberAtPoint:screenPoint
				 belowWindowWithWindowNumber:0];
      NSWindow *window = [NSApp windowWithWindowNumber:windowNumber];

      if (window != emacsWindow)
	mac_dnd_return_frame = RETURN_FRAME_NOW;

      if (mac_dnd_return_frame != RETURN_FRAME_NOW
	  || ![window isKindOfClass:EmacsWindow.class])
	goto out;

      EmacsFrameController *frameController = ((EmacsFrameController *)
					       window.delegate);
      struct frame *f = frameController.emacsFrame;

      if (FRAME_TOOLTIP_P (f))
	goto out;

      mac_dnd_return_frame_object = f;

      NSPoint location =
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
	[window convertPointFromScreen:screenPoint];
#else
	[window convertRectFromScreen:(NSMakeRect (screenPoint.x, screenPoint.y,
						   0, 0))].origin;
#endif
      NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
					location:location
				   modifierFlags:0 timestamp:0
				    windowNumber:windowNumber context:nil
				      characters:@"\e"
				charactersIgnoringModifiers:@"\e"
				       isARepeat:NO keyCode:kVK_Escape];

      [NSApp postEvent:event atStart:YES];
    }

 out:
  if (mac_dnd_update_tooltip)
    mac_move_tooltip_to_mouse_location ();
}

- (void)draggingSession:(NSDraggingSession *)session
	   endedAtPoint:(NSPoint)screenPoint
	      operation:(NSDragOperation)operation
{
  mac_dnd_action = operation;
  mac_dnd_in_progress = false;
}

- (void)trackDraggingObjects:(NSArrayOf (id <NSPasteboardWriting>) *)objects
     unregisterAsDestination:(BOOL)unregisterAsDestination
{
  NSMutableArrayOf (NSImage *) *images =
    [NSMutableArray arrayWithCapacity:objects.count];
  CGFloat totalImageWidth = 0, maxImageHeight = 0;

  for (id <NSPasteboardWriting> object in objects)
    {
      NSImage *image = nil;

      if (!mac_dnd_update_tooltip && [object isKindOfClass:NSURL.class])
	{
	  NSURL *url = (NSURL *) object;

	  if (url.isFileURL)
	    image = [NSWorkspace.sharedWorkspace iconForFile:url.path];
	}
      if (!image)
	image = MRC_AUTORELEASE ([[NSImage alloc]
				   initWithSize:(NSMakeSize (2, 1))]);
      [images addObject:image];

      NSSize size = image.size;

      totalImageWidth += size.width;
      if (size.height > maxImageHeight)
	maxImageHeight = size.height;
    }

  NSPoint locationInView =
    [self convertEmacsViewPointFromScreen:NSEvent.mouseLocation];
  NSEvent *event =
    [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
		       location:[emacsView convertPoint:locationInView
						 toView:nil]
		  modifierFlags:NSEvent.modifierFlags timestamp:0
		   windowNumber:emacsWindow.windowNumber context:nil
		    eventNumber:0 clickCount:1 pressure:0];
  NSMutableArrayOf (NSDraggingItem *) *items =
    [NSMutableArray arrayWithCapacity:objects.count];

  locationInView.x -= totalImageWidth / 2;
  for (NSUInteger i = 0; i < objects.count; i++)
    {
      NSDraggingItem *item = [[NSDraggingItem alloc]
			       initWithPasteboardWriter:objects[i]];
      NSImage *image = images[i];
      NSSize size = image.size;

      [item setDraggingFrame:(NSMakeRect (locationInView.x,
					  locationInView.y - maxImageHeight,
					  size.width, size.height))
		    contents:image];
      [items addObject:item];
      MRC_RELEASE (item);
      locationInView.x += size.width;
    }

  NSArrayOf (NSPasteboardType) *savedTypes = nil;

  if (unregisterAsDestination)
    {
      savedTypes = [emacsView registeredDraggedTypes];
      [emacsView unregisterDraggedTypes];
    }

  NSDraggingSession *session = [emacsView beginDraggingSessionWithItems:items
								  event:event
								 source:self];

  session.animatesToStartingPositionsOnCancelOrFail = NO;
  mac_dnd_in_progress = true;
  while (mac_dnd_in_progress)
    mac_run_loop_run_once (kEventDurationForever);

  if (unregisterAsDestination)
    [emacsView registerForDraggedTypes:savedTypes];
}

@end				// EmacsFrameController (DragAndDrop)

/* Update the pasteboard types derived from the value of
   mac-dnd-known-types and register them so every Emacs view can
   accept them.  The registered types are stored in
   registered_dragged_types.  */

static void
update_dragged_types (void)
{
  NSMutableArrayOf (NSPasteboardType) *array =
    [[NSMutableArray alloc] initWithCapacity:0];
  Lisp_Object rest, tail, frame;

  for (rest = Vmac_dnd_known_types; CONSP (rest); rest = XCDR (rest))
    if (STRINGP (XCAR (rest)))
      {
	NSPasteboardType typeString =
	  [NSString stringWithUTF8LispString:(XCAR (rest))];

	if (typeString)
	  [array addObject:typeString];
      }

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_TOOLTIP_P (f))
	continue;

      if (FRAME_MAC_P (f))
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

	  mac_within_gui (^{
	      [frameController registerEmacsViewForDraggedTypes:array];
	    });
	}
    }

  (void) MRC_AUTORELEASE (registered_dragged_types);
  registered_dragged_types = array;
}

/* Return default value for mac-dnd-known-types.  */

Lisp_Object
mac_dnd_default_known_types (void)
{
  return list3 ([(__bridge NSPasteboardType)UTI_URL UTF8LispString],
		[NSPasteboardTypeString UTF8LispString],
		[NSPasteboardTypeTIFF UTF8LispString]);
}

DragActions
mac_dnd_begin_drag_and_drop (struct frame *f, DragActions actions,
			     enum mac_return_frame_mode mode,
			     struct frame **frame_return,
			     bool allow_current_frame, Lisp_Object class_names,
			     bool follow_tooltip)
{
  if (mode == RETURN_FRAME_NOW)
    {
      struct frame *f1 = mac_get_frame_at_mouse (false);

      if (f1 && !FRAME_TOOLTIP_P (f1))
	{
	  *frame_return = f1;

	  return NSDragOperationNone;
	}
    }

  if (mac_dnd_in_progress)
    error ("A drag-and-drop session is already in progress");

  NSMutableArrayOf (Class) *classes = [NSMutableArray arrayWithCapacity:0];

  for (; CONSP (class_names); class_names = XCDR (class_names))
    if (STRINGP (XCAR (class_names)))
      {
	NSString *name = [NSString stringWithLispString:(XCAR (class_names))];
	Class class = NSClassFromString (name);

	if ([class conformsToProtocol:@protocol(NSPasteboardReading)]
	    && [class conformsToProtocol:@protocol(NSPasteboardWriting)]
	    && ![class isEqual:NSPasteboardItem.class])
	  [classes addObject:class];
      }

  Selection sel;
  NSPasteboard *pasteboard = nil;

  mac_get_selection_from_symbol (QXdndSelection, false, &sel);
  if (sel)
    pasteboard = (__bridge NSPasteboard *) sel;

  NSArray *objects = [pasteboard readObjectsForClasses:classes options:nil];
  if (objects.count == 0)
    error ("No DND objects in XdndSelection");

  mac_dnd_action = NSDragOperationNone;
  mac_dnd_wanted_action = actions;
  mac_dnd_return_frame = mode;
  mac_dnd_return_frame_object = NULL;
  mac_dnd_update_tooltip = follow_tooltip;

  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui_allowing_inner_lisp (^{
      [frameController trackDraggingObjects:objects
		    unregisterAsDestination:!allow_current_frame];
    });

  /* The drop happened, so delete the tooltip.  */
  if (follow_tooltip)
    Fx_hide_tip ();

  /* Assume all buttons have been released since the drag-and-drop
     operation is now over.  */
  if (!mac_dnd_return_frame_object)
    FRAME_DISPLAY_INFO (f)->grabbed = 0;

  *frame_return = mac_dnd_return_frame_object;

  return mac_dnd_action;
}


/************************************************************************
			Services menu support
 ************************************************************************/

@implementation EmacsMainView (Services)

- (id)validRequestorForSendType:(NSPasteboardType)sendType
		     returnType:(NSPasteboardType)returnType
{
  MAC_LOOP_QUERY_NEEDS_LISP (id, [super validRequestorForSendType:sendType
						      returnType:returnType],
			     [self validRequestorForSendType:sendType
						  returnType:returnType]);

  Selection sel;

  if ([sendType length] == 0
      || (!NILP (Fmac_selection_owner_p (Vmac_service_selection, Qnil))
	  && mac_get_selection_from_symbol (Vmac_service_selection, false,
					    &sel) == noErr
	  && sel
	  && [(__bridge NSPasteboard *)sel availableTypeFromArray:@[sendType]]))
    {
      Lisp_Object rest;
      NSPasteboardType dataType;

      if ([returnType length] == 0)
	return self;

      for (rest = Vselection_converter_alist; CONSP (rest);
	   rest = XCDR (rest))
	if (CONSP (XCAR (rest)) && SYMBOLP (XCAR (XCAR (rest)))
	    && (dataType =
		get_pasteboard_data_type_from_symbol (XCAR (XCAR (rest)), nil))
	    && [dataType isEqualToString:returnType])
	  return self;
    }

  return [super validRequestorForSendType:sendType returnType:returnType];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
			     types:(NSArrayOf (NSPasteboardType) *)types
{
  MAC_LOOP_QUERY_NEEDS_LISP (BOOL, NO,
			     [self writeSelectionToPasteboard:pboard
							types:types]);

  OSStatus err;
  Selection sel;
  NSPasteboard *servicePboard;
  BOOL result = NO;

  err = mac_get_selection_from_symbol (Vmac_service_selection, false, &sel);
  if (err != noErr || sel == NULL)
    return NO;

  [pboard declareTypes:@[] owner:nil];

  servicePboard = (__bridge NSPasteboard *) sel;
  for (NSPasteboardType type in [servicePboard types])
    if ([types containsObject:type])
      {
	NSData *data = [servicePboard dataForType:type];

	if (data)
	  {
	    [pboard addTypes:@[type] owner:nil];
	    result = [pboard setData:data forType:type] || result;
	  }
      }

  return result;
}

/* Copy whole data of pasteboard PBOARD to the pasteboard specified by
   mac-service-selection.  */

static BOOL
copy_pasteboard_to_service_selection (NSPasteboard *pboard)
{
  OSStatus err;
  Selection sel;
  NSPasteboard *servicePboard;
  BOOL result = NO;

  err = mac_get_selection_from_symbol (Vmac_service_selection, true, &sel);
  if (err != noErr || sel == NULL)
    return NO;

  servicePboard = (__bridge NSPasteboard *) sel;
  [servicePboard declareTypes:@[] owner:nil];
  for (NSPasteboardType type in [pboard types])
    {
      NSData *data = [pboard dataForType:type];

      if (data)
	{
	  [servicePboard addTypes:@[type] owner:nil];
	  result = [servicePboard setData:data forType:type] || result;
	}
    }

  return result;
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
  MAC_LOOP_QUERY_NEEDS_LISP (BOOL, NO,
			     [self readSelectionFromPasteboard:pboard]);

  BOOL result = copy_pasteboard_to_service_selection (pboard);

  if (result)
    {
      OSStatus err;
      EventRef event;

      err = CreateEvent (NULL, kEventClassService, kEventServicePaste, 0,
			 kEventAttributeNone, &event);
      if (err == noErr)
	{
	  err = mac_store_event_ref_as_apple_event (0, 0, Qservice, Qpaste,
						    event, 0, NULL, NULL);
	  ReleaseEvent (event);
	}

      if (err != noErr)
	result = NO;
    }

  return result;
}

@end				// EmacsMainView (Services)

@implementation NSMethodSignature (Emacs)

/* Dummy method.  Just for getting its method signature.  */

- (void)messageName:(NSPasteboard *)pboard
	   userData:(NSString *)userData
	      error:(NSString **)error
{
}

@end				// NSMethodSignature (Emacs)

static BOOL
is_services_handler_selector (SEL selector)
{
  NSString *name = NSStringFromSelector (selector);

  /* The selector name is of the form `MESSAGENAME:userData:error:' ?  */
  if ([name hasSuffix:@":userData:error:"]
      && (NSMaxRange ([name rangeOfString:@":"])
	  == [name length] - (sizeof ("userData:error:") - 1)))
    {
      /* Lookup the binding `[service perform MESSAGENAME]' in
	 mac-apple-event-map.  */
      Lisp_Object tem = get_keymap (Vmac_apple_event_map, 0, 0);

      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qservice, 0, 1), 0, 0);
      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qperform, 0, 1), 0, 0);
      if (!NILP (tem))
	{
	  NSUInteger index = [name length] - (sizeof (":userData:error:") - 1);

	  name = [name substringToIndex:index];
	  tem = access_keymap (tem, intern (SSDATA ([name UTF8LispString])),
			       0, 1);
	}
      if (!NILP (tem) && !EQ (tem, Qundefined))
	return YES;
    }

  return NO;
}

/* Return the method signature of services handlers.  */

static NSMethodSignature *
services_handler_signature (void)
{
  static NSMethodSignature *signature;

  if (signature == nil)
    signature =
      MRC_RETAIN ([NSMethodSignature
		    instanceMethodSignatureForSelector:@selector(messageName:userData:error:)]);

  return signature;
}

static void
handle_services_invocation (NSInvocation *invocation)
{
  NSPasteboard * __unsafe_unretained pboard;
  NSString * __unsafe_unretained userData;
  /* NSString **error; */
  BOOL result;

  [invocation getArgument:&pboard atIndex:2];
  [invocation getArgument:&userData atIndex:3];
  /* [invocation getArgument:&error atIndex:4]; */

  result = copy_pasteboard_to_service_selection (pboard);
  if (result)
    {
      OSStatus err;
      EventRef event;

      err = CreateEvent (NULL, kEventClassService, kEventServicePerform,
			 0, kEventAttributeNone, &event);
      if (err == noErr)
	{
	  static const EventParamName names[] =
	    {kEventParamServiceMessageName, kEventParamServiceUserData};
	  static const EventParamType types[] =
	    {typeCFStringRef, typeCFStringRef};
	  NSString *name = NSStringFromSelector ([invocation selector]);
	  NSUInteger index;

	  index = [name length] - (sizeof (":userData:error:") - 1);
	  name = [name substringToIndex:index];

	  err = SetEventParameter (event, kEventParamServiceMessageName,
				   typeCFStringRef, sizeof (CFStringRef),
				   &name);
	  if (err == noErr)
	    if (userData)
	      err = SetEventParameter (event, kEventParamServiceUserData,
				       typeCFStringRef, sizeof (CFStringRef),
				       &userData);
	  if (err == noErr)
	    err = mac_store_event_ref_as_apple_event (0, 0, Qservice,
						      Qperform, event,
						      countof (names),
						      names, types);
	  ReleaseEvent (event);
	}
    }
}

static void
update_services_menu_types (void)
{
  NSMutableArrayOf (NSPasteboardType) *array =
    [NSMutableArray arrayWithCapacity:0];
  Lisp_Object rest;

  for (rest = Vselection_converter_alist; CONSP (rest);
       rest = XCDR (rest))
    if (CONSP (XCAR (rest)) && SYMBOLP (XCAR (XCAR (rest))))
      {
	NSPasteboardType dataType =
	  get_pasteboard_data_type_from_symbol (XCAR (XCAR (rest)), nil);

	if (dataType)
	  [array addObject:dataType];
      }

  mac_within_gui (^{
      [NSApp registerServicesMenuSendTypes:array returnTypes:array];
    });
}


/************************************************************************
			    Action support
 ************************************************************************/

static BOOL
is_action_selector (SEL selector)
{
  NSString *name = NSStringFromSelector (selector);

  /* The selector name is of the form `ACTIONNAME:' ?  */
  if (NSMaxRange ([name rangeOfString:@":"]) == [name length])
    {
      /* Lookup the binding `[action ACTIONNAME]' in
	 mac-apple-event-map.  */
      Lisp_Object tem = get_keymap (Vmac_apple_event_map, 0, 0);

      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qaction, 0, 1), 0, 0);
      if (!NILP (tem))
	{
	  name = [name substringToIndex:([name length] - 1)];
	  tem = access_keymap (tem, intern (SSDATA ([name UTF8LispString])),
			       0, 1);
	}
      if (!NILP (tem) && !EQ (tem, Qundefined))
	return YES;
    }

  return NO;
}

/* Return the method signature of actions.  */

static NSMethodSignature *
action_signature (void)
{
  static NSMethodSignature *signature;

  if (signature == nil)
    signature =
      MRC_RETAIN ([NSApplication
		    instanceMethodSignatureForSelector:@selector(terminate:)]);

  return signature;
}

static void
handle_action_invocation (NSInvocation *invocation)
{
  id __unsafe_unretained sender;
  Lisp_Object arg = Qnil;
  struct input_event inev;
  NSString *name = NSStringFromSelector ([invocation selector]);
  Lisp_Object name_symbol =
    intern (SSDATA ([[name substringToIndex:([name length] - 1)]
		      UTF8LispString]));
  CGEventFlags flags = (CGEventFlags) [[NSApp currentEvent] modifierFlags];
  UInt32 modifiers = mac_cgevent_flags_to_modifiers (flags);

  arg = Fcons (Fcons (build_string ("kmod"), /* kEventParamKeyModifiers */
		      Fcons (build_string ("magn"), /* typeUInt32 */
			     mac_four_char_code_to_string (modifiers))),
	       arg);

  [invocation getArgument:&sender atIndex:2];

  if (sender)
    {
      Lisp_Object rest;

      for (rest = Fget (name_symbol, Qmac_action_key_paths);
	   CONSP (rest); rest = XCDR (rest))
	if (STRINGP (XCAR (rest)))
	  {
	    NSString *keyPath;
	    id value;
	    Lisp_Object obj;

	    keyPath = [NSString stringWithUTF8LispString:(XCAR (rest))];

	    @try
	      {
		value = [sender valueForKeyPath:keyPath];
	      }
	    @catch (NSException *exception)
	      {
		value = nil;
	      }

	    if (value == nil)
	      continue;
	    obj = cfobject_to_lisp ((__bridge CFTypeRef) value,
				    CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
	    arg = Fcons (Fcons (XCAR (rest),
				Fcons (build_string ("Lisp"), obj)),
			 arg);
	  }

      if ([sender isKindOfClass:NSView.class])
	{
	  Lisp_Object frame = [[sender window] lispFrame];

	  if (!NILP (frame))
	    arg = Fcons (Fcons (Qframe,
				Fcons (build_string ("Lisp"), frame)),
			 arg);
	}
    }

  EVENT_INIT (inev);
  inev.kind = MAC_APPLE_EVENT;
  inev.x = Qaction;
  inev.y = name_symbol;
  inev.frame_or_window = mac_event_frame ();
  inev.arg = Fcons (build_string ("aevt"), arg);
  [emacsController storeEvent:&inev];
}

bool
mac_send_action (Lisp_Object symbol, bool dry_run_p)
{
  bool __block result = false;
  AUTO_STRING (colon, ":");
  Lisp_Object string = concat2 (SYMBOL_NAME (symbol), colon);
  SEL action = NSSelectorFromString ([NSString stringWithLispString:string]);

  if (!action)
    return false;

  mac_within_app (^{
      id target = [NSApp targetForAction:action];
      NSMethodSignature *signature = [target methodSignatureForSelector:action];

      if ([signature isEqual:(action_signature ())]
	  && [target respondsToSelector:@selector(validateUserInterfaceItem:)])
	{
	  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:action
						 keyEquivalent:@""];

	  if ([target validateUserInterfaceItem:item])
	    {
	      if (dry_run_p)
		result = true;
	      else
		result = [NSApp sendAction:action to:target from:nil];
	    }
	  MRC_RELEASE (item);
	}
    });

  return result;
}


/************************************************************************
		 Open Scripting Architecture support
 ************************************************************************/

@implementation EmacsOSAScript

- (NSAppleEventDescriptor *)executeAndReturnError:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (inhibit_window_system)
    return [super executeAndReturnError:errorInfo];
  else
    {
      NSAppleEventDescriptor * __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui_allowing_inner_lisp (^{
	  mac_within_app (^{
	      result = [super executeAndReturnError:&errorInfo1];
#if !USE_ARC
	      if (result == nil)
		[errorInfo1 retain];
	      [result retain];
#endif
	    });
	});

      if (result == nil)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

- (NSAppleEventDescriptor *)executeAndReturnDisplayValue:(NSAttributedString **)displayValue error:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (inhibit_window_system)
    return [super executeAndReturnDisplayValue:displayValue error:errorInfo];
  else
    {
      NSAppleEventDescriptor * __block result;
      NSAttributedString * __block displayValue1;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui_allowing_inner_lisp (^{
	  mac_within_app (^{
	      result = [super executeAndReturnDisplayValue:&displayValue1
						     error:&errorInfo1];
#if !USE_ARC
	      if (result)
		[displayValue1 retain];
	      else
		[errorInfo1 retain];
	      [result retain];
#endif
	    });
	});

      if (result)
	*displayValue = MRC_AUTORELEASE (displayValue1);
      else
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

- (NSAppleEventDescriptor *)executeAppleEvent:(NSAppleEventDescriptor *)event error:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (inhibit_window_system)
    return [super executeAppleEvent:event error:errorInfo];
  else
    {
      NSAppleEventDescriptor * __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui_allowing_inner_lisp (^{
	  mac_within_app (^{
	      result = [super executeAppleEvent:event error:&errorInfo1];
#if !USE_ARC
	      if (result == nil)
		[errorInfo1 retain];
	      [result retain];
#endif
	    });
	});

      if (result == nil)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

- (BOOL)compileAndReturnError:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (pthread_main_np ())
    return [super compileAndReturnError:errorInfo];
  else
    {
      BOOL __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui (^{
	  result = [super compileAndReturnError:&errorInfo1];
#if !USE_ARC
	  if (!result)
	    [errorInfo1 retain];
#endif
	});

      if (!result)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return result;
    }
}

- (NSData *)compiledDataForType:(NSString *)type
	    usingStorageOptions:(OSAStorageOptions)storageOptions
			  error:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (pthread_main_np ())
    return [super compiledDataForType:type
		  usingStorageOptions:storageOptions error:errorInfo];
  else
    {
      NSData * __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui (^{
	  result = [super compiledDataForType:type
			  usingStorageOptions:storageOptions error:&errorInfo1];
#if !USE_ARC
	  if (result == nil)
	    [errorInfo1 retain];
	  [result retain];
#endif
	});

      if (result == nil)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

@end				// EmacsOSAScript

Lisp_Object
mac_osa_language_list (bool long_format_p)
{
  Lisp_Object result = Qnil, default_language_props = Qnil;
  OSALanguage *defaultLanguage = [OSALanguage defaultLanguage];

  for (OSALanguage *language in [OSALanguage availableLanguages])
    {
      Lisp_Object language_props = [[language name] lispString];

      if (long_format_p)
	{
	  Lisp_Object tmp = list2 (QCfeatures, make_int (language.features));

	  tmp = Fcons (QCmanufacturer,
		       Fcons (mac_four_char_code_to_string ([language
							      manufacturer]),
			      tmp));
	  tmp = Fcons (QCsub_type,
		       Fcons (mac_four_char_code_to_string ([language subType]),
			      tmp));
	  tmp = Fcons (QCtype,
		       Fcons (mac_four_char_code_to_string ([language type]),
			      tmp));
	  tmp = Fcons (QCversion, Fcons ([[language version] lispString], tmp));
	  tmp = Fcons (QCinfo, Fcons ([[language info] lispString], tmp));
	  language_props = Fcons (language_props, tmp);
	}
      if (![language isEqual:defaultLanguage])
	result = Fcons (language_props, result);
      else
	default_language_props = language_props;
    }
  if (!NILP (default_language_props))
    result = Fcons (default_language_props, result);

  return result;
}

static Lisp_Object
mac_osa_error_info_to_lisp (NSDictionaryOf (NSString *, id) *errorInfo)
{
  Lisp_Object result = Qnil;
  NSString *errorMessage = errorInfo[OSAScriptErrorMessage];
  NSNumber *errorNumber = errorInfo[OSAScriptErrorNumber];
  NSString *errorAppName = errorInfo[OSAScriptErrorAppName];
  NSValue *errorRange = errorInfo[OSAScriptErrorRange];

  if (errorRange)
    {
      NSRange range = [errorRange rangeValue];

      result = Fcons (Fcons (Qrange, Fcons (make_int (range.location),
					    make_int (range.length))),
		      result);
    }
  if (errorAppName)
    result = Fcons (Fcons (Qapp_name, [errorAppName lispString]), result);
  if (errorNumber)
    result = Fcons (Fcons (Qnumber, make_int (errorNumber.intValue)), result);
  result = Fcons ((errorMessage ? [errorMessage lispString]
		   : build_string ("OSA script error")), result);

  return result;
}

static OSALanguage *
mac_osa_language_from_lisp (Lisp_Object language)
{
  OSALanguage *result;

  if (NILP (language))
    result = [OSALanguage defaultLanguage];
  else
    {
      NSString *name = [NSString stringWithLispString:language];
      result = [OSALanguage languageForName:name];
    }

  return result;
}

static EmacsOSAScript *
mac_osa_create_script_from_file (Lisp_Object filename,
				 Lisp_Object compiled_p_or_language,
				 Lisp_Object *error_data)
{
  EmacsOSAScript *result;
  Lisp_Object encoded;
  NSURL *url;
  NSAppleEventDescriptor *dataDescriptor;
  NSDictionaryOf (NSString *, id) *errorInfo = nil;
  OSALanguage *language;

  filename = Fexpand_file_name (filename, Qnil);
  encoded = ENCODE_FILE (filename);
  url = [NSURL fileURLWithPath:[NSString stringWithLispString:encoded]];
  dataDescriptor = [OSAScript scriptDataDescriptorWithContentsOfURL:url];

  if (dataDescriptor == nil)
    result = nil;
  else
    {
      NSError *error;

      language = [OSALanguage languageForScriptDataDescriptor:dataDescriptor];
      if (language == nil)
	{
	  if (EQ (compiled_p_or_language, Qt))
	    {
	      *error_data =
		list2 (build_string ("Can't obtain OSA language from file"),
		       filename);

	      return nil;
	    }
	  language = mac_osa_language_from_lisp (compiled_p_or_language);
	  if (language == nil)
	    {
	      *error_data =
		list2 (build_string ("OSA language not available"),
		       compiled_p_or_language);

	      return nil;
	    }
	}
      result = [[EmacsOSAScript alloc]
		 initWithScriptDataDescriptor:dataDescriptor fromURL:url
			     languageInstance:[language sharedLanguageInstance]
			  usingStorageOptions:OSANull error:&error];
      if (result == nil)
	errorInfo = [error userInfo];
  }
  if (result == nil)
    {
      if (errorInfo)
	*error_data = mac_osa_error_info_to_lisp (errorInfo);
      else
	*error_data =
	  list2 (build_string ("Can't create OSA script from file"),
		 filename);
    }

  return result;
}

static EmacsOSAScript *
mac_osa_create_script_from_code (Lisp_Object code,
				 Lisp_Object compiled_p_or_language,
				 Lisp_Object *error_data)
{
  EmacsOSAScript *result;

  if (!EQ (compiled_p_or_language, Qt))
    {
      OSALanguage *language =
	mac_osa_language_from_lisp (compiled_p_or_language);

      if (language == nil)
	{
	  *error_data = list2 (build_string ("OSA language not available"),
			       compiled_p_or_language);

	  return nil;
	}
      result = [[EmacsOSAScript alloc]
		 initWithSource:[NSString stringWithLispString:code]
			fromURL:nil
		 languageInstance:[language sharedLanguageInstance]
		 usingStorageOptions:OSANull];
      if (result == nil)
	*error_data =
	  list2 (build_string ("Can't create OSA script from source"),
		 code);
    }
  else
    {
      NSData *data = [NSData dataWithBytes:(SDATA (code))
				    length:(SBYTES (code))];
      NSDictionaryOf (NSString *, id) *errorInfo = nil;
      NSError *error;

      result = [[EmacsOSAScript alloc] initWithCompiledData:data fromURL:nil
					usingStorageOptions:OSANull
						      error:&error];
      if (result == nil)
	errorInfo = [error userInfo];
      if (result == nil)
	{
	  if (errorInfo)
	    *error_data = mac_osa_error_info_to_lisp (errorInfo);
	  else
	    *error_data =
	      list2 (build_string ("Can't create OSA script from data"),
		     code);
	}
    }

  return result;
}

static EmacsOSAScript *
mac_osa_create_script (Lisp_Object code_or_file,
		       Lisp_Object compiled_p_or_language,
		       bool file_p, Lisp_Object *error_data)
{
  if (file_p)
    return mac_osa_create_script_from_file (code_or_file,
					    compiled_p_or_language, error_data);
  else
    return mac_osa_create_script_from_code (code_or_file,
					    compiled_p_or_language, error_data);
}

Lisp_Object
mac_osa_compile (Lisp_Object code_or_file, Lisp_Object compiled_p_or_language,
		 bool file_p, Lisp_Object *error_data)
{
  Lisp_Object result = Qnil;
  EmacsOSAScript *script;

  *error_data = Qnil;
  script = mac_osa_create_script (code_or_file, compiled_p_or_language, file_p,
				  error_data);
  if (script)
    {
      NSDictionaryOf (NSString *, id) *errorInfo;
      NSData *compiledData = [script compiledDataForType:@""
				     usingStorageOptions:OSANull
						   error:&errorInfo];

      if (compiledData == nil)
	*error_data = mac_osa_error_info_to_lisp (errorInfo);
      else
	result = [compiledData lispString];
      MRC_RELEASE (script);
    }

  return result;
}

static NSAppleEventDescriptor *
mac_apple_event_descriptor_with_handler_call (Lisp_Object handler_call,
					      ptrdiff_t nargs,
					      Lisp_Object *args)
{
  NSAppleEventDescriptor *result = nil;

  if (STRINGP (handler_call))
    {
      AEDescList param_list;

      if (AECreateList (NULL, 0, false, &param_list) == noErr)
	{
	  ptrdiff_t i;
	  NSAppleEventDescriptor *parameters, *target, *handler;
	  NSString *handlerName;

	  for (i = 0; i < nargs; i++)
	    mac_ae_put_lisp (&param_list, 0, args[i]);

	  target = [NSAppleEventDescriptor nullDescriptor];
	  result = [NSAppleEventDescriptor
		     appleEventWithEventClass:kASAppleScriptSuite
				      eventID:kASSubroutineEvent
			     targetDescriptor:target
				     returnID:kAutoGenerateReturnID
				transactionID:kAnyTransactionID];
	  handlerName = [NSString stringWithLispString:handler_call];
	  handler = [NSAppleEventDescriptor descriptorWithString:handlerName];
	  [result setDescriptor:handler forKeyword:keyASSubroutineName];
	  parameters = [[NSAppleEventDescriptor alloc]
			 initWithAEDescNoCopy:&param_list];
	  [result setDescriptor:parameters forKeyword:keyDirectObject];
	  MRC_RELEASE (parameters);
	}
    }
  else
    {
      AppleEvent apple_event;

      if (create_apple_event_from_lisp (handler_call, &apple_event) == noErr)
	result = MRC_AUTORELEASE ([[NSAppleEventDescriptor alloc]
				    initWithAEDescNoCopy:&apple_event]);
    }

  return result;
}

static const void *
cfarray_event_ref_retain (CFAllocatorRef allocator, const void *value)
{
  return RetainEvent ((EventRef) value);
}

static void
cfarray_event_ref_release (CFAllocatorRef allocator, const void *value)
{
  ReleaseEvent ((EventRef) value);
}

static const CFArrayCallBacks
cfarray_event_ref_callbacks = {0, cfarray_event_ref_retain,
			       cfarray_event_ref_release, NULL, NULL};

static void
mac_begin_defer_key_events (void)
{
  deferred_key_events = CFArrayCreateMutable (NULL, 0,
					      &cfarray_event_ref_callbacks);
}

static void
mac_end_defer_key_events (void)
{
  EventQueueRef queue = GetMainEventQueue ();
  CFIndex index, count = CFArrayGetCount (deferred_key_events);

  for (index = 0; index < count; index++)
    {
      EventRef event = (EventRef) CFArrayGetValueAtIndex (deferred_key_events,
							  index);

      PostEventToQueue (queue, event, kEventPriorityHigh);
    }
  CFRelease (deferred_key_events);
  deferred_key_events = NULL;
}

Lisp_Object
mac_osa_script (Lisp_Object code_or_file, Lisp_Object compiled_p_or_language,
		bool file_p, Lisp_Object value_form, Lisp_Object handler_call,
		ptrdiff_t nargs, Lisp_Object *args, Lisp_Object *error_data)
{
  Lisp_Object result = Qnil;
  EmacsOSAScript *script;
  NSAppleEventDescriptor *desc = nil;
  NSAttributedString *displayValue;

  *error_data = Qnil;
  script = mac_osa_create_script (code_or_file, compiled_p_or_language, file_p,
				  error_data);
  if (script)
    {
      NSDictionaryOf (NSString *, id) *errorInfo;
      NSAppleEventDescriptor *event = nil;

      if (![script compileAndReturnError:&errorInfo])
	*error_data = mac_osa_error_info_to_lisp (errorInfo);
      else if (!NILP (handler_call))
	{
	  event = mac_apple_event_descriptor_with_handler_call (handler_call,
								nargs, args);
	  if (event == nil)
	    *error_data = Fcons (build_string ("Can't create Apple event"),
				Fcons (handler_call, Flist (nargs, args)));
	}
      if (NILP (*error_data))
	{
	  mac_menu_set_in_use (true);
	  mac_begin_defer_key_events ();
	  if (event)
	    {
	      desc = [script executeAppleEvent:event error:&errorInfo];
	      if (desc && NILP (value_form))
		displayValue = [script richTextFromDescriptor:desc];
	    }
	  else if (NILP (value_form))
	    desc = [script executeAndReturnDisplayValue:&displayValue
						  error:&errorInfo];
	  else
	    desc = [script executeAndReturnError:&errorInfo];
	  if (desc == nil)
	    *error_data = mac_osa_error_info_to_lisp (errorInfo);
	  mac_end_defer_key_events ();
	  mac_menu_set_in_use (false);
	}
      MRC_RELEASE (script);
    }

  if (desc)
    {
      if (NILP (value_form))
	result = [[displayValue string] lispString];
      else
	result = mac_aedesc_to_lisp ([desc aeDesc]);
    }

  return result;
}


/************************************************************************
			Document rasterization
 ************************************************************************/

static NSMutableDictionaryOf (id, NSDictionaryOf (NSString *, id) *)
  *documentRasterizerCache;
static NSDate *documentRasterizerCacheOldestTimestamp;
#define DOCUMENT_RASTERIZER_CACHE_DURATION 60.0

@implementation EmacsPDFDocument

/* Like -[PDFDocument initWithURL:], but suppress warnings if not
   loading a PDF file.  */

- (instancetype)initWithURL:(NSURL *)url
		    options:(NSDictionaryOf (NSString *, id) *)options
{
  NSFileHandle *fileHandle;
  NSData *data;
  NSString *type = options[@"UTI"]; /* NSFileTypeDocumentOption */

  if (type && !CFEqual ((__bridge CFStringRef) type, UTI_PDF))
    goto error;

  fileHandle = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
  data = [fileHandle readDataUpToLength:5 error:NULL];
#else
  data = [fileHandle readDataOfLength:5];
#endif

  if ([data length] < 5 || memcmp ([data bytes], "%PDF-", 5) != 0)
    goto error;

  self = [self initWithURL:url];

  return self;

 error:
  self = [super init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

/* Like -[PDFDocument initWithData:], but suppress warnings if not
   loading a PDF data.  */

- (instancetype)initWithData:(NSData *)data
		     options:(NSDictionaryOf (NSString *, id) *)options
{
  NSString *type = options[@"UTI"]; /* NSFileTypeDocumentOption */

  if (type && !CFEqual ((__bridge CFStringRef) type, UTI_PDF))
    goto error;
  if ([data length] < 5 || memcmp ([data bytes], "%PDF-", 5) != 0)
    goto error;

  self = [self initWithData:data];

  return self;

 error:
  self = [super init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

+ (BOOL)shouldInitializeInMainThread
{
  return NO;
}

- (BOOL)shouldNotCache
{
  return NO;
}

+ (NSArrayOf (NSString *) *)supportedTypes
{
  return @[(__bridge NSString *) UTI_PDF];
}

- (NSSize)integralSizeOfPageAtIndex:(NSUInteger)index
{
  PDFPage *page = [self pageAtIndex:index];
  NSRect bounds = [page boundsForBox:kPDFDisplayBoxCropBox];
  int rotation = [page rotation];

  if (rotation == 0 || rotation == 180)
    return NSMakeSize (ceil (NSWidth (bounds)), ceil (NSHeight (bounds)));
  else
    return NSMakeSize (ceil (NSHeight (bounds)), ceil (NSWidth (bounds)));
}

- (CGColorRef)copyBackgroundCGColorOfPageAtIndex:(NSUInteger)index
{
  return NULL;
}

- (NSDictionaryOf (NSString *, id) *)documentAttributesOfPageAtIndex:(NSUInteger)index
{
  return [self documentAttributes];
}

- (void)drawPageAtIndex:(NSUInteger)index inRect:(NSRect)rect
	      inContext:(CGContextRef)ctx
		options:(NSDictionaryOf (NSString *, id) *)options /* unused */
{
  PDFPage *page = [self pageAtIndex:index];
  NSRect bounds = [page boundsForBox:kPDFDisplayBoxCropBox];
  int rotation = [page rotation];
  CGFloat width, height;

  if (rotation == 0 || rotation == 180)
    width = ceil (NSWidth (bounds)), height = ceil (NSHeight (bounds));
  else
    width = ceil (NSHeight (bounds)), height = ceil (NSWidth (bounds));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmisleading-indentation"
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101200
  if ([page respondsToSelector:@selector(drawWithBox:toContext:)])
#endif
    {
      CGContextSaveGState (ctx);
      CGContextTranslateCTM (ctx, NSMinX (rect), NSMinY (rect));
      CGContextScaleCTM (ctx, NSWidth (rect) / width, NSHeight (rect) / height);
      [page drawWithBox:kPDFDisplayBoxCropBox toContext:ctx];
      CGContextRestoreGState (ctx);
    }
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101200
  else
    {
      NSAffineTransform *transform = [NSAffineTransform transform];
      NSGraphicsContext *gcontext =
	[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:NO];

      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext = gcontext;
      [transform translateXBy:(NSMinX (rect)) yBy:(NSMinY (rect))];
      [transform scaleXBy:(NSWidth (rect) / width)
		      yBy:(NSHeight (rect) / height)];
      [transform concat];
      [page drawWithBox:kPDFDisplayBoxTrimBox];
      [NSGraphicsContext restoreGraphicsState];
    }
#endif
#pragma clang diagnostic pop
}

@end				// EmacsPDFDocument

@implementation EmacsSVGDocument

/* WebView object that was used in the last deallocated
   EmacsSVGDocument object.  This is reused to avoid the overhead of
   WebView object creation.  */
#ifdef USE_WK_API
static WKWebView *EmacsSVGDocumentLastWebView;
/* Fake scheme for circumventing local file access restriction. */
#define URL_FAKE_FILE_SCHEME (@"EmacsSVGDocument.file")
#else
static WebView *EmacsSVGDocumentLastWebView;
#endif

#ifdef USE_WK_API
- (void)setFinishNavigationHandler:(void (^) (WKWebView *, WKNavigation *))block
{
  MRC_RELEASE (finishNavigationHandler);
  finishNavigationHandler = [block copy];
}
#else
- (void)setFinishLoadForFrameHandler:(void (^) (WebView *, WebFrame *))block
{
  MRC_RELEASE (finishLoadForFrameHandler);
  finishLoadForFrameHandler = [block copy];
}
#endif

- (instancetype)initWithURL:(NSURL *)url
		    options:(NSDictionaryOf (NSString *, id) *)options
{
  NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:url
								 error:NULL];
  NSData *data = fileHandle.availableData;

  if (!data)
    goto error;

  self = [self initWithData:data options:options];

  return self;

 error:
  self = [super init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

- (NSSize)frameSizeForBoundingBox:(id)boundingBox widthBaseVal:(id)widthBaseVal
		    heightBaseVal:(id)heightBaseVal imageWidth:(int *)imageWidth
		      imageHeight:(int *)imageHeight
{
  NSNumber *unitType, *num;
  NSSize frameSize;
  int width, height;
  enum {
	SVG_LENGTHTYPE_PERCENTAGE = 2
  };

  unitType = [widthBaseVal valueForKey:@"unitType"];
  if (unitType.intValue == SVG_LENGTHTYPE_PERCENTAGE)
    {
      frameSize.width =
	round ([[boundingBox valueForKey:@"x"] doubleValue]
	       + [[boundingBox valueForKey:@"width"] doubleValue]);
      num = [widthBaseVal valueForKey:@"valueInSpecifiedUnits"];
      width = lround (frameSize.width * num.doubleValue / 100);
    }
  else
    {
      num = [widthBaseVal valueForKey:@"value"];
      width = lround (num.doubleValue);
      frameSize.width = width;
    }

  unitType = [heightBaseVal valueForKey:@"unitType"];
  if (unitType.intValue == SVG_LENGTHTYPE_PERCENTAGE)
    {
      frameSize.height =
	round ([[boundingBox valueForKey:@"y"] doubleValue]
	       + [[boundingBox valueForKey:@"height"] doubleValue]);
      num = [heightBaseVal valueForKey:@"valueInSpecifiedUnits"];
      height = lround (frameSize.height * num.doubleValue / 100);
    }
  else
    {
      num = [heightBaseVal valueForKey:@"value"];
      height = lround (num.doubleValue);
      frameSize.height = height;
    }

  *imageWidth = width;
  *imageHeight = height;

  return frameSize;
}

- (instancetype)initWithData:(NSData *)data
		     options:(NSDictionaryOf (NSString *, id) *)options
{
  NSString *type = options[@"UTI"]; /* NSFileTypeDocumentOption */

  if (type && !CFEqual ((__bridge CFStringRef) type, UTI_SVG))
    {
      self = [super init];
      MRC_RELEASE (self);
      self = nil;

      return self;
    }

  self = [super init];

  if (self == nil)
    return nil;

  NSRect frameRect = NSMakeRect (0, 0, 100, 100); /* Adjusted later.  */
  if (!EmacsSVGDocumentLastWebView)
    {
#ifdef USE_WK_API
      WKWebViewConfiguration *configuration =
	[[WKWebViewConfiguration alloc] init];

      configuration.suppressesIncrementalRendering = YES;
      [configuration setURLSchemeHandler:self
			    forURLScheme:URL_FAKE_FILE_SCHEME];
      webView = [[WKWebView alloc] initWithFrame:frameRect
				   configuration:configuration];
      EmacsSVGDocumentLastWebView = webView;
      MRC_RELEASE (configuration);
#else  /* !USE_WK_API */
      webView = [[WebView alloc] initWithFrame:frameRect frameName:nil
				     groupName:nil];
#endif  /* !USE_WK_API */
    }
  else
    {
      webView = EmacsSVGDocumentLastWebView;
      webView.frame = frameRect;
    }

  NSURL *baseURL = options[@"baseURL"];
  BOOL __block finished = NO;
  enum {SVG_LENGTHTYPE_PERCENTAGE = 2};
  NSString *styleSheet = options[@"styleSheet"];
#ifdef USE_WK_API
  id boundingBox, widthBaseVal, heightBaseVal;
  NSString * __block jsonString = nil;
  if (baseURL)
    {
      NSURLComponents *components =
	[NSURLComponents componentsWithURL:baseURL resolvingAgainstBaseURL:YES];
      components.scheme = URL_FAKE_FILE_SCHEME;
      baseURL = components.URL;
    }
  webView.navigationDelegate = self;
  self.finishNavigationHandler = ^(WKWebView *view, WKNavigation *navigation) {
    /* Characters unescaped with encodeURIComponent.  */
    static NSCharacterSet *allowedCharacters;
    if (allowedCharacters == nil)
      allowedCharacters = MRC_RETAIN ([NSCharacterSet
					characterSetWithCharactersInString:@""
					"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
					"abcdefghijklmnopqrstuvwxyz"
					"0123456789" "-_.!~*'()"]);
    NSString *encodedStyleSheet =
    [styleSheet
      stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters];
    NSString *script = [NSString stringWithFormat:@""
"var documentElement = document.documentElement;\n"
"const styleElement = document.createElementNS ('http://www.w3.org/2000/svg', 'style');\n"
"styleElement.textContent = decodeURIComponent (\"%@\");\n"
"documentElement.appendChild (styleElement);\n"
"function filter (obj, names) {\n"
"  return names.reduce ((acc, nm) => {acc[nm] = obj[nm]; return acc;}, {});\n"
"}\n"
"JSON.stringify (['width', 'height'].reduce\n"
"  ((obj, dim) => {\n"
"     obj[dim + 'BaseVal'] =\n"
"       filter (documentElement[dim].baseVal,\n"
"	       ['unitType', 'value', 'valueInSpecifiedUnits']);\n"
"     return obj;\n"
"   }, {boundingBox:\n"
"       ((documentElement.width.baseVal.unitType != SVGLength.SVG_LENGTHTYPE_PERCENTAGE\n"
"	 && documentElement.height.baseVal.unitType != SVGLength.SVG_LENGTHTYPE_PERCENTAGE)\n"
"	? null : filter (documentElement.getBBox (),\n"
"			 ['x', 'y', 'width', 'height']))}))",
				 encodedStyleSheet ? encodedStyleSheet : @""];
    [view evaluateJavaScript:script
	   completionHandler:^(id scriptResult, NSError *error) {
	if ([scriptResult isKindOfClass:NSString.class])
	  jsonString = MRC_RETAIN (scriptResult);
	else
	  jsonString = nil;
	finished = YES;
      }];
  };
  [webView loadData:data MIMEType:@"image/svg+xml"
	   characterEncodingName:@"UTF-8" baseURL:baseURL];
#else  /* !USE_WK_API */
  id __block boundingBox = nil, widthBaseVal = nil, heightBaseVal = nil;
  webView.frameLoadDelegate = self;
  webView.mainFrame.frameView.allowsScrolling = NO;
  self.finishLoadForFrameHandler = ^(WebView *view, WebFrame *frame) {
    @try
      {
	DOMDocument *document =
	[webView.windowScriptObject valueForKey:@"document"];
	DOMElement *documentElement = document.documentElement;
	if (styleSheet)
	  {
	    DOMElement *styleElement =
	      [document createElementNS:@"http://www.w3.org/2000/svg"
			  qualifiedName:@"style"];
	    styleElement.textContent = styleSheet;
	    [documentElement appendChild:styleElement];
	  }

	widthBaseVal = [documentElement valueForKeyPath:@"width.baseVal"];
	heightBaseVal = [documentElement valueForKeyPath:@"height.baseVal"];
	if ((((NSNumber *) [widthBaseVal valueForKey:@"unitType"]).intValue
	     == SVG_LENGTHTYPE_PERCENTAGE)
	    || (((NSNumber *) [heightBaseVal valueForKey:@"unitType"]).intValue
		== SVG_LENGTHTYPE_PERCENTAGE))
	  boundingBox = [documentElement callWebScriptMethod:@"getBBox"
					       withArguments:@[]];
	else
	  boundingBox = nil;
      }
    @catch (NSException *exception)
      {
      }
    MRC_RETAIN (widthBaseVal);
    MRC_RETAIN (heightBaseVal);
    MRC_RETAIN (boundingBox);
    finished = YES;
  };
  [webView.mainFrame loadData:data MIMEType:@"image/svg+xml"
	     textEncodingName:nil baseURL:baseURL];
#endif  /* !USE_WK_API */

  /* webView.isLoading is not sufficient if we have <image
     xlink:href=... /> */
  while (!finished)
    mac_run_loop_run_once (0);

  int width = -1, height;
#ifdef USE_WK_API
  if (jsonString == nil)
    widthBaseVal = nil;
  else
    {
      NSData *data =
	[jsonString dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary *jsonObject =
	[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];

      boundingBox = jsonObject[@"boundingBox"];
      widthBaseVal = jsonObject[@"widthBaseVal"];
      heightBaseVal = jsonObject[@"heightBaseVal"];
      MRC_AUTORELEASE (jsonString);
    }
#else
  MRC_AUTORELEASE (widthBaseVal);
  MRC_AUTORELEASE (heightBaseVal);
  MRC_AUTORELEASE (boundingBox);
#endif
  if (widthBaseVal == nil)
    {
      MRC_RELEASE (self);
      self = nil;

      return self;
    }

  frameRect.size = [self frameSizeForBoundingBox:boundingBox
				    widthBaseVal:widthBaseVal
				   heightBaseVal:heightBaseVal
				      imageWidth:&width
				     imageHeight:&height];
#ifdef USE_WK_API
  NSString *script = [NSString stringWithFormat:@""
"const svgElement = document.createElementNS ('http://www.w3.org/2000/svg', 'svg');\n"
"const gElement = document.createElementNS ('http://www.w3.org/2000/svg', 'g');\n"
"svgElement.setAttribute ('width', '%d');\n"
"svgElement.setAttribute ('height', '%d');\n"
"svgElement.setAttribute ('viewBox', '0, 0, %d, %d');\n"
"if (documentElement.width.baseVal.unitType == SVGLength.SVG_LENGTHTYPE_PERCENTAGE)\n"
"  documentElement.setAttribute ('width', '%d');\n"
"if (documentElement.height.baseVal.unitType == SVGLength.SVG_LENGTHTYPE_PERCENTAGE)\n"
"  documentElement.setAttribute ('height', '%d');\n"
"document.replaceChild (svgElement, documentElement);\n"
"svgElement.appendChild (gElement);\n"
"gElement.appendChild (documentElement);\n"
"documentElement = svgElement;\n"
"null;", width, height, width, height, width, height];
  [webView evaluateJavaScript:script
	    completionHandler:^(id scriptResult, NSError *error) {
    }];
#endif

  webView.frame = frameRect;
  frameRect.size.width = width;
  frameRect.origin.y = NSHeight (frameRect) - height;
  frameRect.size.height = height;
  viewRect = frameRect;

  return self;
}

+ (BOOL)shouldInitializeInMainThread
{
  return YES;
}

- (BOOL)shouldNotCache
{
  return NO; //YES;
}

+ (NSArrayOf (NSString *) *)supportedTypes
{
  return @[(__bridge NSString *) UTI_SVG];
}

- (NSUInteger)pageCount
{
  return 1;
}

- (NSSize)integralSizeOfPageAtIndex:(NSUInteger)index
{
  return viewRect.size;
}

- (CGColorRef)copyBackgroundCGColorOfPageAtIndex:(NSUInteger)index
{
  return NULL;
}

- (NSDictionaryOf (NSString *, id) *)documentAttributesOfPageAtIndex:(NSUInteger)index
{
  return nil;
}

- (void)drawPageAtIndex:(NSUInteger)index inRect:(NSRect)rect
	      inContext:(CGContextRef)ctx
		options:(NSDictionaryOf (NSString *, id) *)options
{
  mac_within_app (^{
      NSArrayOf (NSString *) *keys = @[@"foregroundColor", @"backgroundColor"];
      NSMutableDictionaryOf (NSString *, NSString *) *colorsInHex =
	[NSMutableDictionary dictionaryWithCapacity:keys.count];

      for (NSString *key in keys)
	{
	  CGColorRef cg_color = (__bridge CGColorRef) options[key];
	  CGFloat components[4];

	  if (cg_color && [[NSColor colorWithCGColor:cg_color]
			    getSRGBComponents:components])
	    {
	      NSString *colorInHex =
		[NSString stringWithFormat:@"#%02x%02x%02x",
			  (unsigned int) (components[0] * 255 + .5),
			  (unsigned int) (components[1] * 255 + .5),
			  (unsigned int) (components[2] * 255 + .5)];

	      if (colorInHex)
		colorsInHex[key] = colorInHex;
	    }
	}

      NSString *fgInHex = colorsInHex[@"foregroundColor"];
      NSString *bgInHex = colorsInHex[@"backgroundColor"];
#ifdef USE_WK_API
      CGAffineTransform ctm = CGContextGetCTM (ctx);
      NSRect destRect = NSRectFromCGRect (CGRectApplyAffineTransform
					  (NSRectToCGRect (rect), ctm));

      destRect.origin = NSZeroPoint;
      destRect.size.width = lround (NSWidth (destRect));
      destRect.size.height = lround (NSHeight (destRect));

      ctm = CGAffineTransformTranslate (ctm, NSMinX (rect), NSMinY (rect));
      ctm = CGAffineTransformScale (ctm, NSWidth (rect) / NSWidth (viewRect),
				    NSHeight (rect) / NSHeight (viewRect));

      CGAffineTransform flip = CGAffineTransformMake (1, 0, 0, -1,
						      0, NSHeight (destRect));
      ctm = CGAffineTransformConcat (ctm, flip);
      flip.ty = NSHeight (viewRect);
      ctm = CGAffineTransformConcat (flip, ctm);

      BOOL __block finished = NO;
      NSImage * __block image = nil;
      int destWidth = NSWidth (destRect), destHeight = NSHeight (destRect);
      NSString *script = [NSString stringWithFormat:@""
"documentElement.style.color = '%@';\n"
"documentElement.style.fill = 'currentColor';\n"
"documentElement.style.backgroundColor = '%@';\n"
"documentElement.setAttribute ('width', '%d');\n"
"documentElement.setAttribute ('height', '%d');\n"
"documentElement.setAttribute ('viewBox', '0, 0, %d, %d');\n"
"gElement.setAttribute ('transform', 'matrix (%f, %f, %f, %f, %f, %f)');\n"
"null;", fgInHex ? fgInHex : @"black",
				 bgInHex ? bgInHex : @"transparent",
				   destWidth, destHeight, destWidth, destHeight,
				   ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty];

      [webView evaluateJavaScript:script
		completionHandler:^(id scriptResult, NSError *error) {
	  if (!error)
	    {
	      WKSnapshotConfiguration *snapshotConfiguration =
		[[WKSnapshotConfiguration alloc] init];

	      webView.frame = destRect;
	      [webView _setOverrideDeviceScaleFactor:1];
	      [webView takeSnapshotWithConfiguration:snapshotConfiguration
				   completionHandler:^(NSImage *snapshotImage,
						       NSError *error) {
		  image = MRC_RETAIN (snapshotImage);
		  finished = YES;
		}];
	      MRC_RELEASE (snapshotConfiguration);
	    }
	}];

      while (!finished)
	mac_run_loop_run_once (0);

      if (image)
	{
	  NSGraphicsContext *gcontext =
	    [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
	  [NSGraphicsContext saveGraphicsState];
	  NSGraphicsContext.currentContext = gcontext;
	  NSRectClip (rect);
	  [[NSAffineTransform transform] set];
	  [image drawInRect:destRect];
	  MRC_RELEASE (image);
	  [NSGraphicsContext restoreGraphicsState];
	}
#else  /* !USE_WK_API */
      DOMDocument *document =
	[webView.windowScriptObject valueForKey:@"document"];
      DOMElement *documentElement = document.documentElement;

      if (fgInHex)
	{
	  documentElement.style.color = fgInHex;
	  [documentElement.style setProperty:@"fill" value:@"currentColor"
				      priority:@""];
	}
      if (bgInHex)
	documentElement.style.backgroundColor = bgInHex;

      NSAffineTransform *transform = [NSAffineTransform transform];
      NSGraphicsContext *gcontext =
	[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:NO];

      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext = gcontext;
      [transform translateXBy:(NSMinX (rect)) yBy:(NSMinY (rect))];
      [transform scaleXBy:(NSWidth (rect) / NSWidth (viewRect))
		      yBy:(NSHeight (rect) / NSHeight (viewRect))];
      [transform translateXBy:(- NSMinX (viewRect))
			  yBy:(- NSMinY (viewRect))];
      [transform concat];
      [webView displayRectIgnoringOpacity:viewRect inContext:gcontext];
      [NSGraphicsContext restoreGraphicsState];
#endif  /* !USE_WK_API */
    });
}

#ifdef USE_WK_API
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation
{
  if (finishNavigationHandler)
    {
      finishNavigationHandler (view, navigation);
      self.finishNavigationHandler = nil;
    }
}

- (void)webView:(WKWebView *)view startURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
  NSURL *url = urlSchemeTask.request.URL;
  NSURLComponents *components =
    [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];

  eassert ([components.scheme caseInsensitiveCompare:URL_FAKE_FILE_SCHEME]
	   == NSOrderedSame);
  components.scheme = NSURLFileScheme;
  url = components.URL;

  NSError *error = nil;
  NSFileHandle *fileHandle =
    [NSFileHandle fileHandleForReadingFromURL:url error:&error];

  NSString *mimeType = nil;
  if (fileHandle)
    {
#if HAVE_UNIFORM_TYPE_IDENTIFIERS
      UTType *contentType;
      if ([url getResourceValue:&contentType forKey:NSURLContentTypeKey
			  error:&error])
	mimeType = contentType.preferredMIMEType;
#else
      NSString *typeIdentifier;
      if ([url getResourceValue:&typeIdentifier forKey:NSURLTypeIdentifierKey
			  error:&error])
	mimeType = CFBridgingRelease
	  (UTTypeCopyPreferredTagWithClass (((__bridge CFStringRef)
					     typeIdentifier),
					    kUTTagClassMIMEType));
#endif
    }

  NSData *data = nil;
  if (mimeType)
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101500
      data = [fileHandle readDataToEndOfFileAndReturnError:&error];
#else
      @try
	{
	  data = [fileHandle readDataToEndOfFile];
	}
      @catch (NSException *exception)
	{
	  error = [NSError errorWithDomain:NSCocoaErrorDomain
				      code:NSFileReadUnknownError
				  userInfo:exception.userInfo];
	}
#endif
    }

  if (!data)
    {
      [urlSchemeTask didFailWithError:error];
      return;
    }

  NSURLResponse *response =
    MRC_AUTORELEASE ([[NSURLResponse alloc]
		       initWithURL:urlSchemeTask.request.URL MIMEType:mimeType
		       expectedContentLength:data.length textEncodingName:nil]);
  [urlSchemeTask didReceiveResponse:response];
  [urlSchemeTask didReceiveData:data];
  [urlSchemeTask didFinish];
}

- (void)webView:(WKWebView *)view stopURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
}
#else
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
  if (finishLoadForFrameHandler)
    {
      finishLoadForFrameHandler (sender, frame);
      self.finishLoadForFrameHandler = nil;
    }
}
#endif

@end				// EmacsSVGDocument

@implementation EmacsDocumentRasterizer
- (instancetype)initWithAttributedString:(NSAttributedString *)anAttributedString
		      documentAttributes:(NSDictionaryOf (NSString *, id) *)docAttributes
{
  NSLayoutManager *layoutManager;
  NSTextContainer *textContainer;
  int viewMode;
  NSRange glyphRange;

  self = [super init];

  if (self == nil)
    return nil;

  textStorage = [[NSTextStorage alloc]
		  initWithAttributedString:anAttributedString];
  layoutManager = [[NSLayoutManager alloc] init];
  textContainer = [[NSTextContainer alloc] init];

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
  [layoutManager setUsesScreenFonts:NO];
#endif

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  if (!(textStorage && layoutManager && textContainer))
    {
      MRC_RELEASE (self);
      self = nil;

      return self;
    }

  viewMode = [docAttributes[NSViewModeDocumentAttribute] intValue];
  if (viewMode == 0)
    [textContainer setLineFragmentPadding:0];
  else
    {
      /* page layout */
      NSSize pageSize = [docAttributes[NSPaperSizeDocumentAttribute] sizeValue];
      NSAttributedStringDocumentAttributeKey __unsafe_unretained
	marginAttributes[4] = {
	NSLeftMarginDocumentAttribute, NSRightMarginDocumentAttribute,
	NSTopMarginDocumentAttribute, NSBottomMarginDocumentAttribute
      };
      NSNumber * __unsafe_unretained marginValues[4];
      int i;

      for (i = 0; i < 4; i++)
	marginValues[i] = docAttributes[marginAttributes[i]];
      for (i = 0; i < 2; i++)
	if (marginValues[i])
	  pageSize.width -= [marginValues[i] doubleValue];
      for (; i < 4; i++)
	if (marginValues[i])
	  pageSize.height -= [marginValues[i] doubleValue];

      pageSize.width = ceil (pageSize.width);
      pageSize.height = ceil (pageSize.height);
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      [textContainer setSize:pageSize];
#else
      [textContainer setContainerSize:pageSize];
#endif

      [layoutManager setDelegate:self];
    }

  /* Fully lay out.  */
  glyphRange =
    [layoutManager
      glyphRangeForCharacterRange:(NSMakeRange (0, [textStorage length]))
	     actualCharacterRange:NULL];
  if (NSMaxRange (glyphRange) == 0)
    {
      MRC_RELEASE (self);
      self = nil;

      return self;
    }
  (void) [layoutManager
	   textContainerForGlyphAtIndex:(NSMaxRange (glyphRange) - 1)
			 effectiveRange:NULL];

  if (viewMode == 0)
    {
      NSRect rect = [layoutManager usedRectForTextContainer:textContainer];
      NSSize containerSize = NSMakeSize (ceil (NSMaxX (rect)),
					 ceil (NSMaxY (rect)));

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      [textContainer setSize:containerSize];
#else
      [textContainer setContainerSize:containerSize];
#endif
    }

  documentAttributes = MRC_RETAIN (docAttributes);

  return self;
}

- (instancetype)initWithURL:(NSURL *)url
		    options:(NSDictionaryOf (NSString *, id) *)options
{
  NSAttributedString *attrString;
  NSDictionaryOf (NSAttributedStringDocumentAttributeKey, id) *docAttributes;

  attrString = [[NSAttributedString alloc]
		 initWithURL:url options:options
		 documentAttributes:&docAttributes error:NULL];
  if (attrString == nil)
    goto error;

  self = [self initWithAttributedString:attrString
		     documentAttributes:docAttributes];
  MRC_RELEASE (attrString);

  return self;

 error:
  self = [self init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

- (instancetype)initWithData:(NSData *)data
		     options:(NSDictionaryOf (NSString *, id) *)options
{
  NSAttributedString *attrString;
  NSDictionaryOf (NSAttributedStringDocumentAttributeKey, id) *docAttributes;

  attrString = [[NSAttributedString alloc]
		 initWithData:data options:options
		 documentAttributes:&docAttributes error:NULL];
  if (attrString == nil)
    goto error;

  self = [self initWithAttributedString:attrString
		     documentAttributes:docAttributes];
  MRC_RELEASE (attrString);

  return self;

 error:
  self = [self init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

+ (BOOL)shouldInitializeInMainThread
{
  return YES;
}

- (BOOL)shouldNotCache
{
  return NO;
}

#if !USE_ARC
- (void)dealloc
{
  [textStorage release];
  [documentAttributes release];
  [super dealloc];
}
#endif

- (NSLayoutManager *)layoutManager
{
  return textStorage.layoutManagers[0];
}

- (NSUInteger)pageCount
{
  NSLayoutManager *layoutManager = [self layoutManager];

  return [[layoutManager textContainers] count];
}

+ (NSArrayOf (NSString *) *)supportedTypes
{
  return [NSAttributedString textTypes];
}

- (NSSize)integralSizeOfPageAtIndex:(NSUInteger)index
{
  NSLayoutManager *layoutManager = self.layoutManager;
  NSTextContainer *textContainer = layoutManager.textContainers[index];

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
  return textContainer.size;
#else
  return textContainer.containerSize;
#endif
}

- (CGColorRef)copyBackgroundCGColorOfPageAtIndex:(NSUInteger)index
{
  NSColor *backgroundColor =
    documentAttributes[NSBackgroundColorDocumentAttribute];

  /* `backgroundColor' might be nil, but that's OK.  */
  return CGColorRetain (backgroundColor.CGColor);
}

- (NSDictionaryOf (NSString *, id) *)documentAttributesOfPageAtIndex:(NSUInteger)index
{
  return documentAttributes;
}

- (void)drawPageAtIndex:(NSUInteger)index inRect:(NSRect)rect
	      inContext:(CGContextRef)ctx
		options:(NSDictionaryOf (NSString *, id) *)options /* unused */
{
  NSLayoutManager *layoutManager = self.layoutManager;
  NSTextContainer *textContainer = layoutManager.textContainers[index];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
  NSSize containerSize = textContainer.size;
#else
  NSSize containerSize = textContainer.containerSize;
#endif
  NSRange glyphRange = [layoutManager glyphRangeForTextContainer:textContainer];
  NSAffineTransform *transform = NSAffineTransform.transform;
  NSGraphicsContext *gcontext =
    [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];

  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = gcontext;
  [transform translateXBy:(NSMinX (rect)) yBy:(NSMaxY (rect))];
  [transform scaleXBy:(NSWidth (rect) / containerSize.width)
		  yBy:(- NSHeight (rect) / containerSize.height)];
  [transform concat];
  [layoutManager drawBackgroundForGlyphRange:glyphRange atPoint:NSZeroPoint];
  [layoutManager drawGlyphsForGlyphRange:glyphRange atPoint:NSZeroPoint];
  [NSGraphicsContext restoreGraphicsState];
}

- (void)layoutManager:(NSLayoutManager *)aLayoutManager
didCompleteLayoutForTextContainer:(NSTextContainer *)aTextContainer
		atEnd:(BOOL)flag
{
  if (aTextContainer == nil)
    {
      NSLayoutManager *layoutManager = self.layoutManager;
      NSTextContainer *firstContainer = layoutManager.textContainers[0];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      NSTextContainer *textContainer = [[NSTextContainer alloc]
					 initWithSize:firstContainer.size];
#else
      NSSize containerSize = [firstContainer containerSize];
      NSTextContainer *textContainer = [[NSTextContainer alloc]
					 initWithContainerSize:containerSize];
#endif

      [aLayoutManager addTextContainer:textContainer];
      MRC_RELEASE (textContainer);
    }
}

@end				// EmacsDocumentRasterizer

static NSArrayOf (Class <EmacsDocumentRasterizer>) *
document_rasterizer_get_classes (void)
{
  return @[EmacsPDFDocument.class,
	   EmacsSVGDocument.class,
	   EmacsDocumentRasterizer.class];
}

CFArrayRef
mac_document_copy_type_identifiers (void)
{
  NSMutableArrayOf (NSString *) *identifiers = [NSMutableArray array];

  for (Class <EmacsDocumentRasterizer> class
	 in document_rasterizer_get_classes ())
    [identifiers addObjectsFromArray:[class supportedTypes]];

  return CFBridgingRetain (identifiers);
}

static void
document_cache_evict (void)
{
  NSDate *currentDate, *oldestTimestamp;

  if ([documentRasterizerCacheOldestTimestamp timeIntervalSinceNow]
      > - DOCUMENT_RASTERIZER_CACHE_DURATION)
    return;

  currentDate = [NSDate date];
  oldestTimestamp = nil;
  for (id key in [documentRasterizerCache allKeys])
    {
      NSDictionaryOf (NSString *, id) *value = documentRasterizerCache[key];
      NSDate *timestamp = value[@"timestamp"];

      if ([currentDate timeIntervalSinceDate:timestamp]
	  >= DOCUMENT_RASTERIZER_CACHE_DURATION)
	[documentRasterizerCache removeObjectForKey:key];
      else
	{
	  if (oldestTimestamp == nil)
	    oldestTimestamp = timestamp;
	  else
	    oldestTimestamp = [oldestTimestamp earlierDate:timestamp];
	}
    }
  MRC_RELEASE (documentRasterizerCacheOldestTimestamp);
  documentRasterizerCacheOldestTimestamp = MRC_RETAIN (oldestTimestamp);
}

static id <EmacsDocumentRasterizer>
document_cache_lookup (id key, NSDate *modificationDate)
{
  id <EmacsDocumentRasterizer> result = nil;

  if (documentRasterizerCache)
    {
      NSDictionaryOf (NSString *, id) *dictionary =
	documentRasterizerCache[key];

      if (dictionary
	  && (modificationDate == nil
	      || [modificationDate
		   isEqualToDate:[dictionary fileModificationDate]]))
	result = dictionary[@"document"];
    }

  return result;
}

static void
document_cache_set (id <NSCopying> key, id <EmacsDocumentRasterizer> document,
		    NSDate *modificationDate)
{
  NSDate *currentDate;
  NSDictionaryOf (NSString *, id) *value;

  if (documentRasterizerCache == nil)
    documentRasterizerCache = [[NSMutableDictionary alloc] init];

  currentDate = [NSDate date];
  value = [NSDictionary dictionaryWithObjectsAndKeys:document, @"document",
			currentDate, @"timestamp",
			/* The value of modificationDate might be nil,
			   so we don't use NSDictionary literals
			   here.  */
			modificationDate, NSFileModificationDate,
			nil];
  /* This might update an object containing the oldest time stamp.
     Even in such a case, documentRasterizerCacheOldestTimestamp still
     holds an older or equal date than the real oldest time stamp in
     the cache.  */
  documentRasterizerCache[key] = value;
  if (documentRasterizerCacheOldestTimestamp == nil)
    documentRasterizerCacheOldestTimestamp = MRC_RETAIN (currentDate);
}

static id <EmacsDocumentRasterizer>
document_rasterizer_create (id url_or_data,
			    NSDictionaryOf (NSString *, id) *options)
{
  BOOL isURL = [url_or_data isKindOfClass:NSURL.class];

  for (Class class in document_rasterizer_get_classes ())
    {
      id <EmacsDocumentRasterizer> __block document;
      void (^block) (void);

      if (isURL)
	block = ^{
	  document = [((id <EmacsDocumentRasterizer>) [class alloc])
		       initWithURL:((NSURL *) url_or_data) options:options];
	};
      else
	block = ^{
	  document = [((id <EmacsDocumentRasterizer>) [class alloc])
		       initWithData:((NSData *) url_or_data) options:options];
	};

      if ([(Class <EmacsDocumentRasterizer>)class shouldInitializeInMainThread])
	mac_within_gui (block);
      else
	block ();

      if (document)
	return document;
    }

  return nil;
}

EmacsDocumentRef
mac_document_create_with_url (CFURLRef url, CFDictionaryRef options)
{
  NSURL *nsurl = (__bridge NSURL *) url;
  NSDictionaryOf (NSString *, id) *nsoptions =
    (__bridge NSDictionaryOf (NSString *, id) *) options;
  NSDate *modificationDate = nil;
  id <EmacsDocumentRasterizer> document = nil;

  if ([nsurl isFileURL])
    {
      [[nsurl URLByResolvingSymlinksInPath]
	getResourceValue:&modificationDate
		  forKey:NSURLAttributeModificationDateKey
		   error:NULL];
    }

  if (modificationDate)
    {
      NSDictionaryOf (NSString *, id) *key =
	[NSDictionary dictionaryWithObjectsAndKeys:nsurl, @"URL",
		      /* The value of nsoptions might be nil, so we
			 don't use NSDictionary literals here.  */
		      nsoptions, @"options", nil];

      document = MRC_RETAIN (document_cache_lookup (key, modificationDate));
      if (document == nil)
	document = document_rasterizer_create (nsurl, nsoptions);
      if (document && !document.shouldNotCache)
	document_cache_set (key, document, modificationDate);
    }

  document_cache_evict ();

  return CF_ESCAPING_BRIDGE (document);
}

EmacsDocumentRef
mac_document_create_with_data (CFDataRef data, CFDictionaryRef options)
{
  NSData *nsdata = (__bridge NSData *) data;
  NSDictionaryOf (NSString *, id) *nsoptions =
    (__bridge NSDictionaryOf (NSString *, id) *) options;
  NSDictionaryOf (NSString *, id) *key =
    [NSDictionary dictionaryWithObjectsAndKeys:nsdata, @"data",
		  /* The value of nsoptions might be nil, so we don't
		     use NSDictionary literals here.  */
		  nsoptions, @"options", nil];
  id <EmacsDocumentRasterizer> document =
    MRC_RETAIN (document_cache_lookup (key, nil));

  if (document == nil)
    document = document_rasterizer_create (nsdata, nsoptions);
  if (document && !document.shouldNotCache)
    document_cache_set (key, document, nil);

  document_cache_evict ();

  return CF_ESCAPING_BRIDGE (document);
}

size_t
mac_document_get_page_count (EmacsDocumentRef document)
{
  id <EmacsDocumentRasterizer> documentRasterizer =
    (__bridge id <EmacsDocumentRasterizer>) document;

  return [documentRasterizer pageCount];
}

void
mac_document_copy_page_info (EmacsDocumentRef document, size_t index,
			     CGSize *size, CGColorRef *background,
			     CFDictionaryRef *attributes)
{
  id <EmacsDocumentRasterizer> documentRasterizer =
    (__bridge id <EmacsDocumentRasterizer>) document;

  if (size)
    *size = NSSizeToCGSize ([documentRasterizer
			      integralSizeOfPageAtIndex:index]);
  if (background)
    *background = [documentRasterizer copyBackgroundCGColorOfPageAtIndex:index];
  if (attributes)
    *attributes = CFBridgingRetain ([documentRasterizer
				      documentAttributesOfPageAtIndex:index]);
}

void
mac_document_draw_page (CGContextRef c, CGRect rect, EmacsDocumentRef document,
			size_t index, CFDictionaryRef options)
{
  id <EmacsDocumentRasterizer> documentRasterizer =
    (__bridge id <EmacsDocumentRasterizer>) document;

  [documentRasterizer drawPageAtIndex:index inRect:(NSRectFromCGRect (rect))
			    inContext:c
			      options:((__bridge
					NSDictionaryOf (NSString *, id) *)
				       options)];
}


/************************************************************************
			Accessibility Support
 ************************************************************************/

static id ax_get_value (EmacsMainView *);
static id ax_get_selected_text (EmacsMainView *);
static id ax_get_selected_text_range (EmacsMainView *);
static id ax_get_number_of_characters (EmacsMainView *);
static id ax_get_visible_character_range (EmacsMainView *);
#if 0
static id ax_get_shared_text_ui_elements (EmacsMainView *);
static id ax_get_shared_character_range (EmacsMainView *);
#endif
static id ax_get_insertion_point_line_number (EmacsMainView *);
static id ax_get_selected_text_ranges (EmacsMainView *);

static id ax_get_line_for_index (EmacsMainView *, id);
static id ax_get_range_for_line (EmacsMainView *, id);
static id ax_get_string_for_range (EmacsMainView *, id);
static id ax_get_range_for_position (EmacsMainView *, id);
static id ax_get_range_for_index (EmacsMainView *, id);
static id ax_get_bounds_for_range (EmacsMainView *, id);
static id ax_get_rtf_for_range (EmacsMainView *, id);
#if 0
static id ax_get_style_range_for_index (EmacsMainView *, id);
#endif
static id ax_get_attributed_string_for_range (EmacsMainView *, id);

static const struct {
  NSAccessibilityAttributeName const *ns_name_ptr;
  CFStringRef fallback_name;
  id (*handler) (EmacsMainView *);
} ax_attribute_table[] = {
  {&NSAccessibilityValueAttribute, NULL, ax_get_value},
  {&NSAccessibilitySelectedTextAttribute, NULL, ax_get_selected_text},
  {&NSAccessibilitySelectedTextRangeAttribute,
   NULL, ax_get_selected_text_range},
  {&NSAccessibilityNumberOfCharactersAttribute, NULL,
   ax_get_number_of_characters},
  {&NSAccessibilityVisibleCharacterRangeAttribute, NULL,
   ax_get_visible_character_range},
#if 0
  {&NSAccessibilitySharedTextUIElementsAttribute, NULL,
   ax_get_shared_text_ui_elements},
  {&NSAccessibilitySharedCharacterRangeAttribute, NULL,
   ax_get_shared_character_range},
#endif	/* 0 */
  {&NSAccessibilityInsertionPointLineNumberAttribute, NULL,
   ax_get_insertion_point_line_number},
  {
    &NSAccessibilitySelectedTextRangesAttribute,
    CFSTR ("AXSelectedTextRanges"), ax_get_selected_text_ranges},
};
static const size_t ax_attribute_count = countof (ax_attribute_table);
static NSArrayOf (NSAccessibilityAttributeName) *ax_attribute_names;
static Lisp_Object ax_attribute_event_ids;

static const struct {
  NSAccessibilityParameterizedAttributeName const *ns_name_ptr;
  CFStringRef fallback_name;
  id (*handler) (EmacsMainView *, id);
} ax_parameterized_attribute_table[] = {
  {&NSAccessibilityLineForIndexParameterizedAttribute, NULL,
   ax_get_line_for_index},
  {&NSAccessibilityRangeForLineParameterizedAttribute, NULL,
   ax_get_range_for_line},
  {&NSAccessibilityStringForRangeParameterizedAttribute, NULL,
   ax_get_string_for_range},
  {&NSAccessibilityRangeForPositionParameterizedAttribute, NULL,
   ax_get_range_for_position},
  {&NSAccessibilityRangeForIndexParameterizedAttribute, NULL,
   ax_get_range_for_index},
  {&NSAccessibilityBoundsForRangeParameterizedAttribute, NULL,
   ax_get_bounds_for_range},
  {&NSAccessibilityRTFForRangeParameterizedAttribute, NULL,
   ax_get_rtf_for_range},
#if 0
  {&NSAccessibilityStyleRangeForIndexParameterizedAttribute, NULL,
   ax_get_style_range_for_index},
#endif	/* 0 */
  {&NSAccessibilityAttributedStringForRangeParameterizedAttribute, NULL,
   ax_get_attributed_string_for_range},
};
static const size_t ax_parameterized_attribute_count =
  countof (ax_parameterized_attribute_table);
static NSArrayOf (NSAccessibilityParameterizedAttributeName)
  *ax_parameterized_attribute_names;

static const struct {
  NSAccessibilityActionName const *ns_name_ptr;
  CFStringRef fallback_name;
} ax_action_table[] = {
  {&NSAccessibilityShowMenuAction, NULL},
};
static const size_t ax_action_count = countof (ax_action_table);
static NSArrayOf (NSAccessibilityActionName) *ax_action_names;
static Lisp_Object ax_action_event_ids;

static NSAccessibilityNotificationName ax_selected_text_changed_notification;

static Lisp_Object
ax_name_to_symbol (NSString *name, NSString *prefix)
{
  NSArrayOf (NSString *) *nameComponents =
    [[name substringFromIndex:2] /* strip off leading "AX" */
      componentsSeparatedByCamelCasingWithCharactersInSet:nil];
  NSMutableArrayOf (NSString *) *symbolComponents =
    [NSMutableArray arrayWithCapacity:[nameComponents count]];

  if (prefix)
    [symbolComponents addObject:prefix];
  for (NSString *component in nameComponents)
    [symbolComponents addObject:[component lowercaseString]];

  return Fintern ([[symbolComponents componentsJoinedByString:@"-"]
		    UTF8LispString], Qnil);
}

static void
init_accessibility (void)
{
  int i;
  NSString * __unsafe_unretained *buf;

  buf = ((NSString * __unsafe_unretained *)
	 xmalloc (sizeof (NSString *) * ax_attribute_count));
  ax_attribute_event_ids =
    Fmake_vector (make_fixnum (ax_attribute_count), Qnil);
  staticpro (&ax_attribute_event_ids);
  for (i = 0; i < ax_attribute_count; i++)
    {
      buf[i] = (ax_attribute_table[i].ns_name_ptr
		? *ax_attribute_table[i].ns_name_ptr
		: (__bridge NSString *) ax_attribute_table[i].fallback_name);
      ASET (ax_attribute_event_ids, i, ax_name_to_symbol (buf[i], @"set"));
    }
  ax_attribute_names = [[NSArray alloc] initWithObjects:buf
						  count:ax_attribute_count];

  buf = ((NSString * __unsafe_unretained *)
	 xrealloc (buf,
		   sizeof (NSString *) * ax_parameterized_attribute_count));
  for (i = 0; i < ax_parameterized_attribute_count; i++)
    buf[i] = (ax_parameterized_attribute_table[i].ns_name_ptr
	      ? *ax_parameterized_attribute_table[i].ns_name_ptr
	      : ((__bridge NSString *)
		 ax_parameterized_attribute_table[i].fallback_name));
  ax_parameterized_attribute_names =
    [[NSArray alloc] initWithObjects:buf
			       count:ax_parameterized_attribute_count];

  buf = ((NSString * __unsafe_unretained *)
	 xrealloc (buf, sizeof (NSString *) * ax_action_count));
  ax_action_event_ids = Fmake_vector (make_fixnum (ax_action_count), Qnil);
  staticpro (&ax_action_event_ids);
  for (i = 0; i < ax_action_count; i++)
    {
      buf[i] = (ax_action_table[i].ns_name_ptr
		? *ax_action_table[i].ns_name_ptr
		: (__bridge NSString *) ax_action_table[i].fallback_name);
      ASET (ax_action_event_ids, i, ax_name_to_symbol (buf[i], nil));
    }
  ax_action_names = [[NSArray alloc] initWithObjects:buf count:ax_action_count];

  xfree (buf);

  ax_selected_text_changed_notification =
    NSAccessibilitySelectedTextChangedNotification;
}

@implementation EmacsController (Accessibility)

- (void)accessibilityDisplayOptionsDidChange:(NSNotification *)notification
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self accessibilityDisplayOptionsDidChange:
					notification]);

  mac_update_accessibility_display_options ();
}

struct mac_accessibility_display_options mac_accessibility_display_options;

static void
mac_update_accessibility_display_options (void)
{
  NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

  mac_accessibility_display_options.increase_contrast_p =
    [workspace accessibilityDisplayShouldIncreaseContrast];
  mac_accessibility_display_options.differentiate_without_color_p =
    [workspace accessibilityDisplayShouldDifferentiateWithoutColor];
  mac_accessibility_display_options.reduce_transparency_p =
    [workspace accessibilityDisplayShouldReduceTransparency];
}

@end				// EmacsController (Accessibility)

@implementation EmacsMainView (Accessibility)

- (BOOL)accessibilityIsIgnored
{
  return mac_ignore_accessibility;
}

- (NSArrayOf (NSAccessibilityAttributeName) *)accessibilityAttributeNames
{
  static NSArrayOf (NSAccessibilityAttributeName) *names = nil;

  if (names == nil)
    names = MRC_RETAIN ([[super accessibilityAttributeNames]
			  arrayByAddingObjectsFromArray:ax_attribute_names]);

  return names;
}

static id
ax_get_value (EmacsMainView *emacsView)
{
  return [emacsView string];
}

static id
ax_get_selected_text (EmacsMainView *emacsView)
{
  struct frame *f = [emacsView emacsFrame];
  CFRange selectedRange;
  CFStringRef string;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  mac_ax_selected_text_range (f, &selectedRange);
  string = mac_ax_create_string_for_range (f, &selectedRange, NULL);

  return CFBridgingRelease (string);
}

static id
ax_get_insertion_point_line_number (EmacsMainView *emacsView)
{
  struct frame *f = [emacsView emacsFrame];
  EMACS_INT line;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  line = mac_ax_line_for_index (f, -1);

  return line >= 0 ? @(line) : nil;
}

static id
ax_get_selected_text_range (EmacsMainView *emacsView)
{
  return [NSValue valueWithRange:[emacsView selectedRange]];
}

static id
ax_get_number_of_characters (EmacsMainView *emacsView)
{
  EMACS_INT length = mac_ax_number_of_characters ([emacsView emacsFrame]);

  return @(length);
}

static id
ax_get_visible_character_range (EmacsMainView *emacsView)
{
  NSRange range;

  mac_ax_visible_character_range ([emacsView emacsFrame], (CFRange *) &range);

  return [NSValue valueWithRange:range];
}

static id
ax_get_selected_text_ranges (EmacsMainView *emacsView)
{
  NSValue *rangeValue = [NSValue valueWithRange:[emacsView selectedRange]];

  return @[rangeValue];
}

- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute
{
  MAC_LOOP_QUERY_NEEDS_LISP (id, nil,
			     [self accessibilityAttributeValue:attribute]);

  NSUInteger index = [ax_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    return (*ax_attribute_table[index].handler) (self);
  else if ([attribute isEqualToString:NSAccessibilityRoleAttribute])
    return NSAccessibilityTextAreaRole;
  else
    return [super accessibilityAttributeValue:attribute];
}

- (BOOL)accessibilityIsAttributeSettable:(NSAccessibilityAttributeName)attribute
{
  MAC_LOOP_QUERY_NEEDS_LISP (BOOL, NO,
			     [self accessibilityIsAttributeSettable:attribute]);

  NSUInteger index = [ax_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    {
      Lisp_Object tem = get_keymap (Vmac_apple_event_map, 0, 0);

      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qaccessibility, 0, 1), 0, 0);
      if (!NILP (tem))
	tem = access_keymap (tem, AREF (ax_attribute_event_ids, index),
			     0, 1);

      return !NILP (tem) && !EQ (tem, Qundefined);
    }
  else
    return [super accessibilityIsAttributeSettable:attribute];
}

- (void)accessibilitySetValue:(id)value
		 forAttribute:(NSAccessibilityAttributeName)attribute
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self accessibilitySetValue:value
					       forAttribute:attribute]);

  NSUInteger index = [ax_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    {
      struct frame *f = [self emacsFrame];
      struct input_event inev;
      Lisp_Object arg = Qnil, obj;

      if (NILP (AREF (ax_attribute_event_ids, index)))
	emacs_abort ();

      arg = Fcons (Fcons (Qwindow,
			  Fcons (build_string ("Lisp"),
				 f->selected_window)), arg);
      obj = cfobject_to_lisp ((__bridge CFTypeRef) value,
			      CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
      arg = Fcons (Fcons (build_string ("----"),
			  Fcons (build_string ("Lisp"), obj)), arg);
      EVENT_INIT (inev);
      inev.kind = MAC_APPLE_EVENT;
      inev.x = Qaccessibility;
      inev.y = AREF (ax_attribute_event_ids, index);
      XSETFRAME (inev.frame_or_window, f);
      inev.arg = Fcons (build_string ("aevt"), arg);
      [emacsController storeEvent:&inev];
    }
  else
    [super accessibilitySetValue:value forAttribute:attribute];
}

- (NSArrayOf (NSAccessibilityParameterizedAttributeName) *)accessibilityParameterizedAttributeNames
{
  static NSArrayOf (NSAccessibilityParameterizedAttributeName) *names = nil;

  if (names == nil)
    names = MRC_RETAIN ([[super accessibilityAttributeNames]
			  arrayByAddingObjectsFromArray:ax_parameterized_attribute_names]);

  return names;
}

static id
ax_get_line_for_index (EmacsMainView *emacsView, id parameter)
{
  struct frame *f = [emacsView emacsFrame];
  EMACS_INT line;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  line = mac_ax_line_for_index (f, [(NSNumber *)parameter longValue]);

  return line >= 0 ? @(line) : nil;
}

static id
ax_get_range_for_line (EmacsMainView *emacsView, id parameter)
{
  struct frame *f = [emacsView emacsFrame];
  EMACS_INT line;
  NSRange range;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  line = [(NSNumber *)parameter longValue];
  if (mac_ax_range_for_line (f, line, (CFRange *) &range))
    return [NSValue valueWithRange:range];
  else
    return nil;
}

static id
ax_get_string_for_range (EmacsMainView *emacsView, id parameter)
{
  NSRange range = [(NSValue *)parameter rangeValue];
  struct frame *f = [emacsView emacsFrame];
  CFStringRef string;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  string = mac_ax_create_string_for_range (f, (CFRange *) &range, NULL);

  return CFBridgingRelease (string);
}

static NSRect
ax_get_bounds_for_range_1 (EmacsMainView *emacsView, NSRange range)
{
  NSRange actualRange;
  NSRect rect;

  rect = [emacsView firstRectForCharacterRange:range actualRange:&actualRange];
  while (actualRange.length > 0)
    {
      NSRect rect1;

      if (actualRange.location > range.location)
	{
	  NSRange range1 = NSMakeRange (range.location,
					actualRange.location - range.location);

	  rect1 = ax_get_bounds_for_range_1 (emacsView, range1);
	  rect = NSUnionRect (rect, rect1);
	}
      if (NSMaxRange (actualRange) < NSMaxRange (range))
	{
	  range = NSMakeRange (NSMaxRange (actualRange),
			       NSMaxRange (range) - NSMaxRange (actualRange));
	  rect1 = [emacsView firstRectForCharacterRange:range
					    actualRange:&actualRange];
	  rect = NSUnionRect (rect, rect1);
	}
      else
	break;
    }

  return rect;
}

static id
ax_get_bounds_for_range (EmacsMainView *emacsView, id parameter)
{
  NSRange range = [(NSValue *)parameter rangeValue];
  NSRect rect;

  if (range.location >= NSNotFound)
    rect = [emacsView firstRectForCharacterRange:range actualRange:NULL];
  else
    rect = ax_get_bounds_for_range_1 (emacsView, range);

  return [NSValue valueWithRect:rect];
}

static id
ax_get_range_for_position (EmacsMainView *emacsView, id parameter)
{
  NSPoint position = [(NSValue *)parameter pointValue];
  NSUInteger index = [emacsView characterIndexForPoint:position];

  if (index == NSNotFound)
    return nil;
  else
    return [NSValue valueWithRange:(NSMakeRange (index, 1))];
}

static id
ax_get_range_for_index (EmacsMainView *emacsView, id parameter)
{
  NSRange range = NSMakeRange ([(NSNumber *)parameter unsignedLongValue], 1);

  return [NSValue valueWithRange:range];
}

static id
ax_get_rtf_for_range (EmacsMainView *emacsView, id parameter)
{
  NSRange range = [(NSValue *)parameter rangeValue];
  NSAttributedString *attributedString =
    [emacsView attributedSubstringForProposedRange:range actualRange:NULL];

  return [attributedString
	   RTFFromRange:(NSMakeRange (0, [attributedString length]))
	   documentAttributes:@{}];
}

static id
ax_get_attributed_string_for_range (EmacsMainView *emacsView, id parameter)
{
  NSString *string = ax_get_string_for_range (emacsView, parameter);

  if (string)
    return MRC_AUTORELEASE ([[NSAttributedString alloc] initWithString:string]);
  else
    return nil;
}

- (id)accessibilityAttributeValue:(NSAccessibilityParameterizedAttributeName)attribute
		     forParameter:(id)parameter
{
  MAC_LOOP_QUERY_NEEDS_LISP (id, nil,
			     [self accessibilityAttributeValue:attribute
						  forParameter:parameter]);

  NSUInteger index = [ax_parameterized_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    return (*ax_parameterized_attribute_table[index].handler) (self, parameter);
  else
    return [super accessibilityAttributeValue:attribute forParameter:parameter];
}

- (NSArrayOf (NSAccessibilityActionName) *)accessibilityActionNames
{
  static NSArrayOf (NSAccessibilityActionName) *names = nil;

  if (names == nil)
    names = MRC_RETAIN ([[super accessibilityActionNames]
			  arrayByAddingObjectsFromArray:ax_action_names]);

  return names;
}

- (void)accessibilityPerformAction:(NSAccessibilityActionName)theAction
{
  MAC_LOOP_CALLBACK_NEEDS_LISP ([self accessibilityPerformAction:theAction]);

  NSUInteger index = [ax_action_names indexOfObject:theAction];

  if (index != NSNotFound)
    {
      struct frame *f = [self emacsFrame];
      struct input_event inev;
      Lisp_Object arg = Qnil;

      arg = Fcons (Fcons (Qwindow,
			  Fcons (build_string ("Lisp"),
				 f->selected_window)), arg);
      EVENT_INIT (inev);
      inev.kind = MAC_APPLE_EVENT;
      inev.x = Qaccessibility;
      inev.y = AREF (ax_action_event_ids, index);
      XSETFRAME (inev.frame_or_window, f);
      inev.arg = Fcons (build_string ("aevt"), arg);
      [emacsController storeEvent:&inev];
    }
  else
    [super accessibilityPerformAction:theAction];
}

@end				// EmacsMainView (Accessibility)

@implementation EmacsFrameController (Accessibility)

- (void)postAccessibilityNotificationsToEmacsView
{
  NSAccessibilityPostNotification (emacsView,
				   ax_selected_text_changed_notification);
  NSAccessibilityPostNotification (emacsView,
				   NSAccessibilityValueChangedNotification);
}

@end			       // EmacsFrameController (Accessibility)

void
mac_update_accessibility_status (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController postAccessibilityNotificationsToEmacsView];
}


/************************************************************************
			      Animation
 ************************************************************************/

@implementation EmacsFrameController (Animation)

- (void)setupAnimationLayer
{
  animationLayer = [CALayer layer];
  animationLayer.anchorPoint = CGPointZero;
  [[overlayView layer] addSublayer:animationLayer];
}

- (CALayer *)layerForRect:(NSRect)rect
{
  NSRect rectInLayer = [emacsView convertRect:rect
				       toView:emacsWindow.contentView];
  CALayer *layer, *contentLayer;
  NSBitmapImageRep *bitmap;

  layer = [CALayer layer];
  contentLayer = [CALayer layer];
  layer.frame = NSRectToCGRect (rectInLayer);
  layer.masksToBounds = YES;
  contentLayer.frame = CGRectMake (0, 0, NSWidth (rectInLayer),
				   NSHeight (rectInLayer));
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_12))
    bitmap = [self bitmapImageRepInEmacsViewRect:rect];
  else
    {
      NSRect fullHeightRect = [emacsView bounds];

      fullHeightRect.origin.x = NSMinX (rect);
      fullHeightRect.size.width = NSWidth (rect);
      bitmap = [self bitmapImageRepInEmacsViewRect:fullHeightRect];
      contentLayer.contentsRect =
	CGRectMake (0, NSMinY (rectInLayer) / NSHeight (fullHeightRect),
		    1, NSHeight (rectInLayer) / NSHeight (fullHeightRect));
    }
  contentLayer.contents = (id) [bitmap CGImage];
  [layer addSublayer:contentLayer];

  return layer;
}

- (void)addLayer:(CALayer *)layer
{
  [CATransaction setDisableActions:YES];
  [animationLayer addSublayer:layer];
  [CATransaction commit];
}

static Lisp_Object
get_symbol_from_filter_input_key (NSString *key)
{
  NSArrayOf (NSString *) *components =
    [key componentsSeparatedByCamelCasingWithCharactersInSet:nil];
  NSUInteger count = components.count;

  if (count > 1 && [components[0] isEqualToString:@"input"])
    {
      NSMutableArrayOf (NSString *) *symbolComponents =
	[NSMutableArray arrayWithCapacity:(count - 1)];
      NSUInteger index;
      Lisp_Object string;

      for (index = 1; index < count; index++)
	[symbolComponents addObject:[components[index] lowercaseString]];
      string = [symbolComponents componentsJoinedByString:@"-"].UTF8LispString;
      AUTO_STRING (colon, ":");
      return Fintern (concat2 (colon, string), Qnil);
    }
  else
    return Qnil;
}

- (CIFilter *)transitionFilterFromProperties:(Lisp_Object)properties
{
  struct frame *f = emacsFrame;
  NSString *filterName;
  CIFilter *filter;
  NSDictionaryOf (NSString *, id) *attributes;
  Lisp_Object type = plist_get (properties, QCtype);

  if (EQ (type, Qbars_swipe))
    filterName = @"CIBarsSwipeTransition";
  else if (EQ (type, Qcopy_machine))
    filterName = @"CICopyMachineTransition";
  else if (EQ (type, Qdissolve))
    filterName = @"CIDissolveTransition";
  else if (EQ (type, Qflash))
    filterName = @"CIFlashTransition";
  else if (EQ (type, Qmod))
    filterName = @"CIModTransition";
  else if (EQ (type, Qpage_curl))
    filterName = @"CIPageCurlTransition";
  else if (EQ (type, Qpage_curl_with_shadow))
    filterName = @"CIPageCurlWithShadowTransition";
  else if (EQ (type, Qripple))
    filterName = @"CIRippleTransition";
  else if (EQ (type, Qswipe))
    filterName = @"CISwipeTransition";
  else
    return nil;

  filter = [CIFilter filterWithName:filterName];
  [filter setDefaults];
  if (EQ (type, Qbars_swipe)		   /* [0, 2pi], default pi */
      || EQ (type, Qcopy_machine)	   /* [0, 2pi], default 0 */
      || EQ (type, Qpage_curl)		   /* [-pi, pi], default 0 */
      || EQ (type, Qpage_curl_with_shadow) /* [-pi, pi], default 0 */
      || EQ (type, Qswipe))		   /* [-pi, pi], default 0 */
    {
      Lisp_Object direction = plist_get (properties, QCdirection);
      double direction_angle;

      if (EQ (direction, Qleft))
	direction_angle = M_PI;
      else if (EQ (direction, Qright))
	direction_angle = 0;
      else if (EQ (direction, Qdown))
	{
	  if (EQ (type, Qbars_swipe) || EQ (type, Qcopy_machine))
	    direction_angle = 3 * M_PI_2;
	  else
	    direction_angle = - M_PI_2;
	}
      else if (EQ (direction, Qup))
	direction_angle = M_PI_2;
      else
	direction = Qnil;

      if (!NILP (direction))
	[filter setValue:@(direction_angle) forKey:kCIInputAngleKey];
    }

  if ([filterName isEqualToString:@"CIPageCurlTransition"]
      || EQ (type, Qripple))
    /* TODO: create a real shading image like
       /Library/Widgets/CI Filter Browser.wdgt/Images/restrictedshine.png */
    [filter setValue:[CIImage emptyImage] forKey:kCIInputShadingImageKey];

  attributes = [filter attributes];
  for (NSString *key in [filter inputKeys])
    {
      NSDictionary *keyAttributes = attributes[key];

      if ([keyAttributes[kCIAttributeClass] isEqualToString:@"NSNumber"]
	  && ![key isEqualToString:kCIInputTimeKey])
	{
	  Lisp_Object symbol = get_symbol_from_filter_input_key (key);

	  if (!NILP (symbol))
	    {
	      Lisp_Object value = plist_get (properties, symbol);

	      if (NUMBERP (value))
		[filter setValue:@(XFLOATINT (value)) forKey:key];
	    }
	}
      else if ([keyAttributes[kCIAttributeType]
		   isEqualToString:kCIAttributeTypeOpaqueColor])
	{
	  Lisp_Object symbol = get_symbol_from_filter_input_key (key);

	  if (!NILP (symbol))
	    {
	      Lisp_Object value = plist_get (properties, symbol);
	      CGFloat components[4];
	      int i;

	      if (STRINGP (value))
		{
		  Emacs_Color xcolor;

		  if (mac_defined_color (f, SSDATA (value), &xcolor,
					 false, false))
		    value = list3 (make_fixnum (xcolor.red),
				   make_fixnum (xcolor.green),
				   make_fixnum (xcolor.blue));
		}
	      for (i = 0; i < 3; i++)
		{
		  if (!CONSP (value))
		    break;
		  if (FIXNUMP (XCAR (value)))
		    components[i] =
		      min (max (0, (CGFloat) XFIXNUM (XCAR (value)) / 65535), 1);
		  else if (FLOATP (XCAR (value)))
		    components[i] =
		      min (max (0, XFLOAT_DATA (XCAR (value))), 1);
		  else
		    break;
		  value = XCDR (value);
		}
	      if (i == 3 && NILP (value))
		{
		  CGColorRef cg_color;
		  CIColor *color;

		  components[3] = 1.0;
		  cg_color = CGColorCreate (mac_cg_color_space_rgb, components);
		  if (cg_color)
		    {
		      color = [CIColor colorWithCGColor:cg_color];
		      CGColorRelease (cg_color);
		    }
		  else
		    color = [CIColor colorWithRed:components[0]
					    green:components[1]
					     blue:components[2]];
		  [filter setValue:color forKey:key];
		}
	    }
	}
    }

  return filter;
}

- (void)adjustTransitionFilter:(CIFilter *)filter forLayer:(CALayer *)layer
{
  NSDictionaryOf (NSString *, id) *attributes = filter.attributes;
  CGFloat scaleFactor = 1.0;

  if ([attributes[kCIInputCenterKey][kCIAttributeType]
	  isEqualToString:kCIAttributeTypePosition])
    {
      CGPoint center = layer.position;

      [filter setValue:[CIVector vectorWithX:(center.x * scaleFactor)
					   Y:(center.y * scaleFactor)]
		forKey:kCIInputCenterKey];
    }

  if ([attributes[kCIAttributeFilterName]
	  isEqualToString:@"CIPageCurlWithShadowTransition"])
    {
      CGRect frame = layer.frame;
      CGAffineTransform atfm =
	CGAffineTransformMakeTranslation (CGRectGetMinX (frame) * scaleFactor,
					  CGRectGetMinY (frame) * scaleFactor);
      CALayer *contentLayer = layer.sublayers[0];
      CGFloat scale = 1 / emacsWindow.backingScaleFactor;
      CIImage *image;

      atfm = CGAffineTransformScale (atfm, scale, scale);
      image = [CIImage imageWithCGImage:((__bridge CGImageRef)
					 contentLayer.contents)];
      [filter setValue:[image imageByApplyingTransform:atfm]
		forKey:@"inputBacksideImage"];
    }
}

/* Delegate Methods  */

@end

void
mac_start_animation (Lisp_Object frame_or_window, Lisp_Object properties)
{
  struct frame *f;
  EmacsFrameController *frameController;
  CGRect rect;

  if (FRAMEP (frame_or_window))
    {
      f = XFRAME (frame_or_window);
      rect = CGRectMake (0, 0, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f));
    }
  else
    {
      struct window *w = XWINDOW (frame_or_window);

      f = XFRAME (WINDOW_FRAME (w));
      rect = CGRectMake (WINDOW_LEFT_EDGE_X (w), WINDOW_TOP_EDGE_Y (w),
			 WINDOW_PIXEL_WIDTH (w), WINDOW_PIXEL_HEIGHT (w));
    }
  frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      CIFilter *transitionFilter;
      CALayer *layer, *contentLayer;
      Lisp_Object direction, duration;
      CGFloat h_ratio, v_ratio;
      enum {
	ANIM_TYPE_NONE,
	ANIM_TYPE_MOVE_OUT,
	ANIM_TYPE_MOVE_IN,
	ANIM_TYPE_FADE_OUT,
	ANIM_TYPE_FADE_IN,
	ANIM_TYPE_TRANSITION_FILTER
      } anim_type;

      transitionFilter =
	[frameController transitionFilterFromProperties:properties];
      if (transitionFilter)
	anim_type = ANIM_TYPE_TRANSITION_FILTER;
      else
	{
	  Lisp_Object type;

	  direction = plist_get (properties, QCdirection);

	  type = plist_get (properties, QCtype);
	  if (EQ (type, Qnone))
	    anim_type = ANIM_TYPE_NONE;
	  else if (EQ (type, Qfade_in))
	    anim_type = ANIM_TYPE_FADE_IN;
	  else if (EQ (type, Qmove_in))
	    anim_type = ANIM_TYPE_MOVE_IN;
	  else if (EQ (direction, Qleft) || EQ (direction, Qright)
		   || EQ (direction, Qdown) || EQ (direction, Qup))
	    anim_type = ANIM_TYPE_MOVE_OUT;
	  else
	    anim_type = ANIM_TYPE_FADE_OUT;
	}

      layer = [frameController layerForRect:(NSRectFromCGRect (rect))];
      contentLayer = layer.sublayers[0];

      if (anim_type == ANIM_TYPE_FADE_IN)
	contentLayer.opacity = 0;
      else if (anim_type == ANIM_TYPE_MOVE_OUT
	       || anim_type == ANIM_TYPE_MOVE_IN)
	{
	  h_ratio = v_ratio = 0;
	  if (EQ (direction, Qleft))
	    h_ratio = -1;
	  else if (EQ (direction, Qright))
	    h_ratio = 1;
	  else if (EQ (direction, Qdown))
	    v_ratio = -1;
	  else if (EQ (direction, Qup))
	    v_ratio = 1;

	  if (anim_type == ANIM_TYPE_MOVE_IN)
	    {
	      CGPoint position = contentLayer.position;

	      position.x -= CGRectGetWidth (layer.bounds) * h_ratio;
	      position.y -= CGRectGetHeight (layer.bounds) * v_ratio;
	      contentLayer.position = position;
	    }
	}

      if (anim_type == ANIM_TYPE_MOVE_OUT || anim_type == ANIM_TYPE_MOVE_IN)
	contentLayer.shadowOpacity = 1;

      [frameController addLayer:layer];

      duration = plist_get (properties, QCduration);
      if (NUMBERP (duration))
	[CATransaction setValue:@(XFLOATINT (duration))
			 forKey:kCATransactionAnimationDuration];

      [CATransaction setCompletionBlock:^{
	  [CATransaction setDisableActions:YES];
	  [layer removeFromSuperlayer];
	}];
      switch (anim_type)
	{
	case ANIM_TYPE_NONE:
	  {
	    CGRect bounds = contentLayer.bounds;

	    /* Dummy change of property that does not affect the
	       appearance.  */
	    bounds.origin.x += 1;
	    contentLayer.bounds = bounds;
	  }
	  break;

	case ANIM_TYPE_FADE_OUT:
	  contentLayer.opacity = 0;
	  break;

	case ANIM_TYPE_FADE_IN:
	  contentLayer.opacity = 1;
	  break;

	case ANIM_TYPE_MOVE_OUT:
	case ANIM_TYPE_MOVE_IN:
	  {
	    CGPoint position = contentLayer.position;

	    position.x += CGRectGetWidth (layer.bounds) * h_ratio;
	    position.y += CGRectGetHeight (layer.bounds) * v_ratio;
	    contentLayer.position = position;
	  }
	  break;

	case ANIM_TYPE_TRANSITION_FILTER:
	  {
	    CATransition *transition = CATransition.animation;
	    NSMutableDictionaryOf (NSString *, id <CAAction>) *actions;
	    CALayer *newContentLayer;

	    [frameController adjustTransitionFilter:transitionFilter
					   forLayer:layer];
	    transition.filter = transitionFilter;

	    actions = [NSMutableDictionary
			dictionaryWithDictionary:[layer actions]];
	    actions[@"sublayers"] = transition;
	    layer.actions = actions;

	    newContentLayer = [CALayer layer];
	    newContentLayer.frame = contentLayer.frame;
	    newContentLayer.opacity = 0;
	    [layer replaceSublayer:contentLayer with:newContentLayer];
	  }
	  break;

	default:
	  emacs_abort ();
	}
    });
}


/************************************************************************
				Fonts
 ************************************************************************/

@implementation NSLayoutManager (Emacs)

/* Return union of enclosing rects for glyphRange in textContainer.  */

- (NSRect)enclosingRectForGlyphRange:(NSRange)glyphRange
		     inTextContainer:(NSTextContainer *)textContainer
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
  NSRect __block result = NSZeroRect;

  [self enumerateEnclosingRectsForGlyphRange:glyphRange
		    withinSelectedGlyphRange:(NSMakeRange (NSNotFound, 0))
			     inTextContainer:textContainer
				  usingBlock:^(NSRect rect, BOOL *stop) {
      result = NSUnionRect (result, rect);
    }];
#else
  NSRect result = NSZeroRect;
  NSUInteger i, nrects;
  NSRect *rects = [self rectArrayForGlyphRange:glyphRange
		      withinSelectedGlyphRange:(NSMakeRange (NSNotFound, 0))
			       inTextContainer:textContainer rectCount:&nrects];

  for (i = 0; i < nrects; i++)
    result = NSUnionRect (result, rects[i]);
#endif

  return result;
}

@end				// NSLayoutManager (Emacs)

CFIndex
mac_font_get_weight (CTFontRef font)
{
  NSFont *nsFont = (__bridge NSFont *) font;

  return [[NSFontManager sharedFontManager] weightOfFont:nsFont];
}

ScreenFontRef
mac_screen_font_create_with_name (CFStringRef name, CGFloat size)
{
  NSFont *result, *font;

  font = [NSFont fontWithName:((__bridge NSString *) name) size:size];
  result = [font screenFont];

  return CFBridgingRetain (result);
}

CGFloat
mac_screen_font_get_advance_width_for_glyph (ScreenFontRef font, CGGlyph glyph)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101300
  NSSize advancement = [(__bridge NSFont *)font advancementForCGGlyph:glyph];
#else
  NSSize advancement = [(__bridge NSFont *)font advancementForGlyph:glyph];
#endif

  return advancement.width;
}

Boolean
mac_screen_font_get_metrics (ScreenFontRef font, CGFloat *ascent,
			     CGFloat *descent, CGFloat *leading)
{
  NSFont *nsFont = (__bridge NSFont *) font;
  NSTextStorage *textStorage;
  NSLayoutManager *layoutManager;
  NSTextContainer *textContainer;
  NSRect usedRect;
  NSPoint spaceLocation;
  CGFloat descender;

  textStorage = [[NSTextStorage alloc] initWithString:@" "];
  layoutManager = [[NSLayoutManager alloc] init];
  textContainer = [[NSTextContainer alloc] init];

  [textStorage setFont:nsFont];
  [textContainer setLineFragmentPadding:0];

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  if (!(textStorage && layoutManager && textContainer))
    {
      MRC_RELEASE (textStorage);

      return false;
    }

  usedRect = [layoutManager lineFragmentUsedRectForGlyphAtIndex:0
						 effectiveRange:NULL];
  spaceLocation = [layoutManager locationForGlyphAtIndex:0];
  MRC_RELEASE (textStorage);

  *ascent = spaceLocation.y;
  *descent = NSHeight (usedRect) - spaceLocation.y;
  *leading = 0;
  descender = [nsFont descender];
  if (- descender < *descent)
    {
      *leading = *descent + descender;
      *descent = - descender;
    }

  return true;
}

CFIndex
mac_screen_font_shape (ScreenFontRef screen_font, CFStringRef cf_string,
		       struct mac_glyph_layout *glyph_layouts,
		       CFIndex glyph_len, enum lgstring_direction dir)
{
  NSFont *font = (__bridge NSFont *) screen_font;
  NSString *string = (__bridge NSString *) cf_string;
  NSUInteger i;
  CFIndex result = 0;
  NSTextStorage *textStorage;
  NSLayoutManager *layoutManager;
  NSTextContainer *textContainer;
  NSUInteger stringLength;
  NSPoint spaceLocation;
  NSUInteger used, numberOfGlyphs;

  textStorage = [[NSTextStorage alloc] initWithString:string];
  layoutManager = [[NSLayoutManager alloc] init];
  textContainer = [[NSTextContainer alloc] init];

  /* Append a trailing space to measure baseline position.  */
  [textStorage appendAttributedString:(MRC_AUTORELEASE
				       ([[NSAttributedString alloc]
					  initWithString:@" "]))];
  [textStorage setFont:font];
  [textContainer setLineFragmentPadding:0];

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  if (!(textStorage && layoutManager && textContainer))
    {
      MRC_RELEASE (textStorage);

      return 0;
    }

  stringLength = [string length];

  /* Force layout.  */
  (void) [layoutManager glyphRangeForTextContainer:textContainer];

  spaceLocation = [layoutManager locationForGlyphAtIndex:stringLength];

  /* Remove the appended trailing space because otherwise it may
     generate a wrong result for a right-to-left text.  */
  [textStorage beginEditing];
  [textStorage deleteCharactersInRange:(NSMakeRange (stringLength, 1))];
  [textStorage endEditing];
  (void) [layoutManager glyphRangeForTextContainer:textContainer];

  i = 0;
  while (i < stringLength)
    {
      NSRange range;
      NSFont *fontInTextStorage =
	[textStorage attribute:NSFontAttributeName atIndex:i
		     longestEffectiveRange:&range
		       inRange:(NSMakeRange (0, stringLength))];

      if (!(fontInTextStorage == font
	    || [[fontInTextStorage fontName] isEqualToString:[font fontName]]))
	break;
      i = NSMaxRange (range);
    }
  if (i < stringLength)
    /* Make the test `used <= glyph_len' below fail if textStorage
       contained some fonts other than the specified one.  */
    used = glyph_len + 1;
  else
    {
      NSRange range = NSMakeRange (0, stringLength);

      range = [layoutManager glyphRangeForCharacterRange:range
				    actualCharacterRange:NULL];
      numberOfGlyphs = NSMaxRange (range);
      used = numberOfGlyphs;
      for (i = 0; i < numberOfGlyphs; i++)
	if ([layoutManager notShownAttributeForGlyphAtIndex:i])
	  used--;
    }

  if (0 < used && used <= glyph_len)
    {
      NSUInteger glyphIndex, prevGlyphIndex;
      unsigned char bidiLevel;
      NSUInteger *permutation;
      NSRange compRange, range;
      CGFloat totalAdvance;

      glyphIndex = 0;
      while ([layoutManager notShownAttributeForGlyphAtIndex:glyphIndex])
	glyphIndex++;

      /* For now we assume the direction is not changed within the
	 string.  */
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101100
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      if ([layoutManager
	    respondsToSelector:@selector(getGlyphsInRange:glyphs:properties:characterIndexes:bidiLevels:)])
#endif
	{
	  [layoutManager getGlyphsInRange:(NSMakeRange (glyphIndex, 1))
				   glyphs:NULL properties:NULL
			 characterIndexes:NULL bidiLevels:&bidiLevel];
	}
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      else
#endif
#endif
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101100 || MAC_OS_X_VERSION_MIN_REQUIRED < 101100
	{
	  [layoutManager getGlyphsInRange:(NSMakeRange (glyphIndex, 1))
				   glyphs:NULL characterIndexes:NULL
			glyphInscriptions:NULL elasticBits:NULL
			       bidiLevels:&bidiLevel];
	}
#endif
      if (bidiLevel & 1)
	permutation = xmalloc (sizeof (NSUInteger) * used);
      else
	permutation = NULL;

#define RIGHT_TO_LEFT_P permutation

      /* Fill the `comp_range' member of struct mac_glyph_layout, and
	 setup a permutation for right-to-left text.  */
      compRange = NSMakeRange (0, 0);
      for (range = NSMakeRange (0, 0); NSMaxRange (range) < used;
	   range.length++)
	{
	  struct mac_glyph_layout *gl = glyph_layouts + NSMaxRange (range);
	  NSUInteger characterIndex =
	    [layoutManager characterIndexForGlyphAtIndex:glyphIndex];

	  gl->string_index = characterIndex;

	  if (characterIndex >= NSMaxRange (compRange))
	    {
	      compRange.location = NSMaxRange (compRange);
	      do
		{
		  NSRange characterRange =
		    [string
		      rangeOfComposedCharacterSequenceAtIndex:characterIndex];

		  compRange.length =
		    NSMaxRange (characterRange) - compRange.location;
		  [layoutManager glyphRangeForCharacterRange:compRange
					actualCharacterRange:&characterRange];
		  characterIndex = NSMaxRange (characterRange) - 1;
		}
	      while (characterIndex >= NSMaxRange (compRange));

	      if (RIGHT_TO_LEFT_P)
		for (i = 0; i < range.length; i++)
		  permutation[range.location + i] = NSMaxRange (range) - i - 1;

	      range = NSMakeRange (NSMaxRange (range), 0);
	    }

	  gl->comp_range.location = compRange.location;
	  gl->comp_range.length = compRange.length;

	  while (++glyphIndex < numberOfGlyphs)
	    if (![layoutManager notShownAttributeForGlyphAtIndex:glyphIndex])
	      break;
	}
      if (RIGHT_TO_LEFT_P)
	for (i = 0; i < range.length; i++)
	  permutation[range.location + i] = NSMaxRange (range) - i - 1;

      /* Then fill the remaining members.  */
      glyphIndex = prevGlyphIndex = 0;
      while ([layoutManager notShownAttributeForGlyphAtIndex:glyphIndex])
	glyphIndex++;

      if (!RIGHT_TO_LEFT_P)
	totalAdvance = 0;
      else
	{
	  NSRect glyphRect =
	    [layoutManager enclosingRectForGlyphRange:(NSMakeRange
						       (0, numberOfGlyphs))
				      inTextContainer:textContainer];

	  totalAdvance = NSMaxX (glyphRect);
	}

      for (i = 0; i < used; i++)
	{
	  struct mac_glyph_layout *gl;
	  NSPoint location;
	  NSUInteger nextGlyphIndex;
	  NSRange glyphRange;
	  NSRect glyphRect;

	  if (!RIGHT_TO_LEFT_P)
	    gl = glyph_layouts + i;
	  else
	    {
	      NSUInteger dest = permutation[i];

	      gl = glyph_layouts + dest;
	      if (i < dest)
		{
		  CFIndex tmp = gl->string_index;

		  gl->string_index = glyph_layouts[i].string_index;
		  glyph_layouts[i].string_index = tmp;
		}
	    }

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
	  gl->glyph_id = [layoutManager CGGlyphAtIndex:glyphIndex];
#else
	  gl->glyph_id = [layoutManager glyphAtIndex:glyphIndex];
#endif
	  location = [layoutManager locationForGlyphAtIndex:glyphIndex];
	  gl->baseline_delta = spaceLocation.y - location.y;

	  for (nextGlyphIndex = glyphIndex + 1; nextGlyphIndex < numberOfGlyphs;
	       nextGlyphIndex++)
	    if (![layoutManager
		   notShownAttributeForGlyphAtIndex:nextGlyphIndex])
	      break;

	  if (!RIGHT_TO_LEFT_P)
	    {
	      CGFloat maxX;

	      if (prevGlyphIndex == 0)
		glyphRange = NSMakeRange (0, nextGlyphIndex);
	      else
		glyphRange = NSMakeRange (glyphIndex,
					  nextGlyphIndex - glyphIndex);
	      glyphRect =
		[layoutManager enclosingRectForGlyphRange:glyphRange
					  inTextContainer:textContainer];
	      maxX = max (NSMaxX (glyphRect), totalAdvance);
	      gl->advance_delta = location.x - totalAdvance;
	      gl->advance = maxX - totalAdvance;
	      totalAdvance = maxX;
	    }
	  else
	    {
	      CGFloat minX;

	      if (nextGlyphIndex == numberOfGlyphs)
		glyphRange = NSMakeRange (prevGlyphIndex,
					  numberOfGlyphs - prevGlyphIndex);
	      else
		glyphRange = NSMakeRange (prevGlyphIndex,
					  glyphIndex + 1 - prevGlyphIndex);
	      glyphRect =
		[layoutManager enclosingRectForGlyphRange:glyphRange
					  inTextContainer:textContainer];
	      minX = min (NSMinX (glyphRect), totalAdvance);
	      gl->advance = totalAdvance - minX;
	      totalAdvance = minX;
	      gl->advance_delta = location.x - totalAdvance;
	    }

	  prevGlyphIndex = glyphIndex + 1;
	  glyphIndex = nextGlyphIndex;
	}

      if (RIGHT_TO_LEFT_P)
	xfree (permutation);

#undef RIGHT_TO_LEFT_P

      result = used;
    }
  MRC_RELEASE (textStorage);

  return result;
}


/************************************************************************
				Sound
 ************************************************************************/

@implementation EmacsController (Sound)

- (void)sound:(NSSound *)sound didFinishPlaying:(BOOL)finishedPlaying
{
  [NSApp postDummyEvent];
}

@end

CFTypeRef
mac_sound_create (Lisp_Object file, Lisp_Object data)
{
  NSSound *sound;

  if (STRINGP (file))
    {
      file = ENCODE_FILE (file);
      sound = [[NSSound alloc]
		initWithContentsOfFile:[NSString stringWithUTF8LispString:file]
			   byReference:YES];
    }
  else if (STRINGP (data))
    sound = [[NSSound alloc]
	      initWithData:[NSData dataWithBytes:(SDATA (data))
					  length:(SBYTES (data))]];
  else
    sound = nil;

  return CF_ESCAPING_BRIDGE (sound);
}

void
mac_sound_play (CFTypeRef mac_sound, Lisp_Object volume, Lisp_Object device)
{
  NSSound *sound = (__bridge NSSound *) mac_sound;

  if ((FIXNUMP (volume) || FLOATP (volume)))
    [sound setVolume:(FIXNUMP (volume) ? XFIXNAT (volume) * 0.01f
		      : (float) XFLOAT_DATA (volume))];
  if (STRINGP (device))
    [sound setPlaybackDeviceIdentifier:[NSString stringWithLispString:device]];

  [sound setDelegate:emacsController];
  [sound play];
  while ([sound isPlaying])
    mac_run_loop_run_once (kEventDurationForever);
}


/***********************************************************************
			Thread Synchronization
***********************************************************************/

/* Binary semaphores for synchronization between GUI and Lisp
   threads.  */
static dispatch_semaphore_t mac_gui_semaphore, mac_lisp_semaphore;

/* Queues of blocks to be executed in GUI or Lisp thread
   respectively.  */
static NSMutableArray *mac_gui_queue, *mac_lisp_queue;

/* Queues of blocks to be executed in Lisp thread at the end of the
   call to mac_within_gui_and_here.  */
static NSMutableArray *mac_deferred_lisp_queue;

/* Dispatch source to break the run loop in the GUI thread for the
   select emulation.  */
static dispatch_source_t mac_select_dispatch_source;

/* Command to execute in the GUI thread after the run loop is
   broken.  */
static enum
{
  MAC_SELECT_COMMAND_TERMINATE	= 1 << 0,
  MAC_SELECT_COMMAND_SUSPEND	= 1 << 1
} mac_select_next_command;

static void
mac_init_thread_synchronization (void)
{
  BEGIN_AUTORELEASE_POOL;

  mac_gui_semaphore = dispatch_semaphore_create (0);
  mac_lisp_semaphore = dispatch_semaphore_create (0);

  mac_gui_queue = [[NSMutableArray alloc] initWithCapacity:2];
  mac_lisp_queue = [[NSMutableArray alloc] initWithCapacity:1];
  mac_deferred_lisp_queue = [[NSMutableArray alloc] initWithCapacity:0];

  mac_select_next_command = MAC_SELECT_COMMAND_TERMINATE;
  mac_select_dispatch_source =
    dispatch_source_create (DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0,
			    dispatch_get_main_queue ());
  if (mac_select_dispatch_source == NULL)
    {
      fprintf (stderr, "Can't create dispatch source\n");
      exit (1);
    }
  dispatch_source_set_event_handler (mac_select_dispatch_source, ^{
      mac_select_next_command |=
	dispatch_source_get_data (mac_select_dispatch_source);
    });
  dispatch_resume (mac_select_dispatch_source);

  END_AUTORELEASE_POOL;
}

/* Keep synchronously executing blocks in `mac_gui_queue', which has
   been set by `mac_within_gui_and_here', in the GUI thread until the
   dequeued block is nil.  */

static void
mac_gui_loop (void)
{
  eassert (pthread_main_np ());
  void (^block) (void);

  do
    {
      BEGIN_AUTORELEASE_POOL;
      dispatch_semaphore_wait (mac_gui_semaphore, DISPATCH_TIME_FOREVER);
      block = [mac_gui_queue dequeue];
      if (block)
	block ();
      dispatch_semaphore_signal (mac_lisp_semaphore);
      END_AUTORELEASE_POOL;
    }
  while (block);
}

static void
mac_gui_loop_once (void)
{
  void (^block) (void);

  BEGIN_AUTORELEASE_POOL;
  dispatch_semaphore_wait (mac_gui_semaphore, DISPATCH_TIME_FOREVER);
  block = [mac_gui_queue dequeue];
  eassert (block);
  block ();
  dispatch_semaphore_signal (mac_lisp_semaphore);
  END_AUTORELEASE_POOL;
}

/* Ask execution of BLOCK to the GUI thread synchronously.  The
   calling thread must not be the GUI thread.  BLOCK will be executed
   in its own autorelease pool.  So if you want to bring back
   NSObjects from BLOCK via __block or global variables, make sure
   they are retained for non-ARC environments.  */

void
mac_within_gui (void (^block) (void))
{
  mac_within_gui_and_here (block, NULL);
}

/* Ask execution of BLOCK_GUI to the GUI thread.  The calling thread
   must not be the GUI thread.  If BLOCK_HERE is non-nil, then it is
   also executed in the calling Lisp thread simultaneously.  Control
   returns when the both executions has finished.  */

static void
mac_within_gui_and_here (void (^block_gui) (void),
			 void (^block_here) (void))
{
  if (mac_persistent_loop_p)
    {
      /* Only mac_select uses BLOCK_HERE, and the persistent loop
	 has its own select emulation.  */
      eassert (!block_here);
      mac_loop_within_gui (block_gui);
      return;
    }

  eassert (!pthread_main_np ());
  eassert (mac_gui_queue.count <= 1);

  [mac_gui_queue enqueue:block_gui];
  dispatch_source_merge_data (mac_select_dispatch_source,
			      MAC_SELECT_COMMAND_SUSPEND);
  dispatch_semaphore_signal (mac_gui_semaphore);
  if (block_here)
    block_here ();
  dispatch_semaphore_wait (mac_lisp_semaphore, DISPATCH_TIME_FOREVER);
  if (mac_deferred_lisp_queue.count)
    {
      NSMutableArray *queue = mac_deferred_lisp_queue;

      mac_deferred_lisp_queue = [[NSMutableArray alloc] initWithCapacity:0];
      do
	{
	  void (^block) (void) = [queue dequeue];

	  block ();
	}
      while (queue.count);
      MRC_RELEASE (queue);
      eassert (mac_deferred_lisp_queue.count == 0);
    }
}

/* Ask execution of BLOCK to the GUI thread synchronously with
   allowing block executions in the calling Lisp thread via
   `mac_within_lisp' from the BLOCK_GUI context.  The calling thread
   must not be the GUI thread.  */

static void
mac_within_gui_allowing_inner_lisp (void (^block) (void))
{
  eassert (!pthread_main_np ());
  if (mac_persistent_loop_p)
    {
      /* Every persistent-loop request services inner Lisp blocks.  */
      mac_loop_within_gui (block);
      return;
    }

  bool __block completed_p = false;

  mac_within_gui (^{
      block ();
      completed_p = true;
    });
  while (!completed_p)
    {
      void (^block_lisp) (void) = [mac_lisp_queue dequeue];

      block_lisp ();
      mac_within_gui (nil);
      dispatch_semaphore_wait (mac_lisp_semaphore, DISPATCH_TIME_FOREVER);
    }
}

/* Ask synchronous execution of BLOCK to the Lisp thread that has
   called `mac_within_gui_allowing_inner_lisp'.  This should be used
   in the context of the block argument of
   `mac_within_gui_allowing_inner_lisp'.  One can use `mac_within_gui'
   etc. in the context of BLOCK.  */

static void
mac_within_lisp (void (^block) (void))
{
  eassert (pthread_main_np ());
  if (mac_persistent_loop_p)
    {
      /* Synchronous only while the Lisp thread is parked on a
	 request; otherwise the GUI thread must not wait for Lisp, so
	 queue the block instead.  */
      if (!mac_loop_within_lisp (block))
	{
	  MAC_TRACE_LOOP ("within-lisp deferred (no parked request)\n");
	  mac_loop_queue_lisp_block (block);
	}
      return;
    }
  eassert (mac_lisp_queue.count == 0);
  eassert (block);

  [mac_lisp_queue enqueue:block];
  dispatch_semaphore_signal (mac_lisp_semaphore);
  mac_gui_loop ();
}

/* Ask deferred execution of BLOCK to the Lisp thread.  This should be
   used in the context of the block argument of `mac_within_gui' etc.
   BLOCK is called at the end of `mac_within_gui' etc. call.  One can
   use `mac_within_gui' etc. in the context of BLOCK.  */

static void
mac_within_lisp_deferred (void (^block) (void))
{
  eassert (pthread_main_np ());
  eassert (block);

  if (mac_persistent_loop_p)
    {
      if (!mac_loop_defer_to_request (block))
	mac_loop_queue_lisp_block (block);
      return;
    }

  [mac_deferred_lisp_queue enqueue:(MRC_AUTORELEASE ([block copy]))];
}

/* Ask execution of BLOCK to the Lisp thread.  Process BLOCK
   synchronously if some popup menu or dialog is in use, and otherwise
   deferred.  */

static void
mac_within_lisp_deferred_unless_popup (void (^block) (void))
{
  if (popup_activated ())
    mac_within_lisp (block);
  else
    mac_within_lisp_deferred (block);
}

/* If called from the GUI thread, ask deferred execution of BLOCK to
   the Lisp thread.  Otherwise, execute BLOCK directly.  */

void
mac_within_lisp_deferred_if_gui_thread (void (^block) (void))
{
  if (mac_gui_thread_p ())
    mac_within_lisp_deferred (block);
  else
    block ();
}


/***********************************************************************
			   Select emulation
***********************************************************************/

/* File descriptors of the socket pair used for breaking pselect calls
   in Lisp threads.  One direction, writing to mac_select_fds[0] and
   reading from mac_select_fds[1], is for notifying termination of the
   run loop in the GUI thread.  The other direction, writing to
   mac_select_fds[1] and reading from mac_select_fds[0] is for
   notifying delivery of SIGALRM.  */
static int mac_select_fds[2];

struct mac_select_latency_stats mac_select_latency_stats;

/* Whether buffer and glyph matrix access from the GUI thread is
   restricted to the case that no Lisp thread is running.  */
static bool mac_buffer_and_glyph_matrix_access_restricted_p;

static void
mac_record_select_latency (double *total, double *maximum, double start)
{
  double elapsed = mac_system_uptime () - start;

  if (elapsed < 0.0)
    elapsed = 0.0;

  *total += elapsed;
  if (*maximum < elapsed)
    *maximum = elapsed;
}

void
mac_get_select_latency_stats (struct mac_select_latency_stats *stats,
			      bool reset)
{
  *stats = mac_select_latency_stats;
  if (reset)
    memset (&mac_select_latency_stats, 0, sizeof mac_select_latency_stats);
}

static int
read_all_from_nonblocking_fd (int fd)
{
  int rtnval;
  char buf[64];

  do
    {
      rtnval = read (fd, buf, sizeof (buf));
    }
  while (rtnval > 0 || (rtnval < 0 && errno == EINTR));

  return rtnval;
}

static int
write_one_byte_to_fd (int fd)
{
  int rtnval;

  do
    {
      rtnval = write (fd, "", 1);
    }
  while (rtnval == 0 || (rtnval < 0 && errno == EINTR));

  return rtnval;
}

static void
mac_init_select_fds (void)
{
  int err, i;

  err = socketpair (AF_UNIX, SOCK_STREAM, 0, mac_select_fds);
  if (err < 0)
    {
      emacs_perror ("Can't create socketpair");
      exit (1);
    }
  for (i = 0; i < 2; i++)
    {
      int flags;

      if ((flags = fcntl (mac_select_fds[i], F_GETFL, 0)) < 0
	  || fcntl (mac_select_fds[i], F_SETFL, flags | O_NONBLOCK) == -1
	  || (flags = fcntl (mac_select_fds[i], F_GETFD, 0)) < 0
	  || fcntl (mac_select_fds[i], F_SETFD, flags | FD_CLOEXEC) == -1)
	{
	  emacs_perror ("Can't make select fds non-blocking");
	  exit (1);
	}
    }
}

int
mac_get_select_fd (void)
{
  return mac_select_fds[1];
}

void
mac_handle_alarm_signal (void)
{
  if (initialized)
    write_one_byte_to_fd (mac_select_fds[1]);
}

/* Restrict/unrestrict buffer and glyph matrix access from the GUI
   thread to the case that no Lisp thread is running.  */

static void
mac_set_buffer_and_glyph_matrix_access_restricted (bool flag)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  /* Temporarily disable autodisplay if the Lisp thread may switch to
     another one and some drawing may happen there.  */
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f)
	  && !FRAME_MAC_DOUBLE_BUFFERED_P (f))
	{
	  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

	  [window setAutodisplay:!flag];
	}
    }
#endif

  mac_buffer_and_glyph_matrix_access_restricted_p = flag;
}

static bool
mac_try_buffer_and_glyph_matrix_access (void)
{
  if (mac_persistent_loop_p && pthread_main_np ())
    {
      /* Nested accesses end in reverse order on the GUI thread.  */
      int token = mac_loop_begin_lisp_access ();

      if (token == MAC_LOOP_NO_ACCESS)
	return false;
      eassert (mac_loop_access_token_depth < countof (mac_loop_access_tokens));
      mac_loop_access_tokens[mac_loop_access_token_depth++] = token;
      return true;
    }
  if (mac_buffer_and_glyph_matrix_access_restricted_p)
    return !thread_try_acquire_global_lock ();

  return true;
}

static void
mac_end_buffer_and_glyph_matrix_access (void)
{
  if (mac_persistent_loop_p && pthread_main_np ())
    {
      eassert (mac_loop_access_token_depth > 0);
      mac_loop_end_lisp_access
	(mac_loop_access_tokens[--mac_loop_access_token_depth]);
      return;
    }
  if (mac_buffer_and_glyph_matrix_access_restricted_p)
    thread_release_global_lock ();
}

int
mac_select (int nfds, fd_set *rfds, fd_set *wfds, fd_set *efds,
	    struct timespec *timeout, sigset_t *sigmask)
{
  bool __block has_event_p, thread_may_switch_p;
  int __block r;

  if (mac_persistent_loop_p && initialized)
    return mac_loop_select (nfds, rfds, wfds, efds, timeout, sigmask);

  if (!initialized)
    return thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);

  double select_start = mac_system_uptime ();
  mac_select_latency_stats.calls++;

  read_all_from_nonblocking_fd (mac_select_fds[0]);

  if (inhibit_window_system || noninteractive || nfds <= mac_select_fds[1]
      || rfds == NULL || !FD_ISSET (mac_select_fds[1], rfds))
    {
      fd_set rfds_fallback;

      if (rfds == NULL)
	{
	  FD_ZERO (&rfds_fallback);
	  rfds = &rfds_fallback;
	}
      FD_SET (mac_select_fds[0], rfds);
      if (nfds <= mac_select_fds[0])
	nfds = mac_select_fds[0] + 1;

      r = thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);

      if (r > 0 && FD_ISSET (mac_select_fds[0], rfds))
	{
	  /* SIGALRM is delivered.  */
	  FD_CLR (mac_select_fds[0], rfds);
	  errno = EINTR;
	  r = -1;
	}

      mac_select_latency_stats.fallback_calls++;
      mac_record_select_latency (&mac_select_latency_stats.total_seconds,
				 &mac_select_latency_stats.max_seconds,
				 select_start);
      return r;
    }

  /* Check if some input is already available.  We need to block input
     because run loop may call back drawRect:.  */
  double gui_probe_start = mac_system_uptime ();
  mac_select_latency_stats.gui_probe_calls++;
  block_input ();
  mac_within_gui_and_here (^{
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			       beforeDate:[NSDate date]];
      has_event_p = (mac_peek_next_event () != NULL);
    },
    ^{
      fd_set orfds, owfds, oefds;
      struct timespec select_timeout = make_timespec (0, 0);

      orfds = *rfds;
      if (wfds) owfds = *wfds;
      if (efds) oefds = *efds;

      read_all_from_nonblocking_fd (mac_select_fds[1]);

      FD_CLR (mac_select_fds[1], rfds);
      r = pselect (nfds, rfds, wfds, efds, &select_timeout, sigmask);
      if (r == 0)
	{
	  *rfds = orfds;
	  if (wfds) *wfds = owfds;
	  if (efds) *efds = oefds;
	}
    });
  unblock_input ();
  mac_record_select_latency (&mac_select_latency_stats.gui_probe_seconds,
			     &mac_select_latency_stats.max_gui_probe_seconds,
			     gui_probe_start);

  /* unblock_input above might have read some events.  */
  if (has_event_p || detect_input_pending ())
    {
      /* Pretend that `select' is interrupted by a signal.  */
      errno = EINTR;

      mac_record_select_latency (&mac_select_latency_stats.total_seconds,
				 &mac_select_latency_stats.max_seconds,
				 select_start);
      return -1;
    }
  else if (r != 0 || (timeout && timespec_sign (*timeout) == 0))
    {
      mac_record_select_latency (&mac_select_latency_stats.total_seconds,
				 &mac_select_latency_stats.max_seconds,
				 select_start);
      return r;
    }

  double gui_wait_start = mac_system_uptime ();
  mac_select_latency_stats.gui_wait_calls++;
  block_input ();
  turn_on_atimers (false);
  thread_may_switch_p = !NILP (XCDR (Fall_threads ()));
#if MAC_SELECT_ALLOW_LISP_EVALUATION
  mac_select_allow_lisp_evaluation = !thread_may_switch_p;
  bool __block completed_p = false;
#endif
  mac_within_gui_and_here (^{
      if (thread_may_switch_p)
	mac_set_buffer_and_glyph_matrix_access_restricted (true);
      while (true)
	{
	  mac_select_next_command = 0;
	  /* On macOS 10.12, the application sometimes becomes
	     unresponsive to Dock icon clicks (though it reacts to
	     Command-Tab) if we directly run a run loop and the
	     application windows are covered by other applications for
	     a while.  */
	  mac_within_app (^{
	      NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
	      NSDate *limit = [NSDate distantFuture];
	      bool written_p = false;

	      /* On Mac OS X 10.7, delayed visible toolbar item
		 validation (see the documentation of -[NSToolbar
		 validateVisibleItems]) is treated as if it were an
		 input source firing rather than a timer function (as
		 in Mac OS X 10.6).  So it makes -[NSRunLoop
		 runMode:beforeDate:] return despite no available
		 input to process.  In such cases, we want to call
		 -[NSRunLoop runMode:beforeDate:] again so as to avoid
		 wasting CPU time caused by vacuous reactivation of
		 delayed visible toolbar item validation via window
		 update events issued in the application event
		 loop.  */
	      do
		{
		  [currentRunLoop runMode:NSDefaultRunLoopMode
			       beforeDate:limit];
		  mac_select_latency_stats.run_loop_iterations++;
		  bool useful_wakeup_p = (mac_peek_next_event () != NULL
					  || detect_input_pending ()
					  || emacs_windows_need_display_p ());
		  if (!written_p && useful_wakeup_p)
		    {
		      write_one_byte_to_fd (mac_select_fds[0]);
		      written_p = true;
		      mac_select_latency_stats.run_loop_wakeups_with_work++;
		    }
		  else if (!useful_wakeup_p && !mac_select_next_command)
		    mac_select_latency_stats.run_loop_wakeups_without_work++;
		  if ((mac_select_next_command & MAC_SELECT_COMMAND_SUSPEND)
		      && mac_gui_queue.count == 0)
		    /* Bogus suspend command: would be a residual from
		       the previous round.  */
		    mac_select_next_command &= ~MAC_SELECT_COMMAND_SUSPEND;
		}
	      while (!mac_select_next_command);
	    });
	  if (mac_select_next_command & MAC_SELECT_COMMAND_TERMINATE)
	    break;
	  else
	    mac_gui_loop_once ();
	}
      if (thread_may_switch_p)
	mac_set_buffer_and_glyph_matrix_access_restricted (false);
#if MAC_SELECT_ALLOW_LISP_EVALUATION
      mac_select_allow_lisp_evaluation = false;
      completed_p = true;
#endif
    },
    ^{
#if MAC_SELECT_ALLOW_LISP_EVALUATION
      if (thread_may_switch_p)
	{
#endif
	  r = thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);
	  dispatch_source_merge_data (mac_select_dispatch_source,
				      MAC_SELECT_COMMAND_TERMINATE);
#if MAC_SELECT_ALLOW_LISP_EVALUATION
	}
      else
	{
	  dispatch_queue_t queue =
	    dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

	  dispatch_async (queue, ^{
	      r = pselect (nfds, rfds, wfds, efds, timeout, sigmask);
	      dispatch_source_merge_data (mac_select_dispatch_source,
					  MAC_SELECT_COMMAND_TERMINATE);
	    });
	  dispatch_semaphore_wait (mac_lisp_semaphore, DISPATCH_TIME_FOREVER);
	  while (!completed_p)
	    {
	      void (^block_lisp) (void) = [mac_lisp_queue dequeue];
	      bool was_waiting_for_input = waiting_for_input;

	      waiting_for_input = 0;
	      block_lisp ();
	      waiting_for_input = was_waiting_for_input;
	      mac_within_gui (nil);
	      dispatch_semaphore_wait (mac_lisp_semaphore,
				       DISPATCH_TIME_FOREVER);
	    }
	  dispatch_semaphore_signal (mac_lisp_semaphore);
	}
#endif
      if (r > 0 && FD_ISSET (mac_select_fds[1], rfds))
	/* Pretend that `select' is interrupted by a signal.  */
	r = -1;
    });
  turn_on_atimers (true);
  unblock_input ();
  mac_record_select_latency (&mac_select_latency_stats.gui_wait_seconds,
			     &mac_select_latency_stats.max_gui_wait_seconds,
			     gui_wait_start);

  if (r < 0 || detect_input_pending ())
    {
      /* Pretend that `select' is interrupted by a signal.  */
      errno = EINTR;

      mac_record_select_latency (&mac_select_latency_stats.total_seconds,
				 &mac_select_latency_stats.max_seconds,
				 select_start);
      return -1;
    }

  mac_record_select_latency (&mac_select_latency_stats.total_seconds,
			     &mac_select_latency_stats.max_seconds,
			     select_start);
  return r;
}


/***********************************************************************
			 Persistent event loop
***********************************************************************/

/* With EMACS_MAC_PERSISTENT_LOOP=1 (or the configured default), the
   GUI thread runs -[NSApplication run] for the process lifetime
   instead of running AppKit only while Lisp waits in mac_select or
   calls read_socket.

   Lisp-to-GUI requests (mac_within_gui) are queued, delivered through
   a run-loop source in the common modes, and completed individually.
   The Lisp thread services synchronous inner-Lisp blocks from the GUI
   thread while it waits for its request.

   The GUI thread touches Lisp or redisplay state only with "Lisp
   access": either it is executing a request, so that the requesting
   Lisp thread is parked, or it holds the global Lisp lock taken by
   try-lock while Lisp waits for input.  Without access, Emacs-bound
   NSEvents are deferred in order (except the quit key, which becomes
   a queued input event), native events go to AppKit, and callbacks
   that need Lisp are queued for the Lisp thread.  */

@interface EmacsGUIRequest : NSObject
{
@public
  void (^block) (void);
  /* Blocks deferred to the Lisp thread while executing BLOCK.  */
  NSMutableArray *deferredLispBlocks;
  bool done;
}
@end

@implementation EmacsGUIRequest

- (void)dealloc
{
  MRC_RELEASE (block);
  MRC_RELEASE (deferredLispBlocks);
#if !USE_ARC
  [super dealloc];
#endif
}

@end

/* A deferred state callback (MAC_LOOP_STATE_CALLBACK_NEEDS_LISP).  */

@interface EmacsLoopStateCallback : NSObject
{
@public
  /* Compared by identity only; BLOCK retains it.  */
  __unsafe_unretained id owner;
  const char *key;
  void (^block) (void);
}
@end

@implementation EmacsLoopStateCallback

- (void)dealloc
{
  MRC_RELEASE (block);
#if !USE_ARC
  [super dealloc];
#endif
}

@end

/* Guards the three queues below.  */
static pthread_mutex_t mac_loop_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Pending Lisp-to-GUI requests (EmacsGUIRequest).  */
static NSMutableArray *mac_loop_requests;

/* Synchronous GUI-to-Lisp blocks for the parked Lisp thread.  */
static NSMutableArray *mac_loop_inner_lisp_blocks;

/* Asynchronous GUI-to-Lisp items, in order: NSData holding a struct
   input_event, or a block.  */
static NSMutableArray *mac_loop_lisp_items;

static dispatch_semaphore_t mac_loop_gui_semaphore, mac_loop_lisp_semaphore;
static CFRunLoopSourceRef mac_loop_request_source, mac_loop_retry_source;
static CFRunLoopRef mac_loop_main_run_loop;

/* GUI thread state.  */
static EmacsGUIRequest *mac_loop_current_request;
static int mac_loop_request_depth;
static bool mac_loop_gui_owns_lock;
static NSMutableArray *mac_loop_deferred_events;
static struct input_event mac_loop_gui_hold_quit;

/* The request that launched the application; completed from
   -applicationDidFinishLaunching:.  */
static EmacsGUIRequest *mac_loop_launch_request;
static bool mac_loop_launch_requested_p;

/* Shared flags.  */
static int mac_loop_deferred_count;	/* Number of deferred NSEvents.  */
static bool mac_loop_lisp_waiting_p;	/* Lisp is inside thread_select.  */
static unsigned mac_loop_wait_generation; /* Counts Lisp's input waits.  */

/* Counters for test/manual/mac-app-loop: Lisp access granted by
   try-lock, granted while a request parks Lisp, denied; deferred
   NSEvents and callbacks; queued GUI-to-Lisp items; deferred state
   callbacks replaced by a later one.  */
static unsigned long mac_loop_stats[7];
enum
  {
    MAC_LOOP_STAT_LOCKED, MAC_LOOP_STAT_BORROWED, MAC_LOOP_STAT_DENIED,
    MAC_LOOP_STAT_DEFERRED_EVENTS, MAC_LOOP_STAT_DEFERRED_CALLBACKS,
    MAC_LOOP_STAT_LISP_ITEMS, MAC_LOOP_STAT_COALESCED_CALLBACKS
  };

/* Lisp thread: hold_quit of the drain in progress, if any.  */
static struct input_event *mac_loop_lisp_hold_quit;

static void
mac_loop_lock (void)
{
  pthread_mutex_lock (&mac_loop_mutex);
}

static void
mac_loop_unlock (void)
{
  pthread_mutex_unlock (&mac_loop_mutex);
}

/* Remove and return the first element of ARRAY under the mutex, or
   nil.  The result is autoreleased.  */

static id
mac_loop_pop (NSMutableArray *array)
{
  id obj = nil;

  mac_loop_lock ();
  if (array.count)
    {
      obj = MRC_AUTORELEASE (MRC_RETAIN (array[0]));
      [array removeObjectAtIndex:0];
    }
  mac_loop_unlock ();

  return obj;
}

static void
mac_loop_push (NSMutableArray *array, id obj)
{
  mac_loop_lock ();
  [array addObject:obj];
  mac_loop_unlock ();
}

/* Wake the main run loop so that a signalled source fires.  */

static void
mac_loop_signal_source (CFRunLoopSourceRef source)
{
  if (source)
    {
      CFRunLoopSourceSignal (source);
      CFRunLoopWakeUp (mac_loop_main_run_loop);
    }
}

/* GUI thread: execute pending requests, including requests issued by
   inner Lisp blocks while an outer request waits for them.  */

static void
mac_loop_run_requests (void)
{
  eassert (pthread_main_np ());

  while (true)
    {
      EmacsGUIRequest *request = mac_loop_pop (mac_loop_requests);

      if (request == nil)
	break;

      EmacsGUIRequest *saved = mac_loop_current_request;

      mac_loop_current_request = request;
      mac_loop_request_depth++;
      BEGIN_AUTORELEASE_POOL;
      if (request->block)
	request->block ();
      END_AUTORELEASE_POOL;
      mac_loop_request_depth--;
      mac_loop_current_request = saved;

      if (request == mac_loop_launch_request)
	/* Completed by -applicationDidFinishLaunching:.  */
	continue;
      __atomic_store_n (&request->done, true, __ATOMIC_RELEASE);
      dispatch_semaphore_signal (mac_loop_lisp_semaphore);
    }
}

static void
mac_loop_request_source_perform (void *info)
{
  BEGIN_AUTORELEASE_POOL;
  mac_loop_run_requests ();
  END_AUTORELEASE_POOL;
}

/* Lisp thread: run synchronous blocks queued by the GUI thread.  */

static void
mac_loop_run_inner_lisp_blocks (void)
{
  while (true)
    {
      void (^block) (void) = mac_loop_pop (mac_loop_inner_lisp_blocks);

      if (block == nil)
	break;
      block ();
    }
}

/* Lisp thread: ask the GUI thread to execute BLOCK and wait for it,
   servicing inner Lisp blocks meanwhile.  */

static void
mac_loop_within_gui (void (^block) (void))
{
  eassert (!pthread_main_np ());

  EmacsGUIRequest *request = [[EmacsGUIRequest alloc] init];

  request->block = [block copy];
  mac_loop_push (mac_loop_requests, request);
  dispatch_semaphore_signal (mac_loop_gui_semaphore);
  mac_loop_signal_source (mac_loop_request_source);

  double start = mac_trace_loop_p ? mac_system_uptime () : 0;

  while (!__atomic_load_n (&request->done, __ATOMIC_ACQUIRE))
    {
      dispatch_semaphore_wait (mac_loop_lisp_semaphore, DISPATCH_TIME_FOREVER);
      mac_loop_run_inner_lisp_blocks ();
    }
  if (start && mac_system_uptime () - start > 0.05)
    MAC_TRACE_LOOP ("request took %.0f ms\n",
		    (mac_system_uptime () - start) * 1000);

  for (void (^deferred) (void) in request->deferredLispBlocks)
    deferred ();
  MRC_RELEASE (request);
}

/* GUI thread: run BLOCK synchronously in the Lisp thread if it is
   parked on a request.  Return false (without running BLOCK) if not.  */

static bool
mac_loop_within_lisp (void (^block) (void))
{
  eassert (pthread_main_np ());

  if (mac_loop_request_depth == 0)
    return false;

  bool __block finished = false;
  void (^wrapper) (void) = ^{
    block ();
    __atomic_store_n (&finished, true, __ATOMIC_RELEASE);
    dispatch_semaphore_signal (mac_loop_gui_semaphore);
  };

  mac_loop_push (mac_loop_inner_lisp_blocks,
		 MRC_AUTORELEASE ([wrapper copy]));
  dispatch_semaphore_signal (mac_loop_lisp_semaphore);
  while (!__atomic_load_n (&finished, __ATOMIC_ACQUIRE))
    {
      dispatch_semaphore_wait (mac_loop_gui_semaphore, DISPATCH_TIME_FOREVER);
      mac_loop_run_requests ();
    }

  return true;
}

/* GUI thread: defer BLOCK to the end of the current request, as the
   old loop does.  Return false if no request is being executed.  */

static bool
mac_loop_defer_to_request (void (^block) (void))
{
  if (mac_loop_current_request == nil)
    return false;
  if (mac_loop_current_request->deferredLispBlocks == nil)
    mac_loop_current_request->deferredLispBlocks =
      [[NSMutableArray alloc] initWithCapacity:1];
  [mac_loop_current_request->deferredLispBlocks
      addObject:MRC_AUTORELEASE ([block copy])];

  return true;
}

/* Wake the Lisp thread: from its input wait via the select fd, and
   from busy computation via pending_signals, which makes maybe_quit
   call read_socket.  */

static void
mac_loop_wake_lisp (void)
{
  pending_signals = true;
  write_one_byte_to_fd (mac_select_fds[0]);
}

static void
mac_loop_queue_lisp_block (void (^block) (void))
{
  __atomic_add_fetch (&mac_loop_stats[MAC_LOOP_STAT_LISP_ITEMS], 1,
		      __ATOMIC_RELAXED);
  mac_loop_push (mac_loop_lisp_items, MRC_AUTORELEASE ([block copy]));
  mac_loop_wake_lisp ();
}

static void
mac_loop_queue_input_event (const struct input_event *event)
{
  __atomic_add_fetch (&mac_loop_stats[MAC_LOOP_STAT_LISP_ITEMS], 1,
		      __ATOMIC_RELAXED);
  mac_loop_push (mac_loop_lisp_items,
		 [NSData dataWithBytes:event length:(sizeof *event)]);
  mac_loop_wake_lisp ();
}

static bool
mac_loop_lisp_items_pending_p (void)
{
  bool result;

  mac_loop_lock ();
  result = mac_loop_lisp_items.count != 0;
  mac_loop_unlock ();

  return result;
}

/* Lisp thread: return true if the frame of EVENT, if any, is live.
   Frames are compared by identity so that a frame deleted after the
   event was queued is not dereferenced.  */

static bool
mac_loop_event_target_live_p (const struct input_event *event)
{
  Lisp_Object target = event->frame_or_window, tail, frame;

  if (NILP (target) || WINDOWP (target))
    return true;
  FOR_EACH_FRAME (tail, frame)
    if (EQ (frame, target))
      return true;

  return false;
}

/* Lisp thread, holding the global lock: move queued GUI-to-Lisp items
   into the keyboard buffer or run them.  Return the number of stored
   events.  */

static int
mac_loop_drain_lisp_items (struct input_event *hold_quit)
{
  int count = 0;
  struct input_event *saved = mac_loop_lisp_hold_quit;

  eassert (!pthread_main_np ());
  mac_loop_lisp_hold_quit = hold_quit;
  for (bool more = true; more; )
    {
      BEGIN_AUTORELEASE_POOL;
      id item = mac_loop_pop (mac_loop_lisp_items);

      if (item == nil)
	more = false;
      else if ([item isKindOfClass:NSData.class])
	{
	  struct input_event event;

	  memcpy (&event, [item bytes], sizeof event);
	  if (mac_loop_event_target_live_p (&event))
	    {
	      kbd_buffer_store_event_hold (&event, hold_quit);
	      count++;
	    }
	  else
	    MAC_TRACE_LOOP ("dropped event for deleted frame\n");
	}
      else
	((void (^) (void)) item) ();
      END_AUTORELEASE_POOL;
    }
  mac_loop_lisp_hold_quit = saved;

  return count;
}

/* Take the global Lisp lock from the GUI thread.  Wait at most 50 ms,
   and only while Lisp is waiting for input: it then releases the lock
   within the wait and must not be kept from redisplay for long.  */

static bool
mac_loop_try_global_lock (void)
{
  /* Another Lisp thread may hold the lock while the waiting one is in
     its input wait.  After one spin fails, do not spin again until
     Lisp starts another input wait.  */
  static unsigned failed_generation = -1;
  unsigned generation = __atomic_load_n (&mac_loop_wait_generation,
					 __ATOMIC_ACQUIRE);
  double start = 0;

  while (true)
    {
      if (thread_try_acquire_global_lock () == 0)
	return true;
      if (!__atomic_load_n (&mac_loop_lisp_waiting_p, __ATOMIC_ACQUIRE)
	  || generation == failed_generation)
	return false;
      double now = mac_system_uptime ();
      if (start == 0)
	start = now;
      else if (now - start > 0.05)
	{
	  failed_generation = generation;
	  return false;
	}
      usleep (200);
    }
}

/* Begin Lisp access from the GUI thread.  Return a token for
   mac_loop_end_lisp_access, or MAC_LOOP_NO_ACCESS.  Under the old
   loop the GUI thread runs only while Lisp is parked, so access is
   always granted.  */

static int
mac_loop_begin_lisp_access (void)
{
  if (!mac_persistent_loop_p || !pthread_main_np ())
    return MAC_LOOP_BORROWED_ACCESS;
  if (mac_loop_request_depth > 0 || mac_loop_gui_owns_lock)
    {
      mac_loop_stats[MAC_LOOP_STAT_BORROWED]++;
      return MAC_LOOP_BORROWED_ACCESS;
    }
  if (!mac_loop_try_global_lock ())
    {
      mac_loop_stats[MAC_LOOP_STAT_DENIED]++;
      return MAC_LOOP_NO_ACCESS;
    }
  mac_loop_gui_owns_lock = true;
  mac_loop_stats[MAC_LOOP_STAT_LOCKED]++;

  return MAC_LOOP_LOCKED_ACCESS;
}

static void
mac_loop_end_lisp_access (int token)
{
  if (token == MAC_LOOP_LOCKED_ACCESS)
    {
      eassert (mac_loop_gui_owns_lock);
      mac_loop_gui_owns_lock = false;
      thread_release_global_lock ();
    }
}

static bool
mac_loop_gui_has_lisp_access (void)
{
  return (!mac_persistent_loop_p || !pthread_main_np ()
	  || mac_loop_request_depth > 0 || mac_loop_gui_owns_lock);
}

/* Run BLOCK with Lisp access on the GUI thread if possible, and
   otherwise queue it for the Lisp thread.  */

static void
mac_loop_with_lisp_access_or_defer (void (^block) (void))
{
  int token = mac_loop_begin_lisp_access ();

  if (token == MAC_LOOP_NO_ACCESS)
    {
      MAC_TRACE_LOOP ("callback deferred to Lisp thread\n");
      mac_loop_queue_lisp_block (block);
      return;
    }
  block ();
  mac_loop_end_lisp_access (token);
  if (token == MAC_LOOP_LOCKED_ACCESS)
    mac_loop_wake_lisp ();
}

/* GUI thread: pass a quit request held while handling events to the
   Lisp thread, which quits at its next read_socket.  */

static void
mac_loop_forward_gui_hold_quit (void)
{
  if (mac_loop_gui_hold_quit.kind != NO_EVENT)
    {
      MAC_TRACE_LOOP ("quit forwarded to Lisp thread\n");
      mac_loop_queue_input_event (&mac_loop_gui_hold_quit);
      EVENT_INIT (mac_loop_gui_hold_quit);
    }
}

/* Return true if EVENT is handled by Emacs views rather than by
   AppKit-owned window chrome.  */

static bool
mac_loop_event_emacs_bound_p (NSEvent *event)
{
  switch (event.type)
    {
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged:
      return true;

    case NSEventTypeLeftMouseDown:
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown:
    case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown:
    case NSEventTypeOtherMouseUp:
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged:
    case NSEventTypeMouseMoved:
    case NSEventTypeMouseEntered:
    case NSEventTypeMouseExited:
    case NSEventTypeCursorUpdate:
    case NSEventTypeScrollWheel:
    case NSEventTypeMagnify:
    case NSEventTypeSwipe:
    case NSEventTypeRotate:
    case NSEventTypeBeginGesture:
    case NSEventTypeEndGesture:
    case NSEventTypeSmartMagnify:
    case NSEventTypePressure:
    case NSEventTypeTabletPoint:
    case NSEventTypeTabletProximity:
      {
	NSWindow *window = event.window;
	NSView *contentView = window.contentView;

	if (![window isKindOfClass:EmacsWindow.class] || contentView == nil)
	  return false;

	/* Hit-test from the frame view so that titlebar controls and
	   resize edges over a full-size content view are recognized
	   as window chrome.  */
	NSView *frameView = contentView.superview;
	NSView *hitView;

	if (frameView)
	  hitView = [frameView hitTest:[frameView.superview
					  convertPoint:event.locationInWindow
					      fromView:nil]];
	else
	  hitView = [contentView hitTest:event.locationInWindow];

	return hitView && [hitView isDescendantOf:contentView];
      }

    default:
      return false;
    }
}

/* GUI thread, with Lisp access: handle the deferred NSEvents and then
   EVENT (if non-nil) as the old loop's read_socket would.  Return the
   number of stored events.  */

static int
mac_loop_handle_events_with_access (NSEvent *event)
{
  int count = 0;

  /* The FIFO holds NSEvents and callback blocks.  */

  mac_loop_dispatch_depth++;
  while (mac_loop_deferred_events.count)
    {
      id deferred = MRC_AUTORELEASE (MRC_RETAIN
				     (mac_loop_deferred_events[0]));

      [mac_loop_deferred_events removeObjectAtIndex:0];
      __atomic_store_n (&mac_loop_deferred_count,
			mac_loop_deferred_events.count, __ATOMIC_RELEASE);
      if ([deferred isKindOfClass:NSEvent.class])
	count += [emacsController handleNSEventWithHoldingQuitIn:NULL
							   event:deferred];
      else if ([deferred isKindOfClass:EmacsLoopStateCallback.class])
	((EmacsLoopStateCallback *) deferred)->block ();
      else
	/* A callback that needed Lisp access.  */
	((void (^) (void)) deferred) ();
    }
  if (event)
    count += [emacsController handleNSEventWithHoldingQuitIn:NULL
						       event:event];
  mac_loop_dispatch_depth--;

  return count;
}

/* GUI thread: -[EmacsApplication sendEvent:] under the persistent
   loop.  */

static void
mac_loop_send_event (NSEvent *event)
{
  bool record_p = (mac_loop_test_recording_p
		   && event.type != NSEventTypeAppKitDefined
		   && event.type != NSEventTypeSystemDefined);

  if (!mac_loop_event_emacs_bound_p (event))
    {
      [(EmacsApplication *) NSApp sendEventToAppKit:event];
      mac_loop_forward_gui_hold_quit ();
      return;
    }

  int token = mac_loop_begin_lisp_access ();

  if (record_p)
    mac_loop_test_record ("dispatch %ld access %d", (long) event.type, token);
  if (token == MAC_LOOP_NO_ACCESS)
    {
      if (event.type == NSEventTypeKeyDown
	  && mac_keydown_cgevent_quit_p (event.coreGraphicsEvent))
	{
	  struct input_event inev;

	  EVENT_INIT (inev);
	  inev.arg = Qnil;
	  inev.frame_or_window = mac_event_frame ();
	  mac_cgevent_to_input_event (event.coreGraphicsEvent, &inev);
	  MAC_TRACE_LOOP ("quit key while Lisp is busy\n");
	  mac_loop_queue_input_event (&inev);
	  return;
	}

      id last = mac_loop_deferred_events.lastObject;

      if ([last isKindOfClass:NSEvent.class]
	  && ((NSEvent *) last).type == NSEventTypeMouseMoved
	  && event.type == NSEventTypeMouseMoved)
	[mac_loop_deferred_events removeLastObject];
      [mac_loop_deferred_events addObject:event];
      mac_loop_stats[MAC_LOOP_STAT_DEFERRED_EVENTS]++;
      __atomic_store_n (&mac_loop_deferred_count,
			mac_loop_deferred_events.count, __ATOMIC_RELEASE);
      MAC_TRACE_LOOP ("deferred event type %ld (%lu pending)\n",
		      (long) event.type,
		      (unsigned long) mac_loop_deferred_events.count);
      /* Let a busy Lisp thread dispatch them from read_socket.  */
      mac_loop_wake_lisp ();
      return;
    }

  int count = mac_loop_handle_events_with_access (event);

  mac_loop_end_lisp_access (token);
  mac_loop_forward_gui_hold_quit ();
  if (count > 0 && token == MAC_LOOP_LOCKED_ACCESS)
    mac_loop_wake_lisp ();
}

/* GUI thread: run BLOCK now if Lisp access is available, after the
   deferred items; otherwise append it to the deferred FIFO so that it
   runs, in order, the next time the GUI thread has access.  */

static void
mac_loop_with_access_now_or_later_coalesced (id owner, const char *key,
					     void (^block) (void))
{
  int token = mac_loop_begin_lisp_access ();

  if (token == MAC_LOOP_NO_ACCESS)
    {
      if (key)
	{
	  /* Drop the pending callback of the same kind and append this
	     one, so that Lisp learns the latest state after the events
	     that preceded it.  */
	  NSUInteger i = [mac_loop_deferred_events
			   indexOfObjectPassingTest:^BOOL (id obj,
							   NSUInteger idx,
							   BOOL *stop) {
			      EmacsLoopStateCallback *callback = obj;

			      return ([obj isKindOfClass:
					     EmacsLoopStateCallback.class]
				      && callback->owner == owner
				      && strcmp (callback->key, key) == 0);
			    }];

	  if (i != NSNotFound)
	    {
	      [mac_loop_deferred_events removeObjectAtIndex:i];
	      mac_loop_stats[MAC_LOOP_STAT_COALESCED_CALLBACKS]++;
	    }

	  EmacsLoopStateCallback *callback =
	    [[EmacsLoopStateCallback alloc] init];

	  callback->owner = owner;
	  callback->key = key;
	  callback->block = [block copy];
	  [mac_loop_deferred_events addObject:callback];
	  MRC_RELEASE (callback);
	}
      else
	[mac_loop_deferred_events addObject:MRC_AUTORELEASE ([block copy])];
      mac_loop_stats[MAC_LOOP_STAT_DEFERRED_CALLBACKS]++;
      __atomic_store_n (&mac_loop_deferred_count,
			mac_loop_deferred_events.count, __ATOMIC_RELEASE);
      MAC_TRACE_LOOP ("callback deferred (%lu pending, lisp %s)\n",
		      (unsigned long) mac_loop_deferred_events.count,
		      (__atomic_load_n (&mac_loop_lisp_waiting_p,
					__ATOMIC_ACQUIRE)
		       ? "waiting" : "running"));
      mac_loop_wake_lisp ();
      if (__atomic_load_n (&mac_loop_lisp_waiting_p, __ATOMIC_ACQUIRE))
	mac_loop_signal_source (mac_loop_retry_source);
      return;
    }

  if (mac_loop_deferred_events.count)
    mac_loop_handle_events_with_access (nil);
  block ();
  mac_loop_end_lisp_access (token);
  mac_loop_forward_gui_hold_quit ();
  if (token == MAC_LOOP_LOCKED_ACCESS)
    mac_loop_wake_lisp ();
}

static void
mac_loop_with_access_now_or_later (void (^block) (void))
{
  mac_loop_with_access_now_or_later_coalesced (nil, NULL, block);
}

/* GUI thread: retry deferred events when Lisp reaches its input wait.  */

static void
mac_loop_retry_source_perform (void *info)
{
  if (mac_loop_deferred_events.count == 0)
    return;

  int token = mac_loop_begin_lisp_access ();

  MAC_TRACE_LOOP ("retry %lu deferred: %s (mode %s)\n",
		  (unsigned long) mac_loop_deferred_events.count,
		  token == MAC_LOOP_NO_ACCESS ? "denied" : "granted",
		  [[NSRunLoop currentRunLoop].currentMode UTF8String]);
  if (token == MAC_LOOP_NO_ACCESS)
    return;

  int count;

  BEGIN_AUTORELEASE_POOL;
  count = mac_loop_handle_events_with_access (nil);
  END_AUTORELEASE_POOL;

  mac_loop_end_lisp_access (token);
  mac_loop_forward_gui_hold_quit ();
  if (count > 0 && token == MAC_LOOP_LOCKED_ACCESS)
    mac_loop_wake_lisp ();
}

/* Lisp thread (read_socket): dispatch deferred NSEvents on the GUI
   thread while this thread is parked, then drain queued items.  */

static int
mac_loop_read_socket_events (struct input_event *hold_quit)
{
  int __block count = 0;

  if (__atomic_load_n (&mac_loop_deferred_count, __ATOMIC_ACQUIRE))
    mac_within_gui (^{
	[emacsController setHoldQuit:hold_quit];
	count = mac_loop_handle_events_with_access (nil);
	[emacsController setHoldQuit:NULL];
      });
  count += mac_loop_drain_lisp_items (hold_quit);

  return count;
}

/* GUI thread: complete the launch request once the application has
   finished launching.  The GUI thread then stays in -[NSApp run].  */

static void
mac_loop_complete_launch (void)
{
  EmacsGUIRequest *request = mac_loop_launch_request;

  if (request == nil)
    return;
  mac_loop_launch_request = nil;
  mac_loop_request_depth--;
  mac_loop_current_request = nil;
  __atomic_store_n (&request->done, true, __ATOMIC_RELEASE);
  dispatch_semaphore_signal (mac_loop_lisp_semaphore);
  MRC_RELEASE (request);
}

/* GUI thread, inside the install_application_handler request: keep
   the request open until launching finishes, and leave the pre-launch
   loop so that `main' can run the application.  */

static void
mac_loop_begin_launch (void)
{
  mac_loop_launch_request = MRC_RETAIN (mac_loop_current_request);
  mac_loop_launch_requested_p = true;
}

/* GUI thread: window(s) that currently show the W8 Quit indicator, so
   it can be cleared without re-deriving the target set.  */
static NSMutableArray *mac_loop_quit_indicator_controllers;
static bool mac_loop_quit_pending;
static unsigned long mac_loop_quit_generation;

/* W8: at most one pending Quit.  Return true if this is the first
   pending Quit request, so the caller should proceed to dispatch
   kAEQuitApplication; false if one is already pending, so the caller
   should drop this request.  */

static bool
mac_loop_quit_begin (void)
{
  eassert (pthread_main_np ());

  if (mac_loop_quit_pending)
    return false;

  mac_loop_quit_pending = true;
  __atomic_add_fetch (&mac_loop_pending_indicator_count, 1, __ATOMIC_RELEASE);

  unsigned long generation = ++mac_loop_quit_generation;

  dispatch_after (dispatch_time (DISPATCH_TIME_NOW,
				 (int64_t) (0.1 * NSEC_PER_SEC)),
		  dispatch_get_main_queue (), ^{
      if (!mac_loop_quit_pending || mac_loop_quit_generation != generation)
	return;

      NSMutableArray *targets = [NSMutableArray arrayWithCapacity:1];
      NSWindow *keyWindow = NSApp.keyWindow;

      if ([keyWindow isKindOfClass:EmacsWindow.class])
	[targets addObject:keyWindow];
      else
	for (NSWindow *window in NSApp.windows)
	  if ([window isKindOfClass:EmacsWindow.class] && window.isVisible)
	    [targets addObject:window];

      if (mac_loop_quit_indicator_controllers == nil)
	mac_loop_quit_indicator_controllers =
	  [[NSMutableArray alloc] initWithCapacity:targets.count];
      for (EmacsWindow *window in targets)
	{
	  EmacsFrameController *controller =
	    (EmacsFrameController *) window.delegate;

	  if ([controller isKindOfClass:EmacsFrameController.class])
	    {
	      [controller macLoopShowQuitIndicator];
	      [mac_loop_quit_indicator_controllers addObject:controller];
	    }
	}
    });

  return true;
}

/* Clear W8 Quit-pending state and any indicator it applied.  Called
   once Lisp has resolved the Quit request: a prompt is up, it was
   cancelled, or (moot, since the process is exiting) it proceeded.  */

static void
mac_loop_quit_clear (void)
{
  eassert (pthread_main_np ());

  if (!mac_loop_quit_pending)
    return;

  mac_loop_quit_pending = false;
  mac_loop_quit_generation++;
  __atomic_sub_fetch (&mac_loop_pending_indicator_count, 1, __ATOMIC_RELEASE);
  for (EmacsFrameController *controller in mac_loop_quit_indicator_controllers)
    [controller macLoopClearQuitIndicator];
  [mac_loop_quit_indicator_controllers removeAllObjects];
}

/* GUI thread, with Lisp access: resolve W7/W8 pending indicators for
   all frames and for Quit.  Called from mac_loop_select once Lisp
   reaches its next input wait after a close or Quit was requested: a
   minibuffer prompt or the frame's own deletion (see -closeWindow)
   counts as acknowledgment (W7/W8).  */

static void
mac_loop_resolve_pending_indicators (void)
{
  Lisp_Object tail, frame;

  eassert (pthread_main_np ());
  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f))
	{
	  EmacsFrameController *controller = FRAME_CONTROLLER (f);

	  [controller macLoopClearClosePending];
	}
    }
  mac_loop_quit_clear ();
}

/* Menu-bar item selection under the persistent loop.  Menu tracking
   is not intercepted, so deliver the classic selection through the
   Lisp thread.  */

static void
mac_loop_note_menu_selection (NSInteger tag)
{
  mac_loop_with_lisp_access_or_defer (^{
      struct frame *f = SELECTED_FRAME ();

      if (FRAME_LIVE_P (f) && FRAME_MAC_P (f)
	  && 0 < tag && tag < f->menu_bar_items_used
	  && VECTORP (f->menu_bar_vector)
	  && f->menu_bar_items_used <= ASIZE (f->menu_bar_vector))
	find_and_call_menu_selection (f, f->menu_bar_items_used,
				      f->menu_bar_vector,
				      (void *) (intptr_t) tag);
      else
	MAC_TRACE_LOOP ("stale menu selection %ld dropped\n", (long) tag);
    });
}

/* Lisp thread: select emulation under the persistent loop.  The wait
   goes through thread_select so that the global lock is released,
   which is what lets the GUI thread take Lisp access at safe points.  */

static int
mac_loop_select (int nfds, fd_set *rfds, fd_set *wfds, fd_set *efds,
		 struct timespec *timeout, sigset_t *sigmask)
{
  fd_set rfds_fallback;
  bool keyboard_p = (rfds && nfds > mac_select_fds[1]
		     && FD_ISSET (mac_select_fds[1], rfds));
  int r;

  /* W7/W8: Lisp is about to wait for input, i.e., it is idle, so any
     close or Quit request it has not yet handled is now either
     resolved (frame deleted -- cleared already by -closeWindow -- or
     the request was refused) or has a prompt up (also treated as
     resolved).  */
  if (__atomic_load_n (&mac_loop_pending_indicator_count, __ATOMIC_ACQUIRE))
    mac_within_gui (^{
	mac_loop_resolve_pending_indicators ();
      });

  read_all_from_nonblocking_fd (mac_select_fds[0]);
  if (mac_trace_loop_p && getenv ("EMACS_MAC_TRACE_LOOP")[0] == '2')
    MAC_TRACE_LOOP ("select keyboard=%d deferred=%d\n", keyboard_p,
		    __atomic_load_n (&mac_loop_deferred_count,
				     __ATOMIC_ACQUIRE));
  if (keyboard_p)
    {
      read_all_from_nonblocking_fd (mac_select_fds[1]);
      if (mac_loop_lisp_items_pending_p ()
	  || __atomic_load_n (&mac_loop_deferred_count, __ATOMIC_ACQUIRE))
	{
	  /* read_socket, reached through detect_input_pending, takes
	     the items and deferred events.  */
	  if (__atomic_load_n (&mac_loop_deferred_count, __ATOMIC_ACQUIRE)
	      && !mac_loop_lisp_items_pending_p ())
	    /* Only deferred NSEvents: let the GUI take them at the
	       wait below instead of a round trip.  */
	    ;
	  else
	    {
	      errno = EINTR;
	      return -1;
	    }
	}
    }

  if (rfds == NULL)
    {
      FD_ZERO (&rfds_fallback);
      rfds = &rfds_fallback;
    }
  FD_SET (mac_select_fds[0], rfds);
  if (nfds <= mac_select_fds[0])
    nfds = mac_select_fds[0] + 1;

  __atomic_add_fetch (&mac_loop_wait_generation, 1, __ATOMIC_RELEASE);
  __atomic_store_n (&mac_loop_lisp_waiting_p, true, __ATOMIC_RELEASE);
  if (__atomic_load_n (&mac_loop_deferred_count, __ATOMIC_ACQUIRE))
    {
      MAC_TRACE_LOOP ("select: signal retry (%d deferred)\n",
		      __atomic_load_n (&mac_loop_deferred_count,
				       __ATOMIC_ACQUIRE));
      mac_loop_signal_source (mac_loop_retry_source);
    }
  r = thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);
  __atomic_store_n (&mac_loop_lisp_waiting_p, false, __ATOMIC_RELEASE);
  if (mac_trace_loop_p && getenv ("EMACS_MAC_TRACE_LOOP")[0] == '2')
    MAC_TRACE_LOOP ("select returned %d\n", r);

  if (r > 0 && FD_ISSET (mac_select_fds[0], rfds))
    {
      /* SIGALRM is delivered.  */
      read_all_from_nonblocking_fd (mac_select_fds[0]);
      errno = EINTR;
      return -1;
    }
  if (r > 0 && keyboard_p && FD_ISSET (mac_select_fds[1], rfds))
    {
      /* The GUI thread stored events or queued items.  */
      read_all_from_nonblocking_fd (mac_select_fds[1]);
      errno = EINTR;
      return -1;
    }

  return r;
}

/* GUI thread entry point under the persistent loop.  Execute requests
   until Lisp asks for the application, then run it for the process
   lifetime.  Daemon, -nw and batch sessions never leave the first
   loop.  */

static void
mac_loop_gui_main (void)
{
  mac_loop_main_run_loop = CFRunLoopGetCurrent ();

  CFRunLoopSourceContext context = {0};

  context.perform = mac_loop_request_source_perform;
  mac_loop_request_source = CFRunLoopSourceCreate (NULL, 0, &context);
  context.perform = mac_loop_retry_source_perform;
  mac_loop_retry_source = CFRunLoopSourceCreate (NULL, 1, &context);
  CFRunLoopAddSource (mac_loop_main_run_loop, mac_loop_request_source,
		      kCFRunLoopCommonModes);
  CFRunLoopAddSource (mac_loop_main_run_loop, mac_loop_retry_source,
		      kCFRunLoopDefaultMode);

  while (!mac_loop_launch_requested_p)
    {
      BEGIN_AUTORELEASE_POOL;
      dispatch_semaphore_wait (mac_loop_gui_semaphore, DISPATCH_TIME_FOREVER);
      mac_loop_run_requests ();
      END_AUTORELEASE_POOL;
    }

  /* The launch request stays open, so the GUI thread keeps borrowed
     Lisp access until -applicationDidFinishLaunching:.  */
  mac_loop_current_request = mac_loop_launch_request;
  mac_loop_request_depth++;
  MAC_TRACE_LOOP ("entering persistent NSApplication run\n");
  while (true)
    {
      BEGIN_AUTORELEASE_POOL;
      [NSApp run];
      END_AUTORELEASE_POOL;
      MAC_TRACE_LOOP ("NSApplication run returned; resuming\n");
    }
}

/* Diagnostics: with EMACS_MAC_TRACE_LOOP set, SIGINFO (kill -INFO)
   makes the GUI thread and the Lisp main thread print backtraces to
   stderr.  Debugging aid for hangs; lldb and sample may be
   unavailable.  */

static pthread_t mac_loop_gui_thread_id;
static pthread_t mac_lisp_main_thread_id;

static void
mac_loop_siginfo_handler (int sig)
{
  static volatile sig_atomic_t forwarding;
  void *frames[64];
  int n = backtrace (frames, 64);
  char header[64];
  pthread_t self = pthread_self ();
  int len = snprintf (header, sizeof header, "mac-loop: backtrace of %s\n",
		      (pthread_equal (self, mac_loop_gui_thread_id) ? "GUI"
		       : pthread_equal (self, mac_lisp_main_thread_id)
		       ? "Lisp main" : "other"));

  write (STDERR_FILENO, header, len);
  backtrace_symbols_fd (frames, n, STDERR_FILENO);
  if (!forwarding)
    {
      forwarding = 1;
      if (!pthread_equal (self, mac_loop_gui_thread_id))
	pthread_kill (mac_loop_gui_thread_id, SIGINFO);
      if (!pthread_equal (self, mac_lisp_main_thread_id))
	pthread_kill (mac_lisp_main_thread_id, SIGINFO);
    }
}

static void
mac_loop_init (void)
{
  if (mac_trace_loop_p)
    {
      mac_loop_gui_thread_id = pthread_self ();
      signal (SIGINFO, mac_loop_siginfo_handler);
    }
  mac_loop_requests = [[NSMutableArray alloc] initWithCapacity:2];
  mac_loop_inner_lisp_blocks = [[NSMutableArray alloc] initWithCapacity:1];
  mac_loop_lisp_items = [[NSMutableArray alloc] initWithCapacity:8];
  mac_loop_deferred_events = [[NSMutableArray alloc] initWithCapacity:8];
  mac_loop_gui_semaphore = dispatch_semaphore_create (0);
  mac_loop_lisp_semaphore = dispatch_semaphore_create (0);
  EVENT_INIT (mac_loop_gui_hold_quit);
}

/* Decide the event loop for this process.  EMACS_MAC_PERSISTENT_LOOP
   overrides the configured default in either direction.  */

static void
mac_loop_select_mode (void)
{
  const char *value = getenv ("EMACS_MAC_PERSISTENT_LOOP");

#ifdef MAC_PERSISTENT_LOOP_DEFAULT
  mac_persistent_loop_p = true;
#else
  mac_persistent_loop_p = false;
#endif
  if (value && *value)
    mac_persistent_loop_p = strcmp (value, "0") != 0;
  mac_trace_loop_p = getenv ("EMACS_MAC_TRACE_LOOP") != NULL;
  MAC_TRACE_LOOP ("%s event loop selected\n",
		  mac_persistent_loop_p ? "persistent" : "legacy");
}

/* Return the serial number of F's latest fullscreen parameter event
   under the persistent loop.  */

EMACS_INT
mac_frame_fullscreen_serial (struct frame *f)
{
  __block EMACS_INT serial = 0;

  mac_within_gui (^{
      serial = [FRAME_CONTROLLER (f) fullscreenParameterSerial];
    });

  return serial;
}

/* Give the installed menu-bar root generation NEW if it still carries
   OLD, so later selections bind to the snapshot of the current
   selected window and buffer (see mac_refresh_menu_bar_snapshot).  */

void
mac_restamp_menu_bar_generation (unsigned long old, unsigned long new)
{
  mac_within_gui (^{
      NSMenu *mainMenu = NSApp.mainMenu;

      if ([mainMenu isKindOfClass:EmacsMenu.class]
	  && [(EmacsMenu *) mainMenu persistentMenuGeneration] == old)
	[(EmacsMenu *) mainMenu setPersistentMenuGeneration:new];
    });
}

/* Lisp-visible predicate (mac-persistent-event-loop-p in macterm.c)
   and C callers outside this file (macmenu.c) that need to know which
   loop is active without a raw extern of the static flag above.  */

bool
mac_persistent_event_loop_active (void)
{
  return mac_persistent_loop_p;
}

/* Test support for the persistent loop (test/manual/mac-app-loop).
   Actions are scheduled on the GUI thread's main dispatch queue, which
   is serviced in the common run-loop modes, so they fire while Lisp is
   busy and during native tracking.  Posted NSEvents take the normal
   -[NSApplication sendEvent:] path.  A GUI-thread heartbeat measures
   the longest gap in main-thread service.  */


#define MAC_LOOP_TEST_MAX_RECORDS 4096

static struct
{
  double time;
  char label[64];
} mac_loop_test_records[MAC_LOOP_TEST_MAX_RECORDS];
static int mac_loop_test_nrecords;
static bool mac_loop_test_recording_p;
static double mac_loop_test_last_beat, mac_loop_test_max_gap;
static int mac_loop_test_long_gaps;
static dispatch_source_t mac_loop_test_heartbeat;

/* GUI thread.  */

static void
mac_loop_test_record (const char *format, ...)
{
  if (!mac_loop_test_recording_p
      || mac_loop_test_nrecords >= MAC_LOOP_TEST_MAX_RECORDS)
    return;

  va_list ap;
  int i = mac_loop_test_nrecords++;

  mac_loop_test_records[i].time = mac_system_uptime ();
  va_start (ap, format);
  vsnprintf (mac_loop_test_records[i].label,
	     sizeof mac_loop_test_records[i].label, format, ap);
  va_end (ap);
}

static void
mac_loop_test_start_heartbeat (void)
{
  if (mac_loop_test_heartbeat)
    return;
  mac_loop_test_heartbeat =
    dispatch_source_create (DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
			    dispatch_get_main_queue ());
  dispatch_source_set_timer (mac_loop_test_heartbeat, DISPATCH_TIME_NOW,
			     5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
  dispatch_source_set_event_handler (mac_loop_test_heartbeat, ^{
      double now = mac_system_uptime ();

      if (mac_loop_test_last_beat)
	{
	  double gap = now - mac_loop_test_last_beat;

	  if (gap > mac_loop_test_max_gap)
	    mac_loop_test_max_gap = gap;
	  if (gap > 0.1)
	    {
	      mac_loop_test_long_gaps++;
	      mac_loop_test_record ("gap %.0f ms", gap * 1000);
	    }
	}
      mac_loop_test_last_beat = now;
    });
  dispatch_resume (mac_loop_test_heartbeat);
}

static void
mac_loop_test_perform (struct mac_loop_test_action action,
		       EmacsWindow *window)
{
  NSRect frame = window.frame;
  NSPoint location = NSMakePoint (action.x, NSHeight (frame) - action.y);
  NSEventType type = NSEventTypeLeftMouseDown;
  NSEvent *event = nil;
  const char *name = "?";

  switch (action.kind)
    {
    case MAC_LOOP_TEST_KEY:
      {
	/* ACTION.character is the unmodified character; Control
	   yields the control character, as a keyboard would.  */
	UniChar base = action.character, modified = base;

	if ((action.modifiers & NSEventModifierFlagControl)
	    && base >= '@' && base < 0x80)
	  modified = base & 0x1f;

	NSString *chars = [NSString stringWithCharacters:&modified length:1];
	NSString *ignoring = [NSString stringWithCharacters:&base length:1];

	for (int i = 0; i < 2; i++)
	  {
	    event = [NSEvent keyEventWithType:(i == 0 ? NSEventTypeKeyDown
					       : NSEventTypeKeyUp)
				     location:NSZeroPoint
				modifierFlags:action.modifiers
				    timestamp:[[NSProcessInfo processInfo]
						systemUptime]
				 windowNumber:window.windowNumber
				      context:nil
				   characters:chars
		  charactersIgnoringModifiers:ignoring
				    isARepeat:NO
				      keyCode:action.key_code];
	    [NSApp postEvent:event atStart:NO];
	  }
	mac_loop_test_record ("post key %d", action.key_code);
	return;
      }

    case MAC_LOOP_TEST_MOUSE_UP:
      type = NSEventTypeLeftMouseUp;
      name = "up";
      break;
    case MAC_LOOP_TEST_MOUSE_DRAG:
      type = NSEventTypeLeftMouseDragged;
      name = "drag";
      break;
    case MAC_LOOP_TEST_MOUSE_DOWN:
      name = "down";
      break;

    case MAC_LOOP_TEST_MINIATURIZE:
      [window miniaturize:nil];
      mac_loop_test_record ("miniaturize");
      return;
    case MAC_LOOP_TEST_DEMINIATURIZE:
      [window deminiaturize:nil];
      mac_loop_test_record ("deminiaturize");
      return;
    case MAC_LOOP_TEST_ZOOM:
      [window zoom:nil];
      mac_loop_test_record ("zoom");
      return;
    case MAC_LOOP_TEST_FULLSCREEN:
      [window toggleFullScreen:nil];
      mac_loop_test_record ("fullscreen");
      return;
    case MAC_LOOP_TEST_CLOSE:
      [window performClose:nil];
      mac_loop_test_record ("close");
      return;
    case MAC_LOOP_TEST_ACTIVATE:
      [NSApp activateIgnoringOtherApps:YES];
      [window makeKeyAndOrderFront:nil];
      mac_loop_test_record ("activate key=%d", window.isKeyWindow);
      return;
    case MAC_LOOP_TEST_SET_SIZE:
      {
	NSRect rect = frame;

	rect.origin.y += NSHeight (rect) - action.y;
	rect.size = NSMakeSize (action.x, action.y);
	[window setFrame:rect display:YES];
	mac_loop_test_record ("set-size %.0fx%.0f", action.x, action.y);
	return;
      }
    case MAC_LOOP_TEST_TERMINATE:
      [NSApp terminate:nil];
      mac_loop_test_record ("terminate");
      return;
    case MAC_LOOP_TEST_LAYER:
      {
	id delegate = window.delegate;
	NSView *view = [delegate valueForKey:@"emacsView"];
	NSView *overlay = [delegate valueForKey:@"overlayView"];
	CALayer *layer = view.layer;
	CGSize drawableSize = CGSizeZero;
	const CGFloat *rgb = NULL;

	if ([layer isKindOfClass:CAMetalLayer.class])
	  drawableSize = ((CAMetalLayer *) layer).drawableSize;
	if (layer.backgroundColor
	    && CGColorGetNumberOfComponents (layer.backgroundColor) >= 3)
	  rgb = CGColorGetComponents (layer.backgroundColor);
	/* Two records: labels hold at most 63 characters.  */
	mac_loop_test_record ("layer %s bg=%s%.2f,%.2f,%.2f opaque=%d",
			      layer.contentsGravity.UTF8String,
			      rgb ? "" : "none:", rgb ? rgb[0] : 0,
			      rgb ? rgb[1] : 0, rgb ? rgb[2] : 0, layer.opaque);
	mac_loop_test_record ("layer %.0fx%.0f@%.0f drawable %.0fx%.0f ov=%lu lr=%d",
			      layer.bounds.size.width,
			      layer.bounds.size.height, layer.contentsScale,
			      drawableSize.width, drawableSize.height,
			      (unsigned long) overlay.layer.sublayers.count,
			      view.inLiveResize);
	return;
      }
    case MAC_LOOP_TEST_SUBTITLE:
      {
	NSString *subtitle = nil;

	if ([window respondsToSelector:@selector (subtitle)])
	  subtitle = window.subtitle;
	mac_loop_test_record ("subtitle %s",
			      subtitle ? subtitle.UTF8String : "");
	return;
      }
    case MAC_LOOP_TEST_MENU:
      {
	NSInteger topIndex = (NSInteger) action.x;
	NSInteger itemIndex = (NSInteger) action.y;
	NSMenu *mainMenu = NSApp.mainMenu;
	NSMenuItem *topItem = (topIndex >= 0 && topIndex < mainMenu.numberOfItems
			       ? [mainMenu itemAtIndex:topIndex] : nil);
	NSMenu *submenu = topItem.submenu;

	if (action.sub_index && submenu && itemIndex >= 0
	    && itemIndex < submenu.numberOfItems)
	  {
	    /* The persistent loop fills nested submenus deeply.  */
	    NSMenuItem *item = [submenu itemAtIndex:itemIndex];

	    mac_loop_test_record ("menu open %s", item.title.UTF8String);
	    submenu = item.submenu;
	    itemIndex = action.sub_index - 1;
	  }
	if (submenu && itemIndex >= 0 && itemIndex < submenu.numberOfItems)
	  {
	    mac_loop_test_record ("menu perform %ld %ld %d",
				  (long) topIndex, (long) itemIndex,
				  action.sub_index);
	    [submenu performActionForItemAtIndex:itemIndex];
	  }
	else
	  mac_loop_test_record ("menu missing %ld %ld %d (%ld items)",
				(long) topIndex, (long) itemIndex,
				action.sub_index,
				(long) (submenu ? submenu.numberOfItems : -1));
	return;
      }
    default:
      mac_loop_test_record ("probe %.0f window %.0fx%.0f%s", action.x,
			    NSWidth (frame), NSHeight (frame),
			    ((window.styleMask & NSWindowStyleMaskFullScreen)
			     ? " fullscreen" : ""));
      return;
    }

  event = [NSEvent mouseEventWithType:type location:location
			modifierFlags:action.modifiers
			    timestamp:[[NSProcessInfo processInfo] systemUptime]
			 windowNumber:window.windowNumber context:nil
			  eventNumber:0 clickCount:1
			     pressure:(type == NSEventTypeLeftMouseUp ? 0 : 1)];
  [NSApp postEvent:event atStart:NO];
  mac_loop_test_record ("post %s %.0f,%.0f", name, action.x, action.y);
}

/* Lisp thread: schedule ACTIONS (an array of N elements) against the
   window of frame F, relative to now.  */

void
mac_loop_test_schedule (struct frame *f,
			const struct mac_loop_test_action *actions, int n)
{
  EmacsWindow *window = MRC_RETAIN (FRAME_MAC_WINDOW_OBJECT (f));
  struct mac_loop_test_action *copy = xmalloc (n * sizeof *copy);

  memcpy (copy, actions, n * sizeof *copy);
  mac_within_gui (^{
      mac_loop_test_recording_p = true;
      mac_loop_test_start_heartbeat ();
      mac_loop_test_record ("schedule %d", n);
      for (int i = 0; i < n; i++)
	{
	  struct mac_loop_test_action action = copy[i];

	  dispatch_after (dispatch_time (DISPATCH_TIME_NOW,
					 action.delay * NSEC_PER_SEC),
			  dispatch_get_main_queue (), ^{
			      mac_loop_test_perform (action, window);
			    });
	}
    });
  xfree (copy);
}

/* Lisp thread: return the records and heartbeat statistics.  If
   RESET, clear them.  */

Lisp_Object
mac_loop_test_results (bool reset)
{
  __block Lisp_Object records = Qnil;
  __block double max_gap;
  __block int long_gaps;
  unsigned long stats[countof (mac_loop_stats)];
  unsigned long *statsp = stats;
  int n = 0;
  double *times = NULL;
  char (*labels)[64] = NULL;

  mac_within_gui (^{
      max_gap = mac_loop_test_max_gap;
      long_gaps = mac_loop_test_long_gaps;
      memcpy (statsp, mac_loop_stats, sizeof mac_loop_stats);
      if (reset)
	{
	  memset (mac_loop_stats, 0, sizeof mac_loop_stats);
	  mac_loop_test_max_gap = 0;
	  mac_loop_test_long_gaps = 0;
	}
    });
  /* Copy without allocating Lisp objects on the GUI thread.  */
  __block int count;
  mac_within_gui (^{ count = mac_loop_test_nrecords; });
  n = count;
  times = xmalloc ((n + 1) * sizeof *times);
  labels = xmalloc ((n + 1) * sizeof *labels);
  mac_within_gui (^{
      for (int i = 0; i < n; i++)
	{
	  times[i] = mac_loop_test_records[i].time;
	  memcpy (labels[i], mac_loop_test_records[i].label, 64);
	}
      if (reset)
	mac_loop_test_nrecords = 0;
    });
  for (int i = n - 1; i >= 0; i--)
    records = Fcons (Fcons (make_float (times[i]), build_string (labels[i])),
		     records);
  xfree (times);
  xfree (labels);

  Lisp_Object counters = Qnil;

  for (int i = countof (mac_loop_stats) - 1; i >= 0; i--)
    counters = Fcons (make_uint (stats[i]), counters);

  return list4 (make_float (max_gap), make_fixnum (long_gaps), records,
		counters);
}


/***********************************************************************
			       Startup
***********************************************************************/

/* Thread ID of the Lisp main thread.  This should be the same as
   `main_thread_id' in sysdep.c.  Note that this is not the thread ID
   of the main/initial thread, which is dedicated to GUI
   processing.  */

static pthread_t mac_lisp_main_thread_id;

/* The entry point of the Lisp main thread.  */

static void *
mac_start_lisp_main (void *arg)
{
  char **argv = (char **) arg;
  int argc = 1;

  pthread_setname_np ("org.gnu.Emacs.lisp-main");

  while (argv[argc])
    argc++;

  emacs_main (argc, argv);

  return 0;
}

/* Return true if the current thread is the GUI thread.  */

bool
mac_gui_thread_p (void)
{
  return initialized && pthread_main_np ();
}

/* The entry point of the main/initial thread.  */

int
main (int argc, char **argv)
{
  int err;
  pthread_attr_t attr;
  struct rlimit rlim;

  if (will_dump_p ())
    return emacs_main (argc, argv);

  if (getenv ("EMACS_REINVOKED_FROM_SHELL"))
    unsetenv ("EMACS_REINVOKED_FROM_SHELL");
  else
    {
      char *shlvl = getenv ("SHLVL");

      if (shlvl == NULL || atoi (shlvl) == 0)
	{
	  CFBundleRef bundle = CFBundleGetMainBundle ();

	  /* Reinvoke the current executable using the helper script
	     in .../Emacs.app/Contents/MacOS/Emacs.sh so the
	     application can get environment variables from the login
	     shell if necessary.  Previously we invoked the helper
	     script directly by specifying it as the value for
	     CFBundleExecutable in Info.plist.  But this makes
	     LookupViewSource invoked by Command-Control-D or
	     three-finger tap crash on OS X 10.10.3.  This is because
	     the ViewBridge framework tries to create a bundle object
	     from the URL obtained by SecCodeCopyPath, which does not
	     store the URL for the application bundle but the one for
	     the executable if CFBundleExecutable does not correspond
	     to the running application process.  */
	  if (bundle && CFBundleGetIdentifier (bundle))
	    {
	      char **new = alloca ((argc + 1) * sizeof *new);
	      size_t len = strlen (argv[0]);

	      new[0] = alloca (len + sizeof (".sh"));
	      strcpy (new[0], argv[0]);
	      strcpy (new[0] + len, ".sh");
	      memcpy (new + 1, argv + 1, argc * sizeof *new);
	      execvp (new[0], new);
	    }
	}
    }

  mac_loop_select_mode ();
  mac_init_thread_synchronization ();
  mac_init_select_fds ();
  if (mac_persistent_loop_p)
    mac_loop_init ();

  err = pthread_attr_init (&attr);
  if (!err)
    err = pthread_attr_setdetachstate (&attr, PTHREAD_CREATE_DETACHED);
  /* Calculation of the stack size from emacs.c.  */
  if (!err && !getrlimit (RLIMIT_STACK, &rlim)
      && 0 <= rlim.rlim_cur && rlim.rlim_cur <= LONG_MAX)
    {
      /* In case the current stack size limit is not a multiple of
	 page size.  */
      rlim.rlim_cur = round_page (rlim.rlim_cur);
      rlim_t lim = rlim.rlim_cur;

      /* Approximate the amount regex.c needs per unit of
	 emacs_re_max_failures, then add 33% to cover the size of the
	 smaller stacks that regex.c successively allocates and
	 discards on its way to the maximum.  */
      int min_ratio = 20 * sizeof (char *);
      int ratio = min_ratio + min_ratio / 3;

      /* Extra space to cover what we're likely to use for other
         reasons.  For example, a typical GC might take 30K stack
         frames.  */
      int extra = (30 * 1000) * 50;

      bool try_to_grow_stack = true;
#ifndef CANNOT_DUMP
      try_to_grow_stack = !noninteractive || initialized;
#endif

      if (try_to_grow_stack)
	{
	  rlim_t newlim = emacs_re_max_failures * ratio + extra;

	  /* Round the new limit to a page boundary; this is needed
	     for Darwin kernel 15.4.0 (see Bug#23622) and perhaps
	     other systems.  Do not shrink the stack and do not exceed
	     rlim_max.  Don't worry about exact values of
	     RLIM_INFINITY etc. since in practice when they are
	     nonnegative they are so large that the code does the
	     right thing anyway.  */
	  long pagesize = getpagesize ();
	  newlim += pagesize - 1;
	  if (0 <= rlim.rlim_max && rlim.rlim_max < newlim)
	    newlim = rlim.rlim_max;
	  newlim -= newlim % pagesize;

	  if (newlim > lim	/* in case rlim_t is an unsigned type */
	      && pagesize <= newlim - lim)
	    rlim.rlim_cur = newlim;
	}

      err = pthread_attr_setstacksize (&attr, rlim.rlim_cur);
    }
  if (!err)
    err = pthread_create (&mac_lisp_main_thread_id, &attr, mac_start_lisp_main,
			  argv);
  if (err)
    {
      fprintf (stderr, "Can't create Lisp main thread: %s\n", strerror (err));
      exit (1);
    }
  pthread_attr_destroy (&attr);

  if (mac_persistent_loop_p)
    mac_loop_gui_main ();
  else
    mac_gui_loop ();

  emacs_abort ();
}
