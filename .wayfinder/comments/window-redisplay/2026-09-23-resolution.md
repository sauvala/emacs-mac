# Resolution

[Choose window lifecycle and redisplay coordination](../../issues/06-window-redisplay.md)
resolved on 2026-09-23 with the user's live confirmation of the
[recorded decisions](2026-09-23-discussion.md).

Each window field has one owner. The GUI owns geometry, screen, scale,
visibility, minimized and fullscreen state, applies user changes immediately
and posts coalesced records to Lisp. Lisp owns title, size hints, background,
menu and IME data and publishes them at the end of redisplay. Live resize
stays in one tracking session. Geometry reaches Lisp during the drag and
Lisp may draw in tracking mode. While Lisp cannot draw, the last presentation
stays top-left, clipped or padded with the background, never stretched or
uninitialized. Synthetic resize events and GUI-thread Lisp writes during
fullscreen retire. The four event-loop preferences are not registered under
the new loop and can be re-enabled one at a time for validation.

Close and Quit keep their Lisp-decided routes, ignore repeat clicks while one
is pending, and show "Waiting for Emacs…" after 100 ms. Lisp window requests
stay synchronous structural requests; resizing a frame being dragged waits
for the drag to end. Lisp fullscreen requests return once AppKit accepts the
transition. Scale changes are applied by the layer until Lisp redraws.
Accessibility discovery uses AppKit window state, and content queries follow
04. A window prototype extending 04's decides the design.

A cheaper agent inventoried window and redisplay code; the parent verified the
cited sites. No application code changed and no GUI tests were run.
