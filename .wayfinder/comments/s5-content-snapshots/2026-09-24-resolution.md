# S5 resolution

Closed on 2026-09-24 with the user's live confirmation.

The user typed with Apple Pinyin in the development build under the
persistent loop while the agent set up idle and 20 s busy periods from
`emacsclient`. Composition in a buffer and in isearch worked while
idle, with the candidate window at the cursor or beside the echo area.
While Lisp was busy the candidate window still appeared at the last
published cursor position and the committed text arrived once, in
order, when the busy loop ended. See
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-ime.md`. The
scripted `text-idle` and `text-busy` scenarios pass in both loops
(`2026-09-24-macos27-both-s5-snapshots.md`). Implementation choices are
in the implementation notes of `../window-redisplay/2026-09-23-discussion.md`.

Deviations from the acceptance gate, accepted by the user:
- VoiceOver was not run; the user excluded it. Accessibility is covered
  by the scripted scenarios and by `windows.py` at window level (S3
  evidence), not by a screen reader reading buffer text.
- The old loop was not compared interactively. One early isearch
  attempt received raw letters, attributed to the input source not yet
  being active; a retry with Pinyin selected first was clean.
