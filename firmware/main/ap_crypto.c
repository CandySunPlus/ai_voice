#include "ap_crypto.h"
#include "mbedtls/sha256.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
bool ap_hex_decode(const char *text, uint8_t *out, size_t n) {
    if (strlen(text) != n * 2) return false;
    for (size_t i = 0; i < n; ++i) {
        int a = nibble(text[i * 2]), b = nibble(text[i * 2 + 1]);
        if (a < 0 || b < 0) return false;
        out[i] = (uint8_t)((a << 4) | b);
    }
    return true;
}
void ap_hex_encode(const uint8_t *data, size_t n, char *out) {
    const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < n; ++i) { out[i * 2] = hex[data[i] >> 4]; out[i * 2 + 1] = hex[data[i] & 15]; }
    out[n * 2] = 0;
}
bool ap_constant_equal(const uint8_t *a, const uint8_t *b, size_t n) {
    volatile uint8_t difference = 0;
    for (size_t i = 0; i < n; ++i) difference |= a[i] ^ b[i];
    return difference == 0;
}
static void begin(mbedtls_sha256_context *ctx, const uint8_t key[32], uint8_t pad) {
    uint8_t block[64]; memset(block, pad, sizeof block);
    for (unsigned i = 0; i < 32; ++i) block[i] ^= key[i];
    mbedtls_sha256_init(ctx); mbedtls_sha256_starts(ctx, 0);
    mbedtls_sha256_update(ctx, block, sizeof block);
}
static void finish(mbedtls_sha256_context *ctx, const uint8_t key[32], uint8_t out[32]) {
    uint8_t inner[32]; mbedtls_sha256_finish(ctx, inner); mbedtls_sha256_free(ctx);
    begin(ctx, key, 0x5c); mbedtls_sha256_update(ctx, inner, sizeof inner);
    mbedtls_sha256_finish(ctx, out); mbedtls_sha256_free(ctx); memset(inner, 0, sizeof inner);
}
void ap_hmac(const uint8_t key[32], const void *bytes, size_t n, uint8_t out[32]) {
    mbedtls_sha256_context ctx; begin(&ctx, key, 0x36);
    mbedtls_sha256_update(&ctx, bytes, n); finish(&ctx, key, out);
}
void ap_control_mac(const uint8_t key[32], const char *session, uint32_t seq,
                    const char *kind, const char *body, uint8_t out[32]) {
    char number[11]; snprintf(number, sizeof number, "%" PRIu32, seq);
    const char *parts[] = { session, "|", number, "|", kind, "|", body };
    mbedtls_sha256_context ctx; begin(&ctx, key, 0x36);
    for (unsigned i = 0; i < sizeof parts / sizeof parts[0]; ++i)
        mbedtls_sha256_update(&ctx, (const uint8_t *)parts[i], strlen(parts[i]));
    finish(&ctx, key, out);
}
