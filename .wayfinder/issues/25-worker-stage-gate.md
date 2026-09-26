---
id: worker-stage-gate
title: "Gate for building the worker-thread stage"
status: open
labels: ["wayfinder:grilling"]
parent: treesit-budgeted-parse
assignee: claude
---

## Question

State the measured condition under which the worker-thread stage is built after stage two ships. For example: the largest keystroke latency in the latency scenarios, the number of restarts under continuous typing, or first-parse time. Also state what to do if the condition is not met: close the map with stage two as the end state.

## Blocked by

- [Tree-sitter latency scenarios for the benchmark harness](21-ts-latency-scenarios.md)
- [How a halted parse continues on the Lisp thread](23-idle-slice-continuation.md)
