#include <config.h>
#include "rope_internal.h"

#include <stddef.h>

bool utf8_is_char_boundary(unsigned char byte) {
    return (byte & 0xC0u) != 0x80u;
}

size_t utf8_next_len(unsigned char first_byte) {
    if ((first_byte & 0x80u) == 0) {
        return 1;
    }
    if ((first_byte & 0xE0u) == 0xC0u) {
        return 2;
    }
    if ((first_byte & 0xF0u) == 0xE0u) {
        return 3;
    }
    if ((first_byte & 0xF8u) == 0xF0u) {
        return 4;
    }
    return 0;
}

static bool utf8_is_cont(unsigned char b) {
    return (b & 0xC0u) == 0x80u;
}

bool utf8_validate(const char *text, size_t len) {
    for (size_t i = 0; i < len;) {
        const unsigned char b = (unsigned char)text[i];
        const size_t n = utf8_next_len(b);
        if (n == 0 || i + n > len) {
            return false;
        }

        if (n == 1) {
            i += 1;
            continue;
        }

        for (size_t k = 1; k < n; ++k) {
            if (!utf8_is_cont((unsigned char)text[i + k])) {
                return false;
            }
        }

        if (n == 2) {
            const uint32_t cp = ((b & 0x1Fu) << 6u) | ((unsigned char)text[i + 1] & 0x3Fu);
            if (cp < 0x80u) {
                return false;
            }
        } else if (n == 3) {
            const uint32_t cp = ((b & 0x0Fu) << 12u) | (((unsigned char)text[i + 1] & 0x3Fu) << 6u) |
                                ((unsigned char)text[i + 2] & 0x3Fu);
            if (cp < 0x800u || (cp >= 0xD800u && cp <= 0xDFFFu)) {
                return false;
            }
        } else {
            const uint32_t cp = ((b & 0x07u) << 18u) | (((unsigned char)text[i + 1] & 0x3Fu) << 12u) |
                                (((unsigned char)text[i + 2] & 0x3Fu) << 6u) |
                                ((unsigned char)text[i + 3] & 0x3Fu);
            if (cp < 0x10000u || cp > 0x10FFFFu) {
                return false;
            }
        }

        i += n;
    }
    return true;
}

size_t utf8_count_chars(const char *text, size_t len) {
    size_t count = 0;
    for (size_t i = 0; i < len;) {
        const size_t n = utf8_next_len((unsigned char)text[i]);
        if (n == 0 || i + n > len) {
            break;
        }
        count += 1;
        i += n;
    }
    return count;
}

size_t utf8_count_utf16(const char *text, size_t len) {
    size_t count = 0;
    for (size_t i = 0; i < len;) {
        const unsigned char b = (unsigned char)text[i];
        const size_t n = utf8_next_len(b);
        if (n == 0 || i + n > len) {
            break;
        }
        if (n == 4) {
            count += 2;
        } else {
            count += 1;
        }
        i += n;
    }
    return count;
}
