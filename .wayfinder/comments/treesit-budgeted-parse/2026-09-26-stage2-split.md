# Decision: split stage 2 into a parse cap and deferred idle slices

2026-09-26, agreed with the user.

Stage 1 showed that reparses are almost never slow in the user's
editing: none above 3 ms live, and 0.05% of replayed edits in the user's
files. Large repositories reach 8 ms in 0.65% of edits, at most 48 ms.
The one harmful case was the 596 s hang caused by an old TypeScript
grammar.

Other editors all bound parse time: Zed moves slow parses to a thread,
Neovim continues them in slices, and Helix gives up after a timeout.
Upstream Emacs has no bound. For Emacs, the bound is what protects
against a freeze, while slicing only smooths rare hitches, and slicing
carries the risk: stale trees, deferred jit-lock chunks and waiters.

So stage 2 (ticket 27) is now only the hard cap: halt a parse past a
limit, keep the old tree, give up on that parser until the user retries.
Budgeting and idle slices become stage 2b (ticket 28), started only if
the stage 1 stats or the user's experience call for it, with the same
threshold as the worker-stage gate. Tickets 22 and 23 stay valid for 2b.
