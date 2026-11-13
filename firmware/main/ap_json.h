#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { AP_OBJECT, AP_ARRAY, AP_STRING, AP_NUMBER, AP_TRUE, AP_FALSE, AP_NULL } ap_json_type;
typedef struct { uint16_t start, end, next, count; ap_json_type type; } ap_token;
typedef struct { const char *text; ap_token tokens[256]; unsigned count; } ap_json;
// Strict, bounded parser: max 8192 bytes, 256 tokens and eight nested containers.
bool ap_json_parse(ap_json *doc, const char *text, size_t length);
int ap_json_get(const ap_json *doc, int object, const char *name);
int ap_json_at(const ap_json *doc, int array, unsigned index);
bool ap_json_string(const ap_json *doc, int token, char *out, size_t capacity);
bool ap_json_u32(const ap_json *doc, int token, uint32_t *value);
bool ap_json_is(const ap_json *doc, int token, const char *value);
bool ap_utf8(const char *text, size_t length);
