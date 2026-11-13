#pragma once
#include "ap_config.h"
#include <stdbool.h>
#include <stdint.h>
typedef bool (*ap_link_message)(const char *kind, const ap_json *body, void *user);
// All link calls are serialized by the application owner; callback runs inline.
void ap_link_init(ap_link_message callback, void *user);
bool ap_link_open(const ap_host *host, const char device[33]);
void ap_link_close(void);
void ap_link_step(void);
bool ap_link_connected(void);
bool ap_link_authenticated(void);
bool ap_link_send(const char *kind, const char *json_body);
const uint8_t *ap_link_key(void);
const uint8_t *ap_link_nonce(void);
const char *ap_link_error(void);
// Escapes one UTF-8 JSON string including quotes; returns false on overflow.
bool ap_json_quote(const char *source, char *out, size_t capacity);
