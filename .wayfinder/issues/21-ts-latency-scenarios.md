---
id: ts-latency-scenarios
title: "Tree-sitter latency scenarios for the benchmark harness"
status: open
labels: ["wayfinder:task"]
parent: treesit-budgeted-parse
assignee: null
---

## Question

Add repeatable GUI measurements to the harness (`test/src/mac-performance-benchmark.el` or `test/manual/redisplay-bench/`), with `jit-lock-defer-on-input` bound to nil and a check that faces were actually applied. Cover:

- a keystroke;
- a page scroll;
- typing `"` then deleting it;
- opening the file (first parse to fontified screen).

Run them in python-ts-mode and typescript-ts-mode on large and typical files, using files that exist on any macOS machine with Homebrew or files checked into `test/`. Record a baseline on the installed build. The gates in later tickets are stated against these numbers.

This is an AFK task; it unblocks the gate decision.

## Blocked by

None.
