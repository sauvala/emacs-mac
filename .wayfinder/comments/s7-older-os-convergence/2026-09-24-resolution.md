# S7 older macOS versions resolution

Closed on 2026-09-24 by the user's explicit decision: "we can drop
support for older macos versions".

No other OS was validated (runtime validation was on macOS 27 only, by
the user's earlier decision against VMs and Intel hardware). Older
systems are dropped rather than flipped: the nemesis branch supports
macOS 27 and later only, as stated in README.md and AGENTS.md. The
build floor was not raised; code for older systems outside the event
loop, windows and menus was left as it was, and is unverified.
