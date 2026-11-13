#include "ap_audio.h"
#include "ap_crypto.h"
#include "bsp_audio.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

static TaskHandle_t worker;
static atomic_bool run;
static atomic_int state;
static atomic_uint last_sequence;
static struct { ap_host host; uint8_t key[32], nonce[16]; uint32_t recording; } command;
static uint8_t packet[30 + 640 + 32];
static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void audio_task(void *unused) {
    (void)unused;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (!atomic_load_explicit(&run, memory_order_acquire)) {
            memset(&command, 0, sizeof command);
            atomic_store_explicit(&state, AP_AUDIO_FINISHED, memory_order_release); continue;
        }
        ap_audio_state result = AP_AUDIO_FINISHED;
        int fd = -1;
        // Codec is opened only inside a speak-authorized recording lifetime.
        if (bsp_audio_init() != ESP_OK || bsp_audio_wake() != ESP_OK ||
            bsp_audio_set_format(16000, 16, 1) != ESP_OK) {
            result = AP_AUDIO_ERROR; goto done;
        }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd < 0) { result = AP_AUDIO_ERROR; goto done; }
        struct timeval timeout = { .tv_usec = 100000 };
        if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout) < 0) { result = AP_AUDIO_ERROR; goto done; }
        struct sockaddr_in peer = { .sin_family = AF_INET, .sin_port = htons(command.host.port) };
        if (inet_pton(AF_INET, command.host.address, &peer.sin_addr) != 1) { result = AP_AUDIO_ERROR; goto done; }
        memcpy(packet, "APV1", 4); memcpy(packet + 4, command.nonce, 16);
        be32(packet + 20, command.recording); packet[28] = 1; packet[29] = 64; // 320 samples
        uint32_t sequence = 0;
        int64_t started = esp_timer_get_time();
        while (atomic_load_explicit(&run, memory_order_acquire)) {
            if (sequence == 6000 || esp_timer_get_time() - started >= 120000000) { result = AP_AUDIO_LIMIT; break; }
            if (bsp_audio_read(packet + 30, 640) != ESP_OK) { result = AP_AUDIO_ERROR; break; }
            if (!atomic_load_explicit(&run, memory_order_acquire)) break;
            be32(packet + 24, sequence + 1);
            ap_hmac(command.key, packet, 670, packet + 670);
            if (sendto(fd, packet, sizeof packet, 0, (struct sockaddr *)&peer, sizeof peer) != (ssize_t)sizeof packet) {
                result = AP_AUDIO_ERROR; break;
            }
            atomic_store_explicit(&last_sequence, ++sequence, memory_order_release);
        }
    done:
        if (fd >= 0) close(fd);
        if (bsp_audio_sleep() != ESP_OK) result = AP_AUDIO_ERROR;
        memset(packet, 0, sizeof packet); memset(&command, 0, sizeof command);
        atomic_store(&run, false);
        // Publish completion only after all old-session hardware and key accesses end.
        atomic_store_explicit(&state, result, memory_order_release);
    }
}
bool ap_audio_init(void) {
    if (worker) return true;
    atomic_store(&state, AP_AUDIO_IDLE);
    return xTaskCreate(audio_task, "passport_audio", 4096, NULL, 6, &worker) == pdPASS;
}
bool ap_audio_start(const ap_host *host, const uint8_t key[32], const uint8_t nonce[16], uint32_t recording) {
    if (!worker || atomic_load_explicit(&state, memory_order_acquire) == AP_AUDIO_RUNNING || !recording) return false;
    command.host = *host; memcpy(command.key, key, 32); memcpy(command.nonce, nonce, 16); command.recording = recording;
    atomic_store(&last_sequence, 0); atomic_store(&state, AP_AUDIO_RUNNING);
    atomic_store_explicit(&run, true, memory_order_release); xTaskNotifyGive(worker); return true;
}
void ap_audio_request_stop(void) { atomic_store_explicit(&run, false, memory_order_release); }
ap_audio_state ap_audio_status(uint32_t *last) {
    ap_audio_state s = atomic_load_explicit(&state, memory_order_acquire);
    if (last) *last = atomic_load_explicit(&last_sequence, memory_order_acquire);
    return s;
}
bool ap_audio_halt(uint32_t *last) {
    ap_audio_request_stop();
    int64_t deadline = esp_timer_get_time() + 350000;
    while (ap_audio_status(last) == AP_AUDIO_RUNNING && esp_timer_get_time() < deadline) vTaskDelay(pdMS_TO_TICKS(5));
    return ap_audio_status(last) != AP_AUDIO_RUNNING;
}
