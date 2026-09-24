# Interactive acceptance, persistent loop (macOS 27), first pass

| Field | Value |
| --- | --- |
| Source revision | `6847108c06a` (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Deployment target | configure default |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | `--with-metal-rendering --with-native-compilation --with-tree-sitter --enable-mac-app=yes --enable-mac-self-contained --with-rope --with-mailutils 'CFLAGS=-O2 -mcpu=native -fobjc-arc'` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=1`, `EMACS_MAC_TRACE_LOOP=1` (via `run.sh new`); no menu flags |
| Lisp state | idle, and busy via `(mac-app-loop-busy 10)` |
| Tester | the user, with real mouse and keyboard input |
| Pass/fail/unverified | see table |

The user reported the results as a summary ("everything looks like it
works") rather than per step. Timings were not measured, and there were no
screenshots. Each row below records the user's report of the checklist item
they were given.

| Scenario | Observed outcome | Result |
| --- | --- | --- |
| Edge and corner drags, idle and busy | Worked, per the user's summary | pass (user report) |
| Menu bar with the mouse, idle and busy, including nested submenus | Worked | pass (user report) |
| Control-F2 menu-bar keyboard navigation | Worked | pass (user report) |
| F10 while idle | Opens the popup | pass (user report) |
| F10 while busy | No popup while `mac-app-loop-busy` runs. This is expected under D9: F10 is an ordinary key bound to `menu-bar-open` and waits for Lisp to read it. Control-F2 and the mouse open the native menu bar without Lisp. The user has not reported whether the popup appeared after the busy loop ended. | expected; follow-up unverified |
| C-g and Escape with a menu open (D15) | Worked | pass (user report) |
| Selection, then buffer switch while busy (D5) | Worked | pass (user report) |
| Services send and Help search | Worked | pass (user report) |
| Quit with an unsaved buffer, repeated clicks while busy | Worked | pass (user report) |
| Dock reopen and opening a file from Finder | Worked | pass (user report) |
| Accessibility discovery (`windows.py`) | Not run; there was no time | unverified |

## Follow-ups

- Confirm that a busy-time F10 opens the popup once Lisp is idle again.
- Run `windows.py` with Accessibility permission, idle and busy.
- Repeat with measured timings against the 100 ms response and 250 ms
  stall targets before S6.
