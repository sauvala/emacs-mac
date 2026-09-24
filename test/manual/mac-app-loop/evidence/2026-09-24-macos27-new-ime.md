# Real input method, idle and busy, new loop (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | `635d52a4b61` (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2, built-in Retina display only |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `run.sh new` (`EMACS_MAC_PERSISTENT_LOOP=1`, `EMACS_MAC_TRACE_LOOP=1`), `-Q`, fixture loaded, server `loopcheck` |
| Input method | Apple Pinyin (Simplified Chinese) |
| Lisp state | idle, and `mac-app-loop-busy` for 20 s, started from `emacsclient` |
| Scenario | ticket 13 input-method gap: composition in a buffer and in isearch, candidate window placement |
| Pass/fail/unverified | pass; VoiceOver: **not run** (excluded by the user) |

The user typed; the agent set up busy periods and read the fixture log,
the loop trace and `search-ring` through `emacsclient`.

## Results

| Check | Result |
| --- | --- |
| Idle, buffer | marked pinyin shown at the cursor, candidate window at the cursor; the chosen characters were inserted (`就哦哦`, and earlier `哦几节课空空的 地方i蛋糕 建瓯`) |
| Idle, isearch | marked text in the echo area, candidate window beside it; committing 就 gave one `isearch-printing-char` with 23601 (U+5C31), the cursor moved to 就, and `search-ring` held `"就"` after `RET` |
| Busy (20 s), buffer | candidate window appeared at the last published cursor position while Lisp was busy; no hang; after `BUSY-END` the queued click and the committed `就哦哦` arrived in order, once each |
| Busy, isearch | `C-s` typed during the busy period is queued with other input, so isearch starts only after `BUSY-END` (expected: no Lisp runs while busy) |
| Loop report | GUI max gap 168 ms, 2 gaps over 100 ms (116 and 168 ms); Lisp heartbeat max gap 20.0 s (the busy loop) |

While Lisp was busy, text-input queries were answered from the text
snapshot (`content query during a request: unavailable` in the trace,
followed by snapshot answers); no query read buffer text without Lisp
access.

An earlier idle isearch attempt produced plain `j`, `o`, `o` as
isearch characters (`search-ring` `"joo"`). On retry, with Pinyin
selected before `C-s`, only the composed character arrived. The raw
letters are attributed to the input source not yet being active for
those keystrokes, not to the loop; the old loop was not compared.

Logs: `$TMPDIR/mac-app-loop/20260924T170440Z-new.{log,stderr}`.
