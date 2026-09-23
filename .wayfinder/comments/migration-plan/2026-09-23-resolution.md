# Resolution

[Decide migration stages and workaround retirement gates](../../issues/07-migration-plan.md)
resolved on 2026-09-23 with the user's live confirmation of the
[recorded decisions](2026-09-23-discussion.md).

Implementation proceeds in stages merged into `nemesis` with the new loop off
by default: S0 instrumentation and busy-Lisp fixtures, S1 launch selector, S2
event-loop core (04's decisive prototype), S3 windows and redisplay, S4 menus,
S5 IME and accessibility content, S6 macOS 27 default, S7 per-OS default
flips, S8 removal of the old loop. Each stage is accepted on macOS 27 against
its ticket's prototype criteria with recorded evidence. S6 also needs the full
03 scenario table and a week of daily use. Older systems are validated in UTM
guests (26, 15, 14, 12, then 13). macOS 10.10-11 and Intel remain on the old
loop, unverified, without narrowing support.

New code stays in mac-only files; the existing `thread.c` try-lock pair
suffices, and any new shared hook is documented in `AGENTS.md`. The new loop
must wait for input through `thread_select`, because the current
single-thread `mac_select` path holds the global lock. Rollback is by launch
environment variable and per-OS configure default. Each workaround leaves the
new loop in its stage and is deleted only in S8, after every affected OS has
flipped with evidence or been explicitly dropped.

A cheaper agent mapped the shared-file footprint; the parent verified the
load-bearing sites. No application code changed and no GUI tests were run.
