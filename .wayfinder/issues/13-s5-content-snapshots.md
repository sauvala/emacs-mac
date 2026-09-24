---
id: s5-content-snapshots
title: "S5: Replace IME and accessibility stubs with safe content access"
status: closed
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Publish the IME cursor rectangle and marked/selected range at the end of
redisplay, and serve accessibility content queries under the safe-point lock
or as unavailable, replacing the `poll_suppress_count`/`inhibit-quit`
heuristics under the new loop.

## Acceptance gate

The IME and accessibility scenarios of the acceptance contract pass on
macOS 27 with Lisp idle and busy, with evidence recorded.

## Decisions

- [Event-loop decisions](../comments/event-loop-ownership/2026-09-23-discussion.md)
- [Window decisions W11, W13](../comments/window-redisplay/2026-09-23-discussion.md)
- [Acceptance contract](../comments/native-behavior/2026-09-23-discussion.md)

## Blocked by

- [S2: Build the persistent event-loop core](10-s2-event-loop-core.md)

## Progress (2026-09-24)

Stubbed as planned: on branch `app-loop` the NSTextInputClient and
accessibility queries return neutral values without Lisp access and
answer normally with it. Real snapshots are not started.

Later on 2026-09-24 (agent-adopted; see the implementation notes in the
window discussion):
- Lisp publishes a text snapshot per frame when the cursor of the
  frame's selected window or the echo area is drawn. It holds the
  selected range, visible range, character count, input overlay start
  and cursor rectangle.
- Content queries (buffer text, glyph matrices) run only at a safe
  point: Lisp in its input wait, with the lock taken by try-lock
  (`mac_try_content_access`). Access borrowed from a Lisp request no
  longer counts. The `poll_suppress_count`/`inhibit-quit` heuristics
  apply only to the old loop.
- Without a safe point, `selectedRange`, `markedRange`, the marked-text
  `firstRectForCharacterRange:` and the selected-range, character-count
  and visible-range attributes come from the snapshot. The role and
  AppKit's own attributes need no Lisp. Text is unavailable.
- Scripted evidence:
  `test/manual/mac-app-loop/evidence/2026-09-24-macos27-both-s5-snapshots.md`
  (`text-idle`, `text-busy`). That run also found and fixed an idle
  wakeup spin in the new loop.

Not done (needs the user at the Mac):
- A real input method while Lisp is busy: candidate window placement,
  and marked text in the echo area during isearch.
- VoiceOver or `windows.py` reading an editor window, idle and busy.

## Resolution (2026-09-24)

Closed with the user's confirmation after a real input-method check;
see [the resolution](../comments/s5-content-snapshots/2026-09-24-resolution.md).
