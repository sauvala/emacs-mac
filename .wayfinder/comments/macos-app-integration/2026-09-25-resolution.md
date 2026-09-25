# macOS application integration map resolution

Closed on 2026-09-25 after the user's confirmation of the S8 build.

Every child ticket (01-18) is closed. The planning destination was
reached and then implemented: the persistent `NSApplication.run` loop
is the only event loop, menus use published snapshots with an
open-time refresh, windows follow the single-owner and live-resize
contracts, and the old loop with its workarounds is gone.

The destination's "every supported macOS version" was met by the
user's decision to support only macOS 27 and later (S7), not by
validation on older systems. VoiceOver and mixed-scale display checks
were not run (see tickets 11 and 13).
