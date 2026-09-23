# Resolution

[Define native responsiveness and acceptance scenarios](../../issues/03-native-behavior.md)
resolved on 2026-09-23 with the user's live confirmation of the assembled
[acceptance contract](2026-09-23-discussion.md).

Native window operations and menu opening respond without waiting for Lisp;
editor content may be stale but never corrupt, and converges once Lisp resumes.
Menus fall back to the last valid cached menu with unverifiable entries
disabled. Close and Quit acknowledge immediately, then defer to existing save
prompts and hooks. Queued commands keep their original context and execute at
most once or are rejected with feedback. The first C-g in a menu only dismisses
it. Targets are 100 ms native response, a 250 ms stall failure limit, and
250 ms catch-up on a small buffer; they are not yet demonstrated.

The 10.10 support floor is preserved. Validation starts on macOS 27, and a
legacy path is retired only with runtime evidence for each affected OS, CPU,
and renderer. Startup, reopen, last-frame close, Quit, and daemon semantics are
preserved. Window discovery and automation must work while Lisp is busy.

The contract selects behavior, not architecture. No application code changed
and no GUI tests were run.
