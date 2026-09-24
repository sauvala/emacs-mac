# S0 instrumentation resolution

Closed on 2026-09-24 at the user's request, after the later stages had
been built and checked with this instrumentation.

- The fixture, traces and scripted scenarios live in
  `test/manual/mac-app-loop/` and ran on macOS 27 throughout S2-S5.
- The unchanged old loop's baseline is the `loop=0` half of
  `test/manual/mac-app-loop/evidence/2026-09-24-macos27-both-scripted.md`.
- Both configurations (old loop default and the persistent loop) built
  and ran the full scenario list on both loops.

The ticket was not closed when the work was done; nothing was missing
from its gate.
