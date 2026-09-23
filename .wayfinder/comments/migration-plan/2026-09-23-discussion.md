# Migration plan discussion

Status: open, awaiting user confirmation. Per the user's 2026-09-23
instruction, the agent adopted its recommended answers and documented them.
Every decision below is **agent-adopted, not yet user-confirmed**. The ticket
closes only with the user's live confirmation.

Inputs: the contract of [ticket 03](../native-behavior/2026-09-23-discussion.md),
and the decisions of [04](../event-loop-ownership/2026-09-23-discussion.md),
[05](../menu-callbacks/2026-09-23-discussion.md) and
[06](../window-redisplay/2026-09-23-discussion.md).

## Source and environment facts (verified by the parent agent)

A cheaper agent mapped the shared-file footprint; the parent checked the
load-bearing sites at `395af2c0eea`.

- About 45 `HAVE_MACGUI` sites already exist in shared files (`keyboard.c`,
  `xdisp.c`, `frame.c`, `emacs.c`, `menu.c`, `lisp.h`, `thread.c`,
  `process.c`, `atimer.c`, `dispnew.c`). `blockinput.h`, `sysselect.h` and
  `sysdep.c` have none.
- `thread.c:1229` already provides `thread_try_acquire_global_lock` and
  `thread_release_global_lock` under `HAVE_MACGUI`, used by
  `mac_try_buffer_and_glyph_matrix_access` (`src/macappkit.m:17642`).
  04's safe-point try-lock needs no new shared primitive.
- `thread_select` releases the global lock around the wait
  (`really_call_select`, `thread.c:612`). But `process.c:5859` calls
  `mac_select` directly, and with a single Lisp thread `mac_select` waits
  through a raw `pselect` on a GCD queue while the Lisp thread keeps the lock
  and services `mac_lisp_queue` blocks (`src/macappkit.m:17757`, `:17842`).
  **The current input wait does not release the lock in the common
  single-thread case.** The new loop must wait through `thread_select`
  unconditionally; this is a mac-only change.
- `kbd_buffer` has no lock; the GUI thread stores into it through
  `kbd_buffer_store_event_hold` (`src/macappkit.m:1547`) and relies on the
  semaphore handoff for exclusion. The new locked queue must be the only
  structure the GUI writes; only the Lisp thread moves records into
  `kbd_buffer`. This is also mac-only.
- `process_pending_signals` already returns early on the GUI thread
  (`keyboard.c:8457`).
- `--enable-mac-native-menus` sits at `configure.ac:696-701` with its guard
  and define at `:5670-5676`; a new launch-selection option fits beside it.
- Test host: Apple M2, macOS 27.0 (26A428), SDK 27.0, with UTM installed.
  Apple's Virtualization documentation supports macOS guests on Apple silicon
  starting with macOS 12 (restore-image API availability). Intel hardware
  and macOS 10.10-11 cannot be covered on this host.

## Decisions (agent-adopted)

- **M1. Stages.** Each stage is a reviewable series merged into `nemesis`
  with the new loop off by default, so `nemesis` stays usable throughout.
  1. **S0 Instrumentation and fixtures** (no behaviour change): response and
     acknowledgment timing, a busy-Lisp fixture that never waits for input,
     tracing of GUI-thread Lisp evaluation, Carbon queue access, synthetic
     events and preference registration, and an evidence-record template.
  2. **S1 Launch selector:** the configure option and environment variable of
     04, compiling both loops; the old loop stays the default and unchanged.
  3. **S2 Event-loop core (04's decisive prototype):** persistent run, locked
     input queue with GUI quit recognition, per-request delivery in both mode
     classes, the input wait through `thread_select`, safe-point try-lock.
     Menus stay on the old path; IME/accessibility snapshots are stubbed.
  4. **S3 Windows and redisplay (06):** single-owner fields, live resize and
     stale presentation, fullscreen records, close/Quit dedupe and indicator,
     preferences not registered.
  5. **S4 Menus and callbacks (05):** snapshots, generation table,
     revalidated actions, popup F10 and Control-F2, Services and Help data.
  6. **S5 Content snapshots:** IME and accessibility content under the
     safe-point rule, replacing the stubs.
  7. **S6 macOS 27 default:** the new loop becomes the compiled default on
     macOS 27+ only, with the environment variable selecting the old loop.
  8. **S7 Older-OS convergence:** per-OS default flips as evidence arrives.
  9. **S8 Removal:** old-loop code and its workarounds are deleted.
  *Why this order:* S2 is 04's decisive prototype and everything depends on
  it. S3 precedes S4 because 04 accepted the old menu path under the new loop
  during prototyping, while the headline macOS 27 resize failure and the
  preference removal live in S3.
- **M2. Gates.** A stage merges when its standalone checks pass and both
  loops build. It is *accepted* when its prototype criteria pass on macOS 27
  in fresh processes with evidence recorded: S2 as in 04, S3 as W15, S4 as
  D21, S5 as 03's IME/accessibility scenarios. S6 requires S2-S5 accepted
  plus one week of daily use on macOS 27 with no open regression, and the
  full 03 scenario table under idle, busy, minibuffer, multi-thread and
  delayed-quit Lisp states.
- **M3. macOS 27 first.** An opt-in on macOS 27+ is used (S1-S6). Opt-in is
  available on any OS from S1, as 04 decided, but only macOS 27 is gated
  first.
- **M4. Older-OS convergence.** Runtime evidence is gathered on macOS 26, 15,
  14 and 12 in UTM guests, in that order (26 carries the update-cycle
  preferences; 14 is the Metal floor; 12 is the virtualization floor), then
  13 when time allows. Each OS repeats the S6 scenario table, with the
  ordinary renderer and, where available, Metal. Metal inside a VM is
  unverified until a guest shows a Metal device; host-only Metal evidence is
  recorded as such. Each OS's default flips independently. macOS 10.10-11 and
  Intel stay on the old loop, marked unverified, until hardware is available.
  Support is not narrowed.
- **M5. Shared-code boundary.** New code lives in mac-only files
  (`src/mac*.{c,m,h}`, `lisp/term/mac-win.el`, `configure.ac` mac sections).
  Shared files may only receive narrowly guarded `HAVE_MACGUI` hooks beside
  existing ones; S2-S4 are expected to need none beyond the existing
  `thread.c` pair. Any new shared hook is listed in `AGENTS.md` under merge
  conflict resolution in the same change.
- **M6. Upstream sync.** After every weekly GNU master sync, build both loops
  and run the standalone checks (`rope`, `macmetal`, `wrap-cache`,
  `mac-menu`, and the new loop checks) before calling the merge done, as
  `AGENTS.md` already requires for the old loop. A sync that breaks only the
  new loop does not block the sync; it opens a fix before the next stage
  merges.
- **M7. Rollback.**
  - Any user can select the old loop at launch with the environment variable.
  - Reverting a default flip is a one-line configure default change per OS.
  - A crash, data loss, lost input, duplicated command or a hang in a
    defaulted OS reverts that OS's default immediately; a missed timing
    target reverts only if it exceeds the 250 ms stall limit.
  - Old-loop code is kept untouched until S8, so rollback never needs
    reconstruction.
- **M8. Workaround retirement.** Each item stops being used by the new loop
  in its stage, and is deleted from source only in S8.

  | Workaround | Replaced by | Leaves new loop | Deleted when |
  | --- | --- | --- | --- |
  | `NSEventConcurrentProcessingEnabled=NO`, `NSApplicationUpdateCycleEnabled=NO` (26+) | persistent run, no Carbon queue access (04, D8) | S3 | S8 |
  | `NSWindowResizeNeedsTrackingLoop=YES`, `NSControlPrefersGestureRecognizerTracking=NO` (27+) | single live-resize session (W2) | S3 | S8 |
  | Synthetic resize release/press (pre-27) | W2/W4 | S3 | S8, after each pre-27 OS flips |
  | Temporary `[NSApp run]` stop/start | persistent run | S2 | S8 |
  | Semaphore bridge, `mac_within_lisp*`, GUI-thread Lisp | per-request delivery, D1 | S2 (window kinds S3, menu kinds S4) | S8 |
  | Carbon menu-bar interception, replay, fake click | D8, D9 | S4 | S8 |
  | Native/worker menu retry, Help redirection, `mac_select_allow_lisp_evaluation` | D2, D3, D10 | S4 | S8, with `EMACS_MAC_NATIVE_MENUS`, `EMACS_MAC_WORKER_MENUS`, `--enable-mac-native-menus` |
  | GUI-thread `store_frame_param` during fullscreen | W6 records | S3 | S8 |
  | Accessibility `poll_suppress_count`/`inhibit-quit` heuristics | safe-point lock (W13) | S5 | S8 |
  | Raw `pselect` input wait holding the lock | `thread_select` | S2 | S8 |

  Every row's removal also requires that each OS still on the old loop has
  either flipped with evidence or been explicitly dropped by the user.
- **M9. Evidence.** Records live under `test/manual/mac-app-loop/` as one
  file per run, with the fields of 03 (revision, OS/build, hardware, SDK,
  deployment target, renderer, configure and runtime flags, Lisp state,
  timings, command outcomes). Unavailable cases are "unverified", never
  "pass".
- **M10. Automation.** Standalone C checks cover the input queue, generation
  table and snapshot lifetime (extending `test/manual/mac-menu/check.py`).
  Scripted GUI runs use the busy-Lisp fixture plus accessibility-driven
  input (System Events or an automation client) for window discovery,
  menu commands, drags and timing. A human signs off each OS acceptance run;
  scripted runs do not replace it, since 03 requires real interactions.
- **M11. Upstream coordination.** Nothing is sent to GNU Emacs. After S2 is
  accepted, the agent asks the user whether to share the design with the
  emacs-mac maintainer; no contact without explicit approval (04).
- **M12. Excluded or deferred.** Complete editor accessibility; private APIs
  outside event/window/menu/lifecycle; asynchronous Lisp-to-GUI requests and
  timeout-and-skip for modal callbacks (04 later hardening); macOS 10.10-11
  and Intel verification until hardware exists; Metal-in-VM coverage.
  Integration failures discovered during validation become new tickets under
  this map if they affect the destination, otherwise separate efforts.

## Open items for user review

- M4 relies on UTM guests; confirm which older OS images you are willing to
  install and whether any Intel Mac is available.
- M2's one-week daily-use requirement before S6 is a judgment call.
- M1 puts windows before menus; the opposite order is viable if menus under
  the persistent loop prove unusable during S2.
