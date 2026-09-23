# Native behavior discussion

Status: all nine choices answered; assembled contract awaits final user review.
This records user answers, not a ticket resolution.

## Agreed behavior

- Native resize, zoom and fullscreen must keep responding while Lisp is busy.
  Editor content may remain stale until Lisp can redraw. Presentation must not
  expose corrupt or uninitialized pixels; final geometry and content must
  converge after Lisp resumes.
- Open the last valid cached menu immediately when Lisp cannot prepare a fresh
  menu. Disable entries whose validity cannot be established. Revalidate the
  selected command when Lisp can execute it. With no valid menu, show a
  dismissible unavailable/loading state.
- Close and Quit receive immediate visible acknowledgment, then wait for Lisp
  to run existing save prompts and hooks. Do not implicitly interrupt Lisp.
- The first C-g during menu tracking dismisses the menu only. A subsequent C-g
  requests Lisp interruption under existing safe-point and inhibit-quit rules.
- On a reference machine under controlled load, target native input response
  or acknowledgment within 100 ms. Any app-caused stall over 250 ms fails
  acceptance. After Lisp becomes available, target visible catch-up within
  250 ms for a small test buffer. Measure OS animation duration and expensive
  Lisp commands separately. These are agreed targets, not demonstrated results.
- Bind queued menu commands to their original buffer/frame context and
  revalidate before execution. If that context is gone or the action is no
  longer valid, reject with feedback. Never silently retarget to the newly
  selected buffer or execute a request twice. Repeated close clicks on a frame
  represent one pending close; repeated Quit clicks represent one pending Quit.
- Preserve the declared OS X 10.10 support floor. Start runtime validation on
  macOS 27 and require runtime evidence for each supported major OS before
  retiring its legacy path. Cover Intel and Apple silicon where supported,
  ordinary rendering and optional Metal on supported versions, and compiled
  defaults and opt-in launches. Untested versions retain their existing path
  and remain explicitly unverified.
- Preserve existing Emacs configuration, hooks, and daemon/non-daemon
  semantics for startup, Dock reopen, last-frame close, and Quit. Preserve
  save/cancel behavior while providing responsive native feedback. Reject
  duplicate frames, lost open-file requests, and stranded processes as
  acceptance failures. Do not introduce an always-running application policy.
- Ordinary editor windows remain discoverable through accessibility and
  window-manager automation while Lisp is idle or busy, with correct identity,
  title, geometry, and minimized state. Focus, move, resize, and
  minimize/restore respond without waiting for Lisp. Automated close follows
  the deferred save/hook contract. Cover fullscreen, Spaces, and mixed-scale
  displays. Full editor accessibility remains outside this effort.

## Acceptance scenarios

Use fresh GUI processes for each candidate configuration. Exercise the relevant
scenarios under idle Lisp, long-running Lisp computation, input waits and
minibuffers, multiple Lisp threads, and delayed quit handling. A running worker
or heartbeat alone does not demonstrate behavior when Lisp cannot service GUI
requests.

| Scenario | Required observable result |
| --- | --- |
| Continuous edge/corner drags and rapid reversals | Native movement continues within the response limits; stale editor content is allowed, corrupt or uninitialized pixels are not; final geometry and redisplay converge after Lisp resumes. |
| Minimize/Dock restore, zoom, fullscreen, close | Exercise actual controls, including after menu use. Native operations respond while Lisp is busy; close acknowledges and waits for save prompts/hooks. |
| Mouse and keyboard menu use | Cached-menu policy holds; unavailable content is dismissible. Verify actual command execution, including Help interactions and Services commands, not merely submenu display. |
| Nested menus, Escape and C-g, cancellation during preparation/retry | Menus dismiss without an unintended command or surprise reopening; subsequent menus and ordinary input work. Menu C-g does not also interrupt Lisp. Cover configured quit-key recognition. |
| Selection followed by buffer/frame changes, menu replacement and GC | A request executes at most once in its original valid context, or is rejected with feedback. It never targets a newly selected context silently or refers to reclaimed objects. |
| Close/Quit while busy, with unsaved work and repeated clicks | Native acknowledgment is prompt; prompts and hooks wait for Lisp; save/cancel semantics remain intact; repeated requests do not duplicate prompts or destruction. |
| Fullscreen/Spaces and mixed-scale display transitions | Native transitions remain responsive, window identity/state remain coherent, and final geometry and editor presentation converge. |
| Accessibility/window-manager operations while idle and busy | Discover ordinary editor windows and verify identity, title, geometry and minimized state. Focus, move, resize and minimize/restore do not wait for Lisp; close follows the deferred contract. |
| Startup, file opening, Dock reopen, last-frame close, Quit | Preserve configured Emacs and daemon/non-daemon behavior; no duplicate frames, lost open-file requests, or stranded processes. Include pending menu actions and busy Lisp. |

## Evidence and compatibility requirements

- Record source revision, OS version/build, hardware/CPU, SDK, deployment
  target, renderer, configure flags, runtime flags, Lisp state, timing results,
  and actual command outcomes. Keep runtime coverage distinct from successful
  compilation or SDK availability.
- Validate macOS 27 first. Retirement of a legacy path requires runtime
  evidence on each supported major OS affected, with Intel/Apple silicon and
  renderer coverage where supported. Test compiled defaults and opt-in launches.
- Mark unavailable cases unverified and unsupported combinations not
  applicable. Neither is a pass. Unverified OS versions retain their existing
  path; support is not silently dropped.
- Use controlled-load reference runs to assess the agreed 100 ms native
  response target and 250 ms stall limit. Measure catch-up from Lisp becoming
  available, using a small test buffer, against the 250 ms target. Report OS
  animation time and expensive Lisp work separately.
- Existing historical GUI results and source-level checks do not replace
  fresh interactive evidence for the redesigned path.

## Handoff boundaries

This contract selects behavior, not an event-loop architecture. Later tickets
choose ownership and safe callback delivery, cached-menu validity and command
context representation, window/redisplay coordination and pending-action
feedback, then prototypes and migration/retirement gates. Their implementation
plans must specify the measurement fixture and exact compatibility runs needed
to demonstrate this contract.

## Evidence checked this session

The historical fixture records menu operation with a Lisp worker, minimize and
restore, continuous resize, and C-g dismissal. It does not establish native
responsiveness while Lisp cannot service GUI requests. Services execution,
nested menus, remapped quit keys, and cancellation during retry need coverage.
See [the fixture record](../../../test/manual/mac-menu/README.md).

A read-only review by a cheaper agent identified queued-action lifetime,
cancel/retry races, dirty-frame close, display transitions, accessibility
discovery, and startup/reopen/quit as acceptance gaps. The primary agent checked
the fixture and the current cancellation handler against these findings.
These observations are not new GUI test results.

## Final review

Awaiting user confirmation that the assembled contract captures the agreed
behavior. No application code changed and no new GUI validation was performed.
