# Transactional live-resize presentation resolution

Closed on 2026-09-24 with the user's live confirmation.

The user installed the `transactional-resize` build and resized the
window by hand on macOS 27 with their own configuration (17 pt font,
`perfect-margin-mode`). They were asked to check that the mode line
follows the bottom edge without jumping back, that fast grows and
shrinks show no white or empty bands or flicker, and that dragging
stays responsive, including while Emacs is busy. They reported "now it
works".

The scripted evidence is
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-sync-resize.md`:
with the wait disabled, 62 of 175 frames of an 8 ms-step drag had an
undrawn band of up to 70 px at the growing edge; with it, none.

Deviations from the acceptance gate:
- The user's check was not screen-recorded; the frame-by-frame check
  was made on scripted drags (`resize-band.sh`).
- Whether the user ran a busy-Lisp drag was not stated separately.
  Scripted busy drags (`busy-resize-layer`, `live-resize`,
  `stalled-resize-layer`) keep GUI gaps under 50 ms.
- The workarounds from `fb6cb18a20f` and `a5972084b64` were kept, not
  removed (agent-adopted; see ticket 18 Progress): the asynchronous
  path still serves programmatic resizes, zoom, fullscreen, and frames
  after busy-Lisp steps.
