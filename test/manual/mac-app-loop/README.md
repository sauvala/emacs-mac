# mac-app-loop S0 evidence kit

Stage S0 of the persistent event loop project
(`.wayfinder/issues/08-s0-instrumentation.md`). S0 makes **no behavior
change** to the mac port: it adds measurement, tracing and fixtures so later
stages can be evaluated against the acceptance contract in
[`../../../.wayfinder/comments/native-behavior/2026-09-23-discussion.md`](../../../.wayfinder/comments/native-behavior/2026-09-23-discussion.md)
and the migration plan's M9/M10 in
[`../../../.wayfinder/comments/migration-plan/2026-09-23-discussion.md`](../../../.wayfinder/comments/migration-plan/2026-09-23-discussion.md).

Scripted checks here are a starting point, not a substitute. Per M10, a
human signs off each OS acceptance run; the acceptance contract requires
real interactions (actual menu commands, actual drags, actual Close/Quit
clicks), which cannot be automated from outside AppKit's tracking loops.

## Files

- `fixture.el` — Lisp fixture loaded into the target Emacs process. No
  external packages; byte-compiles cleanly. Key entry points:
  - `mac-app-loop-start` — call once (e.g. `-l fixture.el -f mac-app-loop-start`).
    Logs a `SESSION-START` line (Emacs version, `system-configuration`,
    `EMACS_MAC_PERSISTENT_LOOP`, `window-system`, display pixel size),
    installs the logging hooks, and starts the heartbeat.
  - `mac-app-loop-busy SECONDS` — pure-Lisp CPU loop, never calls
    `sit-for`/`sleep-for`/`accept-process-output`; C-g still interrupts it
    (ordinary Lisp, so `maybe_quit` runs at normal check points).
  - `mac-app-loop-busy-no-quit SECONDS` — same, wrapped in `inhibit-quit`;
    a quit received during the loop is deferred and logged as
    `BUSY-NOQUIT-INTERRUPTED`.
  - `mac-app-loop-heartbeat-start` / `-stop` — 0.1s repeating timer; each
    tick logs the actual gap since the previous tick, so a stall shows up
    as an outsized `gap=` value.
  - `mac-app-loop-key-latency-mode` — global minor mode; for mouse clicks,
    logs the difference between arrival time and the event's
    `posn-timestamp` (a relative diagnostic only — that timestamp is not
    wall-clock/epoch time); for key events, logs arrival time only (key
    events carry no timestamp).
  - `mac-app-loop-setup-test-buffers` — a plain buffer plus a modified,
    unsaved file-visiting buffer under a fresh temp directory, for
    close/quit save-prompt scenarios.
  - `mac-app-loop-gui-heartbeat-start` — started by `mac-app-loop-start`
    on builds with `mac-loop-test-schedule`: a 5 ms GUI-thread heartbeat
    whose gaps measure GUI stalls independently of Lisp. Call it again to
    reset before a measured step.
  - `mac-app-loop-report` — summarizes the log (line/command/frame-size
    counts, max heartbeat gap, and the GUI heartbeat's max gap and gaps
    over 100 ms, also logged as `GUI-GAPS`) into `*mac-app-loop-report*`.
  - Logs to the file named by `MAC_APP_LOOP_LOG` (default
    `/tmp/mac-app-loop.log`); one line per event: `TIMESTAMP<TAB>TAG<TAB>DATA`.

  Verified with the installed `/Applications/Emacs.app`:
  `Emacs -Q --batch -f batch-byte-compile fixture.el` compiles with no
  warnings (the `.elc` is not kept in the repo — delete it after checking).

- `fixture-tests.el` — ERT tests for the pure helpers (log line
  format/parse round-trip, malformed-line handling, log summarizing over a
  synthetic log, plus a short bounded check that the busy loop actually
  spins). Runs in plain `--batch` mode, no GUI, no real files:

  ```sh
  /Applications/Emacs.app/Contents/MacOS/Emacs -Q --batch \
    -l test/manual/mac-app-loop/fixture-tests.el \
    -f ert-run-tests-batch-and-exit
  ```

  All 9 tests pass as of this writing; compiles with no warnings.

- `run.sh` — launches a built `Emacs.app` bundle with the fixture loaded,
  in either loop mode:

  ```sh
  test/manual/mac-app-loop/run.sh old   # EMACS_MAC_PERSISTENT_LOOP=0 (default)
  test/manual/mac-app-loop/run.sh new   # EMACS_MAC_PERSISTENT_LOOP=1
  test/manual/mac-app-loop/run.sh new --eval '(mac-app-loop-setup-test-buffers)'
  ```

  Always sets `EMACS_MAC_TRACE_LOOP=1` (for the C-side `mac-loop:` traces
  added separately) and a fresh `MAC_APP_LOOP_LOG` under
  `${TMPDIR:-/tmp}/mac-app-loop/<timestamp>-<mode>.log`, with the process's
  stderr captured alongside it as `<same>.stderr`. Prints both paths before
  launching. Defaults to `$REPO/mac/Emacs.app`; override with `EMACS_APP`.
  Sets `EMACSLOADPATH` to the checkout's `lisp` directory automatically when
  the bundle lacks `Contents/Resources/lisp` (see AGENTS.md's note on this).

  Verified end-to-end against `/Applications/Emacs.app` in both modes
  (`EMACS_APP=/Applications/Emacs.app run.sh old --eval '(kill-emacs)'` and
  the `new` equivalent): each run produced a `SESSION-START` line with the
  correct `EMACS_MAC_PERSISTENT_LOOP` value, a `FRAME-SIZE` line for the
  initial frame, and a `KILL-EMACS` line, with an empty stderr log.

- `windows.py` — Python 3, standard library only. Lists the target
  process's windows (name, position, size, `AXMinimized`) via
  `osascript`/System Events, as JSON:

  ```sh
  test/manual/mac-app-loop/windows.py          # defaults to process "Emacs"
  test/manual/mac-app-loop/windows.py Emacs
  ```

  Reports a clear error, distinct from "process not found", when System
  Events reports no assistive-access permission. Read-only: it never
  clicks, moves, or resizes anything.

  Verified: the AppleScript-record parser round-trips a synthetic two
  -window sample and an empty list; `no such process` is reported cleanly.
  A live run against a real process (`Finder`) hit an AppleEvent timeout in
  this non-interactive session rather than completing or reporting a clean
  permission error — likely this sandboxed session cannot satisfy or
  present the Accessibility permission prompt. **Unverified**: a live run
  against a real Emacs process with Accessibility permission actually
  granted in the interactive session that will do the acceptance runs.

## Evidence records

One Markdown file per run under `evidence/`, named
`YYYY-MM-DD-<os>-<mode>-<topic>.md` (e.g.
`2026-09-23-macos27-old-baseline.md`). Fields, following the acceptance
contract and migration plan M9:

| Field | Notes |
| --- | --- |
| Source revision | commit hash |
| OS version/build | e.g. macOS 27.0 (26A428) |
| Hardware/CPU | e.g. Apple M2 |
| SDK | SDK used to build |
| Deployment target | `MACOSX_DEPLOYMENT_TARGET` / configure setting |
| Renderer | CG (default) or Metal |
| Configure flags | full `./configure` invocation |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP`, `EMACS_MAC_TRACE_LOOP`, any menu-path flags in effect |
| Lisp state | idle / busy (`mac-app-loop-busy`) / busy-no-quit / input-wait / minibuffer / multi-thread / delayed-quit |
| Scenario | one row from the table below |
| Steps | what was actually done, in order |
| Timings | measured values against the 100ms response / 250ms stall / 250ms catch-up targets, and OS animation time vs. Lisp work time kept separate |
| Observed outcome | what actually happened, in enough detail to reproduce |
| Pass/fail/unverified | never "pass" for a case that could not be exercised |
| Notes | anything else relevant, including tool/environment limitations |

"Unverified" and "not applicable" are both distinct from "pass" — mark
unavailable cases unverified per the acceptance contract; do not silently
drop coverage.

### Scenario checklist (copy into an evidence record)

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

Exercise each scenario under multiple Lisp states where relevant (idle,
`mac-app-loop-busy` running, `mac-app-loop-busy-no-quit` running, a
minibuffer prompt open, multiple Lisp threads, delayed-quit) — a running
heartbeat/worker alone does not demonstrate behavior when Lisp cannot
service GUI requests.

### What scripted checks do and do not cover

`run.sh` + `fixture.el` give: precise timing of commands/frame-size/focus
events, a genuinely non-yielding busy workload, and heartbeat-gap evidence
of stalls. `windows.py` gives: scripted window discovery/geometry/minimized
-state checks, useful for the accessibility scenario's non-interactive
half. Neither substitutes for actually dragging a window edge, opening a
real menu, or clicking Close/Quit — those require a human at the acceptance
gate, per M10.
