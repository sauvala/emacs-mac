# Resolution

[Establish documented AppKit lifecycle and tracking contracts](../../issues/01-appkit-contracts.md)
resolved on 2026-09-23 by the delegated researcher and reviewed by the parent agent.

The [research report](../../research/appkit-contracts.md) establishes documented
application-loop ownership, mode-sensitive message delivery, menu preparation
and cancellation, and live-resize constraints. Core candidate mechanisms predate
macOS 27. The evidence supports investigating continuous AppKit processing;
it does not select that architecture or prove the existing preferences can be removed.

Synchronous Lisp callback safety, nested-loop fairness, menu snapshot behavior,
and resize presentation still need design decisions and prototype evidence.
Those obligations feed the acceptance, ownership, menu, and window tickets.
No new prototype ticket is created yet because its decisive pass/fail contract
depends on those decisions.

Research commit: `b66b6abf276` on `research/appkit-contracts`.
Context7 and official Apple documentation were consulted successfully; no
interactive tests were performed.
