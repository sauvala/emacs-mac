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

## Testing

On macOS 27 and later, preserve the existing event-loop settings and register
`NSWindowResizeNeedsTrackingLoop` before creating the application. Also register
`NSControlPrefersGestureRecognizerTracking=NO`: on the tested macOS 27 system,
the yellow button's gesture recognizer intercepted clicks without dispatching
`miniaturize:`, while traditional control tracking restored minimization.
The integrated build passed interactive minimize/restore, mouse menu command
delivery, and continuous edge resizing together. Other titlebar controls and
the broader menu matrix still need checking. Avoid
synthetic release/press events during resize so a drag stays in one session.
This combination passed an interactive continuous-resize check. Native menu
activation/command selection also fails in the unchanged installed build
under `-Q` on the tested macOS 27 system; treat that as a separate unresolved
issue, not a regression established by the resize patch. Enabling the update
cycle restored native resizing in experiments but did not resolve menus.
These AppKit settings are undocumented;
recheck after major OS updates. Validate each candidate in a fresh GUI process
with edge/corner drags, actual menu commands, and `C-g`; programmatic
`set-frame-size` alone is insufficient. When launching the development bundle
directly, set `EMACSLOADPATH` to this checkout's absolute `lisp` directory if
the bundle lacks `Contents/Resources/lisp`.

Configure with `--enable-mac-native-menus` to enable both experimental menu
paths for normal Dock/Finder launches on macOS 27+. Otherwise the native-menu
path is opt-in via the presence of
`EMACS_MAC_NATIVE_MENUS` (unset it to disable); `EMACS_MAC_TRACE_MENUS`
enables lifecycle diagnostics. Run `python3 test/manual/mac-menu/check.py`
for snapshot ownership checks and use `test/manual/mac-menu/README.md` for
the interactive fixture. The standalone check does not exercise AppKit or
real Lisp GC. Menu actions can arrive after tracking ends, so snapshot
cleanup must preserve queued actions. Do not use the legacy popup-active
flag to represent native tracking: it also authorizes synchronous Lisp
callbacks, which are unsafe in some event-loop contexts.
The separate `EMACS_MAC_WORKER_MENUS` experiment cancels the actual submenu
in tracking run-loop mode before deferring preparation to Lisp. Initial
command/lifecycle checks passed. Clearing stale submenu contents and temporarily
redirecting Help search to an off-bar menu removed visible blinking in tested
openings. Capture the main window for retry ownership: Help's popup can become
the key window. Cancelling only the root previously froze in AppKit's
tracking loop despite end notifications. Do not rely on those notifications
to prove that the native event loop has returned.
Native menu tracking can bypass menu key-equivalent callbacks. The opt-in
C-g handler intercepts dequeued key events in `EmacsApplication`, uses the
existing quit-key recognizer, and cancels tracking without evaluating Lisp.
It passed Edit/Help dismissal and ordinary prefix cancellation outside menus.

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
