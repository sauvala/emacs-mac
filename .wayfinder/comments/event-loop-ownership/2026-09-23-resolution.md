# Resolution

[Choose application event-loop ownership and Lisp scheduling](../../issues/04-event-loop-ownership.md)
resolved on 2026-09-23 with the user's live confirmation of the
[recorded decisions](2026-09-23-discussion.md).

The main thread runs a persistent `NSApplication.run` for the process lifetime;
Lisp keeps its own thread. The GUI never waits on Lisp without bound: it may
wait briefly (about 50 ms) at a safe point, defined as Lisp having released the
global lock, and otherwise answers from Lisp-published snapshots or reports
unavailable. Callbacks inside Lisp-initiated modal loops are the one documented
exception. Lisp-to-GUI requests stay synchronous, with per-request completion
and a mode class: presentation and geometry work in every mode, structural work
in default mode only. Input crosses a locked queue; the GUI records quit
requests atomically and never longjmps. Startup order and the Apple-event Quit
route are preserved.

Old and new loops ship in one binary, selected at launch, opt-in on any OS,
with the old loop the default until migration gates pass. A focused macOS 27
prototype with Lisp busy decides the ownership choice; menu and redisplay
prototypes belong to their tickets. Upstream PRs are comparison only.

A cheaper agent inventoried the GUI/Lisp boundary; the parent verified the
cited sites. No application code changed and no GUI tests were run.
