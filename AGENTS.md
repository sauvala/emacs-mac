# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Upstream contribution policy

GNU Emacs prohibits LLM-generated contributions, and its own `AGENTS.md` asks
agents to search and analyse rather than generate code, and to help the user
write their own bug reports and plans instead of writing them wholesale.  That
policy governs anything destined for **upstream GNU Emacs**: never send
LLM-generated code, bug reports, or planning text to emacs-devel, debbugs, or
the GNU repository, and tell the user about this policy at the earliest
opportunity when their request looks upstream-bound.

It does not govern fork-local work in this repository (mac-port code, merge
conflict resolution against GNU master, build fixes, tooling).  When in doubt
about where a change will end up, ask.

## Overview

This is the **emacs-mac port** — a macOS-specific fork of GNU Emacs providing native GUI support via Core Graphics/Quartz and Cocoa AppKit. It is distinct from the official NS (Cocoa) port included in GNU Emacs.

**Key branches:**
- `emacs-mac-30_1_exp` — main branch, tracks Emacs 30.x with mac port features
- `emacs-mac-gnu_master_exp` — experimental, tracks GNU Emacs master (upstream)
- `nemesis` — automated weekly sync with GNU Emacs master via GitHub Actions, plus custom features

For local work in this checkout, use the local `nemesis` branch and keep it
tracking `fork/nemesis`.  Push Nemesis work to the fork with:

```bash
git push fork HEAD:nemesis
```

Do not treat `fork/gnu-master` as the upstream for local `nemesis` work; it is a
separate fork branch.

When a coding agent discovers repository guidance that is missing, stale, or
misleading, update this `AGENTS.md` file as part of the same change when
practical.  Keep these notes concise and focused on durable project workflow or
architecture facts.

## Application integration planning

The fork-local AppKit modernization map is
`.wayfinder/issues/macos-app-integration.md`. Read `.wayfinder/README.md`
for local ticket claims, dependencies, and research resolutions. This map is
planning-only; it does not authorize removing the working macOS compatibility
settings before replacement behavior has passed the agreed interactive checks.

## Build Commands

```bash
# Prerequisites
brew install pkgconf texinfo
# Optional: brew install tree-sitter libgccjit librsvg

# From scratch
./autogen.sh
CFLAGS="-O2 -mcpu=native" ./configure \
  --with-native-compilation --with-tree-sitter \
  --enable-mac-app=yes --enable-mac-self-contained
make -j$(sysctl -n hw.ncpu)
make install  # self-contained goes to /Applications/Emacs.app

# Debug build
CFLAGS="-O0 -g3" ./configure --enable-mac-app=yes
make -j$(sysctl -n hw.ncpu)
# Run without install: cd mac/Emacs.app/Contents && ln -s ../../../native-lisp .
lldb mac/Emacs.app  # start from src/ directory for .lldbinit
```

Must use clang (macOS `gcc` is aliased to clang). Real GCC cannot build this — it lacks Blocks extension support.

Do not add `-fobjc-arc` to global `CFLAGS`. With `--with-metal-rendering`,
the build adds ARC specifically to `macmetal.o`; other Objective-C sources
use manual retain/release.

If `temacs` crashes in `rpl_pipe2` while generating `emacs.pdmp`, check for
an SDK/runtime mismatch: configure can detect a weak `pipe2` symbol that
the running OS does not provide. Re-run the same configure command with
`ac_cv_func_pipe2=no` in its environment, then rebuild. This selects the
bundled `pipe`/`fcntl` fallback. Use this override only for the confirmed
missing-symbol case, not for arbitrary dump failures.

## Testing

When launching the development bundle directly, set `EMACSLOADPATH` to this
checkout's absolute `lisp` directory if the bundle lacks
`Contents/Resources/lisp`. Validate GUI changes in a fresh GUI process with
real edge/corner drags, actual menu commands, and `C-g`; programmatic
`set-frame-size` alone is insufficient.

### Persistent event loop

The fork supports only macOS 27 and later (user decision, 2026-09-24):
runtime validation happens on macOS 27 only, and older systems are not
supported. The persistent AppKit event loop is the only event loop; the old
loop, its launch selector (`EMACS_MAC_PERSISTENT_LOOP`,
`--enable-mac-persistent-loop`), the native-menu experiments
(`EMACS_MAC_NATIVE_MENUS`, `EMACS_MAC_WORKER_MENUS`,
`--enable-mac-native-menus`) and the undocumented event-loop preferences
(`NSEventConcurrentProcessingEnabled`, `NSApplicationUpdateCycleEnabled`,
`NSWindowResizeNeedsTrackingLoop`, `NSControlPrefersGestureRecognizerTracking`)
were removed (wayfinder S8). Do not reintroduce synthetic mouse
release/press events or GUI-thread Lisp to work around AppKit tracking.

`-[NSApplication run]` runs on the GUI thread for the process lifetime; see
the "Persistent event loop" section of `src/macappkit.m` and
`.wayfinder/issues/macos-app-integration.md`. The GUI thread may touch Lisp
or redisplay state only with Lisp access
(a request parks the Lisp thread, or the GUI holds the global lock taken by
try-lock while Lisp waits for input). New AppKit callbacks that read or build
Lisp state must start with `MAC_LOOP_CALLBACK_NEEDS_LISP` or
`MAC_LOOP_QUERY_NEEDS_LISP`; a GUI-thread crash in GC or allocation usually
means one is missing. This includes view event handlers:
`mac_loop_send_event` takes access only for events whose hit test lands
in the content view, but AppKit routes mouse-moved, drag and up events
to the first responder or the view of the down event, so under a
transparent titlebar they reach `EmacsMainView` without access.
Scroll-wheel events that find Lisp busy are always dispatched to
AppKit at once, to be deferred by `-[EmacsMainView scrollWheel:]`:
AppKit drops momentum events replayed later through
`-[NSWindow sendEvent:]`.
Deferred precise scroll events in the middle of a scroll or momentum
phase merge with the previous deferred one (summed deltas, newest
event) when window, view, modifiers and phases match; phase boundaries
never merge (`mac_loop_defer_scroll_event`). Callbacks that only sync AppKit window state to Lisp
use `MAC_LOOP_STATE_CALLBACK_NEEDS_LISP`, which replaces a pending deferred
callback of the same kind. While Lisp is busy, a growing window shows the
last Metal drawable anchored top-left over the frame background, which is
the layer's `backgroundColor`. Idle live-resize steps redraw a garbaged
frame; `mac_update_end` holds the Metal presentation of `redraw_frame`'s
clear, and implicit frames stay held until the redraw, so that no blank
frame reaches the screen between steps. A held frame never waits for a
drawable: it snapshots the backbuffer for a pending presentation. While Lisp
is idle, each live-resize step waits (`EMACS_MAC_RESIZE_WAIT_MS`, default
30; 0 disables) for Lisp to redraw at the new size and presents that
frame in the step's Core Animation transaction
(`presentsWithTransaction`), so the window edge and contents move
together; redisplay stays on the Lisp thread. Fullscreen transitions
skip this. `test/manual/mac-app-loop/resize-band.sh` measures the
undrawn band at the growing edge. Do not add
GUI-thread snapshots that read
the window tree or faces without Lisp access. Text input and
accessibility queries that read buffer text or glyph matrices use
`mac_try_content_access` or `MAC_LOOP_CONTENT_QUERY`, which allow only a
safe point (Lisp in its input wait), not access borrowed from a Lisp
request. Otherwise they answer from the text snapshot that
`mac_publish_text_snapshot` stores at the end of redisplay, or report
the value as unavailable. Menu-bar selections carry the generation of the
snapshot that
`set_frame_menubar` published with the installed root menu, and are
rejected with a message if the frame, selected window or buffer changed,
or if the item's `:enable` no longer holds there; publish a new
generation rather than mutating a snapshot that queued actions may
reference.  A deleted frame's snapshots are retracted in
`free_frame_menubar`.  `test/manual/mac-menu/check.py` covers the
snapshot table.  The menu bar is filled deeply, but only once Emacs is
idle (`mac-update-pending-menu-bars` idle timer), since a deep build
costs 10-40 ms. Lisp keeps running while the menu bar is tracked, so
`mac_fill_menubar` refuses to change a tracked root; the end of
tracking queues a `mac-menu-bar-refresh` special event that applies
the held-back update. When a top-level menu opens while Lisp waits
for input, `menuNeedsUpdate:` asks for that menu alone with a
`mac-menu-bar-open-refresh` special event and waits at most 50 ms,
running Lisp requests meanwhile (D3). The refreshed menu carries its
own snapshot generation, and the root is rebuilt when tracking ends.
A late answer is never applied to a displayed menu. AppKit adds its own
items to Edit, Window and Help, so never `removeAllItems` on a top-level
menu. Menu tracking can bypass key-equivalent callbacks, so
`-[EmacsApplication nextEventMatchingMask:...]` lets a quit key cancel
menu-bar tracking without evaluating Lisp (D15); cancel the submenus as
well as the root. F10 shows the menu-bar keymap as a popup, and
repeated close/Quit requests are dropped until Lisp reaches its next
input wait.

`EMACS_MAC_TRACE_LOOP=1` traces deferrals to stderr (`2` adds every select);
with it set, `kill -INFO <pid>` prints GUI and Lisp thread backtraces, useful
where lldb or `sample` hang. `test/manual/mac-app-loop/run-scenarios.sh
[scenario...]` runs scripted scenarios in fresh processes and
`summarize.el` summarizes them. They post real NSEvents and native window
operations from GUI-thread timers (`mac-loop-test-schedule`), so they need no
accessibility or screen-recording permission, but they are not interactive
acceptance: the app may be unable to become active, and plain typing needs a
key window, so scenarios use control-key commands. Scripted drags are slower
than real trackpad drags; use 8 ms steps to expose races.  Run the
scenarios with `MallocScribble=1` in the environment to turn
manual-retain/release use-after-free bugs into reliable crashes. Pass absolute
paths to `-l` when launching the bundle directly.

```bash
make -C test check                          # run all tests
make -C test check-maybe                    # run only outdated tests
make -C test lisp/simple-tests.log          # run single test file (with logging)
make -C test lisp/simple-tests              # run single test file (interactive)
make -C test SELECTOR='test-name' check     # run tests matching selector
```

Default selector excludes `:expensive-test` and `:unstable` tags.

Note that a `.log` target is only rebuilt when it is older than the test file,
so `rm -f test/lisp/foo-tests.log` before re-running a test you just
investigated, or you will read a stale result.

### Injecting settings into a test run

Tests run with `--no-init-file --no-site-file --no-site-lisp`, so the
developer's personal configuration never applies.  To set a variable for a run,
use the `EMACS_EXTRAOPT` variable that `test/Makefile.in` splices into
`EMACSOPT` — this needs no edits to tracked test files, and so creates no
conflict surface against the weekly GNU master sync:

```bash
make -C test lisp/dired-tests.log \
  EMACS_EXTRAOPT='--eval "(setq insert-directory-program \"gls\")"'
```

Prefer this over patching tests or `test/Makefile.in` when a failure is
environmental rather than a real defect.

### macOS `ls` and the dired tests

macOS ships BSD `ls`, which has no `--dired`, so `dired-use-ls-dired`
auto-detects to nil.  This is **not** a cause of test failures: upstream commit
`abde2d1ed3b` made `dired-test-filename-with-newline-1`/`-2` BSD-aware via
`dired--ls-accept-b-switch-p`, and the full `dired-tests.el` passes 23/23 with
stock `/bin/ls`.  Do not "fix" these by installing GNU coreutils or by editing
the tests.  (Installing coreutils and setting `insert-directory-program` to
`gls` is a reasonable *interactive* preference, but it is unrelated to the
suite.)

### Standalone regression checks

These focused checks do not require a completed Emacs executable:

```bash
sh test/manual/rope/check.sh             # rope edits and invariants; ASan/UBSan
sh test/manual/macmetal/check.sh         # offscreen Metal blending; macOS GPU
python3 test/manual/wrap-cache/check.py  # cache validity and lifecycle; ASan/UBSan
```

The Metal check needs a visible Metal GPU and may exit 77 when no device is
available; treat that result as an environment skip.  The wrap-cache check
compiles extracted production function bodies with a small fixture, so it does
not replace live GUI scrolling or redisplay testing.  The scripts use `cc`
(`clang` for Metal) by default and honor `CC` when set.

## Mac Port Architecture

### Preprocessor Guards

Mac-specific code is guarded with:
- **`HAVE_MACGUI`** — primary guard for mac GUI code (set by configure)
- **`DARWIN_OS`** — macOS/Darwin OS detection (from `s/darwin.h`)
- **`MAC_OS`** — legacy internal macro

Pattern: `#ifdef HAVE_MACGUI ... #endif`. Other platform guards: `HAVE_NS`, `HAVE_X11`, `HAVE_NTGUI`, `HAVE_ANDROID`.

### Key Mac-Specific Files

**C/Objective-C sources (`src/`):**
- `macterm.c` — core display module, event loop, frame/window management
- `macterm.h` — display data structures (`struct mac_display_info`)
- `macfont.m` — font handling via Core Text (`CTFontRef`, `CGFontRef`)
- `macappkit.m` / `macappkit.h` — Objective-C AppKit integration layer
- `macgui.h` — GUI abstractions (XGC emulation, colors, geometry)

**Lisp:**
- `lisp/term/mac-win.el` — mac window initialization, keybindings, Apple event handlers

**App bundle:**
- `mac/Emacs.app/` — application bundle structure and resources
- `mac/Makefile.in` — app bundle build rules

### How Mac Port Differs from NS Port

- Direct Core Graphics/Quartz 2D rendering (not NSView-based)
- Core Text for fonts instead of the NS font system
- Uses `macterm.c` instead of `nsterm.m`
- GCD (Grand Central Dispatch) for some drawing operations
- Native Apple event handling, Services menu, DictionaryService
- `pixel-scroll-precision-mode` does not work (use `ultra-scroll` package instead)

## Merge Conflict Resolution

When merging GNU master into mac port branches:
- For code inside `#ifdef HAVE_MACGUI` / `MAC_OS` blocks: preserve mac-port version, integrate upstream structural changes
- For purely upstream files with no mac changes: take the upstream version
- Prefer keeping BOTH sides when possible
- The mac port `slurp_image` has a different signature (`f, img, filename, &size, type`) vs upstream (`filename, &size, type`)
- Watch for mac-specific additions in `#if defined` chains (e.g., image transform support lists)

## CI/CD

`.github/workflows/sync-gnu-master-to-nemesis.yml` — weekly sync of GNU master into `nemesis` branch. On conflict, creates a draft PR and uses Claude Code action (Opus) to auto-resolve, then merges.

### Known conflict: upstream removals of function arguments

Mac-only files (`src/macterm.c`, `src/macappkit.m`, `src/macselect.c`,
`src/macfns.c`, `src/macfont.m`, ...) are invisible to GNU master, so a merge
never flags them when upstream changes a shared function's signature — the
mismatch surfaces only as a compile error afterwards.  After every sync, build
before assuming the merge is done.  Example: upstream `2a5169156b3` dropped the
`autoload` argument from `access_keymap`, breaking eight mac-port call sites
that the merge left untouched.
