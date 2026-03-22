#include <config.h>
#include "rope_internal.h"

#include <string.h>

TextSummary summary_zero(void) {
    TextSummary out;
    memset(&out, 0, sizeof(out));
    return out;
}

TextSummary summary_add(TextSummary left, TextSummary right) {
    TextSummary out = summary_zero();

    out.bytes = left.bytes + right.bytes;
    out.chars = left.chars + right.chars;
    out.chars_utf16 = left.chars_utf16 + right.chars_utf16;

    out.lines.row = left.lines.row + right.lines.row;
    if (right.lines.row == 0) {
        out.lines.col = (uint32_t)(left.lines.col + right.lines.col);
    } else {
        out.lines.col = right.lines.col;
    }

    out.first_line_chars = left.first_line_chars;
    if (left.lines.row == 0) {
        out.first_line_chars += right.first_line_chars;
    }

    out.last_line_chars = right.last_line_chars;
    if (right.lines.row == 0) {
        out.last_line_chars += left.last_line_chars;
    }

    const size_t bridged = left.last_line_chars + right.first_line_chars;
    out.longest_row_chars = left.longest_row_chars;
    out.longest_row = left.longest_row;
    if (right.longest_row_chars > out.longest_row_chars) {
        out.longest_row_chars = right.longest_row_chars;
        out.longest_row = left.lines.row + right.longest_row;
    }
    if (bridged > out.longest_row_chars) {
        out.longest_row_chars = bridged;
        out.longest_row = left.lines.row;
    }

    return out;
}

TextSummary summary_from_bytes(const char *text, size_t len, size_t row_base) {
    TextSummary out = summary_zero();
    out.bytes = len;

    size_t current_line_chars = 0;
    bool saw_newline = false;

    for (size_t i = 0; i < len;) {
        const unsigned char b = (unsigned char)text[i];
        const size_t cp_len = utf8_next_len(b);
        if (cp_len == 0 || i + cp_len > len) {
            break;
        }

        const uint32_t codepoint =
            cp_len == 1 ? b :
            cp_len == 2 ? ((b & 0x1Fu) << 6u) | ((unsigned char)text[i + 1] & 0x3Fu) :
            cp_len == 3 ? ((b & 0x0Fu) << 12u) | (((unsigned char)text[i + 1] & 0x3Fu) << 6u) |
                              ((unsigned char)text[i + 2] & 0x3Fu) :
                          ((b & 0x07u) << 18u) | (((unsigned char)text[i + 1] & 0x3Fu) << 12u) |
                              (((unsigned char)text[i + 2] & 0x3Fu) << 6u) |
                              ((unsigned char)text[i + 3] & 0x3Fu);

        out.chars += 1;
        out.chars_utf16 += (codepoint > 0xFFFFu) ? 2 : 1;

        if (codepoint == '\n') {
            if (!saw_newline) {
                out.first_line_chars = current_line_chars;
            }
            saw_newline = true;
            if (current_line_chars > out.longest_row_chars) {
                out.longest_row_chars = current_line_chars;
                out.longest_row = row_base + out.lines.row;
            }
            out.lines.row += 1;
            current_line_chars = 0;
        } else {
            current_line_chars += 1;
        }

        i += cp_len;
    }

    if (!saw_newline) {
        out.first_line_chars = current_line_chars;
    }
    out.last_line_chars = current_line_chars;
    out.lines.col = (uint32_t)current_line_chars;

    if (current_line_chars > out.longest_row_chars || (out.lines.row == 0 && out.longest_row_chars == 0)) {
        out.longest_row_chars = current_line_chars;
        out.longest_row = row_base + out.lines.row;
    }

    return out;
}
