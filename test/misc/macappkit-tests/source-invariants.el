;;; source-invariants.el --- Tests for macOS AppKit source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect macOS AppKit source directly.  They catch regressions in
;; event-loop instrumentation that is difficult to exercise in batch tests.

;;; Code:

(require 'ert)

(defun macappkit-tests--source (file)
  "Return the contents of src/FILE."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "src/" file) source-directory))
    (buffer-string)))

(defun macappkit-tests--function-body (function-name next-marker)
  "Return FUNCTION-NAME source body from src/macappkit.m up to NEXT-MARKER."
  (let ((source (macappkit-tests--source "macappkit.m")))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (regexp-quote next-marker) source start))
      (substring source start (match-beginning 0)))))

(defun macappkit-tests--method-body (method-name next-marker)
  "Return METHOD-NAME source body from src/macappkit.m up to NEXT-MARKER."
  (let ((source (macappkit-tests--source "macappkit.m")))
    (should (string-match (concat "\n" (regexp-quote method-name) "\n{")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (regexp-quote next-marker) source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macappkit-select-records-latency-stats ()
  "The AppKit select emulation should expose event-loop latency counters."
  (let ((body (macappkit-tests--function-body
               "mac_select"
               "\n\f\n/***********************************************************************\n\t\t\t       Startup")))
    (should (string-match-p "mac_select_latency_stats" body))
    (should (string-match-p "mac_record_select_latency" body))
    (should (string-match-p "gui_wait_seconds" body))
    (should (string-match-p "run_loop_iterations" body)))
  (let ((mac-source (macappkit-tests--source "mac.c"))
        (header-source (macappkit-tests--source "macterm.h")))
    (should (string-match-p "mac-select-latency-stats" mac-source))
    (should (string-match-p "defsubr (&Smac_select_latency_stats)" mac-source))
    (should (string-match-p "mac_get_select_latency_stats" header-source))))

(ert-deftest macappkit-no-menu-bar-frames-remain-full-screen-primary ()
  "Normal no-menu-bar mac frames should remain eligible for Split View."
  (let ((body (macappkit-tests--method-body
               "- (void)updateCollectionBehavior"
               "\n- (void)updateWindowLevel")))
    (should (string-match-p
             "WM_STATE_NO_MENUBAR\\(?:.\\|\n\\)*NSWindowCollectionBehaviorFullScreenPrimary"
             body))
    (should-not (string-match-p
                 "NSWindowCollectionBehaviorFullScreenAuxiliary"
                 body))))

(ert-deftest macappkit-metal-size-and-scale-changes-sync-drawable ()
  "Metal drawing should keep the backbuffer and layer matched to the view."
  (let ((sync-body (macappkit-tests--method-body
                    "- (void)syncMetalDrawableSize"
                    "\n#else  /* !USE_METAL_RENDERING */"))
        (backing-body (macappkit-tests--method-body
                       "- (void)viewDidChangeBackingProperties"
                       "\n- (void)viewFrameDidChange"))
        (frame-body (macappkit-tests--method-body
                     "- (void)viewFrameDidChange:(NSNotification *)notification"
                     "\n@end"))
        (live-resize-body (macappkit-tests--method-body
                           "- (void)viewDidEndLiveResize"
                           "\n- (void)viewFrameDidChange:(NSNotification *)notification"))
        (scale-factor-body (macappkit-tests--method-body
                            "- (void)updateBackingScaleFactor"
                            "\n- (BOOL)emacsViewIsHiddenOrHasHiddenAncestor"))
        (app-screen-body (macappkit-tests--method-body
                          "- (void)applicationDidChangeScreenParameters:(NSNotification *)notification"
                          "\n#endif"))
        (window-screen-body (macappkit-tests--method-body
                             "- (void)windowDidChangeScreen:(NSNotification *)notification"
                             "\n- (void)windowDidChangeBackingProperties")))
    (should (string-match-p "FRAME_METAL_CTX" sync-body))
    (should (string-match-p "CAMetalLayer" sync-body))
    (should (string-match-p "backingScaleFactor" sync-body))
    (should (string-match-p "drawableSize" sync-body))
    (should (string-match-p "emacs_metal_context_resize" sync-body))
    (should (string-match-p "\\[self syncMetalDrawableSize\\]" backing-body))
    (should (string-match-p "\\[self syncMetalDrawableSize\\]" frame-body))
    (should (string-match-p "\\[self syncMetalDrawableSize\\]" live-resize-body))
    (should (string-match-p "emacsView\\.needsDisplay = YES"
                            scale-factor-body))
    (should (string-match-p "USE_METAL_RENDERING" app-screen-body))
    (should (string-match-p "\\[frameController updateBackingScaleFactor\\]"
                            app-screen-body))
    (should (string-match-p "USE_METAL_RENDERING" window-screen-body))
    (should (string-match-p "\\[self updateBackingScaleFactor\\]"
                            window-screen-body))))

(ert-deftest macappkit-metal-layer-uses-byte-exact-pixel-format ()
  "Metal layer should preserve Emacs sRGB color bytes without re-encoding."
  (let ((body (macappkit-tests--method-body
               "- (CALayer *)makeBackingLayer"
               "\n- (BOOL)wantsLayer")))
    (should (string-match-p "MTLPixelFormatBGRA8Unorm" body))
    (should-not (string-match-p "MTLPixelFormatBGRA8Unorm_sRGB" body))))

(ert-deftest macappkit-emacs-view-posts-frame-change-notifications ()
  "Emacs frame dimensions must be updated when the AppKit view frame changes."
  (let ((body (macappkit-tests--method-body
               "- (instancetype)initWithFrame:(NSRect)frameRect"
               "\n- (void)dealloc")))
    (should (string-match-p "setPostsFrameChangedNotifications:YES" body))
    (should (string-match-p "NSViewFrameDidChangeNotification" body))))

;;; source-invariants.el ends here
