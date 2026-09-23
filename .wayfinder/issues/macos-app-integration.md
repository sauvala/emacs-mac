---
id: macos-app-integration
title: Plan documented macOS application integration
status: open
labels: ["wayfinder:map"]
parent: null
assignee: null
---

## Destination

An implementation-ready architecture and migration plan for documented AppKit
integration of the event loop, windows, and menus. The plan must preserve native
responsiveness while Lisp is busy and ultimately cover every supported macOS
version, with explicit validation and retirement criteria for existing workarounds.

## Notes

- Planning only. Implementing the refactoring belongs to subsequent work.
- User-set scope, 2026-09-23: a macOS 27+ opt-in rollout is allowed if useful;
  the final target includes all supported OS versions. Retain existing
  workarounds until replacements pass interactive tests.
- Include resize, close/minimize/zoom/fullscreen, menus, quit handling,
  accessibility window discovery, window-manager automation, multiple displays,
  and application lifecycle. Distinguish immediate native feedback from actions
  whose completion requires Lisp.
- Use wayfinder, grilling, domain-modeling, and unslop. Research uses the
  research skill; API documentation uses find-docs and Context7 as required by
  AGENTS.md, with primary Apple documentation for verification.
- Fork-local work on nemesis; no GNU Emacs submissions. Local Markdown tracker
  operations are in [the tracker guide](../README.md).
- Source baseline: `1b08291ec0350cec8fbd1447fe869185f486097d`.
  The [initial audit](../research/initial-audit.md) is source inspection plus
  recorded historical tests, not a fresh GUI validation.
- Event-loop ownership is selected (ticket 04), pending its decisive prototype.

## Decisions so far

- [Establish documented AppKit lifecycle and tracking contracts](01-appkit-contracts.md): public mechanisms exist; callback safety and tracking responsiveness still require design and prototype evidence.
- [Establish upstream direction and supported macOS baseline](02-upstream-baseline.md): existing thread separation needs new coordination; preserve the declared 10.10 floor and distinguish it from renderer requirements and tested coverage.
- [Define native responsiveness and acceptance scenarios](03-native-behavior.md): native operations and menus respond while Lisp is busy, with deferred save/quit, context-bound single-execution commands, 100/250 ms targets, and per-OS runtime evidence before retiring legacy paths.
- [Choose application event-loop ownership and Lisp scheduling](04-event-loop-ownership.md): persistent `NSApplication.run` with Lisp on its own thread; the GUI never waits unbounded on Lisp, using safe-point lock acquisition or snapshots; synchronous mode-classed Lisp-to-GUI requests; launch-selected opt-in and a busy-Lisp macOS 27 prototype.

## Not yet specified

- Additional migration stages and prototypes exposed by the selected ownership
  and callback contracts.
- Further compatibility exceptions revealed by testing older supported systems.
- Newly discovered integration failures during validation, and whether they
  affect the destination or require separate efforts.

## Out of scope

- Implementing or shipping the redesign during this planning effort.
- A complete accessibility audit beyond window discovery and automation checks.
- Removing every private API elsewhere in the port; this effort covers event,
  window, menu, and application lifecycle integration.
- Replacing the mac port with the NS port or redesigning the editor's UI.
- Sending generated contributions to GNU Emacs.
