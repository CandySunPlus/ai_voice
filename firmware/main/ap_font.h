#pragma once
#include "lvgl.h"
#include <stddef.h>
extern const lv_font_t ap_font_chinese;
// Any unsupported Unicode codepoint becomes visible [U+XXXX], never a blank box.
void ap_display_text(const char *utf8, char *out, size_t capacity);
