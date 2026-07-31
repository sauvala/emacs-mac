# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

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
