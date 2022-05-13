/* NS Cocoa part implementation of xwidget and webkit widget.

Copyright (C) 2019-2022 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>

#include "lisp.h"
#include "blockinput.h"
#include "dispextern.h"
#include "buffer.h"
#include "frame.h"
#ifdef HAVE_MACGUI
# include "menu.h"
# include "macterm.h"
# import "macappkit.h"
# define MAC_BEGIN_GUI	mac_within_gui_check_thread (^{
# define MAC_END_GUI	})
#else
# include "nsterm.h"
# define MAC_BEGIN_GUI
# define MAC_END_GUI
#endif
#include "xwidget.h"

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

/* Thoughts on NS Cocoa xwidget and webkit2:

   Webkit2 process architecture seems to be very hostile for offscreen
   rendering techniques, which is used by GTK xwidget implementation;
   Specifically NSView level view sharing / copying is not working.

   *** So only one view can be associated with a model. ***

   With this decision, implementation is plain and can expect best out
   of webkit2's rationale.  But process and session structures will
   diverge from GTK xwidget.  Though, cosmetically similar usages can
   be presented and will be preferred, if agreeable.

   For other widget types, OSR seems possible, but will not care for a
   while.  */

#if MAC_OS_X_VERSION_MAX_ALLOWED < 101100
@interface WKWebView (AvailableOn101100AndLater)
@property (nullable, nonatomic, copy) NSString *customUserAgent;
@end
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED < 101200
@interface WKOpenPanelParameters : NSObject
@property (nonatomic, readonly) BOOL allowsMultipleSelection;
@end
#endif

/* Xwidget webkit.  */

@interface XwWebView : WKWebView
<WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property struct xwidget *xw;
/* Map url to whether javascript is blocked by
   'Content-Security-Policy' sandbox without allow-scripts.  */
@property(retain) NSMutableDictionary *urlScriptBlocked;
@end
@implementation XwWebView : WKWebView

- (id)initWithFrame:(CGRect)frame
      configuration:(WKWebViewConfiguration *)configuration
            xwidget:(struct xwidget *)xw
{
  /* Script controller to add script message handler and user script.  */
  WKUserContentController *scriptor = [[WKUserContentController alloc] init];
  configuration.userContentController = scriptor;

  /* Enable inspect element context menu item for debugging.  */
  [configuration.preferences setValue:@YES
                               forKey:@"developerExtrasEnabled"];

  Lisp_Object enablePlugins =
    Fintern (build_string ("xwidget-webkit-enable-plugins"), Qnil);
  if (!EQ (Fsymbol_value (enablePlugins), Qnil))
    configuration.preferences.plugInsEnabled = YES;

  self = [super initWithFrame:frame configuration:configuration];
  if (self)
    {
      self.xw = xw;
      self.urlScriptBlocked = [[NSMutableDictionary alloc] init];
      self.navigationDelegate = self;
      self.UIDelegate = self;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      if ([self respondsToSelector:@selector(setCustomUserAgent:)])
#endif
      self.customUserAgent =
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6)"
        @" AppleWebKit/603.3.8 (KHTML, like Gecko)"
        @" Version/11.0.1 Safari/603.3.8";
      [scriptor addScriptMessageHandler:self name:@"keyDown"];
      [scriptor addUserScript:[[WKUserScript alloc]
                                initWithSource:xwScript
                                 injectionTime:
                                  WKUserScriptInjectionTimeAtDocumentStart
                                forMainFrameOnly:NO]];
    }
  return self;
}

- (void)webView:(WKWebView *)webView
didFinishNavigation:(WKNavigation *)navigation
{
  if (EQ (Fbuffer_live_p (self.xw->buffer), Qt))
    store_xwidget_event_string (self.xw, "load-changed", "");
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  switch (navigationAction.navigationType) {
  case WKNavigationTypeLinkActivated:
    decisionHandler (WKNavigationActionPolicyAllow);
    break;
  default:
    // decisionHandler (WKNavigationActionPolicyCancel);
    decisionHandler (WKNavigationActionPolicyAllow);
    break;
  }
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
  if (!navigationResponse.canShowMIMEType)
    {
      NSString *url = navigationResponse.response.URL.absoluteString;
      NSString *mimetype = navigationResponse.response.MIMEType;
      NSString *filename = navigationResponse.response.suggestedFilename;
      decisionHandler (WKNavigationResponsePolicyCancel);
      store_xwidget_download_callback_event (self.xw,
                                             url.UTF8String,
                                             mimetype.UTF8String,
                                             filename.UTF8String);
      return;
    }
  decisionHandler (WKNavigationResponsePolicyAllow);

  self.urlScriptBlocked[navigationResponse.response.URL] =
    [NSNumber numberWithBool:NO];
  if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]])
    {
      NSDictionary *headers =
        ((NSHTTPURLResponse *) navigationResponse.response).allHeaderFields;
      NSString *value = headers[@"Content-Security-Policy"];
      if (value)
        {
          /* TODO: Sloppy parsing of 'Content-Security-Policy' value.  */
          NSRange sandbox = [value rangeOfString:@"sandbox"];
          if (sandbox.location != NSNotFound
              && (sandbox.location == 0
                  || [value characterAtIndex:(sandbox.location - 1)] == ' '
                  || [value characterAtIndex:(sandbox.location - 1)] == ';'))
            {
              NSRange allowScripts = [value rangeOfString:@"allow-scripts"];
              if (allowScripts.location == NSNotFound
                  || allowScripts.location < sandbox.location)
                self.urlScriptBlocked[navigationResponse.response.URL] =
                  [NSNumber numberWithBool:YES];
            }
        }
    }
}

/* No additional new webview or emacs window will be created
   for <a ... target="_blank">.  */
- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *)windowFeatures
{
  if (!navigationAction.targetFrame.isMainFrame)
    [webView loadRequest:navigationAction.request];
  return nil;
}

/* Open panel for file upload.  */
- (void)webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
initiatedByFrame:(WKFrameInfo *)frame
#ifdef HAVE_MACGUI
completionHandler:(void (^)(NSArrayOf (NSURL *) *URLs))completionHandler
#else
completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler
#endif
{
  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
  openPanel.canChooseFiles = YES;
  openPanel.canChooseDirectories = NO;
  openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection;
  if ([openPanel runModal] == NSModalResponseOK)
    completionHandler (openPanel.URLs);
  else
    completionHandler (nil);
}

/* By forwarding mouse events to emacs view (frame)
   - Mouse click in webview selects the window contains the webview.
   - Correct mouse hand/arrow/I-beam is displayed (TODO: not perfect yet).
*/

- (void)mouseDown:(NSEvent *)event
{
  [self.xw->xv->emacswindow mouseDown:event];
  [super mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event
{
  [self.xw->xv->emacswindow mouseUp:event];
  [super mouseUp:event];
}

/* Basically we want keyboard events handled by emacs unless an input
   element has focus.  Especially, while incremental search, we set
   emacs as first responder to avoid focus held in an input element
   with matching text.  */

- (void)keyDown:(NSEvent *)event
{
  Lisp_Object var = Fintern (build_string ("isearch-mode"), Qnil);
  Lisp_Object val = buffer_local_value (var, Fcurrent_buffer ());
  if (!EQ (val, Qunbound) && !EQ (val, Qnil))
    {
      [self.window makeFirstResponder:self.xw->xv->emacswindow];
      [self.xw->xv->emacswindow keyDown:event];
      return;
    }

  /* Emacs handles keyboard events when javascript is blocked.  */
  if ([self.urlScriptBlocked[self.URL] boolValue])
    {
      [self.xw->xv->emacswindow keyDown:event];
      return;
    }

  [self evaluateJavaScript:@"xwHasFocus()"
         completionHandler:^(id result, NSError *error) {
      if (error)
        {
          NSLog (@"xwHasFocus: %@", error);
          [self.xw->xv->emacswindow keyDown:event];
        }
      else if (result)
        {
          NSNumber *hasFocus = result; /* __NSCFBoolean */
          if (!hasFocus.boolValue)
            [self.xw->xv->emacswindow keyDown:event];
          else
            [super keyDown:event];
        }
    }];
}

#ifdef HAVE_MACGUI
- (void)interpretKeyEvents:(NSArrayOf (NSEvent *) *)eventArray
#else
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)eventArray
#endif
{
  /* We should do nothing and do not forward (default implementation
     if we not override here) to let emacs collect key events and ask
     interpretKeyEvents to its superclass.  */
}

static NSString *xwScript;
+ (void)initialize
{
  /* Find out if an input element has focus.
     Message to script message handler when 'C-g' key down.  */
  if (!xwScript)
    xwScript =
      @"function xwHasFocus() {"
      @"  var ae = document.activeElement;"
      @"  if (ae) {"
      @"    var name = ae.nodeName;"
      @"    return name == 'INPUT' || name == 'TEXTAREA';"
      @"  } else {"
      @"    return false;"
      @"  }"
      @"}"
      @"function xwKeyDown(event) {"
      @"  if (event.ctrlKey && event.key == 'g') {"
      @"    window.webkit.messageHandlers.keyDown.postMessage('C-g');"
      @"  }"
      @"}"
      @"document.addEventListener('keydown', xwKeyDown);"
      ;
}

/* Confirming to WKScriptMessageHandler, listens concerning keyDown in
   webkit. Currently 'C-g'.  */
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  if ([message.body isEqualToString:@"C-g"])
    {
      /* Just give up focus, no relay "C-g" to emacs, another "C-g"
         follows will be handled by emacs.  */
      [self.window makeFirstResponder:self.xw->xv->emacswindow];
    }
}

@end

#ifdef HAVE_MACGUI
static void
mac_within_gui_check_thread (void (^ CF_NOESCAPE block) (void))
{
  if (!pthread_main_np ())
    mac_within_gui (block);
  else
    block ();
}
#endif

/* Xwidget webkit commands.  */

bool
nsxwidget_is_web_view (struct xwidget *xw)
{
  return xw->xwWidget != NULL &&
    [xw->xwWidget isKindOfClass:WKWebView.class];
}

Lisp_Object
nsxwidget_webkit_uri (struct xwidget *xw)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  return [xwWebView.URL.absoluteString lispString];
}

Lisp_Object
nsxwidget_webkit_title (struct xwidget *xw)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  return [xwWebView.title lispString];
}

/* @Note ATS - Need application transport security in 'Info.plist' or
   remote pages will not loaded.  */
void
nsxwidget_webkit_goto_uri (struct xwidget *xw, const char *uri)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  NSString *urlString = [NSString stringWithUTF8String:uri];
  NSURL *url = [NSURL URLWithString:urlString];
  NSURLRequest *urlRequest = [NSURLRequest requestWithURL:url];
  MAC_BEGIN_GUI;
  [xwWebView loadRequest:urlRequest];
  MAC_END_GUI;
}

void
nsxwidget_webkit_goto_history (struct xwidget *xw, int rel_pos)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  switch (rel_pos) {
  case -1: [xwWebView goBack]; break;
  case 0: [xwWebView reload]; break;
  case 1: [xwWebView goForward]; break;
  }
}

void
nsxwidget_webkit_zoom (struct xwidget *xw, double zoom_change)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  MAC_BEGIN_GUI;
  xwWebView.magnification += zoom_change;
  /* TODO: setMagnification:centeredAtPoint.  */
  MAC_END_GUI;
}

/* Recursively convert an objc native type JavaScript value to a Lisp
   value.  Mostly copied from GTK xwidget 'webkit_js_to_lisp'.  */
static Lisp_Object
js_to_lisp (id value)
{
  if (value == nil || [value isKindOfClass:NSNull.class])
    return Qnil;
  else if ([value isKindOfClass:NSString.class])
    return [(NSString *) value lispString];
  else if ([value isKindOfClass:NSNumber.class])
    {
      NSNumber *nsnum = (NSNumber *) value;
      char type = nsnum.objCType[0];
      if (type == 'c') /* __NSCFBoolean has type character 'c'.  */
        return nsnum.boolValue? Qt : Qnil;
      else
        {
          if (type == 'i' || type == 'l')
            return make_int (nsnum.longValue);
          else if (type == 'f' || type == 'd')
            return make_float (nsnum.doubleValue);
          /* else fall through.  */
        }
    }
  else if ([value isKindOfClass:NSArray.class])
    {
      NSArray *nsarr = (NSArray *) value;
      EMACS_INT n = nsarr.count;
      Lisp_Object obj;
      struct Lisp_Vector *p = allocate_nil_vector (n);

      for (ptrdiff_t i = 0; i < n; ++i)
        p->contents[i] = js_to_lisp ([nsarr objectAtIndex:i]);
      XSETVECTOR (obj, p);
      return obj;
    }
  else if ([value isKindOfClass:NSDictionary.class])
    {
      NSDictionary *nsdict = (NSDictionary *) value;
      NSArray *keys = nsdict.allKeys;
      ptrdiff_t n = keys.count;
      Lisp_Object obj;
      struct Lisp_Vector *p = allocate_nil_vector (n);

      for (ptrdiff_t i = 0; i < n; ++i)
        {
          NSString *prop_key = (NSString *) [keys objectAtIndex:i];
          id prop_value = [nsdict valueForKey:prop_key];
          p->contents[i] = Fcons ([prop_key lispString],
                                  js_to_lisp (prop_value));
        }
      XSETVECTOR (obj, p);
      return obj;
    }
  NSLog (@"Unhandled type in javascript result");
  return Qnil;
}

void
nsxwidget_webkit_execute_script (struct xwidget *xw, const char *script,
                                 Lisp_Object fun)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  if ([xwWebView.urlScriptBlocked[xwWebView.URL] boolValue])
    {
      message ("Javascript is blocked by 'CSP: sandbox'.");
      return;
    }

  NSString *javascriptString = [NSString stringWithUTF8String:script];
  MAC_BEGIN_GUI;
  [xwWebView evaluateJavaScript:javascriptString
              completionHandler:^(id result, NSError *error) {
      if (error)
        {
          NSLog (@"evaluateJavaScript error : %@", error.localizedDescription);
          NSLog (@"error script=%@", javascriptString);
        }
      else if (result && FUNCTIONP (fun))
        {
          // NSLog (@"result=%@, type=%@", result, [result class]);
          Lisp_Object lisp_value = js_to_lisp (result);
          store_xwidget_js_callback_event (xw, fun, lisp_value);
        }
    }];
  MAC_END_GUI;
}

/* Window containing an xwidget.  */

@implementation XwWindow
- (BOOL)isFlipped { return YES; }
@end

/* Xwidget model, macOS Cocoa part.  */

void
nsxwidget_init(struct xwidget *xw)
{
  block_input ();
  MAC_BEGIN_GUI;
  NSRect rect = NSMakeRect (0, 0, xw->width, xw->height);
  xw->xwWidget = [[XwWebView alloc]
                   initWithFrame:rect
                   configuration:[[WKWebViewConfiguration alloc] init]
                         xwidget:xw];
  xw->xwWindow = [[XwWindow alloc]
                   initWithFrame:rect];
  [xw->xwWindow addSubview:xw->xwWidget];
  xw->xv = NULL; /* for 1 to 1 relationship of webkit2.  */
  MAC_END_GUI;
  unblock_input ();
}

void
nsxwidget_kill (struct xwidget *xw)
{
  if (xw)
    {
      MAC_BEGIN_GUI;
      WKUserContentController *scriptor =
        ((XwWebView *) xw->xwWidget).configuration.userContentController;
      [scriptor removeAllUserScripts];
      [scriptor removeScriptMessageHandlerForName:@"keyDown"];
#if !USE_ARC
      [scriptor release];
#endif
      if (xw->xv)
        xw->xv->model = Qnil; /* Make sure related view stale.  */

      /* This stops playing audio when a xwidget-webkit buffer is
         killed.  I could not find other solution.  */
      nsxwidget_webkit_goto_uri (xw, "about:blank");

#if !USE_ARC
      [((XwWebView *) xw->xwWidget).urlScriptBlocked release];
#endif
      [xw->xwWidget removeFromSuperviewWithoutNeedingDisplay];
#if !USE_ARC
      [xw->xwWidget release];
#endif
      [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
#if !USE_ARC
      [xw->xwWindow release];
#else
      xw->xwWindow = nil;
#endif
      xw->xwWidget = nil;
      MAC_END_GUI;
    }
}

void
nsxwidget_resize (struct xwidget *xw)
{
  if (xw->xwWidget)
    {
      MAC_BEGIN_GUI;
      [xw->xwWindow setFrameSize:NSMakeSize(xw->width, xw->height)];
      [xw->xwWidget setFrameSize:NSMakeSize(xw->width, xw->height)];
      MAC_END_GUI;
    }
}

Lisp_Object
nsxwidget_get_size (struct xwidget *xw)
{
  return list2i (xw->xwWidget.frame.size.width,
                 xw->xwWidget.frame.size.height);
}

/* Xwidget view, macOS Cocoa part.  */

@implementation XvWindow : NSView
- (BOOL)isFlipped { return YES; }
@end

void
nsxwidget_init_view (struct xwidget_view *xv,
                     struct xwidget *xw,
                     struct glyph_string *s,
                     int x, int y)
{
  /* 'x_draw_xwidget_glyph_string' will calculate correct position and
     size of clip to draw in emacs buffer window.  Thus, just begin at
     origin with no crop.  */
  xv->x = x;
  xv->y = y;
  xv->clip_left = 0;
  xv->clip_right = xw->width;
  xv->clip_top = 0;
  xv->clip_bottom = xw->height;

  MAC_BEGIN_GUI;
  xv->xvWindow = [[XvWindow alloc]
                   initWithFrame:NSMakeRect (x, y, xw->width, xw->height)];
  xv->xvWindow.xw = xw;
  xv->xvWindow.xv = xv;

  xw->xv = xv; /* For 1 to 1 relationship of webkit2.  */
  [xv->xvWindow addSubview:xw->xwWindow];

#ifdef HAVE_MACGUI
  xv->emacswindow = (__bridge NSView *) FRAME_MAC_VIEW (s->f);
#else
  xv->emacswindow = FRAME_NS_VIEW (s->f);
#endif

  [xv->emacswindow addSubview:xv->xvWindow];
  MAC_END_GUI;
}

void
nsxwidget_delete_view (struct xwidget_view *xv)
{
  MAC_BEGIN_GUI;
  if (!EQ (xv->model, Qnil))
    {
      struct xwidget *xw = XXWIDGET (xv->model);
      [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
      xw->xv = NULL; /* Now model has no view.  */
    }
  [xv->xvWindow removeFromSuperviewWithoutNeedingDisplay];
#if !USE_ARC
  [xv->xvWindow release];
#else
  xv->xvWindow = nil;
  xv->emacswindow = nil;
#endif
  MAC_END_GUI;
}

void
nsxwidget_show_view (struct xwidget_view *xv)
{
  xv->hidden = NO;
  MAC_BEGIN_GUI;
  [xv->xvWindow setFrameOrigin:NSMakePoint(xv->x + xv->clip_left,
                                           xv->y + xv->clip_top)];
  MAC_END_GUI;
}

void
nsxwidget_hide_view (struct xwidget_view *xv)
{
  xv->hidden = YES;
  MAC_BEGIN_GUI;
  [xv->xvWindow setFrameOrigin:NSMakePoint(10000, 10000)];
  MAC_END_GUI;
}

void
nsxwidget_resize_view (struct xwidget_view *xv, int width, int height)
{
  MAC_BEGIN_GUI;
  [xv->xvWindow setFrameSize:NSMakeSize(width, height)];
  MAC_END_GUI;
}

void
nsxwidget_move_view (struct xwidget_view *xv, int x, int y)
{
  MAC_BEGIN_GUI;
  [xv->xvWindow setFrameOrigin:NSMakePoint (x, y)];
  MAC_END_GUI;
}

/* Move model window in container (view window).  */
void
nsxwidget_move_widget_in_view (struct xwidget_view *xv, int x, int y)
{
  struct xwidget *xww = xv->xvWindow.xw;
  MAC_BEGIN_GUI;
  [xww->xwWindow setFrameOrigin:NSMakePoint (x, y)];
  MAC_END_GUI;
}

void
nsxwidget_set_needsdisplay (struct xwidget_view *xv)
{
  MAC_BEGIN_GUI;
  xv->xvWindow.needsDisplay = YES;
  MAC_END_GUI;
}