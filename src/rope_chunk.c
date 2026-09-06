#include <config.h>
#include "rope_internal.h"

#include <string.h>
#include <sys/types.h>

static rope_u128 bit_at(size_t idx) {
    return ((rope_u128)1) << idx;
}

static rope_u128 lower_mask(size_t bits) {
    if (bits == 0) {
        return 0;
    }
    if (bits >= CHUNK_SIZE) {
        return (rope_u128)(~(rope_u128)0);
    }
    return ((((rope_u128)1) << bits) - 1);
}

static size_t popcount_u128(rope_u128 v) {
    const uint64_t lo = (uint64_t)v;
    const uint64_t hi = (uint64_t)(v >> 64);
    return (size_t)__builtin_popcountll(lo) + (size_t)__builtin_popcountll(hi);
}

static ssize_t msb_index_u128(rope_u128 v) {
    if (v == 0) {
        return -1;
    }
    const uint64_t hi = (uint64_t)(v >> 64);
    if (hi != 0) {
        return (ssize_t)(64 + (63 - __builtin_clzll(hi)));
    }
    const uint64_t lo = (uint64_t)v;
    return (ssize_t)(63 - __builtin_clzll(lo));
}

Chunk chunk_from_text(const char *text, size_t len) {
    Chunk out;
    memset(&out, 0, sizeof(out));

    if (len > CHUNK_SIZE) {
        len = CHUNK_SIZE;
    }
    memcpy(out.text, text, len);
    out.len = (uint8_t)len;

    for (size_t i = 0; i < len; ++i) {
        const unsigned char b = (unsigned char)out.text[i];
        if (b == '\n') {
            out.newlines |= bit_at(i);
        }
        if (b == '\t') {
            out.tabs |= bit_at(i);
        }
        if (utf8_is_char_boundary(b)) {
            out.chars |= bit_at(i);
        }
    }

    return out;
}

/*
 * Find the byte position of the Nth set bit (0-indexed) in a u128.
 * Returns -1 if fewer than n+1 bits are set.
 */
static int64_t nth_set_bit_u128(rope_u128 v, size_t n) {
    const uint64_t lo = (uint64_t)v;
    const uint64_t hi = (uint64_t)(v >> 64);
    const size_t lo_pop = (size_t)__builtin_popcountll(lo);

    uint64_t half;
    size_t base;
    if (n < lo_pop) {
        half = lo;
        base = 0;
    } else {
        half = hi;
        n -= lo_pop;
        base = 64;
    }

    for (size_t i = 0; i < 64; ++i) {
        if (half & (1ULL << i)) {
            if (n == 0) {
                return (int64_t)(base + i);
            }
            --n;
        }
    }
    return -1;
}

/*
 * Find the byte index of the lowest set bit in a u128.
 * Assumes v != 0.
 */
static size_t ctz_u128(rope_u128 v) {
    const uint64_t lo = (uint64_t)v;
    if (lo != 0) {
        return (size_t)__builtin_ctzll(lo);
    }
    return 64 + (size_t)__builtin_ctzll((uint64_t)(v >> 64));
}

TextSummary chunk_summary(const Chunk *chunk, size_t row_base) {
    return summary_from_bytes(chunk->text, chunk->len, row_base);
}

ChunkPoint chunk_offset_to_point(const Chunk *chunk, size_t offset) {
    ChunkPoint out = {0, 0};
    if (offset > chunk->len) {
        offset = chunk->len;
    }

    const rope_u128 mask = lower_mask(offset);
    const rope_u128 nl_before = chunk->newlines & mask;
    out.row = popcount_u128(nl_before);

    const ssize_t last_nl = msb_index_u128(nl_before);
    const size_t start = last_nl < 0 ? 0 : (size_t)last_nl + 1;
    const rope_u128 char_mask = lower_mask(offset) & ~lower_mask(start);
    out.col = popcount_u128(chunk->chars & char_mask);
    return out;
}

ChunkOffsetResult chunk_point_to_offset(const Chunk *chunk, size_t row, size_t col) {
    ChunkOffsetResult out = {0, false};

    /* Use newline bitmask to find the start of the target row */
    size_t row_start = 0;
    if (row > 0) {
        const size_t nl_count = popcount_u128(chunk->newlines);
        if (row > nl_count) {
            out.byte_offset = chunk->len;
            out.clamped = true;
            return out;
        }
        /* Find the byte position of the row-th newline (0-indexed) */
        const int64_t nl_pos = nth_set_bit_u128(chunk->newlines, row - 1);
        if (nl_pos < 0) {
            out.byte_offset = chunk->len;
            out.clamped = true;
            return out;
        }
        row_start = (size_t)nl_pos + 1;
    }

    if (col == 0) {
        out.byte_offset = row_start;
        return out;
    }

    /* Count characters from row_start until we reach `col` characters
     * or hit a newline / end of chunk. Use the chars bitmask to find
     * the byte position of the col-th character on this row. */
    /* Build a mask for bytes [row_start, chunk->len) */
    const rope_u128 range_mask = lower_mask(chunk->len) & ~lower_mask(row_start);

    /* Find where the next newline is (end of this row) */
    const rope_u128 nl_in_range = chunk->newlines & range_mask;
    size_t row_end_byte = chunk->len;
    if (nl_in_range != 0) {
        row_end_byte = ctz_u128(nl_in_range);
    }

    /* Count char boundaries in [row_start, row_end_byte) */
    const rope_u128 row_mask = lower_mask(row_end_byte) & ~lower_mask(row_start);
    const rope_u128 row_chars = chunk->chars & row_mask;
    const size_t total_chars_in_row = popcount_u128(row_chars);

    if (col >= total_chars_in_row) {
        /* col goes past end of row */
        out.byte_offset = row_end_byte;
        if (col > total_chars_in_row) {
            out.clamped = true;
        }
        return out;
    }

    /* Find the byte position of the col-th char boundary starting from row_start.
     * We want the (col)-th set bit in row_chars, counting from bit row_start. */
    /* We already have the char boundaries in row_chars; find the col-th one */
    /* Since nth_set_bit_u128 counts from bit 0, and row_chars has bits only
     * in [row_start, row_end_byte), the col-th set bit gives us the byte position directly. */
    const int64_t target_byte = nth_set_bit_u128(row_chars, col);
    if (target_byte < 0) {
        out.byte_offset = row_end_byte;
        out.clamped = true;
        return out;
    }
    out.byte_offset = (size_t)target_byte;
    return out;
}

size_t chunk_char_to_byte(const Chunk *chunk, size_t char_offset) {
    if (char_offset == 0) {
        return 0;
    }
    const int64_t pos = nth_set_bit_u128(chunk->chars, char_offset);
    return pos < 0 ? chunk->len : (size_t)pos;
}

size_t chunk_byte_to_char(const Chunk *chunk, size_t byte_offset) {
    if (byte_offset > chunk->len) {
        byte_offset = chunk->len;
    }
    return popcount_u128(chunk->chars & lower_mask(byte_offset));
}

size_t chunk_byte_to_utf16(const Chunk *chunk, size_t byte_offset) {
    if (byte_offset > chunk->len) {
        byte_offset = chunk->len;
    }
    /* Each character boundary in [0, byte_offset) is one UTF-16 code unit,
     * except 4/5-byte sequences, which count as two units.  The latter
     * include Emacs extended characters, which have no Unicode encoding.
     * So: utf16_count = num_chars + num_4byte_chars
     * Raw eight-bit characters encoded with C0/C1 count as one unit. */
    const rope_u128 mask = lower_mask(byte_offset);
    const size_t char_count = popcount_u128(chunk->chars & mask);

    /* Count extended lead bytes (F0..F8).  */
    size_t four_byte_count = 0;
    rope_u128 boundaries = chunk->chars & mask;
    while (boundaries != 0) {
        const size_t idx = ctz_u128(boundaries);
        if (utf8_next_len((unsigned char)chunk->text[idx]) >= 4) {
            four_byte_count++;
        }
        boundaries &= boundaries - 1;
    }

    return char_count + four_byte_count;
}
