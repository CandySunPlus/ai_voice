#include "ap_font.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
extern const uint8_t font_data[] asm("_binary_noto16_bin_start");
static bool glyph(const lv_font_t *font, lv_font_glyph_dsc_t *dsc, uint32_t cp, uint32_t next) {
    (void)font; (void)next;
    if (cp > 0xffff || font_data[cp * 33] == 0) return false;
    dsc->adv_w = font_data[cp * 33]; dsc->box_w = 16; dsc->box_h = 16;
    dsc->ofs_x = 0; dsc->ofs_y = 0; dsc->stride = 2;
    dsc->format = LV_FONT_GLYPH_FORMAT_A1; dsc->gid.index = cp;
    dsc->is_placeholder = 0;
    return true;
}
static const void *bitmap(lv_font_glyph_dsc_t *dsc, lv_draw_buf_t *buffer) {
    (void)buffer;
    const uint8_t *source = font_data + dsc->gid.index * 33 + 1;
    if (dsc->req_raw_bitmap) return source;
    // LVGL 9.5 expects A8 pixels unless its raw-bitmap path is requested.
    if (!buffer || !lv_draw_buf_reshape(buffer, LV_COLOR_FORMAT_A8, dsc->box_w, dsc->box_h, LV_STRIDE_AUTO)) return NULL;
    for (unsigned y = 0; y < dsc->box_h; ++y) {
        uint8_t *row = buffer->data + y * buffer->header.stride;
        for (unsigned x = 0; x < dsc->box_w; ++x)
            row[x] = source[y * dsc->stride + x / 8] & (0x80 >> (x & 7)) ? 255 : 0;
    }
    return buffer;
}
const lv_font_t ap_font_chinese = {
    .get_glyph_dsc = glyph, .get_glyph_bitmap = bitmap,
    .line_height = 18, .base_line = 0, .static_bitmap = 1,
    .underline_position = -1, .underline_thickness = 1
};
void ap_display_text(const char *s, char *out, size_t cap) {
    size_t used = 0;
    if (!cap) return;
    while (*s) {
        const unsigned char *p = (const unsigned char *)s;
        uint32_t cp = *p; size_t n = 1;
        if ((*p & 0xe0) == 0xc0) { cp = *p & 31; n = 2; }
        else if ((*p & 0xf0) == 0xe0) { cp = *p & 15; n = 3; }
        else if ((*p & 0xf8) == 0xf0) { cp = *p & 7; n = 4; }
        bool valid = true;
        for (size_t i = 1; i < n; ++i) {
            if (!p[i] || (p[i] & 0xc0) != 0x80) { valid = false; break; }
            cp = (cp << 6) | (p[i] & 63);
        }
        if (!valid) { cp = 0xfffd; n = 1; }
        if (cp == '\n') {
            if (used + 1 >= cap) break;
            out[used++] = '\n';
        } else if (cp >= 32 && cp <= 0xffff && font_data[cp * 33]) {
            if (used + n >= cap) break;
            memcpy(out + used, s, n); used += n;
        } else {
            char escape[16]; int length = snprintf(escape, sizeof escape, "[U+%04lX]", (unsigned long)cp);
            if (used + (size_t)length >= cap) break;
            memcpy(out + used, escape, length); used += length;
        }
        s += n;
    }
    if (*s && cap >= 4) {
        // Explicit truncation rather than silently omitting a title suffix.
        while (used > cap - 4) --used;
        while (used && ((unsigned char)out[used] & 0xc0) == 0x80) --used;
        memcpy(out + used, "...", 3); used += 3;
    }
    out[used] = 0;
}
