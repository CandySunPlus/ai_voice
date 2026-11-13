#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
bool ap_hex_decode(const char *text, uint8_t *out, size_t bytes);
void ap_hex_encode(const uint8_t *data, size_t bytes, char *out);
bool ap_constant_equal(const uint8_t *a, const uint8_t *b, size_t n);
void ap_hmac(const uint8_t key[32], const void *bytes, size_t n, uint8_t out[32]);
void ap_control_mac(const uint8_t key[32], const char *session, uint32_t sequence,
                    const char *kind, const char *body, uint8_t out[32]);
