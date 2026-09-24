# Synchronous live-resize presentation (ticket 18), scripted (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | the commit that adds this file (branch `transactional-resize`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=1`, `EMACS_MAC_RESIZE_WAIT_MS` 0 or default (30), `EMACS_MAC_TRACE_LOOP=1` for step counts |
| Lisp state | idle (drag), busy (scenario list) |
| Scenario | `resize-band.sh`; the user's own init with an 8 ms-step drag; full default scenario list, both loops |
| Pass/fail/unverified | scripted: pass; real hand drags: **unverified** |

## Undrawn band at the growing edge (`resize-band.sh`)

| Wait | Frames | Frames with band > 4 px | Widest band |
| --- | --- | --- | --- |
| 0 (asynchronous presentation) | 175 | 62 | 70 px |
| 30 ms (default) | 179 | 0 | 0 px |

Before steps waited for Lisp to reach its input wait again (see below),
the same drag with a 20 ms wait still had 31 of 167 frames with a band
of up to 46 px: 175 of 208 steps found Lisp finishing the previous
step's redisplay and were deferred.

## Step statistics (trace)

| Setup | Steps with access | Deferred | Presented | Missed | Wait median / p90 / max |
| --- | --- | --- | --- | --- | --- |
| `-Q`, `resize-band.el`, 20 ms wait | 80 | 0 | 79 | 1 | 10.5 / - / 21.0 ms |
| user init (17 pt font, `perfect-margin-mode`), 20 ms wait | 119 | 0 | 118 | 1 | 15.3 / 17.9 / 33.0 ms |

The default wait became 30 ms because the user's configuration needed
up to 18 ms at the 90th percentile.

## Regressions checked

- Blank frames (`fb6cb18a20f` check, 8 ms-step drag, 3 runs): 0.
- Full default scenario list, both loops: all complete; new-loop GUI
  gaps match the earlier evidence except `busy-native` and
  `stress-requests` (590-669 ms, earlier 357-361 ms).  Those are the
  zoom animation and are unchanged with `EMACS_MAC_RESIZE_WAIT_MS=0`
  (606-669 ms) and with the sources of `abbc8807115`, before the
  Metal resize commits (590-622 ms), so the machine state differs from
  the earlier recording, not the code.
- `fullscreen-idle`: fullscreen transitions send live-resize
  notifications; waiting there raised the GUI gap to 113-126 ms.
  Synchronous presentation is skipped during fullscreen transitions,
  which restored 72-95 ms (earlier 76-99 ms).
