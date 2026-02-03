# CLAUDE.md - Emacs Mac Port

This is the **Mac port** of GNU Emacs, maintained by YAMAMOTO Mitsuharu. It provides a native macOS GUI implementation distinct from the official NS (Cocoa) port, supporting macOS 10.10 through macOS 26.

## Build Instructions

```bash
# Prerequisites: Install Xcode Command Line Tools
xcode-select --install

# If building from git, generate configure
./autogen.sh

# Configure (Mac port enabled by default on macOS)
./configure

# Build and install
make
make install
```

### Key Configure Options

- `--with-mac` - Enable Mac port GUI (default on macOS)
- `--with-mac-metal` - Use Metal framework for GPU acceleration
- `--enable-mac-app[=DIR]` - Install Emacs.app (default: /Applications)
- `--enable-mac-self-contained` - Create self-contained app bundle

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `src/` | C source code for Emacs core, including Mac-specific files |
| `lisp/` | Emacs Lisp source code |
| `mac/` | Mac port specific: Emacs.app bundle, Makefiles, templates |
| `nextstep/` | NS (Cocoa) port (not used by Mac port) |
| `lib/` | Source for libraries used by Emacs |
| `lib-src/` | Utility programs (emacsclient, etags, etc.) |
| `etc/` | Architecture-independent data files, images, tutorials |
| `doc/` | Documentation sources (Texinfo manuals) |
| `test/` | Test suite |

## Mac Port Source Files (in `src/`)

| File | Purpose |
|------|---------|
| `macappkit.m` | Main AppKit/Cocoa integration (Objective-C) |
| `macappkit.h` | AppKit headers and compatibility definitions |
| `macterm.c` | Terminal/display management |
| `macterm.h` | Display module headers |
| `macfns.c` | Frame functions (window creation, etc.) |
| `macfont.m` | Core Text font handling |
| `macfont.h` | Font headers |
| `mac.c` | Unix emulation, utility functions |
| `macselect.c` | Clipboard/pasteboard handling |
| `macmenu.c` | Menu system |
| `macgui.h` | GUI type definitions |
| `macuvs.h` | Unicode Variation Sequence data |

### Lisp Support
- `lisp/term/mac-win.el` - Lisp-side Mac window system initialization

### Documentation
- `doc/emacs/macport.texi` - Mac port manual chapter

## Key Mac Port Features

**Display & Graphics:**
- Retina/HiDPI support with @2x image convention
- Metal framework support for GPU-accelerated rendering
- Core Animation for smooth animations
- Application-side double buffering (required for macOS 10.14+)

**Text & Fonts:**
- Core Text layout engine (no libotf dependency)
- Unicode variation selectors for IVS glyphs
- Ligature support via `mac-auto-operator-composition-mode`
- Full emoji support with skin tone modifiers

**macOS Integration:**
- Native fullscreen with menu bar access
- Spaces/Mission Control sticky frame support
- Tab groups (macOS 10.12+)
- Touch Bar support
- Trackpad gestures (pinch, swipe, smooth scrolling)
- Dark Mode automatic adaptation
- Services menu integration
- Proxy icons in title bar

**Image Support:**
- Image I/O framework (no ImageMagick needed)
- SVG via WebKit (no librsvg needed)
- Direct PDF rendering

## Coding Standards

From `.dir-locals.el`:
- **Tab width**: 8
- **Fill column**: 72
- **C/Objective-C**: GNU style with tabs
- **Emacs Lisp**: No tabs, 72-char fill
- **Sentence-end-double-space**: Yes

### C Code Style
```c
/* GNU C style - use tabs for indentation */
static void
function_name (int arg1, char *arg2)
{
  if (condition)
    {
      /* body */
    }
}
```

### Objective-C
Mac-specific Objective-C code follows the same GNU style conventions.

## Configuration

The Mac port uses the macOS Preferences system instead of X resources:

```bash
defaults write org.gnu.Emacs Emacs.cursorType bar
defaults write org.gnu.Emacs Emacs.toolBar -bool false
```

## Bug Reports

- **Mac port-specific bugs**: `mituharu+bug-gnu-emacs-mac@math.s.chiba-u.ac.jp`
- **General bugs**: Reproduce with official builds first, then `M-x report-emacs-bug`

## Key Documentation Files

- `README-mac` - Mac port overview and build instructions
- `NEWS-mac` - Mac port changelog/release notes
- `CONTRIBUTE` - GNU Emacs contribution guidelines
- `INSTALL` - General installation instructions
- `INSTALL.REPO` - Building from repository

## Repository

- **Official**: https://bitbucket.org/mituharu/emacs-mac.git
- **Maintainer**: YAMAMOTO Mitsuharu

## Display/Rendering Architecture

### Core Display Engine (Platform-Independent)

| File | Purpose |
|------|---------|
| `src/xdisp.c` | **Main redisplay engine** - `redisplay_internal()` is the primary entry point, handles glyph row building, text layout, display optimization |
| `src/dispnew.c` | **Display update** - `update_frame()`, `update_window()`, glyph matrix operations, screen update optimization |
| `src/dispextern.h` | **Display interface** - defines `struct redisplay_interface` (abstraction layer all GUI backends implement) |
| `src/frame.c` | Frame/window container management |

### Mac-Specific Display Code

| File | Purpose |
|------|---------|
| `src/macterm.c` | **Primary Mac display implementation** - implements `mac_redisplay_interface` with all drawing functions: `mac_draw_glyph_string()`, `mac_fill_rectangle()`, scrolling, cursor drawing, fringe bitmaps. Uses Core Graphics (CGContext). |
| `src/macterm.h` | Mac display module header - `struct mac_display_info`, `struct mac_output` |
| `src/macappkit.m` | **AppKit/Metal integration** - `EmacsView` class, IOSurface double-buffering, Metal GPU rendering, `drawRect:`/`updateLayer` expose handling |
| `src/macfont.m` | **Core Text font rendering** - `macfont_draw()` using CTFontDrawGlyphs |

### Key Display Entry Points

**Core redisplay (xdisp.c):**
- `redisplay_internal()` - main entry from command loop
- `expose_frame()` - handles expose events

**Display update (dispnew.c):**
- `update_frame()` / `update_window()` - frame/window update

**Mac-specific (macterm.c):**
- `mac_redisplay_interface` (~line 5728) - all Mac drawing function pointers
- `mac_draw_glyph_string()` - main glyph drawing
- `mac_flush()` - flushes drawing to screen

**AppKit layer (macappkit.m):**
- `EmacsView -drawRect:` / `-updateLayer` - AppKit callbacks
- `EmacsFrameBacking` - IOSurface double-buffer management

### Display Architecture Flow

```
Lisp/Command Loop
       |
       v
redisplay_internal() [xdisp.c]
       |
       v
update_frame() [dispnew.c]
       |
       v
struct redisplay_interface [dispextern.h]
       |
       v
mac_redisplay_interface [macterm.c]
  -> Core Graphics drawing via CGContext
       |
       v
EmacsView / EmacsFrameBacking [macappkit.m]
  -> IOSurface double-buffering
  -> Metal GPU acceleration (optional)
       |
       v
macOS Quartz / Core Animation / Metal
```

### Double Buffering

The Mac port uses application-side double buffering with IOSurface:
- `EmacsFrameBacking` class manages two surfaces (front/back)
- Drawing happens to the back buffer
- On flush, surfaces are swapped and contents copied using Metal (GPU) or vImage (CPU)
- `FRAME_MAC_DOUBLE_BUFFERED_P(f)` indicates if double buffering is active
- Required for macOS 10.14+ (Mojave and later)

### Metal GPU Acceleration

Metal support has been **experimental since 2018** and remains so:
- Introduced in emacs-26.1-mac-7.2 (September 2018) as experimental
- Briefly enabled by default in emacs-26.1-mac-7.4 (November 2018)
- **Disabled by default** since emacs-27.2-mac-8.2 (March 2021)
- Reason: M1 Macs achieve 60fps without Metal; earlier perceived CPU savings were due to lower frame rate
- Enable with `./configure --with-mac-metal`

### Rendering Optimization Analysis

See [RENDERING-OPTIMIZATION.md](RENDERING-OPTIMIZATION.md) for a detailed analysis comparing the current rendering architecture to modern GPU-accelerated editors (Zed, Alacritty) and identifying optimization opportunities.

## Gap Buffer Implementation

Emacs uses a **gap buffer** data structure for efficient text editing. This is a fundamental design choice that enables O(1) insertions and deletions at the cursor position.

### Data Structure

The gap buffer is defined in `src/buffer.h` within `struct buffer_text` (lines 240-304):

```c
struct buffer_text {
    unsigned char *beg;       /* Actual address of buffer contents */
    ptrdiff_t gpt;            /* Char position of gap in buffer */
    ptrdiff_t z;              /* Char position of end of buffer */
    ptrdiff_t gpt_byte;       /* Byte position of gap in buffer */
    ptrdiff_t z_byte;         /* Byte position of end of buffer */
    ptrdiff_t gap_size;       /* Size of buffer's gap (in bytes) */
    modiff_count modiff;      /* Modification count */
    /* ... other fields ... */
};
```

**Key insight**: Emacs uses a **two-position system** (character positions and byte positions) because characters can be multibyte (UTF-8). Character position tracks logical position (character count), while byte position tracks physical position in memory.

### Memory Layout

```
[BEG_ADDR] [text before gap] [UNUSED GAP] [text after gap] [Z_ADDR]
           |                 |             |               |
           0              GPT_ADDR    GAP_END_ADDR        Z_ADDR
```

The buffer text is NOT contiguous in memory. Access macros in `buffer.h` automatically skip over the gap:

```c
#define GPT (current_buffer->text->gpt)           /* Gap point (char pos) */
#define GPT_BYTE (current_buffer->text->gpt_byte) /* Gap point (byte pos) */
#define GAP_SIZE (current_buffer->text->gap_size) /* Size in bytes */
#define GPT_ADDR (beg + gpt_byte - BEG_BYTE)      /* Address of gap start */
#define GAP_END_ADDR (beg + gpt_byte + gap_size)  /* Address of gap end */
```

### Core Operations

#### Gap Movement (`src/insdel.c`)

| Function | Purpose | Lines |
|----------|---------|-------|
| `move_gap_both()` | Main entry point - moves gap to specified position | 94 |
| `gap_left()` | Move gap to smaller position (copies chars upward) | 110 |
| `gap_right()` | Move gap to larger position (copies chars downward) | 173 |

Gap movement uses `memmove()` for safe copying and checks for quit signals every 32KB to prevent UI freezes.

#### Insertion (`src/insdel.c:891`)

```c
void insert_1_both (...) {
    /* 1. Move gap to insertion point */
    if (PT != GPT)
        move_gap_both (PT, PT_BYTE);

    /* 2. Expand gap if needed */
    if (GAP_SIZE < nbytes)
        make_gap (nbytes - GAP_SIZE);

    /* 3. Copy data into gap */
    memcpy (GPT_ADDR, string, nbytes);

    /* 4. Update positions - gap shrinks, moves past inserted data */
    GAP_SIZE -= nbytes;
    GPT += nchars;
    GPT_BYTE += nbytes;
    Z += nchars;
    Z_BYTE += nbytes;
}
```

#### Deletion (`src/insdel.c:1991`)

Deletion is efficient - it simply **enlarges the gap** to cover the deleted region:

```c
Lisp_Object del_range_2 (...) {
    /* 1. Move gap adjacent to deletion region */
    if (from > GPT) gap_right (from, from_byte);
    if (to < GPT)   gap_left (to, to_byte, 0);

    /* 2. Expand gap to cover deleted text - no data movement! */
    GAP_SIZE += nbytes_del;
    Z -= nchars_del;
    Z_BYTE -= nbytes_del;
    GPT = from;
    GPT_BYTE = from_byte;
}
```

### Gap Size Management

| Constant | Value | Purpose |
|----------|-------|---------|
| `GAP_BYTES_DFL` | 2000 | Default initial gap size |
| `GAP_BYTES_MIN` | 20 | Minimum gap size |

**Expansion**: `make_gap_larger()` (insdel.c:467) adds space proportional to buffer size to reduce O(n²) reallocation patterns.

**Compaction**: `compact_buffer()` (buffer.c:1855) is called during GC to shrink excessive gaps. Target size: `max(20, min(Z/10, 2000))`.

### Character/Byte Position Conversion

Due to multibyte characters, converting between character and byte positions requires scanning. The implementation in `src/marker.c` uses several optimizations:

1. **Reference points**: Uses known positions (BEG, BEGV, PT, GPT, ZV, Z) as starting points
2. **Marker hints**: Scans buffer's marker list for nearby char/byte pairs
3. **Caching**: Last conversion result is cached
4. **Early termination**: Stops marker search when close enough (within 50 bytes initially, increasing by 50 per marker checked)

Key functions:
- `buf_charpos_to_bytepos()` (marker.c:167) - char→byte
- `buf_bytepos_to_charpos()` (marker.c:320) - byte→char

### Source Files

| File | Purpose |
|------|---------|
| `src/buffer.h` | Data structures, access macros (lines 240-304, 1072-1114) |
| `src/insdel.c` | Gap movement, insertion, deletion (lines 94-220, 467-601, 891-970) |
| `src/marker.c` | Char/byte position conversion (lines 167-270, 320-410) |
| `src/buffer.c` | Buffer allocation, gap compaction (lines 1855-1886) |

### Design Trade-offs

**Advantages:**
- O(1) insertions/deletions at gap (cursor) position
- Memory consolidation reduces fragmentation
- Efficient for typical editing patterns (sequential typing)

**Disadvantages:**
- Gap movement is O(n) where n = distance to new position
- Multibyte handling adds complexity to position calculations
- Always maintains `gap_size` bytes of overhead

## Piece Table Implementation (Experimental)

An experimental piece table implementation is available as an alternative to the gap buffer. Piece tables offer O(log n) insertions and deletions at any position, making them potentially faster for random edits in large files.

### Building with Piece Table Support

```bash
./configure --with-piece-table
make
```

The `--with-piece-table` flag defines `USE_PIECE_TABLE` and compiles the piece table code.

### Enabling Piece Table

**Interactive Commands:**

| Command | Description |
|---------|-------------|
| `M-x piece-table-enable-default` | Enable piece table for all new buffers |
| `M-x piece-table-disable-default` | Disable piece table for new buffers |
| `M-x piece-table-toggle-default` | Toggle piece table for new buffers |
| `M-x buffer-enable-piece-table` | Enable piece table on current buffer (must be empty) |

**Lisp Functions:**

| Function | Description |
|----------|-------------|
| `(buffer-using-piece-table-p)` | Returns `t` if current buffer uses piece table |
| `(buffer-enable-piece-table)` | Enable piece table on current buffer (must be empty) |
| `(piece-table-enable-default)` | Set `use-piece-table-by-default` to `t` |
| `(piece-table-disable-default)` | Set `use-piece-table-by-default` to `nil` |
| `(piece-table-toggle-default)` | Toggle `use-piece-table-by-default` |

**Variables:**

| Variable | Description |
|----------|-------------|
| `use-piece-table-by-default` | When non-nil, new buffers use piece table storage |

**Programmatic Usage:**
```elisp
;; Enable for all new buffers
(setq use-piece-table-by-default t)

;; Check if current buffer uses piece table
(buffer-using-piece-table-p)

;; Enable on specific empty buffer
(with-current-buffer (get-buffer-create "*my-buffer*")
  (buffer-enable-piece-table))
```

### Source Files

| File | Purpose |
|------|---------|
| `src/piece_table.c` | Core piece table implementation (red-black tree) |
| `src/piece_table.h` | Piece table data structures and API |
| `src/piecetbl.c` | Emacs integration layer - wraps piece table for buffer operations |
| `src/piecetbl.h` | Emacs piece table wrapper declarations |

### Architecture

The piece table uses a **red-black tree** for O(log n) lookups. Each node (piece) references either:
- **Original buffer**: Initial file content (read-only)
- **Add buffer**: All inserted text (append-only)

```
PieceTable
    |
    v
Red-Black Tree of Pieces
    |
    +-- Piece 1: { source=ORIGINAL, start=0, length=100 }
    +-- Piece 2: { source=ADD, start=0, length=15 }      <- inserted text
    +-- Piece 3: { source=ORIGINAL, start=150, length=200 }
```

### Key Wrapper Functions (`src/piecetbl.c`)

| Function | Purpose |
|----------|---------|
| `buffer_create_piece_table()` | Initialize piece table for a buffer |
| `pt_insert_emacs()` | Insert text (handles Emacs 1-based positions) |
| `pt_delete_emacs()` | Delete text range |
| `pt_get_text_emacs()` | Extract text to a buffer |
| `pt_char_at_emacs()` | Get single character at position |
| `pt_get_contiguous_emacs()` | Get pointer to contiguous region |

### Integration Points

The piece table integrates with Emacs through conditional compilation (`#ifdef USE_PIECE_TABLE`):

1. **Buffer creation** (`buffer.c`): Optionally creates piece table based on `use-piece-table-by-default`

2. **Insert/delete** (`insdel.c`): `insert_1_both()` and `del_range_2()` route to piece table when enabled

3. **Text access** (`buffer.h`): `FETCH_BYTE` and `BYTE_POS_ADDR` macros check `using_piece_table` flag

4. **Regex search** (`search.c`): Linearizes buffer content before `re_search_2` (temporary copy for correctness)

5. **Replace** (`insdel.c`): `replace_range()` has piece table code path for search-and-replace

6. **File I/O** (`fileio.c`): `insert-file-contents` and `write-region` handle piece table buffers

7. **Newline search** (`search.c`): `find_newline` has piece table-specific code paths using `FETCH_BYTE` instead of pointer arithmetic

8. **Buffer memory access** (`buffer.h`): `BUF_BYTE_ADDRESS`, `BUF_FETCH_MULTIBYTE_CHAR`, and `buf_prev_char_len` handle piece table buffers via `pt_get_contiguous_emacs`

### Current Limitations

- **ASCII only**: Character position must equal byte position (no multibyte support yet). Files containing non-ASCII bytes (UTF-8, etc.) are automatically detected and loaded using the gap buffer instead, with a warning message.
- **Undo not fully working**: Undo records may not capture all piece table operations
- **Performance**: Regex search currently linearizes the entire visible region (temporary copy)
- **Internal buffers excluded**: Buffers with names starting with a space (e.g., ` *temp*`, ` *Minibuf-0*`) never use piece table, even when `use-piece-table-by-default` is set. This is because the Lisp reader (`read`) doesn't work with piece table buffers yet.
- **Experimental**: Not recommended for production use

### Data Structure in `buffer_text`

```c
struct buffer_text {
    /* ... existing gap buffer fields ... */
#ifdef USE_PIECE_TABLE
    struct PieceTable *piece_table;  /* Piece table handle */
    bool using_piece_table;          /* True if this buffer uses piece table */
#endif
};
```

### Design Rationale

The implementation keeps the gap buffer code intact and adds piece table as an opt-in alternative:

1. **Coexistence**: Both storage backends can exist in the same Emacs instance
2. **Gradual migration**: Individual buffers can be converted
3. **Fallback**: If piece table has issues, gap buffer remains available
4. **Minimal changes**: Core Emacs code uses abstraction macros that check `using_piece_table`
