---
id: stage1-parse-instrumentation
title: "Stage 1: time every tree-sitter parse"
status: open
labels: ["wayfinder:task"]
parent: treesit-budgeted-parse
assignee: null
---

## Scope

Switch `treesit_ensure_parsed` to `ts_parser_parse_with_options` (optional load, with fallback) and give it a progress callback that never halts. Record parse counts, time and how often a parse would exceed a budget, exposed as a stats function like the Metal stats. Behaviour does not change.

## Acceptance gate

- The tree-sitter ERT suite passes.
- The latency scenarios show no regression.
- Stats from a day of the user's normal editing show how often parses exceed 1, 3 and 8 ms.

## Blocked by

- [Tree-sitter halt and resume contract](19-ts-halt-resume-contract.md)
- [Keep the change small in upstream files](24-sync-surface-containment.md)
