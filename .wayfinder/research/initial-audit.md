# Initial implementation audit

Inspected 2026-09-23 at `1b08291ec0350cec8fbd1447fe869185f486097d`.
No fresh interactive GUI tests were performed. File positions refer to this revision.

- `src/macappkit.m:2062`: macOS 26+ disables concurrent event processing and
  the application update cycle using undocumented defaults.
- `src/macappkit.m:2074`: macOS 27+ sets
  `NSWindowResizeNeedsTrackingLoop=YES` and
  `NSControlPrefersGestureRecognizerTracking=NO` before application creation.
  The API is public NSUserDefaults; these preference keys are undocumented.
- `src/macappkit.m:3550`: macOS 27+ bypasses legacy synthetic release/press
  events during resize.
- `src/macappkit.m:131`: native menu and worker preparation experiments have
  configure-time defaults or separate environment flags. Alternate paths also
  gate on OS version. Worker menus still cancel, rebuild, and reopen tracking.
- `src/macappkit.m:17334`: the GUI main thread waits for Lisp-submitted blocks.
  `:17389` coordinates synchronous and deferred callbacks. `:17755` integrates
  select with manual run-loop processing. `:17894` starts Lisp on another thread.
  Moving Lisp to a worker is therefore not by itself a new architecture.
- `test/manual/mac-menu/README.md:106` records successful menu interaction,
  yellow-button minimize/restore, and edge/corner resize. Green-button
  zoom/fullscreen and broader coverage remain unestablished by these records.

The upstream [resize issue](https://github.com/jdtsmith/emacs-mac/issues/151)
was open when checked. The maintainer identifies repeated application/run-loop
start/stop as a source of fragility and says redesign work is underway.
The published [titlebar proposal](https://github.com/jdtsmith/emacs-mac/pull/153)
was open and unmerged; it pumps events through mouse-up for titlebar interactions
and refers to an internal fullscreen toolbar class. It is not evidence of a
completed documented-API redesign.

These observations motivate the research tickets. They do not select an architecture.
