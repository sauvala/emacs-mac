# Resolution

[Establish upstream direction and supported macOS baseline](../../issues/02-upstream-baseline.md)
resolved on 2026-09-23 by the delegated researcher and reviewed by the parent agent.

The [research report](../../research/upstream-baseline.md) establishes that
Lisp and GUI already use separate threads, with semaphore handoffs and temporary
application runs as the relevant architectural constraints. The published
titlebar proposal remains a workaround. A bounded public branch and PR survey
found no complete redesign to adopt; unpublished work may exist.

The repository declares Mac-port support from 10.10 through 26, with 27 work
already present. Experimental full Metal rendering separately requires 14+.
These declarations are not a verified test matrix. Preserve the declared lower
bound in planning unless the user explicitly changes it, and distinguish
runtime OS, renderer, CPU, SDK, deployment target, and linked dependencies.

Adjacent upstream accessibility/keymap and dispatch-starvation proposals feed
the callback and scheduling decisions. No fresh build or GUI tests were run.

Research commit: `74b80da0ce1` on `research/macos-upstream-baseline`.
