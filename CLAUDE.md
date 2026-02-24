# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Emacs Mac Port** — a native macOS GUI implementation for GNU Emacs, maintained by YAMAMOTO Mitsuharu. It provides an alternative to the official NS (Cocoa) port with Mac-specific enhancements including native AppKit integration, Apple event handling, Retina display support, and Core Animation effects.

The repository tracks GNU Emacs master (31.x) on the `emacs-mac-gnu_master_exp` branch and Emacs 30.x on `emacs-mac-30_1_exp`.

## Build Commands

### Prerequisites
```bash
brew install pkgconf texinfo
brew install tree-sitter libgccjit librsvg  # optional but recommended
```

### Configure and Build
```bash
./autogen.sh
CFLAGS="-O2 -mcpu=native" ./configure --with-small-ja-dic --with-native-compilation --with-tree-sitter --enable-mac-app=yes --enable-mac-self-contained
make -j$(sysctl -n hw.ncpu)
make install  # installs self-contained to /Applications/Emacs.app
```

### Speeding Up Rebuilds
The Japanese dictionary (`ja-dic.el`) byte-compilation is extremely slow.  Use `--with-small-ja-dic` (shown above) to use a smaller vocabulary.  To skip it entirely, delete the source file:
```bash
rm lisp/leim/ja-dic/ja-dic.el
```

When only C code changed, rebuild just the binary (skips all Lisp compilation):
```bash
cd src && make emacs
```

After binary changes, rebuild the pdmp file and copy to the app bundle:
```bash
cd src && rm -f emacs.pdmp && make emacs.pdmp
cp src/emacs{,.pdmp} mac/Emacs.app/Contents/MacOS/
```

### Debug Build
```bash
CFLAGS="-O0 -g3" ./configure --with-small-ja-dic --with-native-compilation --with-tree-sitter --enable-mac-app=yes
make -j$(sysctl -n hw.ncpu)
# Run under lldb from src/ directory:
cd src && lldb ../mac/Emacs.app
# Then: run -Q
```

For debug without install, symlink native-lisp:
```bash
cd mac/Emacs.app/Contents && ln -s ../../../native-lisp .
```

### Running Tests
```bash
make -C test check                              # standard tests (no expensive/unstable)
make -C test check-expensive                     # include expensive tests
make -C test check-all                           # all tests including unstable
make -C test lisp/files-tests                    # single test file (shows output)
make -C test lisp/files-tests.log                # single test file (output to log)
make -C test check-src                           # all tests in test/src/
make -C test check-lisp-net                      # all tests in test/lisp/net/
make -C test lisp/files-tests SELECTOR='"foo$$"' # filter by regex selector
make -C test lisp/files-tests SELECTOR='test-foo' # run specific named test
```

Do NOT use `make -j` for tests — parallel test execution causes spurious failures.

## Code Style

- **C code**: GNU style (`c-file-style: "GNU"`), tabs for indentation, 70-column limit
- **Emacs Lisp**: no tabs (spaces only), 72-column fill
- **Objective-C**: GNU style, tabs for indentation
- American English in documentation (behavior, not behaviour)
- Two spaces between sentences in docs and comments
- Formatting rules in `.clang-format`; language server config in `.clangd`

## Architecture

### Mac Port GUI Layer (`src/mac*.c`, `src/mac*.m`)
The Mac-specific GUI implementation, separate from the NS (Cocoa) and X11 ports:
- `macterm.c` / `macterm.h` — display/terminal backend (the main Mac rendering loop)
- `macappkit.m` / `macappkit.h` — AppKit/Cocoa bindings (Objective-C)
- `macfns.c` — frame/window management functions
- `macfont.m` — Core Text font handling
- `macmenu.c` — native menu bar implementation
- `macselect.c` — pasteboard/clipboard
- `mac.c` — Mac port initialization

The `mac/` directory contains the `Emacs.app` bundle template (Info.plist, icons, wrapper script).

### Core Text Buffer Engine (`src/`)
- `buffer.c` / `buffer.h` — buffer data structures (gap buffer is the default storage)
- `insdel.c` — insertion/deletion primitives
- `editfns.c` — text editing functions exposed to Lisp
- `search.c` — search and regex engine
- `fileio.c` — file I/O and coding system detection
- `coding.c` — character encoding/decoding
- `xdisp.c` — the redisplay engine (very large, ~35K lines)
- `keyboard.c` — input event handling

### Lisp Layer (`lisp/`)
- `lisp/term/mac-win.el` — Mac port terminal initialization (Mac-specific keybindings, GUI setup)
- The rest of `lisp/` is standard GNU Emacs Lisp code

### Build System
- Autoconf-based: `configure.ac` (very large, ~280KB) generates `configure`
- `src/Makefile.in` — C source compilation; `mac/Makefile.in` — app bundle creation
- Mac port is enabled by `--with-mac` (default on macOS); Metal via `--with-mac-metal`

## Key Conventions

- Mac port bugs go to `mituharu+bug-gnu-emacs-mac@math.s.chiba-u.ac.jp`; generic Emacs bugs to `bug-gnu-emacs@gnu.org` via `M-x report-emacs-bug`
- Commit messages: single summary line (~50 chars), then details with ChangeLog-style entries
- `gcc` on macOS is actually `clang` — this is required (real GCC cannot build the Mac port due to Blocks language extension usage)
- The Mac port builds with ARC (`-fobjc-arc`) — do not use manual retain/release in Objective-C code
- Three GUI backends exist (Mac, NS, X11) — Mac-specific code is guarded by `#ifdef HAVE_MACGUI` or conditionals in configure.ac
