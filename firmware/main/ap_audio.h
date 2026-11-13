#pragma once
#include "ap_config.h"
#include <stdbool.h>
#include <stdint.h>
typedef enum { AP_AUDIO_IDLE, AP_AUDIO_RUNNING, AP_AUDIO_FINISHED, AP_AUDIO_LIMIT, AP_AUDIO_ERROR } ap_audio_state;
bool ap_audio_init(void);
// Owner calls start only after authenticated speak; capture never runs before it.
bool ap_audio_start(const ap_host *host, const uint8_t key[32], const uint8_t nonce[16], uint32_t recording);
void ap_audio_request_stop(void);
ap_audio_state ap_audio_status(uint32_t *last);
// Bounded cooperative stop; false means worker still owns hardware and cannot restart.
bool ap_audio_halt(uint32_t *last);
