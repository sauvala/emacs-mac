---
id: s7-older-os-convergence
title: "S7: Converge older macOS versions"
status: closed
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

The user decided on 2026-09-23 not to validate in UTM or other virtual
machines or on Intel Macs; runtime validation uses macOS 27 on Apple
silicon only. Earlier systems keep the old
loop as their default, marked unverified, with the new loop available by
launch opt-in. This ticket has work only if the user later supplies evidence
for another OS (flipping that OS's default) or explicitly drops older
systems. Otherwise it closes with the user recording that decision.

## Acceptance gate

Each flipped OS has a recorded S6-equivalent run; unflipped OSes are listed
as unverified, never as passing. Closing without flips requires the user's
explicit decision on whether older systems keep the old loop or are dropped.

## Decisions

- [Migration plan M4](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S6: Make the new loop the macOS 27 default](14-s6-macos27-default.md)

## Resolution (2026-09-24)

Closed by the user's live decision: [resolution](../comments/s7-older-os-convergence/2026-09-24-resolution.md).
