---
id: s7-older-os-convergence
title: "S7: Converge older macOS versions"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Gather runtime evidence on macOS 26, 15, 14 and 12 in UTM guests (then
13), with the ordinary renderer and Metal where a guest exposes it, and flip
each OS's default independently. Choose the guest images and any Intel
hardware when this ticket starts. macOS 10.10-11 and Intel stay on the old
loop, unverified, unless hardware becomes available.

## Acceptance gate

Each flipped OS has a recorded S6-equivalent run; unflipped OSes are listed
as unverified, never as passing.

## Decisions

- [Migration plan M4](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S6: Make the new loop the macOS 27 default](14-s6-macos27-default.md)
