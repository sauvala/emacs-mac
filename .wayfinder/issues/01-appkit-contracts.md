---
id: appkit-contracts
title: Establish documented AppKit lifecycle and tracking contracts
status: open
labels: ["wayfinder:research"]
parent: macos-app-integration
assignee: janne
---

## Question

Which documented AppKit contracts constrain a continuously running main-thread
application loop with Lisp on a separate thread, especially during native
tracking, modal interactions, dynamic menus, cancellation, and live resize?
Identify documented integration mechanisms, version availability, and facts
that documentation cannot establish without a prototype. Explain which current
workarounds these contracts might replace without claiming that replacement is proven.

## Blocked by

None.

## Research context

Claimed for Janne by the AppKit research agent on 2026-09-23.
Branch: `research/appkit-contracts`.
Worktree: `/Users/janne/Projects/emacs-mac-wayfinder-appkit`.
Expected asset: `.wayfinder/research/appkit-contracts.md`.
Base: `1b08291ec0350cec8fbd1447fe869185f486097d`.
