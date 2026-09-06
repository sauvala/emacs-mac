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
    if (first_byte == 0xF8) {
        return 5;
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

        /* Emacs's internal encoding extends UTF-8: C0/C1 encode raw
           eight-bit characters, surrogates are allowed, and F0..F8
           cover character codes through 0x3fff7f (see character.h).  */
        uint32_t cp = b & (n == 2 ? 0x1f : n == 3 ? 0x0f : n == 4 ? 0x07 : 0);
        for (size_t k = 1; k < n; ++k)
            cp = (cp << 6) | ((unsigned char)text[i + k] & 0x3f);
        if ((n == 2 && b >= 0xc2 && cp < 0x80)
            || (n == 3 && cp < 0x800)
            || (n == 4 && cp < 0x10000)
            || (n == 5 && (cp < 0x200000 || cp > 0x3fff7f)))
            return false;

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
        if (n >= 4) {
            count += 2;
        } else {
            count += 1;
        }
        i += n;
    }
    return count;
}
