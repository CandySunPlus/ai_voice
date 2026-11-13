#include "ap_config.h"
#include "ap_crypto.h"
#include "esp_random.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "nvs.h"
#include "nvs_flash.h"
#include <string.h>

static bool display_text(const char *s) {
    size_t n = strlen(s);
    if (!n || !ap_utf8(s, n)) return false;
    for (size_t i = 0; i < n; ++i) if ((unsigned char)s[i] < 32 || s[i] == 127) return false;
    return true;
}
static bool identifier(const char *s) {
    uint8_t raw[16];
    if (!ap_hex_decode(s, raw, sizeof raw)) return false;
    for (unsigned i = 0; i < 32; ++i) if (s[i] >= 'A' && s[i] <= 'F') return false;
    return true;
}
static bool address(const char *s) {
    struct in_addr ip;
    if (inet_pton(AF_INET, s, &ip) != 1) return false;
    uint32_t v = ntohl(ip.s_addr);
    // Specific usable unicast IPv4 only, never wildcard, loopback or multicast.
    return (v >> 24) != 0 && (v >> 24) != 127 && (v >> 24) < 224 && v != 0xffffffff;
}
static bool password(const char *s) {
    size_t n = strlen(s);
    if (!n) return true;
    if (n == 64) { uint8_t raw[32]; return ap_hex_decode(s, raw, sizeof raw); }
    if (n < 8 || n > 63) return false;
    for (size_t i = 0; i < n; ++i) if ((unsigned char)s[i] < 32 || (unsigned char)s[i] > 126) return false;
    return true;
}
static bool valid(const ap_config *c) {
    if (c->version != 1 || c->wifi_count > AP_NETWORKS || c->host_count > AP_HOSTS) return false;
    for (unsigned i = 0; i < c->wifi_count; ++i) {
        if (!memchr(c->wifi[i].ssid, 0, sizeof c->wifi[i].ssid) || !memchr(c->wifi[i].password, 0, sizeof c->wifi[i].password) ||
            !display_text(c->wifi[i].ssid) || !password(c->wifi[i].password)) return false;
        for (unsigned j = 0; j < i; ++j) if (!strcmp(c->wifi[i].ssid, c->wifi[j].ssid)) return false;
    }
    for (unsigned i = 0; i < c->host_count; ++i) {
        const ap_host *h = &c->hosts[i];
        if (!memchr(h->id, 0, sizeof h->id) || !memchr(h->name, 0, sizeof h->name) || !memchr(h->address, 0, sizeof h->address) ||
            !identifier(h->id) || !display_text(h->name) || !address(h->address) || h->port != 43821) return false;
        for (unsigned j = 0; j < i; ++j) if (!strcmp(h->id, c->hosts[j].id)) return false;
    }
    return true;
}
esp_err_t ap_config_load(ap_config *c, char device[33]) {
    esp_err_t e = nvs_flash_init();
    if (e != ESP_OK) return e; // Never erase unrelated NVS as a recovery shortcut.
    nvs_handle_t h;
    e = nvs_open("passport", NVS_READWRITE, &h);
    if (e != ESP_OK) return e;
    memset(c, 0, sizeof *c); c->version = 1;
    size_t n = 33;
    e = nvs_get_str(h, "device", device, &n);
    if (e == ESP_ERR_NVS_NOT_FOUND) {
        uint8_t random[16]; esp_fill_random(random, sizeof random); ap_hex_encode(random, sizeof random, device);
        e = nvs_set_str(h, "device", device);
        if (e == ESP_OK) e = nvs_commit(h);
    } else if (e == ESP_OK && !identifier(device)) e = ESP_ERR_INVALID_STATE;
    if (e == ESP_OK) {
        n = sizeof *c;
        e = nvs_get_blob(h, "config", c, &n);
        if (e == ESP_ERR_NVS_NOT_FOUND) { memset(c, 0, sizeof *c); c->version = 1; e = ESP_OK; }
        else if (e == ESP_OK && (n != sizeof *c || !valid(c))) e = ESP_ERR_INVALID_STATE;
    }
    nvs_close(h); return e;
}
esp_err_t ap_config_merge(ap_config *c, const ap_json *d) {
    ap_config next = *c;
    int networks = ap_json_get(d, 0, "wifi"), host = ap_json_get(d, 0, "host");
    if (networks < 0 || d->tokens[networks].type != AP_ARRAY || !d->tokens[networks].count ||
        d->tokens[networks].count > AP_NETWORKS || host < 0 || d->tokens[host].type != AP_OBJECT) return ESP_ERR_INVALID_ARG;
    for (unsigned i = 0; i < d->tokens[networks].count; ++i) {
        int item = ap_json_at(d, networks, i); ap_wifi w = {0};
        if (!ap_json_string(d, ap_json_get(d, item, "ssid"), w.ssid, sizeof w.ssid) ||
            !ap_json_string(d, ap_json_get(d, item, "password"), w.password, sizeof w.password) ||
            !display_text(w.ssid) || !password(w.password)) return ESP_ERR_INVALID_ARG;
        unsigned slot = 0;
        while (slot < next.wifi_count && strcmp(next.wifi[slot].ssid, w.ssid)) ++slot;
        if (slot == AP_NETWORKS) return ESP_ERR_INVALID_SIZE;
        if (slot == next.wifi_count) ++next.wifi_count;
        next.wifi[slot] = w;
    }
    ap_host h = {0}; char key[65]; uint32_t port;
    if (!ap_json_string(d, ap_json_get(d, host, "id"), h.id, sizeof h.id) ||
        !ap_json_string(d, ap_json_get(d, host, "name"), h.name, sizeof h.name) ||
        !ap_json_string(d, ap_json_get(d, host, "address"), h.address, sizeof h.address) ||
        !ap_json_string(d, ap_json_get(d, host, "key"), key, sizeof key) ||
        !ap_hex_decode(key, h.key, sizeof h.key) || !ap_json_u32(d, ap_json_get(d, host, "port"), &port) ||
        port != 43821 || !identifier(h.id) || !display_text(h.name) || !address(h.address)) {
        memset(key, 0, sizeof key); return ESP_ERR_INVALID_ARG;
    }
    memset(key, 0, sizeof key); h.port = port;
    unsigned slot = 0;
    while (slot < next.host_count && strcmp(next.hosts[slot].id, h.id)) ++slot;
    if (slot == AP_HOSTS) return ESP_ERR_INVALID_SIZE;
    if (slot == next.host_count) ++next.host_count;
    next.hosts[slot] = h;
    if (!valid(&next)) return ESP_ERR_INVALID_ARG;
    nvs_handle_t handle;
    esp_err_t e = nvs_open("passport", NVS_READWRITE, &handle);
    if (e == ESP_OK) {
        e = nvs_set_blob(handle, "config", &next, sizeof next);
        if (e == ESP_OK) e = nvs_commit(handle);
        nvs_close(handle);
    }
    if (e == ESP_OK) *c = next;
    memset(&next, 0, sizeof next); memset(&h, 0, sizeof h); return e;
}
esp_err_t ap_config_erase(ap_config *c) {
    nvs_handle_t handle;
    esp_err_t e = nvs_open("passport", NVS_READWRITE, &handle);
    if (e == ESP_OK) {
        e = nvs_erase_key(handle, "config");
        if (e == ESP_ERR_NVS_NOT_FOUND) e = ESP_OK;
        if (e == ESP_OK) e = nvs_commit(handle);
        nvs_close(handle);
    }
    if (e == ESP_OK) { memset(c, 0, sizeof *c); c->version = 1; }
    return e;
}
