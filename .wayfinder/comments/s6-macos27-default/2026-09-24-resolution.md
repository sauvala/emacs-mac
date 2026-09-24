# S6 macOS 27 default resolution

Closed on 2026-09-24 by the user's live decision: "lets make the new
loop the default and remove the old loop".

The acceptance gate asked for the full acceptance scenario table under
idle, busy, minibuffer, multi-thread and delayed-quit Lisp states plus
one week of daily use on macOS 27 before flipping. The user waived the
week of daily use; they had run the new loop as their daily build since
2026-09-24. The scripted scenario table (29 scenarios) passed on the
new loop that day, and S3, S4, S5 and tickets 17 and 18 had their
interactive checks. Instead of flipping a per-OS default, S8 made the
new loop the only loop (commit c31bd2ca898), so the M7 rollback by
environment variable no longer exists; rollback is a revert.
