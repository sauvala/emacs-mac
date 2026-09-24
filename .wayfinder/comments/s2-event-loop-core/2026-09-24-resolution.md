# S2 event-loop core resolution

Closed on 2026-09-24 at the user's request.

The ticket stayed open only for interactive acceptance. That was covered
by the later stages' interactive checks on macOS 27, all built on this
core: S3 windows and redisplay (agent-driven and hand-checked), S4 menus
and D3 open-time refresh (real menu-bar tracking, idle and busy), S5
input methods (real Pinyin input, idle and busy), and ticket 18's
hand-driven resizes. Scripted evidence, including try-lock grants
during the input wait, is in
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-both-scripted.md`.
The user has run the persistent loop as their daily build since
2026-09-24.
