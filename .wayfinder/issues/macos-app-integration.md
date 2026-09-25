---
id: macos-app-integration
title: Plan documented macOS application integration
status: closed
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
- Event-loop ownership (ticket 04), menu callbacks (05) and window/redisplay
  coordination (06) are selected, pending their prototypes. The migration
  plan (07) stages implementation from S0 instrumentation to S8 removal.
- Implementation stages S0-S8 are tracked as `wayfinder:task` children
  (tickets 08-16), created 2026-09-23 at the user's request. Tracking them
  here does not change the planning scope; each task's own work happens in
  later sessions.
- Follow-up tasks: 17 (D3 open-time menu refresh) and 18 (present
  live-resize frames with the window change, replacing the Metal
  presentation workarounds added after S3).

## Decisions so far

- [Establish documented AppKit lifecycle and tracking contracts](01-appkit-contracts.md): public mechanisms exist; callback safety and tracking responsiveness still require design and prototype evidence.
- [Establish upstream direction and supported macOS baseline](02-upstream-baseline.md): existing thread separation needs new coordination; preserve the declared 10.10 floor and distinguish it from renderer requirements and tested coverage.
- [Define native responsiveness and acceptance scenarios](03-native-behavior.md): native operations and menus respond while Lisp is busy, with deferred save/quit, context-bound single-execution commands, 100/250 ms targets, and per-OS runtime evidence before retiring legacy paths.
- [Choose application event-loop ownership and Lisp scheduling](04-event-loop-ownership.md): persistent `NSApplication.run` with Lisp on its own thread; the GUI never waits unbounded on Lisp, using safe-point lock acquisition or snapshots; synchronous mode-classed Lisp-to-GUI requests; launch-selected opt-in and a busy-Lisp macOS 27 prototype.
- [Choose menu preparation and GUI-to-Lisp callback contracts](05-menu-callbacks.md): no GUI-thread Lisp; published per-frame menu snapshots with bounded open-time refresh; revalidated at-most-once actions; Carbon interception and cancel/reopen retire under the new loop; F10 popup plus system Control-F2 navigation.
- [Choose window lifecycle and redisplay coordination](06-window-redisplay.md): single-owner window fields with GUI-applied geometry and coalesced records; Lisp draws during one live-resize session with safe stale presentation; synthetic events and event-loop preferences retire under the new loop; deduplicated close/Quit with a 100 ms waiting indicator.
- [Decide migration stages and workaround retirement gates](07-migration-plan.md): stages S0-S8 behind a launch selector with the old loop default; macOS 27 first; runtime validation on macOS 27 only (user revision: no VM testing), so earlier systems keep the old loop, unverified; mac-only code with no new shared hooks expected; env-var and per-OS default rollback; workarounds leave the new loop per stage and are deleted only in S8.
- [S0: Add loop instrumentation and busy-Lisp fixtures](08-s0-instrumentation.md): closed at the user's request; fixtures, traces and the old-loop baseline served S2-S5.
- [S1: Add the launch-selected event-loop option](09-s1-launch-selector.md): closed at the user's request; the selector chose each loop in fresh processes, and is removed in S8.
- [S2: Build the persistent event-loop core](10-s2-event-loop-core.md): closed at the user's request; its interactive acceptance was covered by the S3-S5 and ticket 18 checks.
- [S3: Move window lifecycle and redisplay to the new loop](11-s3-windows-redisplay.md): closed after agent-driven and hand-checked interactive macOS 27 checks; the mixed-scale display check was not applicable (single display).
- [S4: Move menus and callbacks to the new loop](12-s4-menus-callbacks.md): closed after interactive macOS 27 checks; D3's open-time refresh is deferred to [a follow-up](17-s4-open-time-refresh.md), with an idle-time deep fill standing in for it.
- [S4 follow-up: open-time submenu refresh (D3)](17-s4-open-time-refresh.md): closed after real menu-bar checks idle and busy on macOS 27; the idle-time deep fill stays for menus opened while Lisp is busy.
- [S3 follow-up: present live-resize frames with the window change](18-s3-transactional-resize.md): closed after the user's hand-driven resizes on macOS 27; idle steps wait up to 30 ms for Lisp's frame and present it in the resize transaction, and the asynchronous-path workarounds stay for other resizes.
- [S6: Make the new loop the macOS 27 default](14-s6-macos27-default.md): closed by the user's decision; the week of daily use was waived and S8 made the new loop the only loop.
- [S7: Converge older macOS versions](15-s7-older-os-convergence.md): closed by the user's decision to drop macOS versions before 27.
- [S5: Replace IME and accessibility stubs with safe content access](13-s5-content-snapshots.md): closed after a real input-method check (Pinyin) idle and busy on macOS 27; VoiceOver was not run (user excluded it).
- [S8: Remove the old loop and its workarounds](16-s8-old-loop-removal.md): closed after the user's check of the installed build; a tab-bar mouse race under a transparent titlebar, found then, was fixed first.
- Map closed 2026-09-25: [resolution](../comments/macos-app-integration/2026-09-25-resolution.md).

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
